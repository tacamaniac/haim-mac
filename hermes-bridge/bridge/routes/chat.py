"""
Chat endpoints — send a message and stream the response over SSE.

Flow:
  POST /chat/send
    → calls tui_gateway session.create (if session has no live state yet)
    → calls tui_gateway prompt.submit
    → returns {request_id, session_id, stream_url, status}

  GET /chat/stream/{request_id}
    → SSE stream; reads from the session's event queue
    → translates Hermes events → bridge SSE events
    → ends when assistant.completed / assistant.failed / cancelled

  POST /chat/cancel/{request_id}
    → calls tui_gateway session.interrupt
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
import uuid
from typing import AsyncGenerator

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import StreamingResponse

from bridge import hermes
from bridge.log import write_audit
from bridge.models import ChatRequest, RequestHandle

router = APIRouter()
logger = logging.getLogger(__name__)

# Map request_id → session_id for stream lookup
_request_to_session: dict[str, str] = {}
# Set of cancelled request_ids
_cancelled: set[str] = set()


# ── Send ──────────────────────────────────────────────────────────────

@router.post("/send", response_model=RequestHandle)
async def send(body: ChatRequest) -> RequestHandle:
    session_id = body.session_id

    # Ensure a live session exists (create one if missing from our registry).
    live = hermes.get_session(session_id)
    if live is None:
        live = await hermes.create_session(agent_id=body.agent_id)
        # Override session_id to match the newly created Hermes session
        session_id = live.bridge_session_id

    request_id = uuid.uuid4().hex
    _request_to_session[request_id] = session_id

    # Mark inflight
    done_event = asyncio.Event()
    live.active_request_id = request_id
    live.request_done[request_id] = done_event

    write_audit(
        "chat_request_started",
        request_id=request_id,
        session_id=session_id,
        agent_id=body.agent_id,
    )
    logger.info("chat request started", extra={
        "request_id": request_id,
        "session_id": session_id,
    })

    # prompt.submit is a long handler — gateway returns {status:"streaming"} inline
    # and continues in a pool thread.  We fire-and-forget via rpc().
    asyncio.create_task(
        _submit_prompt(session_id, body.message, request_id, done_event)
    )

    return RequestHandle(
        request_id=request_id,
        session_id=session_id,
        stream_url=f"/chat/stream/{request_id}",  # final path after router prefix
        status="pending",
    )


async def _submit_prompt(
    session_id: str, text: str, request_id: str, done_event: asyncio.Event
) -> None:
    try:
        await hermes.rpc(
            "prompt.submit",
            {"session_id": session_id, "text": text},
            session_id=session_id,
        )
    except Exception as exc:
        logger.error("prompt.submit error: %s", exc, extra={
            "request_id": request_id,
            "session_id": session_id,
        })
        # Inject a synthetic error event so the SSE consumer can close.
        live = hermes.get_session(session_id)
        if live:
            live.event_queue.put_nowait({
                "jsonrpc": "2.0",
                "method": "event",
                "params": {
                    "type": "error",
                    "session_id": session_id,
                    "payload": {"message": str(exc)},
                },
            })


# ── Stream ────────────────────────────────────────────────────────────

@router.get("/stream/{request_id}")
async def stream(request_id: str, request: Request) -> StreamingResponse:
    session_id = _request_to_session.get(request_id)
    if session_id is None:
        raise HTTPException(status_code=404, detail={"code": "STREAM_NOT_FOUND", "message": "Unknown request_id"})

    live = hermes.get_session(session_id)
    if live is None:
        raise HTTPException(status_code=404, detail={"code": "SESSION_NOT_FOUND", "message": "Session not found"})

    return StreamingResponse(
        _event_stream(request_id, session_id, live, request),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
        },
    )


async def _event_stream(
    request_id: str,
    session_id: str,
    live: hermes.LiveSession,
    request: Request,
) -> AsyncGenerator[str, None]:
    queue = live.event_queue
    started_at = time.time()

    yield _sse("request.started", {"request_id": request_id, "session_id": session_id})

    try:
        async for raw_event in _drain_queue(queue, request_id, session_id, request):
            sse_event, sse_data = _translate_event(raw_event, request_id)
            if sse_event is None:
                continue
            yield _sse(sse_event, sse_data)

            if sse_event in ("assistant.completed", "assistant.failed", "request.cancelled"):
                duration_ms = int((time.time() - started_at) * 1000)
                write_audit(
                    "chat_request_completed",
                    request_id=request_id,
                    session_id=session_id,
                    event=sse_event,
                    duration_ms=duration_ms,
                )
                break
    except asyncio.CancelledError:
        yield _sse("request.cancelled", {"request_id": request_id})
    finally:
        done = live.request_done.pop(request_id, None)
        if done:
            done.set()
        if live.active_request_id == request_id:
            live.active_request_id = None
        _request_to_session.pop(request_id, None)
        _cancelled.discard(request_id)

    yield _sse("request.completed", {"request_id": request_id})


async def _drain_queue(
    queue: asyncio.Queue,
    request_id: str,
    session_id: str,
    request: Request,
) -> AsyncGenerator[dict, None]:
    """Yield raw Hermes JSON-RPC event frames until the turn ends or client disconnects."""
    while True:
        if await request.is_disconnected():
            return

        if request_id in _cancelled:
            return

        try:
            frame = await asyncio.wait_for(queue.get(), timeout=15.0)
        except asyncio.TimeoutError:
            # Emit heartbeat to keep connection alive
            yield _heartbeat_frame()
            continue

        if frame is None:
            # Transport closed sentinel
            return

        # Only process event frames for this session; re-queue anything else.
        # (Multiple concurrent requests would need per-request queues; for v1
        #  we enforce one active stream at a time per session.)
        params = frame.get("params") or {}
        if frame.get("method") != "event":
            continue
        if params.get("session_id") not in (session_id, "", None):
            # Re-queue events for other sessions (shouldn't happen in v1)
            await queue.put(frame)
            continue

        yield frame

        # Stop consuming after terminal events
        event_type = params.get("type", "")
        if event_type in ("message.complete", "error"):
            return


def _heartbeat_frame() -> dict:
    return {
        "jsonrpc": "2.0",
        "method": "event",
        "params": {"type": "heartbeat", "session_id": ""},
    }


# ── Cancel ────────────────────────────────────────────────────────────

@router.post("/cancel/{request_id}", status_code=200)
async def cancel(request_id: str) -> dict:
    session_id = _request_to_session.get(request_id)
    if session_id is None:
        raise HTTPException(status_code=404, detail={"code": "STREAM_NOT_FOUND", "message": "Unknown request_id"})

    _cancelled.add(request_id)
    try:
        await hermes.rpc("session.interrupt", {"session_id": session_id}, session_id=session_id)
    except Exception as exc:
        logger.warning("session.interrupt failed: %s", exc)

    write_audit("chat_request_cancelled", request_id=request_id, session_id=session_id)
    return {"request_id": request_id, "status": "cancelled"}


# ── Event translation ─────────────────────────────────────────────────

def _translate_event(frame: dict, request_id: str) -> tuple[str | None, dict]:
    """Map a Hermes JSON-RPC event frame to a bridge SSE (event_name, data_dict)."""
    params = frame.get("params") or {}
    event_type = params.get("type", "")
    payload = params.get("payload") or {}

    mapping: dict[str, tuple[str, dict]] = {
        "message.start": ("assistant.started", {"request_id": request_id}),
        "message.complete": ("assistant.completed", {
            "request_id": request_id,
            "text": payload.get("text", ""),
            "status": payload.get("status", "complete"),
            "usage": payload.get("usage"),
        }),
        "error": ("assistant.failed", {
            "request_id": request_id,
            "message": payload.get("message", "Unknown error"),
        }),
        "tool.start": ("tool.started", {
            "request_id": request_id,
            "tool_id": payload.get("tool_id", ""),
            "name": payload.get("name", ""),
            "context": payload.get("context", ""),
        }),
        "tool.complete": ("tool.finished", {
            "request_id": request_id,
            "tool_id": payload.get("tool_id", ""),
            "name": payload.get("name", ""),
            "duration_s": payload.get("duration_s"),
            "summary": payload.get("summary", ""),
        }),
        "session.updated": ("session.updated", payload),
        "heartbeat": ("heartbeat", {}),
    }

    if event_type == "message.delta":
        return ("token.delta", {
            "request_id": request_id,
            "text": payload.get("text", ""),
        })

    if event_type in mapping:
        return mapping[event_type]

    # Pass through small metadata events; skip session.info (huge payload, not needed by Mac app).
    if event_type in ("thinking.delta", "reasoning.delta", "status.update",
                      "tool.progress", "tool.generating",
                      "approval.request", "review.summary"):
        return (event_type, {"request_id": request_id, **payload})

    return None, {}


# ── SSE formatting ────────────────────────────────────────────────────

def _sse(event: str, data: dict) -> str:
    return f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False, default=str)}\n\n"
