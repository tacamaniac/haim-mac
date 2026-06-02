"""
Hermes integration layer.

Wraps tui_gateway.server.dispatch() with bridge-friendly helpers and
maintains the active session registry (session_id → live state).

Import is deferred to first use so the tui_gateway stdout redirect and
env loading happen after the logging subsystem is configured.
"""

from __future__ import annotations

import asyncio
import logging
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Optional

logger = logging.getLogger(__name__)

# ── Lazy gateway import ───────────────────────────────────────────────
# tui_gateway.server redirects sys.stdout → sys.stderr at import time and
# loads Hermes env vars.  We defer until _ensure_gateway() is called so
# logging is configured first.

_gateway: Any = None
_gateway_ready = False


def _ensure_gateway() -> Any:
    global _gateway, _gateway_ready
    if _gateway_ready:
        return _gateway
    import tui_gateway.server as gw
    _gateway = gw
    _gateway_ready = True
    logger.info("tui_gateway loaded", extra={"hermes_home": str(gw._hermes_home)})
    return _gateway


# ── Active session state ──────────────────────────────────────────────

@dataclass
class LiveSession:
    """Bridge-side state for one active conversation."""
    bridge_session_id: str          # same as Hermes TUI session_id
    agent_id: str
    transport: Any                  # AsyncQueueTransport
    event_queue: asyncio.Queue
    created_at: float = field(default_factory=time.time)
    active_request_id: Optional[str] = None
    request_done: dict[str, asyncio.Event] = field(default_factory=dict)
    # Personality prompt applied to this session's agent (if any).
    personality_prompt: Optional[str] = None


_sessions: dict[str, LiveSession] = {}


# ── Session management ────────────────────────────────────────────────

async def resume_session(session_id: str, agent_id: str) -> LiveSession:
    """Resume an existing Hermes session from DB into a new live TUI session."""
    from bridge.transport import make_transport

    gw = _ensure_gateway()
    loop = asyncio.get_event_loop()
    transport, queue = make_transport(loop)

    rid = uuid.uuid4().hex[:8]
    req = {
        "jsonrpc": "2.0", "id": rid,
        "method": "session.resume",
        "params": {"session_id": session_id, "cols": 120},
    }

    # session.resume is a LONG_HANDLER: dispatch() returns None and writes the
    # JSON-RPC response back via the transport when the pool worker finishes.
    await asyncio.get_event_loop().run_in_executor(
        None, lambda: gw.dispatch(req, transport=transport)
    )

    # Drain queue until the matching response frame arrives (up to 90 s).
    # Discard any event frames emitted during agent build (session.info etc.).
    new_sid: Optional[str] = None
    loop_time = asyncio.get_event_loop().time
    deadline = loop_time() + 90.0
    while loop_time() < deadline:
        try:
            frame = await asyncio.wait_for(queue.get(), timeout=5.0)
        except asyncio.TimeoutError:
            continue
        if frame is None:
            break
        if frame.get("id") == rid:
            if "error" in frame:
                raise RuntimeError(f"session.resume: {frame['error'].get('message', frame['error'])}")
            new_sid = frame["result"]["session_id"]
            break
        # Drop event frames emitted during build — the SSE stream for this
        # session hasn't been established yet so they would never be read.

    if not new_sid:
        raise RuntimeError("session.resume: timed out waiting for response")

    # Resolve and apply personality (agent is already built after resume).
    personality_key = _AGENT_PERSONALITY_MAP.get(agent_id)
    personalities = _load_hermes_personalities() if personality_key else {}
    personality_prompt = personalities.get(personality_key) if personality_key else None

    if personality_prompt:
        tui_session = gw._sessions.get(new_sid)
        if tui_session and tui_session.get("agent"):
            tui_session["agent"].ephemeral_system_prompt = personality_prompt

    session = LiveSession(
        bridge_session_id=new_sid,
        agent_id=agent_id,
        transport=transport,
        event_queue=queue,
        personality_prompt=personality_prompt,
    )
    _sessions[new_sid] = session
    _sessions[session_id] = session
    logger.info("session resumed", extra={
        "original_id": session_id, "tui_id": new_sid, "agent_id": agent_id,
        "personality": personality_key or "default",
    })
    return session


async def create_session(agent_id: str, title: Optional[str] = None) -> LiveSession:
    """Create a new Hermes TUI session and return the bridge LiveSession."""
    from bridge.transport import make_transport

    gw = _ensure_gateway()
    loop = asyncio.get_event_loop()
    transport, queue = make_transport(loop)

    rid = uuid.uuid4().hex[:8]
    req = {"jsonrpc": "2.0", "id": rid, "method": "session.create", "params": {"cols": 120}}

    resp = await asyncio.get_event_loop().run_in_executor(
        None, lambda: gw.dispatch(req, transport=transport)
    )

    if resp is None:
        raise RuntimeError("session.create: no response from gateway")
    if "error" in resp:
        raise RuntimeError(f"session.create failed: {resp['error']}")

    hermes_sid = resp["result"]["session_id"]

    # Resolve personality for this agent and schedule deferred application
    # (agent build is async; we inject the prompt once it's ready).
    personality_key = _AGENT_PERSONALITY_MAP.get(agent_id)
    personalities = _load_hermes_personalities() if personality_key else {}
    personality_prompt = personalities.get(personality_key) if personality_key else None

    session = LiveSession(
        bridge_session_id=hermes_sid,
        agent_id=agent_id,
        transport=transport,
        event_queue=queue,
        personality_prompt=personality_prompt,
    )
    _sessions[hermes_sid] = session

    if personality_prompt:
        asyncio.create_task(_apply_personality_when_ready(hermes_sid, personality_prompt))

    logger.info("session created", extra={
        "session_id": hermes_sid, "agent_id": agent_id,
        "personality": personality_key or "default",
    })
    return session


def get_session(session_id: str) -> Optional[LiveSession]:
    return _sessions.get(session_id)


def remove_session(session_id: str) -> None:
    session = _sessions.pop(session_id, None)
    if session:
        session.transport.close()


# ── RPC helpers ───────────────────────────────────────────────────────

async def rpc(method: str, params: dict, session_id: Optional[str] = None) -> dict:
    """Issue a JSON-RPC call through the gateway dispatcher.

    Uses the session's transport if session_id is provided, so events
    produced by the call route to the right queue.
    """
    gw = _ensure_gateway()
    transport = None
    if session_id:
        sess = _sessions.get(session_id)
        if sess:
            transport = sess.transport

    rid = uuid.uuid4().hex[:8]
    req = {"jsonrpc": "2.0", "id": rid, "method": method, "params": params}

    resp = await asyncio.get_event_loop().run_in_executor(
        None, lambda: gw.dispatch(req, transport=transport)
    )

    if resp is None:
        # Long handler dispatched to pool; no inline response.
        return {}
    if "error" in resp:
        raise RuntimeError(f"{method} error {resp['error']}")
    return resp.get("result", {})


async def rpc_wait(method: str, params: dict, session_id: str, timeout: float = 300.0) -> dict:
    """Issue a long-running session RPC and await its transport response."""
    gw = _ensure_gateway()
    session = _sessions.get(session_id)
    if not session:
        raise RuntimeError(f"{method}: session not found")

    rid = uuid.uuid4().hex[:8]
    req = {"jsonrpc": "2.0", "id": rid, "method": method, "params": params}
    await asyncio.get_event_loop().run_in_executor(
        None, lambda: gw.dispatch(req, transport=session.transport)
    )

    deferred = []
    try:
        while True:
            frame = await asyncio.wait_for(session.event_queue.get(), timeout=timeout)
            if frame is None:
                raise RuntimeError(f"{method}: session closed")
            if frame.get("id") == rid:
                if "error" in frame:
                    raise RuntimeError(frame["error"].get("message", str(frame["error"])))
                return frame.get("result", {})
            deferred.append(frame)
    finally:
        for frame in deferred:
            session.event_queue.put_nowait(frame)


# ── Session history from DB ───────────────────────────────────────────

def list_sessions_from_db(limit: int = 50) -> list[dict]:
    """Read session summaries directly from Hermes SessionDB."""
    try:
        from hermes_state import SessionDB
        db = SessionDB()
        rows = db.list_sessions_rich(
            exclude_sources=["tool"],
            limit=limit,
            order_by_last_active=True,
        )
        return rows
    except Exception as exc:
        logger.warning("SessionDB list failed: %s", exc)
        return []


def get_session_messages_from_db(session_id: str) -> list[dict]:
    """Read full message history from Hermes SessionDB."""
    try:
        from hermes_state import SessionDB
        db = SessionDB()
        return db.get_messages(session_id)
    except Exception as exc:
        logger.warning("SessionDB get_messages failed: %s", exc)
        return []


# ── Personality helpers ───────────────────────────────────────────────

# Maps named agents → Hermes personality keys (None = default, no overlay).
_AGENT_PERSONALITY_MAP: dict[str, Optional[str]] = {
    "callie": None,
    "lyra":   "creative",
    "piper":  "concise",
    "sage":   "teacher",
    "vivian": "helpful",
    "zero":   "technical",
}


def _load_hermes_personalities() -> dict[str, str]:
    """Return {name: system_prompt} for configured Hermes personalities."""
    try:
        import yaml
        from hermes_constants import get_hermes_home
        cfg_path = get_hermes_home() / "config.yaml"
        if not cfg_path.exists():
            return {}
        with open(cfg_path, encoding="utf-8") as f:
            cfg = yaml.safe_load(f) or {}
        raw = (cfg.get("agent") or {}).get("personalities") or {}
        result = {}
        for name, val in raw.items():
            if isinstance(val, str):
                result[name] = val
            elif isinstance(val, dict):
                parts = [val.get("system_prompt", "")]
                if val.get("tone"):
                    parts.append(f"Tone: {val['tone']}")
                if val.get("style"):
                    parts.append(f"Style: {val['style']}")
                result[name] = "\n".join(p for p in parts if p)
        return result
    except Exception as exc:
        logger.warning("could not load Hermes personalities: %s", exc)
        return {}


async def _apply_personality_when_ready(new_sid: str, personality_prompt: str) -> None:
    """Background task: wait for the agent to finish building, then inject personality."""
    gw = _ensure_gateway()
    loop = asyncio.get_event_loop()

    def _wait_and_apply() -> None:
        tui_session = gw._sessions.get(new_sid)
        if not tui_session:
            return
        ready = tui_session.get("agent_ready")
        if ready is not None:
            ready.wait(timeout=60.0)
        agent = tui_session.get("agent")
        if agent is not None:
            agent.ephemeral_system_prompt = personality_prompt
            logger.info("personality applied", extra={"session_id": new_sid})

    await loop.run_in_executor(None, _wait_and_apply)


# ── Agent catalogue ───────────────────────────────────────────────────

_AGENT_CATALOGUE = [
    {
        "id": "callie",
        "display_name": "Callie",
        "profile": "callie",
        "role": "coordinator",
        "description": "Front desk and main coordinator. Balanced, friendly default.",
    },
    {
        "id": "lyra",
        "display_name": "Lyra",
        "profile": "lyra",
        "role": "specialist",
        "description": "Creative thinker. Innovative ideas and outside-the-box solutions.",
    },
    {
        "id": "piper",
        "display_name": "Piper",
        "profile": "piper",
        "role": "specialist",
        "description": "Straight to the point. Brief, direct, no fluff.",
    },
    {
        "id": "sage",
        "display_name": "Sage",
        "profile": "sage",
        "role": "specialist",
        "description": "Patient teacher. Clear explanations with examples.",
    },
    {
        "id": "vivian",
        "display_name": "Vivian",
        "profile": "vivian",
        "role": "specialist",
        "description": "Warm and helpful. Friendly, supportive assistant.",
    },
    {
        "id": "zero",
        "display_name": "Zero",
        "profile": "zero",
        "role": "specialist",
        "description": "Technical expert. Detailed, precise, deep-dive answers.",
    },
]


def get_agents() -> list[dict]:
    """Return the agent catalogue with availability based on Hermes personalities config."""
    personalities = _load_hermes_personalities()
    result = []
    for a in _AGENT_CATALOGUE:
        personality_key = _AGENT_PERSONALITY_MAP.get(a["id"])
        available = (personality_key is None) or (personality_key in personalities)
        result.append({**a, "available": available, "personality": personality_key})
    return result
