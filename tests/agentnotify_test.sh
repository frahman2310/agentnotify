#!/usr/bin/env bash
# agentnotify — deterministic test suite. Runs headless (no real popups/sounds): approve.sh
# uses AGENTNOTIFY_MOCK, notify.sh uses AGENTNOTIFY_DRYRUN, and all state files are redirected
# to a temp dir via AGENTNOTIFY_{APPROVED,AGENTS,MUTED}. The UI side effects (osascript dialog,
# afplay sound, the Focus-aware completion dialog) are verified manually, not here.
#   usage: tests/agentnotify_test.sh      (exit 0 = all pass)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTIFY="$DIR/notify.sh"; APPROVE="$DIR/approve.sh"; TOGGLE="$DIR/notify-toggle.sh"; APPROVED="$DIR/approved.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export AGENTNOTIFY_APPROVED="$TMP/approved" AGENTNOTIFY_AGENTS="$TMP/agents" AGENTNOTIFY_MUTED="$TMP/muted"
: > "$AGENTNOTIFY_APPROVED"; : > "$AGENTNOTIFY_AGENTS"; : > "$AGENTNOTIFY_MUTED"

pass=0; fail=0
eq()  { if [[ "$2" == "$3" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; echo "  got : [$2]"; echo "  want: [$3]"; fi; }
has() { if [[ "$2" == *"$3"* ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — [$2] lacks [$3]"; fi; }
empty(){ if [[ -z "$2" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — expected empty, got [$2]"; fi; }

notify(){ printf '%s' "$2" | AGENTNOTIFY_DRYRUN=1 "$NOTIFY" --agent "$1" --event "$3"; }
approve(){ printf '%s' "$3" | AGENTNOTIFY_MOCK=1 AGENTNOTIFY_MOCK_CHOICE="$2" "$APPROVE" --agent "$1"; }
reset_state(){ : > "$AGENTNOTIFY_APPROVED"; : > "$AGENTNOTIFY_AGENTS"; : > "$AGENTNOTIFY_MUTED"; }

echo "## 1. approve.sh — per-agent decision schemas (4 agents x allow/deny/defer)"
P='{"tool_name":"Bash","tool_input":{"command":"git push"},"cwd":"/x/app","command":"git push","session_id":"s1"}'
eq "claude allow"  "$(approve claude Approve "$P")"  '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
eq "claude deny"   "$(approve claude Decline "$P")"  '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}'
empty "claude defer" "$(approve claude '' "$P")"
eq "codex allow"   "$(approve codex Approve "$P")"   '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
eq "codex deny"    "$(approve codex Decline "$P")"   '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}'
eq "cursor allow"  "$(approve cursor Approve "$P")"  '{"permission":"allow"}'
eq "cursor deny"   "$(approve cursor Decline "$P")"  '{"permission":"deny","agentMessage":"Declined via AgentNotify"}'
eq "cursor defer"  "$(approve cursor '' "$P")"       '{"permission":"ask"}'
empty "gemini allow" "$(approve gemini Approve "$P")"
eq "gemini deny"   "$(approve gemini Decline "$P")"  '{"decision":"deny","reason":"Declined via AgentNotify"}'
eq "gemini defer"  "$(approve gemini '' "$P")"       '{"decision":"deny","reason":"No response — declined by AgentNotify"}'

echo "## 2. approve.sh — --check compiles, picker, and per-chat mute"
has "approve --check" "$("$APPROVE" --check)" "compiles OK"
eq "picker returns choice" "$(printf '%s' '{"options":["A","B","C"]}' | AGENTNOTIFY_MOCK=1 AGENTNOTIFY_MOCK_CHOICE=B "$APPROVE" --agent claude)" "B"
printf 's-muted\n' > "$AGENTNOTIFY_MUTED"
empty "muted chat → approve defers" "$(approve claude Approve '{"tool_name":"Bash","session_id":"s-muted"}')"
: > "$AGENTNOTIFY_MUTED"

echo "## 3. notify.sh — attention always fires (when not muted)"
has "attention fires" "$(notify 'Claude Code' '{"cwd":"/any/proj","message":"needs permission","session_id":"a1"}' attention)" "FIRE [attention"

echo "## 4. notify.sh — completion double gate (agent enabled AND project approved)"
reset_state
C='{"cwd":"/p/app","last-assistant-message":"done","session_id":"c1"}'
has "both empty → silent(agent)"  "$(notify 'Claude Code' "$C" complete)" "SILENT (agent"
echo "/p/app" > "$AGENTNOTIFY_APPROVED"
has "project only → silent(agent)" "$(notify 'Claude Code' "$C" complete)" "SILENT (agent"
echo "claude" > "$AGENTNOTIFY_AGENTS"
has "agent+project → FIRE"        "$(notify 'Claude Code' "$C" complete)" "FIRE [complete"
has "subdir of approved → FIRE"   "$(notify 'Claude Code' '{"cwd":"/p/app/src","last-assistant-message":"d","session_id":"c2"}' complete)" "FIRE [complete"
has "different project → silent(project)" "$(notify 'Claude Code' '{"cwd":"/other","last-assistant-message":"d","session_id":"c3"}' complete)" "SILENT (project"
printf '*\n' > "$AGENTNOTIFY_AGENTS"
has "wildcard agent enables all"  "$(notify 'Gemini' "$C" complete)" "FIRE [complete"

echo "## 5. notify.sh — per-chat mute silences attention AND completion; others unaffected"
reset_state; echo "/p/app" > "$AGENTNOTIFY_APPROVED"; echo "claude" > "$AGENTNOTIFY_AGENTS"
"$TOGGLE" muteme off >/dev/null
MP='{"cwd":"/p/app","message":"m","last-assistant-message":"d","session_id":"muteme"}'
has "muted → attention silent" "$(notify 'Claude Code' "$MP" attention)" "SILENT (chat muted"
has "muted → complete silent"  "$(notify 'Claude Code' "$MP" complete)" "SILENT (chat muted"
has "other chat → still fires" "$(notify 'Claude Code' '{"cwd":"/p/app","message":"m","session_id":"other"}' attention)" "FIRE [attention"

echo "## 6. notify-toggle.sh — status/on/off/toggle + independence"
: > "$AGENTNOTIFY_MUTED"
eq "default status on"  "$("$TOGGLE" chatA status)" "on"
eq "off → off"          "$("$TOGGLE" chatA off)" "off"
eq "status reflects off" "$("$TOGGLE" chatA status)" "off"
eq "chatB independent"  "$("$TOGGLE" chatB status)" "on"
eq "on → on"            "$("$TOGGLE" chatA on)" "on"
eq "toggle flips to off" "$("$TOGGLE" chatA toggle)" "off"
eq "toggle flips to on"  "$("$TOGGLE" chatA toggle)" "on"

echo "## 7. approved.sh — project + agent CLI"
reset_state
"$APPROVED" add /proj/one >/dev/null; "$APPROVED" add /proj/two >/dev/null
has "list shows added project" "$("$APPROVED" list)" "/proj/one"
"$APPROVED" rm /proj/one >/dev/null
out="$("$APPROVED" list)"; if [[ "$out" != *"/proj/one"* && "$out" == *"/proj/two"* ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: rm project"; fi
"$APPROVED" agent add claude >/dev/null; "$APPROVED" agent add cursor >/dev/null
has "agent list shows enabled" "$("$APPROVED" agent list)" "claude"
"$APPROVED" agent rm claude >/dev/null
out="$("$APPROVED" agent list)"; if [[ "$out" != *claude* && "$out" == *cursor* ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: rm agent"; fi
"$APPROVED" clear >/dev/null; "$APPROVED" agent clear >/dev/null
has "list empty after clear" "$("$APPROVED" list)" "none"

echo "## 8. installer wiring (fake HOME): notify + completion + approval per agent"
FH="$TMP/home"; mkdir -p "$FH/.gemini" "$FH/.cursor" "$FH/.codex"; : > "$FH/.aider.conf.yml"
( unset AGENTNOTIFY_APPROVED AGENTNOTIFY_AGENTS AGENTNOTIFY_MUTED; HOME="$FH" "$DIR/install.sh" >/dev/null 2>&1 )
jqv(){ jq -r "$1 // empty" "$2" 2>/dev/null; }
has "claude Notification=attention"     "$(jqv '.hooks.Notification[0].hooks[0].command' "$FH/.claude/settings.json")" "--event attention"
has "claude Notification matcher"        "$(jqv '.hooks.Notification[0].matcher' "$FH/.claude/settings.json")" "permission_prompt"
has "claude Stop=complete"               "$(jqv '.hooks.Stop[0].hooks[0].command' "$FH/.claude/settings.json")" "--event complete"
has "claude PermissionRequest=approve"   "$(jqv '.hooks.PermissionRequest[0].hooks[0].command' "$FH/.claude/settings.json")" "approve.sh --agent claude"
has "claude has NO PreToolUse approve"   "$(jq -r '[.hooks.PreToolUse[]?.hooks[]?.command|select(test("approve"))]|length' "$FH/.claude/settings.json")" "0"
has "gemini AfterAgent=complete"         "$(jqv '.hooks.AfterAgent[0].hooks[0].command' "$FH/.gemini/settings.json")" "--event complete"
has "cursor stop=complete"               "$(jqv '.hooks.stop[0].command' "$FH/.cursor/hooks.json")" "--event complete"
has "cursor beforeShell=approve"         "$(jqv '.hooks.beforeShellExecution[0].command' "$FH/.cursor/hooks.json")" "approve.sh --agent cursor"
has "codex notify=complete"              "$(grep '^notify' "$FH/.codex/config.toml")" '"--event", "complete"'
has "codex PermissionRequest=approve"    "$(jqv '.hooks.PermissionRequest[0].hooks[0].command' "$FH/.codex/hooks.json")" "approve.sh --agent codex"
has "aider notifications-command"        "$(cat "$FH/.aider.conf.yml")" "--event complete"
# idempotency: re-run, counts stay 1
( unset AGENTNOTIFY_APPROVED AGENTNOTIFY_AGENTS AGENTNOTIFY_MUTED; HOME="$FH" "$DIR/install.sh" >/dev/null 2>&1 )
eq "idempotent Notification==1" "$(jq '.hooks.Notification|length' "$FH/.claude/settings.json")" "1"
eq "idempotent Stop==1"         "$(jq '.hooks.Stop|length' "$FH/.claude/settings.json")" "1"
eq "idempotent PermissionRequest==1" "$(jq '.hooks.PermissionRequest|length' "$FH/.claude/settings.json")" "1"

echo
echo "==================================================="
echo "  RESULT: $pass passed, $fail failed"
echo "==================================================="
[[ $fail -eq 0 ]]
