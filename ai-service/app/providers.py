"""Recommendation provider abstraction.

    heuristic  - LocalHeuristicProvider: deterministic, metadata + statistics, no network. Default and fallback.
    openai     - OpenAICompatibleProvider: any OpenAI-compatible /chat/completions endpoint
                 (OpenAI, Azure OpenAI, a local Ollama / LM Studio / vLLM server at .../v1).
    vertex     - VertexGeminiProvider: Gemini on Vertex AI (GCP), Application Default Credentials.

Configuration is environment-only (no secrets in code):
    DQ_LLM_PROVIDER=heuristic|openai|vertex
    DQ_LLM_BASE_URL, DQ_LLM_MODEL, DQ_LLM_API_KEY, DQ_LLM_TIMEOUT_SECONDS      (openai)
    DQ_LLM_REASONING_EFFORT (optional, e.g. low - for reasoning models such as Gemini)
    DQ_LLM_CA_BUNDLE (optional PEM of extra trusted CAs, for TLS-inspecting networks)
    DQ_LLM_FALLBACK_MODELS (optional, comma-separated: tried when the main model is overloaded - HTTP 429/5xx)
    Tested live with Gemini through its OpenAI-compatible endpoint
    (DQ_LLM_BASE_URL=https://generativelanguage.googleapis.com/v1beta/openai) - see qa/run-llm-e2e.ps1.
    GOOGLE_CLOUD_PROJECT, GOOGLE_CLOUD_LOCATION, DQ_VERTEX_MODEL               (vertex)

Data minimisation: an LLM never receives table/column names or data rows - only business keys, Hebrew names,
types, relationships and aggregate statistics. For EXTERNAL endpoints, statistics of fields marked sensitive are
not sent at all.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import ssl
from dataclasses import dataclass
from typing import Optional, Protocol
from urllib.parse import urlparse

from .heuristics import heuristic_suggestions
from .models import EntityProfile, SuggestRequest


log = logging.getLogger("dq-advisor.providers")


class ProviderUnavailable(Exception):
    """The provider could not produce an answer now (not configured, timeout, HTTP error, unparsable output)."""


@dataclass(frozen=True)
class ProviderInfo:
    name: str                 # heuristic | openai | vertex
    is_llm: bool
    model: Optional[str] = None
    external: bool = False    # data leaves the machine


class RecommendationProvider(Protocol):
    info: ProviderInfo

    async def suggest(self, request: SuggestRequest, profiles: list[EntityProfile], feedback: Optional[str] = None) -> list[dict]: ...


class LocalHeuristicProvider:
    """Deterministic, evidence-driven recommendations. Never presented as LLM output."""
    info = ProviderInfo(name="heuristic", is_llm=False)

    async def suggest(self, request, profiles, feedback=None):
        return heuristic_suggestions(request, profiles)


# Backwards-compatible alias
HeuristicProvider = LocalHeuristicProvider


AST_GUIDE = """
Return ONLY JSON: {"suggestions": [ {"title", "explanationHe", "evidence", "severity", "definition"} ]}.
- title, explanationHe, evidence: Hebrew, business language, no technical names.
- evidence must reference the provided statistics (e.g. how many records violate). Do not invent numbers.
- severity: "Low" | "Medium" | "High".
- definition = Rule AST describing the VIOLATION (matching records are anomalies):
  {"schemaVersion":1,"rootEntity":"<entity key>","condition":<node>}
  node := {"type":"group","id":"g1","logic":"and|or","negate":false,"children":[node,...]}
        | {"type":"comparison","id":"c1","left":{"kind":"field","path":["fieldKey"] or ["relationKey","fieldKey"]},
           "operator":"eq|neq|gt|gte|lt|lte|between|in|notIn|contains|startsWith|endsWith|isEmpty|isNotEmpty",
           "right": {"kind":"value","value":...} | {"kind":"field","path":[...]} | {"kind":"values","values":[...]} | {"kind":"range","from":..,"to":..}}
        | {"type":"collection","id":"q1","relation":"<one-to-many relation key>","quantifier":"any|none|all","condition":<node, optional>}
  Inside a collection, {"kind":"field","scope":"root","path":[...]} refers to the parent record.
- isEmpty / isNotEmpty have no "right". Enum fields accept only the listed allowed values.
- Use ONLY the keys listed in the catalog. Paths may traverse only many-to-one relations.
- NEVER output SQL, table names or column names. Node ids must be unique within a suggestion.
"""

SYSTEM_PROMPT = ("You are a senior data-quality analyst. You design data-quality controls as a typed JSON rule AST. "
                 "You never write SQL. You answer with JSON only.")


def build_prompt(request: SuggestRequest, profiles: list[EntityProfile], feedback: Optional[str], external: bool) -> str:
    catalog = []
    for e in request.entities:
        catalog.append({
            "key": e.key, "name": e.displayNamePlural,
            "fields": [{"key": f.key, "name": f.displayName, "type": f.dataType, "requiredByBusiness": f.isRequiredByBusiness,
                        **({"allowedValues": [v.value for v in f.enumValues]} if f.enumValues else {})} for f in e.fields],
            "relations": [{"key": r.key, "name": r.displayName, "to": r.toEntity, "cardinality": r.cardinality} for r in e.relationships],
        })
    stats = []
    for p in profiles:
        e = request.entity(p.entity_key)
        fields = {}
        for key, fp in p.fields.items():
            f = e.field(key) if e else None
            if f is not None and f.isSensitive and external:
                continue  # sensitive statistics never leave the machine
            info = {"missingRatio": round((fp.nulls + fp.empties) / p.row_count, 4) if p.row_count else 0}
            if f is not None and not f.isSensitive:
                info.update({"distinct": fp.distinct, "min": fp.minimum, "max": fp.maximum, "highOutliers": fp.high_outliers})
            fields[key] = info
        stats.append({"entity": p.entity_key, "rows": p.row_count, "fields": fields,
                      "datePairsOutOfOrder": [d.model_dump() for d in p.date_pairs],
                      "linkedToInactive": [x.model_dump(exclude={"root_active_condition"}) for x in p.inactive_parents],
                      "childStartsBeforeParent": [x.model_dump() for x in p.child_before_parent],
                      "withoutChildren": [x.model_dump(exclude={"root_active_condition"}) for x in p.missing_children]})
    prompt = (
        f"Propose up to {request.maxSuggestions} data-quality controls for the business database described below, "
        "prioritising checks supported by the statistics.\n"
        f"{AST_GUIDE}\nCATALOG:\n{json.dumps(catalog, ensure_ascii=False)}\n"
        f"STATISTICS (aggregates only):\n{json.dumps(stats, ensure_ascii=False, default=str)}\n"
    )
    if feedback:
        prompt += f"\nYour previous answer had validation errors. Fix them and answer again:\n{feedback}\n"
    return prompt


def response_schema() -> dict:
    """JSON Schema for structured output (the strict AST check happens afterwards in Python and again in .NET)."""
    return {
        "type": "object",
        "properties": {"suggestions": {"type": "array", "items": {
            "type": "object",
            "properties": {"title": {"type": "string"}, "explanationHe": {"type": "string"}, "evidence": {"type": "string"},
                           "severity": {"type": "string", "enum": ["Low", "Medium", "High"]}, "definition": {"type": "object"}},
            "required": ["title", "explanationHe", "severity", "definition"]}}},
        "required": ["suggestions"],
    }


def parse_suggestions(content: str) -> list[dict]:
    """Extracts the suggestions array from model output (tolerates a ```json fence or text around the JSON)."""
    text = (content or "").strip()
    start, end = text.find("{"), text.rfind("}")
    if start >= 0 and end > start:
        text = text[start:end + 1]
    try:
        data = json.loads(text)
    except json.JSONDecodeError as ex:
        raise ProviderUnavailable(f"model returned non-JSON output: {ex}") from ex
    items = data.get("suggestions") if isinstance(data, dict) else data
    if not isinstance(items, list):
        raise ProviderUnavailable("model output has no 'suggestions' array")
    return [x for x in items if isinstance(x, dict)]


def _error_detail(response) -> str:
    """HTTP status + the provider's own error message (never request headers, so never the key)."""
    msg = ""
    try:
        body = response.json()
        err = body.get("error") if isinstance(body, dict) else None
        if isinstance(err, list) and err:
            err = err[0].get("error", err[0]) if isinstance(err[0], dict) else err[0]
        msg = (err.get("message") if isinstance(err, dict) else str(err or "")) or ""
    except ValueError:
        msg = response.text or ""
    return f"HTTP {response.status_code}" + (f": {msg.strip()[:200]}" if msg else "")


def _is_external(url: str) -> bool:
    host = (urlparse(url).hostname or "").lower()
    return host not in {"localhost", "127.0.0.1", "::1"}


def _tls_context() -> ssl.SSLContext:
    """TLS verification through the operating system's trust store (Windows CryptoAPI / macOS Keychain).
    Needed on networks with TLS inspection, whose root CA is trusted by Windows but not by
    Python's bundled CA list. Verification stays fully on - nothing is disabled.
    DQ_LLM_CA_BUNDLE (optional): a PEM file of trusted public CA certificates (e.g. exported from the Windows
    trust store by qa/run-llm-e2e.ps1) used in addition to the default CA list."""
    bundle = os.getenv("DQ_LLM_CA_BUNDLE")
    if bundle and os.path.isfile(bundle):
        ctx = ssl.create_default_context()
        ctx.load_verify_locations(cafile=bundle)
        return ctx
    try:
        import truststore  # type: ignore
    except ImportError:
        try:
            from pip._vendor import truststore  # type: ignore  # bundled with pip >= 24.2
        except Exception:
            return ssl.create_default_context()
    return truststore.SSLContext(ssl.PROTOCOL_TLS_CLIENT)


class OpenAICompatibleProvider:
    """Works with any server implementing POST {base}/chat/completions
    (OpenAI, Azure OpenAI, Gemini OpenAI-compatible endpoint, Ollama, LM Studio, vLLM)."""

    TRANSIENT = {429, 500, 502, 503, 504}

    def __init__(self, base_url: str, model: str, api_key: Optional[str], timeout_seconds: float = 60, transport=None,
                 reasoning_effort: Optional[str] = None, fallback_models: Optional[list[str]] = None,
                 retry_delays: tuple[float, ...] = (2.0, 5.0)):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.timeout = timeout_seconds
        self.transport = transport  # injectable for tests
        self.reasoning_effort = reasoning_effort
        self.fallback_models = [m for m in (fallback_models or []) if m and m != model]
        self.retry_delays = retry_delays
        self.used_model: Optional[str] = None
        self.info = ProviderInfo(name="openai", is_llm=True, model=model, external=_is_external(base_url))

    def _time_left(self) -> float:
        import time
        return self._deadline - time.monotonic()

    async def _call_model(self, client, model: str, messages: list, headers: dict):
        """One model: structured output first, looser modes on HTTP 400, retries with back-off on transient errors."""
        base = {"model": model, "messages": messages, "temperature": 0.2}
        if self.reasoning_effort:
            base["reasoning_effort"] = self.reasoning_effort
        formats = [{"type": "json_schema", "json_schema": {"name": "dq_suggestions", "schema": response_schema()}},
                   {"type": "json_object"},
                   None]
        r = None
        for attempt in range(len(self.retry_delays) + 1):
            for fmt in formats:
                body = dict(base, **({"response_format": fmt} if fmt else {}))
                r = await client.post(f"{self.base_url}/chat/completions", json=body, headers=headers)
                if r.status_code != 400:
                    break
            if r.status_code not in self.TRANSIENT or attempt == len(self.retry_delays):
                return r
            if self._time_left() < self.retry_delays[attempt] + 15:
                return r  # not enough of the overall budget left for another try
            log.info("LLM %s returned HTTP %d - retrying in %.0fs", model, r.status_code, self.retry_delays[attempt])
            await asyncio.sleep(self.retry_delays[attempt])
        return r

    async def suggest(self, request, profiles, feedback=None):
        import httpx  # imported lazily so the local provider has no network dependency

        messages = [{"role": "system", "content": SYSTEM_PROMPT},
                    {"role": "user", "content": build_prompt(request, profiles, feedback, self.info.external)}]
        headers = {"Authorization": f"Bearer {self.api_key}"} if self.api_key else {}
        import time
        # DQ_LLM_TIMEOUT_SECONDS is the budget for the WHOLE call (retries and backup models included),
        # so the local fallback always answers well within the API's own timeout.
        self._deadline = time.monotonic() + self.timeout
        try:
            async with httpx.AsyncClient(timeout=self.timeout, transport=self.transport, verify=_tls_context()) as client:
                r = None
                for model in [self.info.model] + self.fallback_models:
                    if r is not None and self._time_left() < 15:
                        break
                    r = await self._call_model(client, model, messages, headers)
                    if r.status_code < 400:
                        self.used_model = model
                        break
                    if r.status_code not in self.TRANSIENT:
                        break  # auth / request errors are not fixed by another model
                    log.warning("LLM model %s unavailable (%s) - trying the next configured model", model, _error_detail(r))
                if r.status_code >= 400:
                    raise ProviderUnavailable(f"LLM call failed: {_error_detail(r)}")
                content = r.json()["choices"][0]["message"]["content"]
        except httpx.TimeoutException as ex:
            raise ProviderUnavailable(f"LLM timeout after {self.timeout}s") from ex
        except httpx.HTTPError as ex:
            raise ProviderUnavailable(f"LLM call failed: {type(ex).__name__}: {str(ex)[:200]}") from ex
        except (KeyError, IndexError, TypeError, ValueError) as ex:
            raise ProviderUnavailable(f"LLM returned an unexpected response shape: {type(ex).__name__}") from ex
        return parse_suggestions(content)


class VertexGeminiProvider:
    """Gemini on Vertex AI. Requires `pip install google-genai`, GOOGLE_CLOUD_PROJECT and ADC. Not exercised live in this demo."""

    def __init__(self, project: Optional[str], location: str, model: str, timeout_seconds: float = 60):
        self.project, self.location, self.timeout = project, location, timeout_seconds
        self.info = ProviderInfo(name="vertex", is_llm=True, model=model, external=True)

    async def suggest(self, request, profiles, feedback=None):
        try:
            from google import genai  # type: ignore
        except ImportError as ex:
            raise ProviderUnavailable("google-genai is not installed") from ex
        if not self.project:
            raise ProviderUnavailable("GOOGLE_CLOUD_PROJECT is not set")

        def call():
            client = genai.Client(vertexai=True, project=self.project, location=self.location)
            resp = client.models.generate_content(
                model=self.info.model, contents=SYSTEM_PROMPT + "\n\n" + build_prompt(request, profiles, feedback, True),
                config={"response_mime_type": "application/json", "response_schema": response_schema(), "temperature": 0.2})
            return resp.text
        try:
            text = await asyncio.wait_for(asyncio.to_thread(call), timeout=self.timeout)
        except asyncio.TimeoutError as ex:
            raise ProviderUnavailable(f"Vertex AI timeout after {self.timeout}s") from ex
        except Exception as ex:  # the SDK raises many types; all mean "not available now"
            raise ProviderUnavailable(f"Vertex AI call failed: {type(ex).__name__}") from ex
        return parse_suggestions(text)


def create_provider(env: Optional[dict] = None) -> RecommendationProvider:
    """Selects the provider from configuration only. Misconfiguration degrades to the local provider."""
    env = env if env is not None else dict(os.environ)
    kind = env.get("DQ_LLM_PROVIDER", "heuristic").lower()
    timeout = float(env.get("DQ_LLM_TIMEOUT_SECONDS", "60"))
    if kind == "openai" and env.get("DQ_LLM_BASE_URL") and env.get("DQ_LLM_MODEL"):
        return OpenAICompatibleProvider(env["DQ_LLM_BASE_URL"], env["DQ_LLM_MODEL"], env.get("DQ_LLM_API_KEY"), timeout,
                                        reasoning_effort=env.get("DQ_LLM_REASONING_EFFORT") or None,
                                        fallback_models=[m.strip() for m in env.get("DQ_LLM_FALLBACK_MODELS", "").split(",") if m.strip()])
    if kind == "vertex":
        return VertexGeminiProvider(env.get("GOOGLE_CLOUD_PROJECT"), env.get("GOOGLE_CLOUD_LOCATION", "us-central1"),
                                    env.get("DQ_VERTEX_MODEL", "gemini-2.5-flash"), timeout)
    return LocalHeuristicProvider()
