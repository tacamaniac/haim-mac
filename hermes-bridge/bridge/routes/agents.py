from __future__ import annotations

from fastapi import APIRouter
from bridge import hermes
from bridge.models import Agent

router = APIRouter()


@router.get("/agents", response_model=list[Agent])
async def list_agents() -> list[Agent]:
    return [Agent(**a) for a in hermes.get_agents()]
