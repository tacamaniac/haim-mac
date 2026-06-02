"""
Structured JSON logging for the Hermes bridge.

Log files:
  ~/Library/Logs/HermesMac/bridge.log      — rotating JSON lines
  ~/Library/Application Support/HermesMac/events.jsonl — durable audit trail
"""

from __future__ import annotations

import json
import logging
import logging.handlers
import os
import time
from pathlib import Path
from typing import Any


# ── Paths ─────────────────────────────────────────────────────────────

_LOG_DIR = Path.home() / "Library" / "Logs" / "HermesMac"
_AUDIT_DIR = Path.home() / "Library" / "Application Support" / "HermesMac"
BRIDGE_LOG = _LOG_DIR / "bridge.log"
EVENTS_LOG = _AUDIT_DIR / "events.jsonl"


# ── JSON formatter ────────────────────────────────────────────────────

class _JSONFormatter(logging.Formatter):
    SERVICE = "hermes-bridge"

    def format(self, record: logging.LogRecord) -> str:
        entry: dict[str, Any] = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(record.created)),
            "level": record.levelname.lower(),
            "service": self.SERVICE,
            "logger": record.name,
            "msg": record.getMessage(),
        }
        if record.exc_info:
            entry["exc"] = self.formatException(record.exc_info)
        extra_keys = {
            k: v for k, v in record.__dict__.items()
            if k not in logging.LogRecord.__dict__ and not k.startswith("_")
            and k not in {"message", "asctime", "exc_text", "stack_info",
                          "taskName", "levelno", "pathname", "filename",
                          "module", "lineno", "funcName", "created",
                          "msecs", "relativeCreated", "thread", "threadName",
                          "processName", "process", "name", "msg", "args",
                          "exc_info", "levelname"}
        }
        entry.update(extra_keys)
        return json.dumps(entry, ensure_ascii=False, default=str)


# ── Audit writer ──────────────────────────────────────────────────────

def write_audit(event_type: str, **fields: Any) -> None:
    """Append one JSON line to the durable audit log."""
    entry = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "service": "hermes-bridge",
        "event": event_type,
        **fields,
    }
    try:
        with open(EVENTS_LOG, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False, default=str) + "\n")
    except Exception:
        pass


# ── Setup ─────────────────────────────────────────────────────────────

def setup_logging(level: str = "INFO") -> None:
    """Configure root logger with rotating JSON file + stderr handlers."""
    _LOG_DIR.mkdir(parents=True, exist_ok=True)
    _AUDIT_DIR.mkdir(parents=True, exist_ok=True)

    root = logging.getLogger()
    root.setLevel(getattr(logging, level.upper(), logging.INFO))

    fmt = _JSONFormatter()

    # Rotating file: 10 MB × 5 backups
    fh = logging.handlers.RotatingFileHandler(
        BRIDGE_LOG, maxBytes=10 * 1024 * 1024, backupCount=5, encoding="utf-8"
    )
    fh.setFormatter(fmt)
    root.addHandler(fh)

    # Stderr (uvicorn picks this up)
    sh = logging.StreamHandler()
    sh.setFormatter(fmt)
    root.addHandler(sh)

    # Quiet noisy third-party loggers
    for noisy in ("uvicorn.access", "asyncio"):
        logging.getLogger(noisy).setLevel(logging.WARNING)
