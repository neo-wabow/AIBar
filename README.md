# AIBar

Mac menu bar app for checking local Codex and Claude usage.

![AIBar screenshot](assets/screenshot.png)

## Build

```sh
scripts/build_app.sh
```

The app bundle is generated at:

```text
dist/AI 用量.app
```

## Data Sources

- Codex: `~/.codex/sessions/**/*.jsonl`, reading `token_count` events and rate-limit metadata. The app shows remaining quota as `100 - used_percent`.
- Claude official remaining: `~/.ai-usage/claude-status/*.json`, written by a Claude Code `statusLine` hook. It reads official `rate_limits.five_hour.used_percentage` and `rate_limits.seven_day.used_percentage`, then shows remaining quota as `100 - used_percentage`.
- Claude local fallback: `~/.claude/projects/**/*.jsonl`, reading assistant message `usage` fields and de-duplicating repeated message records.

Codex exposes current rate-limit percentage in local session logs.

Claude local logs expose token usage, but not official plan quota or reset percentage. Accurate Claude remaining quota requires the statusline hook.

## Claude Statusline Setup

Install the hook for the default Claude account:

```sh
scripts/install_claude_statusline.sh
```

For a second Claude account that uses a separate config directory:

```sh
CLAUDE_CONFIG_DIR="$HOME/.claude-work" scripts/install_claude_statusline.sh
```

To label accounts in the menu bar, launch Claude Code with `AI_USAGE_CLAUDE_ACCOUNT`:

```sh
AI_USAGE_CLAUDE_ACCOUNT=個人 claude
AI_USAGE_CLAUDE_ACCOUNT=工作 CLAUDE_CONFIG_DIR="$HOME/.claude-work" claude
```

Claude Code only sends `rate_limits` after the first API response in a session, so a new account card appears after sending one message.
