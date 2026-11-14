"""dq-advisor: internal service (called only by the .NET API) that profiles the data and proposes controls."""
from __future__ import annotations

import asyncio
import logging
import os

from fastapi import FastAPI, Header, HTTPException

from .models import SuggestRequest, SuggestResponse
from .profiler import Profiler, profiler_connection
from .providers import create_provider
from .service import generate

logging.basicConfig(level=logging.INFO, format='{"level":"%(levelname)s","logger":"%(name)s","message":"%(message)s"}')
log = logging.getLogger("dq-advisor")

app = FastAPI(title="dq-advisor", version="1.1.0")
provider = create_provider()
SERVICE_TOKEN = os.getenv("DQ_SERVICE_TOKEN", "dev-internal-token")
log.info("recommendation provider=%s llm=%s model=%s external=%s",
         provider.info.name, provider.info.is_llm, provider.info.model, provider.info.external)


@app.get("/health")
async def health():
    return {"status": "ok", "provider": provider.info.name, "model": provider.info.model, "llm": provider.info.is_llm}


def _profile(request: SuggestRequest):
    with profiler_connection() as conn:
        return Profiler(conn, request).profile_all()


@app.post("/internal/v1/suggestions", response_model=SuggestResponse)
async def suggest(request: SuggestRequest, x_service_token: str | None = Header(default=None)):
    if x_service_token != SERVICE_TOKEN:
        raise HTTPException(status_code=401, detail="invalid service token")
    try:
        profiles = await asyncio.to_thread(_profile, request)
    except Exception as ex:
        log.exception("profiling failed")
        raise HTTPException(status_code=503, detail="database unavailable for profiling") from ex
    return await generate(provider, request, profiles)
