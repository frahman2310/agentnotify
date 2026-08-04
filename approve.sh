#!/usr/bin/env bash
# agentnotify approve (macOS) — inline Approve/Decline (+ multi-option picker) for AI agents.
# Pops a floating dialog OVER whatever app you're in and returns the decision to the agent,
# so a blocked action is approved/denied without switching apps. Each agent window/project
# runs its own hook, so prompts from different projects pop independently (project in title).
#
#   --agent claude|cursor|gemini|codex   (default: claude) — picks the decision schema
#   --check                              compile the AppleScript and exit (no UI)
#   Reads the agent's hook JSON on stdin; prints that agent's decision on stdout.
#   Approve → allow · Decline → deny · timeout/Esc → defer to the agent's own prompt
#   (never auto-approves; Gemini has no neutral channel so its timeout denies).
#   If the payload carries an .options/.choices array, shows a scrollable picker instead.
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

# Escape a string for embedding in an AppleScript double-quoted literal (\, ", newline).
esc() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; printf '%s' "$s"; }

# The multi-line if/else is REQUIRED — AppleScript has no one-line `then X else Y`, and a
# syntax error makes osascript print nothing, silently deferring every decision. `--check`
# osacompiles both scripts to catch that (mock-mode tests can't).
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
picker_script() { # <escaped-title> <escaped-prompt> <applescript-list e.g. "a","b">
  cat <<EOF
set chosen to (choose from list {$3} with title "$1" with prompt "$2" OK button name "Send" cancel button name "Dismiss")
if chosen is false then
	return ""
else
	return item 1 of chosen
end if
EOF
}

if [[ -n "$CHECK" ]]; then
  t="$(mktemp)"; ok=1
  dialog_script "m" "t"          > "$t.d.applescript"
  picker_script "t" "p" "\"a\"" > "$t.p.applescript"
  osacompile -o /dev/null "$t.d.applescript" 2>"$t.e" || { echo "dialog: SYNTAX ERROR"; cat "$t.e"; ok=0; }
  osacompile -o /dev/null "$t.p.applescript" 2>"$t.e" || { echo "picker: SYNTAX ERROR"; cat "$t.e"; ok=0; }
  [[ $ok -eq 1 ]] && echo "AppleScript: compiles OK"
  rm -f "$t" "$t".*; [[ $ok -eq 1 ]] && exit 0 || exit 1
fi

payload="$(cat 2>/dev/null || true)"
get() { jq -r "$1 // empty" <<<"$payload" 2>/dev/null || true; }
cwd="$(get '.cwd')"; proj="${cwd:+$(basename "$cwd")}"

# --- multi-option picker: bigger scrollable list when the payload provides choices ---
opts=(); while IFS= read -r line; do [[ -n "$line" ]] && opts+=("$line"); done \
  < <(jq -r '(.options // .choices // [])[]? | tostring' <<<"$payload" 2>/dev/null || true)
if [[ ${#opts[@]} -gt 0 ]]; then
  q="$(get '.message')"; q="${q:-$(get '.prompt')}"; q="${q:-Choose an option:}"
  if [[ -n "${AGENTNOTIFY_MOCK:-}" ]]; then printf '%s\n' "${AGENTNOTIFY_MOCK_CHOICE:-}"; exit 0; fi
  aslist=""; for o in "${opts[@]}"; do aslist+="\"$(esc "$o")\","; done; aslist="${aslist%,}"
  choice="$(/usr/bin/osascript <<<"$(picker_script "$(esc "Choose${proj:+ · $proj}")" "$(esc "$q")" "$aslist")" 2>/dev/null || true)"
  printf '%s\n' "$choice"; exit 0
fi

# --- standard Approve/Decline ---
tool="$(get '.tool_name')"; tool="${tool:-command}"
detail="$(get '.tool_input.command')"
[[ -z "$detail" ]] && detail="$(get '.command')"            # Cursor beforeShellExecution
[[ -z "$detail" ]] && detail="$(get '.tool_input.file_path')"
[[ -z "$detail" ]] && detail="$(get '.tool_input.path')"
detail="${detail//$'\n'/ }"; detail="${detail:0:400}"

case "$agent" in cursor) name=Cursor ;; gemini) name=Gemini ;; codex) name=Codex ;; *) name=Claude ;; esac
msg="${name} wants to run:"$'\n\n'"${detail:-$tool}"
[[ -n "$proj" ]] && msg+=$'\n\n'"Project: $proj"
title="Approve${proj:+ · $proj}?"

# Per-agent decision schemas (verified against each agent's hook docs). claude & codex both
# use PermissionRequest, so they share the default case.
allow() {
  case "$agent" in
    cursor) printf '{"permission":"allow"}\n' ;;
    gemini) : ;;   # allow is Gemini's default: print nothing
    *)      printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}\n' ;;
  esac
  exit 0
}
deny() {
  case "$agent" in
    cursor) printf '{"permission":"deny","agentMessage":"Declined via AgentNotify"}\n' ;;
    gemini) printf '{"decision":"deny","reason":"Declined via AgentNotify"}\n' ;;
    *)      printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}\n' ;;
  esac
  exit 0
}
defer() {
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
  choice="$(/usr/bin/osascript <<<"$(dialog_script "$(esc "$msg")" "$(esc "$title")")" 2>/dev/null || true)"
fi

case "$choice" in
  Approve) allow ;;
  Decline) deny ;;
  *)       defer ;;   # gave up / Esc / dialog failed → safe: no decision
esac
