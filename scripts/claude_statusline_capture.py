#!/usr/bin/env python3
import json
import os
from pathlib import Path
import re
import sys
import time


def read_input():
    raw = sys.stdin.read()
    if not raw.strip():
        return {}
    return json.loads(raw)


def account_name():
    explicit = os.environ.get("AI_USAGE_CLAUDE_ACCOUNT", "").strip()
    if explicit:
        return explicit

    config_dir = os.environ.get("CLAUDE_CONFIG_DIR", "").strip()
    if config_dir:
        name = Path(config_dir).expanduser().name.strip()
        if name:
            return name

    return "default"


def safe_name(value):
    safe = re.sub(r"[^A-Za-z0-9._-]+", "-", value.strip())
    safe = safe.strip(".-")
    return (safe or "default")[:80]


def pick(source, key):
    value = source.get(key)
    return value if value is not None else None


def read_auth_snapshot():
    config_path = Path.home() / ".claude.json"
    try:
        data = json.loads(config_path.read_text(encoding="utf-8"))
    except Exception:
        return None

    oauth = data.get("oauthAccount")
    if not isinstance(oauth, dict):
        return None

    snapshot = {
        "email": pick(oauth, "emailAddress"),
        "organization_uuid": pick(oauth, "organizationUuid"),
        "organization_name": pick(oauth, "organizationName"),
    }
    return {key: value for key, value in snapshot.items() if value}


def write_snapshot(data, account):
    output_dir = Path.home() / ".ai-usage" / "claude-status"
    output_dir.mkdir(parents=True, exist_ok=True)

    snapshot = {
        "schema_version": 1,
        "captured_at": time.time(),
        "account": account,
        "auth": read_auth_snapshot(),
        "session_id": pick(data, "session_id"),
        "transcript_path": pick(data, "transcript_path"),
        "version": pick(data, "version"),
        "model": pick(data, "model"),
        "rate_limits": pick(data, "rate_limits"),
        "context_window": pick(data, "context_window"),
        "cost": pick(data, "cost"),
    }

    target = output_dir / f"{safe_name(account)}.json"
    temporary = output_dir / f".{target.name}.{os.getpid()}.tmp"
    temporary.write_text(
        json.dumps(snapshot, ensure_ascii=False, sort_keys=True, indent=2),
        encoding="utf-8",
    )
    temporary.replace(target)
    return snapshot


def percent_remaining(window):
    if not isinstance(window, dict):
        return None
    used = window.get("used_percentage")
    if used is None:
        return None
    try:
        return max(0, min(100, 100 - float(used)))
    except (TypeError, ValueError):
        return None


def statusline_text(snapshot):
    account = snapshot.get("account") or "Claude"
    title = "Claude" if account == "default" else f"Claude {account}"
    rate_limits = snapshot.get("rate_limits") or {}
    five_hour = percent_remaining(rate_limits.get("five_hour"))
    seven_day = percent_remaining(rate_limits.get("seven_day"))

    parts = [title]
    if five_hour is not None:
        parts.append(f"5h {five_hour:.0f}%")
    if seven_day is not None:
        parts.append(f"7d {seven_day:.0f}%")
    if len(parts) == 1:
        parts.append("syncing")
    return " | ".join(parts)


def main():
    try:
        data = read_input()
        account = account_name()
        snapshot = write_snapshot(data, account)
        print(statusline_text(snapshot))
    except Exception:
        # Claude Code status lines should never interrupt the interactive session.
        print("Claude syncing")


if __name__ == "__main__":
    main()
