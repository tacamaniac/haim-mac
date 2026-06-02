#!/bin/bash
# Start the Hermes bridge on 127.0.0.1:8765
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

resolve_python() {
  if [[ -n "${HERMES_BRIDGE_PYTHON:-}" ]] && [[ -x "${HERMES_BRIDGE_PYTHON}" ]]; then
    printf '%s' "${HERMES_BRIDGE_PYTHON}"
    return 0
  fi

  for candidate in \
    /opt/homebrew/bin/python3.11 \
    /opt/homebrew/bin/python3 \
    /usr/local/bin/python3 \
    /usr/bin/python3
  do
    if [[ -x "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done

  if command -v python3 >/dev/null 2>&1; then
    command -v python3
    return 0
  fi

  echo "Could not find a usable python3 interpreter. Set HERMES_BRIDGE_PYTHON." >&2
  return 1
}

PYTHON="$(resolve_python)"
PORT="${BRIDGE_PORT:-8765}"
LOG_LEVEL="${BRIDGE_LOG_LEVEL:-info}"

exec "$PYTHON" -m uvicorn main:app \
    --host 127.0.0.1 \
    --port "$PORT" \
    --log-level "$LOG_LEVEL" \
    --no-access-log
