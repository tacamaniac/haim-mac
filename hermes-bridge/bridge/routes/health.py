from __future__ import annotations

import asyncio
import logging
import os
import shutil

from fastapi import APIRouter

from bridge.models import HealthResponse

router = APIRouter()
logger = logging.getLogger(__name__)


@router.get("/health", response_model=HealthResponse)
async def health() -> HealthResponse:
    hermes_ok = await _check_hermes()
    return HealthResponse(
        status="ok" if hermes_ok else "degraded",
        hermes="ok" if hermes_ok else "unavailable",
        version=_bridge_version(),
    )


async def _check_hermes() -> bool:
    hermes_executable = _resolve_hermes_executable()
    if hermes_executable is None:
        return False

    try:
        proc = await asyncio.create_subprocess_exec(
            hermes_executable,
            "--version",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        await asyncio.wait_for(proc.wait(), timeout=3.0)
        return proc.returncode == 0
    except Exception:
        return False


def _resolve_hermes_executable() -> str | None:
    configured = os.environ.get("HERMES_CLI_PATH")
    if configured:
        expanded = os.path.expanduser(configured)
        if os.path.isfile(expanded) and os.access(expanded, os.X_OK):
            return expanded

    for candidate in (
        "/opt/homebrew/bin/hermes",
        "/usr/local/bin/hermes",
    ):
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate

    return shutil.which("hermes")


def _bridge_version() -> str:
    try:
        from hermes_cli import __version__
        return str(__version__)
    except Exception:
        return ""
