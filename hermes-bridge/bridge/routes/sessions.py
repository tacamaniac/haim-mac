from __future__ import annotations

import logging
import time

from fastapi import APIRouter, HTTPException

from bridge import hermes
from bridge.log import write_audit
from bridge.models import (
    CreateSessionRequest,
    CreateSessionResponse,
    Message,
    SessionSummary,
    SessionUsage,
)

router = APIRouter()
logger = logging.getLogger(__name__)


@router.get("/sessions", response_model=list[SessionSummary])
async def list_sessions() -> list[SessionSummary]:
    rows = await _run_sync(hermes.list_sessions_from_db)
    return [
        SessionSummary(
            id=r["id"],
            agent_id="callie",
            title=r.get("title") or "",
            preview=r.get("preview") or "",
            updated_at=r.get("last_active") or r.get("started_at") or 0.0,
            message_count=r.get("message_count") or 0,
        )
        for r in rows
    ]


@router.post("/sessions", response_model=CreateSessionResponse)
async def create_session(body: CreateSessionRequest) -> CreateSessionResponse:
    if body.resume_from:
        session = await hermes.resume_session(
            session_id=body.resume_from,
            agent_id=body.agent_id,
        )
    else:
        session = await hermes.create_session(agent_id=body.agent_id, title=body.title)

    write_audit(
        "session_created",
        session_id=session.bridge_session_id,
        agent_id=body.agent_id,
    )
    logger.info("session opened", extra={
        "session_id": session.bridge_session_id,
        "agent_id": body.agent_id,
    })

    return CreateSessionResponse(
        id=session.bridge_session_id,
        agent_id=session.agent_id,
        title=body.title or "",
        preview="",
        updated_at=session.created_at,
        message_count=0,
    )


@router.get("/sessions/{session_id}", response_model=CreateSessionResponse)
async def get_session(session_id: str) -> CreateSessionResponse:
    # Check live registry first (covers newly created sessions not yet in DB).
    live = hermes.get_session(session_id)
    if live:
        return CreateSessionResponse(
            id=live.bridge_session_id,
            agent_id=live.agent_id,
            title="",
            preview="",
            updated_at=live.created_at,
            message_count=0,
        )
    # Fall back to DB.
    rows = await _run_sync(hermes.list_sessions_from_db)
    row = next((r for r in rows if r["id"] == session_id), None)
    if not row:
        raise HTTPException(status_code=404, detail={"code": "SESSION_NOT_FOUND", "message": "Session not found"})
    return CreateSessionResponse(
        id=row["id"],
        agent_id="callie",
        title=row.get("title") or "",
        preview=row.get("preview") or "",
        updated_at=row.get("last_active") or row.get("started_at") or 0.0,
        message_count=row.get("message_count") or 0,
    )


@router.get("/sessions/{session_id}/messages", response_model=list[Message])
async def get_messages(session_id: str) -> list[Message]:
    msgs = await _run_sync(hermes.get_session_messages_from_db, session_id)
    return [
        Message(
            id=str(m["id"]),
            role=m["role"],
            content=m.get("content") or "",
            created_at=m.get("timestamp") or 0.0,
        )
        for m in msgs
        if m["role"] in ("user", "assistant")
    ]


@router.delete("/sessions/{session_id}", status_code=204)
async def delete_session(session_id: str) -> None:
    try:
        await hermes.rpc("session.delete", {"session_id": session_id}, session_id=session_id)
    except Exception as exc:
        logger.warning("session.delete rpc failed: %s", exc)
    hermes.remove_session(session_id)
    write_audit("session_deleted", session_id=session_id)


@router.get("/sessions/{session_id}/usage", response_model=SessionUsage)
async def get_session_usage(session_id: str) -> SessionUsage:
    usage = await hermes.rpc("session.usage", {"session_id": session_id}, session_id=session_id)
    return SessionUsage(**usage)


@router.post("/sessions/{session_id}/compress", response_model=SessionUsage)
async def compress_session(session_id: str) -> SessionUsage:
    await hermes.rpc_wait("session.compress", {"session_id": session_id}, session_id=session_id)
    usage = await hermes.rpc("session.usage", {"session_id": session_id}, session_id=session_id)
    return SessionUsage(**usage)


# ── Helpers ───────────────────────────────────────────────────────────

import asyncio


async def _run_sync(fn, *args):
    loop = asyncio.get_event_loop()
    return await loop.run_in_executor(None, fn, *args)
