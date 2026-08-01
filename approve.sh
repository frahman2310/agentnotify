#!/usr/bin/env bash
# agentnotify approve (macOS) — inline Approve/Decline for AI coding agents.
# Pops a floating Approve/Decline dialog OVER whatever app you're in and returns the
# decision to the agent, so a blocked command is approved/denied without switching apps.
# Each agent window/project runs its own hook, so prompts from different projects pop
# independently — the dialog title carries the project so you can tell them apart.
#
#   --agent claude|cursor|gemini|codex   (default: claude) — picks the decision schema
#   --check                              compile the dialog AppleScript and exit (no UI)
#   Reads the agent's hook JSON on stdin; prints that agent's decision on stdout.
#   Approve → allow · Decline → deny · timeout/Esc → defer to the agent's own prompt
#   (never auto-approves; Gemini has no neutral channel so its timeout denies).
#
#   Test the decision logic without a real dialog:
#     AGENTNOTIFY_MOCK=1 AGENTNOTIFY_MOCK_CHOICE=Approve ./approve.sh --agent cursor < payload.json
set -euo pipefail

agent="claude"; CHECK=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent) agent="${2:-claude}"; shift 2 ;;
    --check) CHECK=1; shift ;;
    *)       shift ;;
  esac
done

# Build the dialog AppleScript. The multi-line if/else is REQUIRED — AppleScript has no
# one-line `... then X else Y`, and a syntax error just makes osascript print nothing,
# which silently defers every decision. `--check` compiles this to catch that.
dialog_script() { # <escaped-message> <escaped-title>
  cat <<EOF
set res to (display dialog "$1" with title "$2" buttons {"Decline","Approve"} giving up after 120)
if gave up of res then
	return ""
else
	return button returned of res
end if
EOF
}

if [[ -n "$CHECK" ]]; then
  t="$(mktemp)"; dialog_script "probe" "probe" > "$t.applescript"
  if osacompile -o /dev/null "$t.applescript" 2>"$t.err"; then echo "dialog AppleScript: compiles OK"; rm -f "$t" "$t.applescript" "$t.err"; exit 0
  else echo "dialog AppleScript: SYNTAX ERROR"; cat "$t.err"; rm -f "$t" "$t.applescript" "$t.err"; exit 1; fi
fi

payload="$(cat 2>/dev/null || true)"
get() { jq -r "$1 // empty" <<<"$payload" 2>/dev/null || true; }

# One parse block covers every agent's payload shape (cosmetic dialog text).
tool="$(get '.tool_name')"; tool="${tool:-command}"
cwd="$(get '.cwd')"; proj="${cwd:+$(basename "$cwd")}"
detail="$(get '.tool_input.command')"
[[ -z "$detail" ]] && detail="$(get '.command')"            # Cursor beforeShellExecution
[[ -z "$detail" ]] && detail="$(get '.tool_input.file_path')"
[[ -z "$detail" ]] && detail="$(get '.tool_input.path')"
summary="$tool"; [[ -n "$detail" ]] && summary="$tool — $detail"
summary="${summary//$'\n'/ }"; summary="${summary:0:300}"

case "$agent" in
  cursor) name=Cursor ;; gemini) name=Gemini ;; codex) name=Codex ;; *) name=Claude ;;
esac
msg="${name} wants to run: $summary"
title="Approve${proj:+ · $proj}?"        # project in the title → distinguishable when stacked

# Per-agent decision schemas (verified against each agent's hook docs).
allow() {
  case "$agent" in
    cursor) printf '{"permission":"allow"}\n' ;;
    gemini) : ;;   # allow is Gemini's default: print nothing
    codex)  printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}\n' ;;
    *)      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"Approved via AgentNotify"}}\n' ;;
  esac
  exit 0
}
deny() {
  case "$agent" in
    cursor) printf '{"permission":"deny","agentMessage":"Declined via AgentNotify"}\n' ;;
    gemini) printf '{"decision":"deny","reason":"Declined via AgentNotify"}\n' ;;
    codex)  printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Declined via AgentNotify"}}}\n' ;;
    *)      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Declined via AgentNotify"}}\n' ;;
  esac
  exit 0
}
defer() {
  # Timeout/Esc: hand back to the agent's own prompt. Never auto-approve.
  case "$agent" in
    gemini) printf '{"decision":"deny","reason":"No response — declined by AgentNotify"}\n' ;;  # ponytail: gemini has no 'ask'; timeout→deny to avoid auto-approve
    cursor) printf '{"permission":"ask"}\n' ;;   # hand back to Cursor's own approval UI
    # claude, codex: no stdout → the agent's normal permission prompt handles it
  esac
  exit 0
}

if [[ -n "${AGENTNOTIFY_MOCK:-}" ]]; then
  choice="${AGENTNOTIFY_MOCK_CHOICE:-}"          # test mode: never touch the real dialog
else
  em=${msg//\\/\\\\}; em=${em//\"/\\\"}
  et=${title//\\/\\\\}; et=${et//\"/\\\"}
  # Plain `display dialog` (no System Events) needs no Automation permission and floats
  # on top over the frontmost app on macOS Sequoia+/Tahoe. Timeout → empty → defer.
  choice="$(/usr/bin/osascript <<<"$(dialog_script "$em" "$et")" 2>/dev/null || true)"
fi

case "$choice" in
  Approve) allow ;;
  Decline) deny ;;
  *)       defer ;;   # gave up / Esc / dialog failed → safe: no decision
esac
