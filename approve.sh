#!/usr/bin/env bash
# agentnotify approve (macOS) — Claude Code PreToolUse approver.
# Pops an Approve / Decline dialog OVER whatever app you're in and returns the
# decision to Claude Code, so you approve without switching to the terminal.
#
# Reads PreToolUse JSON on stdin; prints a PreToolUse permission decision on stdout.
# Approve → allow · Decline → deny · Open Terminal / timeout / Esc → defer to
# Claude's normal in-terminal prompt (never auto-approves on error).
#
# Test without a real dialog:  AGENTNOTIFY_MOCK_CHOICE=Approve ./approve.sh < payload.json
set -euo pipefail

payload="$(cat 2>/dev/null || true)"
get() { jq -r "$1 // empty" <<<"$payload" 2>/dev/null || true; }

tool="$(get '.tool_name')"; tool="${tool:-a tool}"
cwd="$(get '.cwd')"; proj="${cwd:+$(basename "$cwd")}"
detail="$(get '.tool_input.command')"
[[ -z "$detail" ]] && detail="$(get '.tool_input.file_path')"
[[ -z "$detail" ]] && detail="$(get '.tool_input.path')"
summary="$tool"; [[ -n "$detail" ]] && summary="$tool — $detail"
summary="${summary//$'\n'/ }"; summary="${summary:0:300}"
msg="Claude${proj:+ · $proj} wants to use: $summary"

allow() { printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"Approved via AgentNotify"}}\n'; exit 0; }
deny()  { printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Declined via AgentNotify"}}\n';  exit 0; }
defer() { exit 0; }   # no stdout → Claude falls back to its normal permission prompt

focus_terminal() {
  local b=""
  case "${TERM_PROGRAM:-}" in
    Apple_Terminal) b=com.apple.Terminal ;;   iTerm.app) b=com.googlecode.iterm2 ;;
    vscode) b=com.microsoft.VSCode ;;          Cursor) b=com.todesktop.230313mzl4w4u92 ;;
    WarpTerminal) b=dev.warp.Warp-Stable ;;    ghostty) b=com.mitchellh.ghostty ;;
    Hyper) b=co.zeit.hyper ;;                  WezTerm) b=com.github.wez.wezterm ;;
  esac
  [[ -n "$b" ]] && /usr/bin/osascript -e "tell application id \"$b\" to activate" >/dev/null 2>&1 || true
}

if [[ -n "${AGENTNOTIFY_MOCK:-}" ]]; then
  choice="${AGENTNOTIFY_MOCK_CHOICE:-}"          # test mode: never touch the real dialog
else
  em=${msg//\\/\\\\}; em=${em//\"/\\\"}
  # Explicitly map a timeout (gave up) to empty → defer. Never let a timeout return
  # the default button, which would silently auto-approve.
  choice="$(/usr/bin/osascript <<EOF 2>/dev/null || true
tell application "System Events"
  activate
  set res to (display dialog "$em" with title "Approve tool use?" buttons {"Decline","Open Terminal","Approve"} default button "Approve" giving up after 120)
  if gave up of res then "" else button returned of res
end tell
EOF
)"
fi

case "$choice" in
  Approve)         allow ;;
  Decline)         deny ;;
  "Open Terminal") focus_terminal; defer ;;
  *)               defer ;;   # gave up / Esc / dialog failed → safe: no decision
esac
