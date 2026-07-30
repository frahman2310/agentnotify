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

# TERM_PROGRAM is inherited from the terminal the agent runs in → focus it on click.
bundle_for_term() {
  case "${TERM_PROGRAM:-}" in
    Apple_Terminal) echo com.apple.Terminal ;;
    iTerm.app)      echo com.googlecode.iterm2 ;;
    vscode)         echo com.microsoft.VSCode ;;
    Cursor)         echo com.todesktop.230313mzl4w4u92 ;;
    WarpTerminal)   echo dev.warp.Warp-Stable ;;
    ghostty)        echo com.mitchellh.ghostty ;;
    Hyper)          echo co.zeit.hyper ;;
    WezTerm)        echo com.github.wez.wezterm ;;
    *)              echo "" ;;
  esac
}

# Post silently and never fail the calling hook (some agents read our stdout/exit
# code as a permission decision — we must stay quiet and exit 0).
if command -v terminal-notifier >/dev/null 2>&1; then
  args=(-title "$title" -message "$msg" -sound default -group "agentnotify-$agent")
  bundle="$(bundle_for_term)"; [[ -n "$bundle" ]] && args+=(-activate "$bundle")
  terminal-notifier "${args[@]}" >/dev/null 2>&1 || true
else
  esc_msg=${msg//\\/\\\\};   esc_msg=${esc_msg//\"/\\\"}
  esc_title=${title//\\/\\\\}; esc_title=${esc_title//\"/\\\"}
  /usr/bin/osascript -e "display notification \"$esc_msg\" with title \"$esc_title\" sound name \"Ping\"" >/dev/null 2>&1 || true
fi
exit 0
