"""
Hermes Bridge — FastAPI server on http://127.0.0.1:8765

Entry point. Run with:
    ./run.sh
or directly with a Python interpreter that has the bridge dependencies installed:
    python3 -m uvicorn main:app --host 127.0.0.1 --port 8765
"""

from __future__ import annotations

import logging
import os
import sys

# ── Configure logging BEFORE importing tui_gateway ───────────────────
# tui_gateway.server redirects sys.stdout → sys.stderr at import time.
# Set up our log handlers first so that redirect is harmless.
from bridge.log import setup_logging
setup_logging(level=os.environ.get("BRIDGE_LOG_LEVEL", "INFO"))

logger = logging.getLogger(__name__)

# ── FastAPI app ───────────────────────────────────────────────────────
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from bridge.routes.health import router as health_router
from bridge.routes.agents import router as agents_router
from bridge.routes.sessions import router as sessions_router
from bridge.routes.chat import router as chat_router

app = FastAPI(
    title="Hermes Bridge",
    description="Local bridge between the Hermes Mac app and the Hermes runtime.",
    version="0.1.0",
    docs_url="/docs",
    redoc_url=None,
)

# Allow the SwiftUI app (localhost origin) to hit the bridge.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost", "http://127.0.0.1"],
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(health_router)
app.include_router(agents_router)
app.include_router(sessions_router)
app.include_router(chat_router, prefix="/chat", tags=["chat"])


@app.on_event("startup")
async def _startup() -> None:
    # Warm up the tui_gateway import so the first request doesn't pay for it.
    from bridge.hermes import _ensure_gateway
    try:
        _ensure_gateway()
        logger.info("bridge startup complete", extra={"port": 8765})
    except Exception as exc:
        logger.error("tui_gateway load failed: %s", exc)


@app.on_event("shutdown")
async def _shutdown() -> None:
    from bridge import hermes as _hermes
    for sid in list(_hermes._sessions):
        _hermes.remove_session(sid)
    logger.info("bridge shutdown")
