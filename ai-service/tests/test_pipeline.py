"""Pipeline tests: fallback, invalid LLM output, repair round, source tagging, data minimisation, configuration."""
import asyncio
import json

import pytest

from app.models import SuggestRequest
from app.providers import (LocalHeuristicProvider, OpenAICompatibleProvider, ProviderInfo, ProviderUnavailable,
                           build_prompt, create_provider, parse_suggestions)
from app.service import generate
from tests.test_advisor import CATALOG, profile

VALID = {"title": "אימייל חסר", "explanationHe": "הסבר", "evidence": "3 רשומות", "severity": "Low",
         "definition": {"schemaVersion": 1, "rootEntity": "employee",
                        "condition": {"type": "comparison", "id": "c1", "left": {"kind": "field", "path": ["email"]}, "operator": "isEmpty"}}}
MALICIOUS = {**VALID, "definition": {**VALID["definition"], "sql": "DROP TABLE biz.Employees"}}
HALLUCINATED = {**VALID, "definition": {"schemaVersion": 1, "rootEntity": "employee",
                                        "condition": {"type": "comparison", "id": "c1", "left": {"kind": "field", "path": ["bonus"]}, "operator": "isEmpty"}}}


class FakeLlm:
    def __init__(self, *answers):
        self.answers = list(answers)
        self.calls = []
        self.info = ProviderInfo(name="fake-llm", is_llm=True, model="fake-1")

    async def suggest(self, request, profiles, feedback=None):
        self.calls.append(feedback)
        answer = self.answers.pop(0)
        if isinstance(answer, Exception):
            raise answer
        return answer


def run(coro):
    return asyncio.run(coro)


def req():
    return SuggestRequest.model_validate(CATALOG)


def test_valid_llm_output_is_tagged_as_llm():
    res = run(generate(FakeLlm([VALID]), req(), [profile()]))
    assert res.provider == "fake-llm" and res.model == "fake-1" and not res.fallbackUsed
    assert [s["source"] for s in res.suggestions] == ["llm"]


def test_invalid_output_triggers_one_repair_round_with_feedback():
    llm = FakeLlm([MALICIOUS, HALLUCINATED], [VALID])
    res = run(generate(llm, req(), [profile()]))
    assert len(llm.calls) == 2 and llm.calls[1] and "bonus" in llm.calls[1]
    assert len(res.suggestions) == 1 and not res.fallbackUsed


def test_sql_smuggling_and_hallucinated_keys_never_pass():
    res = run(generate(FakeLlm([MALICIOUS, HALLUCINATED], [MALICIOUS]), req(), [profile()]))
    # nothing valid from the LLM -> local fallback, and the bad items are gone
    assert res.fallbackUsed and res.provider == "heuristic"
    assert all(s["source"] == "local" for s in res.suggestions)
    assert all("sql" not in json.dumps(s["definition"]) for s in res.suggestions)


def test_provider_failure_falls_back_to_local_analysis():
    res = run(generate(FakeLlm(ProviderUnavailable("LLM timeout after 60s")), req(), [profile()]))
    assert res.fallbackUsed and res.fallbackReason == "LLM timeout after 60s"
    assert res.suggestions and all(s["source"] == "local" for s in res.suggestions)


def test_local_provider_is_never_presented_as_llm():
    res = run(generate(LocalHeuristicProvider(), req(), [profile()]))
    assert res.provider == "heuristic" and res.model is None and not res.fallbackUsed
    assert all(s["source"] == "local" for s in res.suggestions)


def test_external_prompt_omits_sensitive_statistics_and_physical_names():
    prompt = build_prompt(req(), [profile()], None, external=True)
    stats = prompt.split("STATISTICS")[1]
    assert '"salary"' not in stats            # sensitive field statistics stay local
    assert "Employees" not in prompt and "biz" not in prompt  # no physical names
    local_stats = build_prompt(req(), [profile()], None, external=False).split("STATISTICS")[1]
    assert '"salary"' in local_stats and '"min"' not in local_stats.split('"salary"')[1][:60]


def test_parse_suggestions_handles_fences_and_rejects_garbage():
    assert parse_suggestions('```json\n{"suggestions":[{"title":"x"}]}\n```') == [{"title": "x"}]
    with pytest.raises(ProviderUnavailable):
        parse_suggestions("I think you should check salaries")


def test_configuration_selects_provider_without_secrets_in_code():
    assert isinstance(create_provider({}), LocalHeuristicProvider)
    assert isinstance(create_provider({"DQ_LLM_PROVIDER": "openai"}), LocalHeuristicProvider)  # incomplete config -> local
    p = create_provider({"DQ_LLM_PROVIDER": "openai", "DQ_LLM_BASE_URL": "http://localhost:11434/v1", "DQ_LLM_MODEL": "qwen2.5:7b"})
    assert isinstance(p, OpenAICompatibleProvider) and p.info.is_llm and not p.info.external
    p = create_provider({"DQ_LLM_PROVIDER": "openai", "DQ_LLM_BASE_URL": "https://api.openai.com/v1", "DQ_LLM_MODEL": "gpt-4o-mini", "DQ_LLM_API_KEY": "k"})
    assert p.info.external


def test_openai_compatible_adapter_sends_structured_output_request_and_parses_answer():
    httpx = pytest.importorskip("httpx")
    seen = {}

    def handler(request):
        seen["body"] = json.loads(request.content)
        seen["auth"] = request.headers.get("authorization")
        content = json.dumps({"suggestions": [VALID]}, ensure_ascii=False)
        return httpx.Response(200, json={"choices": [{"message": {"content": content}}]})

    p = OpenAICompatibleProvider("https://llm.example/v1", "model-x", "secret", 5, transport=httpx.MockTransport(handler))
    out = run(p.suggest(req(), [profile()]))
    assert out[0]["title"] == VALID["title"]
    assert seen["body"]["response_format"]["type"] == "json_schema"
    assert seen["auth"] == "Bearer secret"


def test_openai_compatible_adapter_maps_http_errors_to_provider_unavailable():
    httpx = pytest.importorskip("httpx")
    p = OpenAICompatibleProvider("https://llm.example/v1", "m", None, 5,
                                 transport=httpx.MockTransport(lambda r: httpx.Response(500, json={"error": "x"})))
    with pytest.raises(ProviderUnavailable):
        run(p.suggest(req(), [profile()]))


def test_openai_adapter_degrades_response_format_on_400_and_reports_provider_error_without_key():
    httpx = pytest.importorskip("httpx")
    formats = []

    def handler(request):
        body = json.loads(request.content)
        formats.append((body.get("response_format") or {}).get("type"))
        if len(formats) < 3:
            return httpx.Response(400, json={"error": {"message": "response_format not supported"}})
        content = "Here you go:\n" + json.dumps({"suggestions": [VALID]}, ensure_ascii=False)
        return httpx.Response(200, json={"choices": [{"message": {"content": content}}]})

    p = OpenAICompatibleProvider("https://llm.example/v1", "m", "secret-key", 5, transport=httpx.MockTransport(handler),
                                 reasoning_effort="low")
    out = run(p.suggest(req(), [profile()]))
    assert formats == ["json_schema", "json_object", None]
    assert out[0]["title"] == VALID["title"]

    bad = OpenAICompatibleProvider("https://llm.example/v1", "m", "secret-key", 5, transport=httpx.MockTransport(
        lambda r: httpx.Response(401, json={"error": {"message": "API key not valid"}})))
    with pytest.raises(ProviderUnavailable) as ex:
        run(bad.suggest(req(), [profile()]))
    assert "HTTP 401" in str(ex.value) and "API key not valid" in str(ex.value) and "secret-key" not in str(ex.value)


def test_parse_suggestions_tolerates_text_around_json():
    assert parse_suggestions('Sure!\n```json\n{"suggestions": []}\n```') == []


def test_openai_adapter_retries_overloaded_model_then_switches_to_fallback_model():
    httpx = pytest.importorskip("httpx")
    calls = []

    def handler(request):
        body = json.loads(request.content)
        calls.append(body["model"])
        if body["model"] == "busy-model":
            return httpx.Response(503, json={"error": {"message": "The model is overloaded"}})
        content = json.dumps({"suggestions": [VALID]}, ensure_ascii=False)
        return httpx.Response(200, json={"choices": [{"message": {"content": content}}]})

    p = OpenAICompatibleProvider("https://llm.example/v1", "busy-model", "k", 60, transport=httpx.MockTransport(handler),
                                 fallback_models=["backup-model"], retry_delays=(0, 0))
    out = run(p.suggest(req(), [profile()]))
    assert calls == ["busy-model", "busy-model", "busy-model", "backup-model"]
    assert p.used_model == "backup-model" and out[0]["title"] == VALID["title"]


def test_openai_adapter_respects_overall_time_budget():
    httpx = pytest.importorskip("httpx")
    calls = []

    def handler(request):
        calls.append(json.loads(request.content)["model"])
        return httpx.Response(503, json={"error": {"message": "overloaded"}})

    p = OpenAICompatibleProvider("https://llm.example/v1", "m1", "k", 10, transport=httpx.MockTransport(handler),
                                 fallback_models=["m2", "m3"], retry_delays=(0, 0))
    with pytest.raises(ProviderUnavailable):
        run(p.suggest(req(), [profile()]))
    assert calls == ["m1"]  # a 10s budget leaves no room for retries or backup models -> fast local fallback
