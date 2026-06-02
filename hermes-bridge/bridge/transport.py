"""
AsyncQueueTransport — routes tui_gateway events into an asyncio.Queue.

write() is called from tui_gateway pool threads; it marshals onto the event
loop with call_soon_threadsafe so the async SSE consumer can await queue.get().
"""

from __future__ import annotations

import asyncio
import json
import logging
from typing import Optional

logger = logging.getLogger(__name__)


class AsyncQueueTransport:
    """Drop-in tui_gateway Transport that feeds an asyncio.Queue."""

    def __init__(self, queue: asyncio.Queue, loop: asyncio.AbstractEventLoop) -> None:
        self._queue = queue
        self._loop = loop
        self._closed = False

    # ── Transport protocol ────────────────────────────────────────────

    def write(self, obj: dict) -> bool:
        if self._closed:
            return False
        try:
            # Safe to call from any thread: schedules put_nowait on the loop.
            self._loop.call_soon_threadsafe(self._queue.put_nowait, obj)
            return True
        except RuntimeError:
            # Loop is closed or not running.
            return False
        except Exception as exc:
            logger.warning("AsyncQueueTransport.write error: %s", exc)
            return False

    def close(self) -> None:
        self._closed = True
        # Sentinel so consumers can detect shutdown.
        try:
            self._loop.call_soon_threadsafe(self._queue.put_nowait, None)
        except Exception:
            pass


def make_transport(loop: Optional[asyncio.AbstractEventLoop] = None) -> tuple[AsyncQueueTransport, asyncio.Queue]:
    """Create a (transport, queue) pair bound to *loop* (defaults to running loop)."""
    if loop is None:
        loop = asyncio.get_event_loop()
    q: asyncio.Queue = asyncio.Queue()
    return AsyncQueueTransport(q, loop), q
