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


def config_file_path():
    """The .claude.json that describes *this* session's account.

    Claude Code keeps a config dir's account record inside that dir; only the
    default account's lives at ~/.claude.json. Reading the home copy for every
    account made each snapshot claim the default account's identity, which is
    exactly the signal AIBar uses to notice that a dir changed hands.
    """
    config_dir = os.environ.get("CLAUDE_CONFIG_DIR", "").strip()
    if config_dir:
        return Path(config_dir).expanduser() / ".claude.json"
    return Path.home() / ".claude.json"


def read_auth_snapshot():
    config_path = config_file_path()
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
        "effort": pick(data, "effort"),
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


def model_display(snapshot):
    model = snapshot.get("model")
    if not isinstance(model, dict):
        return None
    return pick(model, "display_name") or pick(model, "id")


def effort_display(snapshot):
    effort = snapshot.get("effort")
    if not isinstance(effort, dict):
        return None
    return pick(effort, "level")


ANSI_RESET = "\033[0m"
ANSI_RED = "\033[31m"
ANSI_YELLOW = "\033[33m"
ANSI_GREEN = "\033[32m"
ANSI_BLUE = "\033[34m"
ANSI_MAGENTA = "\033[35m"
ANSI_CYAN = "\033[36m"

# 剩餘上下文百分比的變色門檻
CTX_RED_BELOW = 15
CTX_YELLOW_BELOW = 30

# 模型家族配色（比對顯示名稱關鍵字，不分大小寫）
MODEL_COLORS = (
    ("opus", ANSI_MAGENTA),
    ("sonnet", ANSI_CYAN),
    ("haiku", ANSI_GREEN),
    ("fable", ANSI_BLUE),
)

# effort 由低到高遞進配色
EFFORT_COLORS = {
    "low": ANSI_GREEN,
    "medium": ANSI_CYAN,
    "high": ANSI_YELLOW,
    "xhigh": ANSI_MAGENTA,
    "max": ANSI_RED,
}


def colorize(text, color):
    return f"{color}{text}{ANSI_RESET}" if color else text


def model_color(name):
    low = name.lower()
    for keyword, color in MODEL_COLORS:
        if keyword in low:
            return color
    return ""


def context_display(snapshot):
    window = snapshot.get("context_window")
    if not isinstance(window, dict):
        return None

    remaining_pct = window.get("remaining_percentage")
    if remaining_pct is None:
        used = window.get("used_percentage")
        if used is not None:
            try:
                remaining_pct = 100 - float(used)
            except (TypeError, ValueError):
                remaining_pct = None

    if remaining_pct is None:
        return None
    try:
        pct = float(remaining_pct)
    except (TypeError, ValueError):
        return None

    if pct < CTX_RED_BELOW:
        color = ANSI_RED
    elif pct < CTX_YELLOW_BELOW:
        color = ANSI_YELLOW
    else:
        color = ANSI_GREEN

    return f"{color}ctx {pct:.0f}%{ANSI_RESET}"


def statusline_text(snapshot):
    account = snapshot.get("account") or "Claude"
    title = "Claude" if account == "default" else f"Claude {account}"
    model_name = model_display(snapshot)
    effort = effort_display(snapshot)
    context = context_display(snapshot)
    rate_limits = snapshot.get("rate_limits") or {}
    five_hour = percent_remaining(rate_limits.get("five_hour"))
    seven_day = percent_remaining(rate_limits.get("seven_day"))

    parts = [title]
    if model_name:
        parts.append(colorize(model_name, model_color(model_name)))
    if effort:
        parts.append(colorize(f"effort {effort}", EFFORT_COLORS.get(effort.lower(), "")))
    if context:
        parts.append(context)
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
