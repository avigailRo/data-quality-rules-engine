"""Recommendation pipeline: provider -> strict validation -> (one repair round) -> fallback -> source tagging.

Kept free of FastAPI and database code so it can be unit-tested in isolation.
"""
from __future__ import annotations

import logging
import time
from typing import Optional

from .models import EntityProfile, SuggestRequest, SuggestResponse
from .providers import LocalHeuristicProvider, ProviderUnavailable, RecommendationProvider
from .validation import validate_suggestion

log = logging.getLogger("dq-advisor.pipeline")


def validate_all(raw: list, request: SuggestRequest) -> tuple[list[dict], list[str]]:
    ok, errors = [], []
    for i, item in enumerate(raw if isinstance(raw, list) else []):
        s, errs = validate_suggestion(item, request) if isinstance(item, dict) else (None, ["not an object"])
        if s is None:
            errors.extend(f"suggestion {i}: {e}" for e in errs)
        else:
            ok.append(s.model_dump(by_alias=True, exclude_none=True))
    return ok, errors


async def generate(provider: RecommendationProvider, request: SuggestRequest, profiles: list[EntityProfile],
                   fallback: Optional[RecommendationProvider] = None) -> SuggestResponse:
    fallback = fallback or LocalHeuristicProvider()
    started = time.perf_counter()
    used, fallback_reason = provider, None
    accepted: list[dict] = []
    rejected = 0

    try:
        raw = await provider.suggest(request, profiles)
        accepted, errors = validate_all(raw, request)
        if errors and provider.info.is_llm:
            log.info("repair round: %d validation errors", len(errors))
            raw = await provider.suggest(request, profiles, feedback="\n".join(errors[:20]))
            accepted, errors = validate_all(raw, request)
        rejected = len(errors)
        if provider.info.is_llm and not accepted:
            fallback_reason = "ה־LLM לא החזיר אף הצעה תקינה"
    except ProviderUnavailable as ex:
        fallback_reason = str(ex)
        log.warning("provider %s unavailable: %s", provider.info.name, ex)

    if fallback_reason is not None:
        used = fallback
        accepted, _ = validate_all(await fallback.suggest(request, profiles), request)

    source = "llm" if used.info.is_llm else "local"
    for s in accepted:
        s["source"] = source

    log.info("suggestions provider=%s model=%s accepted=%d rejected=%d fallback=%s duration_ms=%d",
             used.info.name, used.info.model, len(accepted), rejected, fallback_reason is not None,
             int((time.perf_counter() - started) * 1000))

    model = getattr(used, "used_model", None) or used.info.model
    return SuggestResponse(provider=used.info.name, model=model, fallbackUsed=fallback_reason is not None,
                           fallbackReason=fallback_reason, rejectedCount=rejected,
                           suggestions=accepted[: request.maxSuggestions])
