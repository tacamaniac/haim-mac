"""Pydantic request/response models for the bridge API."""

from __future__ import annotations

from typing import Any, Optional
from pydantic import BaseModel


# ── Canonical entities ────────────────────────────────────────────────

class Agent(BaseModel):
    id: str
    display_name: str
    profile: str
    role: str
    description: str
    available: bool = True
    personality: Optional[str] = None  # mapped Hermes personality key


class SessionSummary(BaseModel):
    id: str
    agent_id: str
    title: str
    preview: str
    updated_at: float
    message_count: int


class Message(BaseModel):
    id: str
    role: str
    content: Any
    created_at: float
    metadata: Optional[dict] = None


class ChatRequest(BaseModel):
    session_id: str
    agent_id: str = "callie"
    message: str
    stream: bool = True


class RequestHandle(BaseModel):
    request_id: str
    session_id: str
    stream_url: str
    status: str


# ── Endpoint request/response shapes ─────────────────────────────────

class CreateSessionRequest(BaseModel):
    agent_id: str = "callie"
    title: Optional[str] = None
    resume_from: Optional[str] = None  # existing Hermes session ID to resume


class CreateSessionResponse(BaseModel):
    id: str
    agent_id: str
    title: str
    preview: str
    updated_at: float
    message_count: int


class SessionUsage(BaseModel):
    model: str = ""
    context_used: int = 0
    context_max: int = 0
    context_percent: int = 0
    compressions: int = 0


class HealthResponse(BaseModel):
    status: str
    hermes: str
    version: str = ""


class ErrorResponse(BaseModel):
    code: str
    message: str
