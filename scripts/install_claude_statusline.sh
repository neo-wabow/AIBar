#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS_FILE="$CONFIG_DIR/settings.json"
INSTALL_DIR="$HOME/.ai-usage/bin"
STATUS_DIR="$HOME/.ai-usage/claude-status"
CAPTURE_SCRIPT="$INSTALL_DIR/claude_statusline_capture.py"

mkdir -p "$CONFIG_DIR" "$INSTALL_DIR" "$STATUS_DIR"
cp "$ROOT_DIR/scripts/claude_statusline_capture.py" "$CAPTURE_SCRIPT"
chmod +x "$CAPTURE_SCRIPT"

if [[ -f "$SETTINGS_FILE" ]]; then
  BACKUP_FILE="$HOME/.ai-usage/claude-settings.backup.$(date +%Y%m%d-%H%M%S).json"
  cp "$SETTINGS_FILE" "$BACKUP_FILE"
  echo "Backed up existing settings to $BACKUP_FILE"
fi

python3 - "$SETTINGS_FILE" "$CAPTURE_SCRIPT" <<'PY'
import json
import os
import sys
from pathlib import Path

settings_path = Path(sys.argv[1])
capture_script = Path(sys.argv[2])

if settings_path.exists() and settings_path.read_text(encoding="utf-8").strip():
    with settings_path.open("r", encoding="utf-8") as handle:
        settings = json.load(handle)
else:
    settings = {}

if not isinstance(settings, dict):
    raise SystemExit(f"{settings_path} must contain a JSON object")

settings["statusLine"] = {
    "type": "command",
    "command": str(capture_script),
    "padding": 1,
    "refreshInterval": 15,
}

temporary = settings_path.with_suffix(settings_path.suffix + ".tmp")
with temporary.open("w", encoding="utf-8") as handle:
    json.dump(settings, handle, ensure_ascii=False, indent=2, sort_keys=True)
    handle.write("\n")
os.replace(temporary, settings_path)
PY

echo "Installed Claude Code statusline hook in $SETTINGS_FILE"
echo "Status snapshots will be written to $STATUS_DIR"
