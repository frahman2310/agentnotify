#!/usr/bin/env bash
# agentnotify (macOS/Linux) — pop a native notification when any AI coding agent
# needs you (approval / your turn). Agent-agnostic: called by each agent's hook.
#
#   Claude / Gemini / Cursor : pipe event JSON on stdin
#   Codex                    : passes event JSON as the final argv
#   Aider                    : no payload — generic message
#
#   ./notify.sh --agent "Codex" --json '{"last-assistant-message":"done"}'
#   echo '<json>' | ./notify.sh --agent "Claude Code"
#   ./notify.sh --test
set -euo pipefail

agent="AI agent"; json=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent) agent="${2:-AI agent}"; shift 2 ;;
    --json)  json="${2:-}";          shift 2 ;;
    --test)  json='{"message":"needs your permission to run: git push origin main","cwd":"'"$PWD"'"}'; shift ;;
    *)       json="$1";              shift ;;   # bare positional = Codex-style JSON arg
  esac
done
# No JSON from args? Read it from stdin (Claude/Gemini/Cursor pipe it in).
[[ -z "$json" && ! -t 0 ]] && json="$(cat)"
[[ -z "$json" ]] && json='{}'

get() { jq -r "$1 // empty" <<<"$json" 2>/dev/null || true; }
msg="$(get '.message')"
[[ -z "$msg" ]] && msg="$(get '.notification.message')"
[[ -z "$msg" ]] && msg="$(get '.["last-assistant-message"]')"
[[ -z "$msg" ]] && msg="$(get '.prompt')"
[[ -z "$msg" ]] && { c="$(get '.command')"; c="${c:-$(get '.tool_input.command')}"; [[ -n "$c" ]] && msg="about to run: $c"; }
[[ -z "$msg" ]] && msg="needs your attention"
msg="${msg//$'\n'/ }"; msg="${msg:0:200}"          # one line, keep it short

cwd="$(get '.cwd')"; proj="${cwd:+ · $(basename "$cwd")}"
title="${agent}${proj}"

# osascript posts as a pre-authorized system app, so it displays reliably on modern
# macOS (terminal-notifier is silently dropped on Tahoe unless authorized). Stay quiet
# and exit 0 — some agents read our stdout/exit code as a permission decision.
em=${msg//\\/\\\\};   em=${em//\"/\\\"}
et=${title//\\/\\\\}; et=${et//\"/\\\"}
/usr/bin/osascript -e "display notification \"$em\" with title \"$et\" sound name \"Ping\"" >/dev/null 2>&1 || true
exit 0
