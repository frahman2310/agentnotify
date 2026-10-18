#!/usr/bin/env bash
# agentnotify (macOS/Linux) — pop a native notification when any AI coding agent
# needs you (approval / your turn) or finishes its work. Agent-agnostic: called by each hook.
#
#   --agent NAME            which agent (for the title)
#   --event attention       (default) needs-you / permission alert — always fires
#   --event complete        work-finished alert — fires ONLY for approved projects
#   Claude / Gemini / Cursor : pipe event JSON on stdin
#   Codex                    : passes event JSON as the final argv
#   Aider                    : no payload — generic message
#
#   echo '<json>' | ./notify.sh --agent "Claude Code" --event complete
#   ./notify.sh --test
set -euo pipefail

agent="AI agent"; json=""; event="attention"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent) agent="${2:-AI agent}"; shift 2 ;;
    --event) event="${2:-attention}"; shift 2 ;;
    --json)  json="${2:-}";          shift 2 ;;
    --test)  json='{"message":"needs your permission to run: git push origin main","cwd":"'"$PWD"'"}'; shift ;;
    *)       json="$1";              shift ;;   # bare positional = Codex-style JSON arg
  esac
done
# No JSON from args? Read it from stdin (Claude/Gemini/Cursor pipe it in).
[[ -z "$json" && ! -t 0 ]] && json="$(cat)"
[[ -z "$json" ]] && json='{}'

get() { jq -r "$1 // empty" <<<"$json" 2>/dev/null || true; }

# The hook's cwd (fallback to the process cwd, which is the project dir the agent ran in).
cwd="$(get '.cwd')"; [[ -z "$cwd" ]] && cwd="$PWD"
proj="$(basename "$cwd" 2>/dev/null || true)"

# "Work completed" notifications fire ONLY for approved projects (curate with approved.sh).
APPROVED="${AGENTNOTIFY_APPROVED:-$HOME/.agentnotify/approved}"
is_approved() { # <dir>
  local dir="$1" line; [[ -f "$APPROVED" ]] || return 1
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    case "$line" in
      *\**) [[ "$dir" == $line ]] && return 0 ;;                      # glob pattern
      *)    [[ "$dir" == "$line" || "$dir" == "$line"/* ]] && return 0 ;;  # dir or anything under it
    esac
  done < "$APPROVED"
  return 1
}

if [[ "$event" == complete ]]; then
  if ! is_approved "$cwd"; then
    [[ -n "${AGENTNOTIFY_DRYRUN:-}" ]] && echo "SILENT (not approved): $cwd"
    exit 0                              # unapproved chat → stay silent
  fi
  msg="$(get '.["last-assistant-message"]')"
  [[ -z "$msg" ]] && msg="$(get '.message')"
  [[ -z "$msg" ]] && msg="finished — your turn"
  title="✅ ${agent} done${proj:+ · $proj}"
  sound="Glass"
else
  msg="$(get '.message')"
  [[ -z "$msg" ]] && msg="$(get '.notification.message')"
  [[ -z "$msg" ]] && msg="$(get '.["last-assistant-message"]')"
  [[ -z "$msg" ]] && msg="$(get '.prompt')"
  [[ -z "$msg" ]] && { c="$(get '.command')"; c="${c:-$(get '.tool_input.command')}"; [[ -n "$c" ]] && msg="about to run: $c"; }
  [[ -z "$msg" ]] && msg="needs your attention"
  title="${agent}${proj:+ · $proj}"
  sound="Ping"
fi
msg="${msg//$'\n'/ }"; msg="${msg:0:200}"          # one line, keep it short

# osascript posts as a pre-authorized system app, so it displays reliably on modern macOS
# (terminal-notifier is silently dropped on Tahoe). Stay quiet and exit 0 — some agents read
# our stdout/exit code as a decision.
if [[ -n "${AGENTNOTIFY_DRYRUN:-}" ]]; then echo "FIRE [$event/$sound] $title :: $msg"; exit 0; fi
em=${msg//\\/\\\\};   em=${em//\"/\\\"}
et=${title//\\/\\\\}; et=${et//\"/\\\"}
/usr/bin/osascript -e "display notification \"$em\" with title \"$et\" sound name \"$sound\"" >/dev/null 2>&1 || true
exit 0
