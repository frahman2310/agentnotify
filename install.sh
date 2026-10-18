#!/usr/bin/env bash
# Wire agentnotify into every supported agent found on this machine (macOS/Linux).
# Notifications (fire-and-forget) + an inline Approve/Decline dialog for agents that can
# process a decision. Safe, idempotent, backs up before touching any config.
#   --no-approve   notifications only (skip the Approve/Decline dialog wiring)
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
notify="$dir/notify.sh"
approve="$dir/approve.sh"
approved="$dir/approved.sh"
chmod +x "$notify" "$approve" "$approved"
have() { command -v "$1" >/dev/null 2>&1; }
declare -a done_msgs=()

if ! have jq; then
  echo "agentnotify: this installer needs 'jq' to edit JSON configs safely." >&2
  echo "  macOS:  brew install jq        Debian/Ubuntu:  sudo apt install jq" >&2
  exit 1
fi

WITH_APPROVE=1
for a in "$@"; do [[ "$a" == "--no-approve" ]] && WITH_APPROVE=0; done

# ---------- notification hooks ----------
# Claude & Gemini JSON settings. Wire a hook for <event> (optional <matcher>) that fires
# notify.sh with --event attention (needs-you, always fires) or complete (work done; the
# notifier itself only fires complete for projects on the approved list — see approved.sh).
merge_notify_hook() { # <settings-file> <event> <matcher|""> <label> <notify-event>
  local settings="$1" event="$2" matcher="$3" label="$4" nevent="$5"
  mkdir -p "$(dirname "$settings")"; [[ -f "$settings" ]] || echo '{}' > "$settings"
  local bak="$settings.bak.$(date +%s)"; cp "$settings" "$bak"; chmod 600 "$bak"
  local cmd="$notify --agent \"$label\" --event $nevent"
  local tmp; tmp="$(mktemp)"
  jq --arg cmd "$cmd" --arg p "$notify" --arg e "$event" --arg m "$matcher" '
    .hooks[$e] =
      (((.hooks // {})[$e] // [])
       | map(select((.hooks // []) | map(.command) | map(contains($p)) | any | not))
       + [ (if $m == "" then {} else {matcher:$m} end) + {hooks:[{type:"command",command:$cmd}]} ])
  ' "$settings" > "$tmp" && mv "$tmp" "$settings"; chmod 600 "$settings"
  done_msgs+=("$([[ $nevent == complete ]] && echo '✅' || echo '🔔') $label $nevent  →  $settings ($event)")
}

# Codex: config.toml top-level notify (turn-complete), JSON as trailing arg.
wire_codex_notify() {
  local cfg="$HOME/.codex/config.toml"; mkdir -p "$HOME/.codex"; [[ -f "$cfg" ]] || : > "$cfg"
  if grep -qE '^[[:space:]]*notify[[:space:]]*=' "$cfg"; then
    grep -qF "$notify" "$cfg" || done_msgs+=("⚠️  Codex  →  existing 'notify' in $cfg left untouched")
    return
  fi
  cp "$cfg" "$cfg.bak.$(date +%s)" 2>/dev/null || true
  printf 'notify = ["%s", "--agent", "Codex", "--event", "complete"]\n%s' "$notify" "$(cat "$cfg")" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
  done_msgs+=("✅ Codex complete  →  $cfg (turn-complete)")
}

# Aider: notifications-command (no decision channel — notify only).
wire_aider() {
  local cfg="$HOME/.aider.conf.yml"; [[ -f "$cfg" ]] || : > "$cfg"
  if grep -qE '^[[:space:]]*notifications-command[[:space:]]*:' "$cfg"; then
    done_msgs+=("⚠️  Aider  →  existing 'notifications-command' left untouched"); return
  fi
  cp "$cfg" "$cfg.bak.$(date +%s)" 2>/dev/null || true
  printf '\nnotifications: true\nnotifications-command: %s --agent Aider --event complete\n' "$notify" >> "$cfg"
  done_msgs+=("✅ Aider complete  →  $cfg")
}

# ---------- approval hooks (Approve/Decline dialog that returns a decision) ----------
# Claude (PreToolUse), Gemini (BeforeTool), Codex hooks.json (PermissionRequest) share
# the {event:[{matcher,hooks:[{type,command}]}]} shape.
merge_approve_hook() { # <settings-file> <event> <matcher> <agent-flag>
  local settings="$1" event="$2" matcher="$3" ag="$4"
  mkdir -p "$(dirname "$settings")"; [[ -f "$settings" ]] || echo '{}' > "$settings"
  cp "$settings" "$settings.bak.$(date +%s)"; chmod 600 "$settings.bak."* 2>/dev/null || true
  local tmp; tmp="$(mktemp)"
  jq --arg cmd "$approve --agent $ag" --arg p "$approve" --arg e "$event" --arg m "$matcher" '
    .hooks[$e] =
      (((.hooks // {})[$e] // [])
       | map(select((.hooks // []) | map(.command) | map(contains($p)) | any | not))
       + [{"matcher":$m,"hooks":[{"type":"command","command":$cmd}]}])
  ' "$settings" > "$tmp" || { echo "jq failed for approve $ag" >&2; return 1; }
  mv "$tmp" "$settings"; chmod 600 "$settings"
  done_msgs+=("🔐 $ag approve  →  $settings ($event)")
}

# Remove our hook from a given event (used to migrate Claude off the old PreToolUse wiring).
strip_event() { # <settings-file> <event> <needle>
  local settings="$1" event="$2" needle="$3"; [[ -f "$settings" ]] || return 0
  local tmp; tmp="$(mktemp)"
  jq --arg e "$event" --arg n "$needle" '
    if (.hooks[$e]) then .hooks[$e] = ((.hooks[$e]) | map(select((.hooks // []) | map(.command) | map(contains($n)) | any | not))) else . end
  ' "$settings" > "$tmp" && mv "$tmp" "$settings"
}

# Cursor: one file holds both notify (stop) and, when approving, the decision hooks
# (beforeShellExecution/beforeMCPExecution). $1 = approve|notify for the before* events.
wire_cursor() { # <mode: approve|notify>
  local mode="$1"; local cfg="$HOME/.cursor/hooks.json"; mkdir -p "$HOME/.cursor"
  [[ -f "$cfg" ]] || echo '{"version":1,"hooks":{}}' > "$cfg"
  cp "$cfg" "$cfg.bak.$(date +%s)"
  local before; [[ "$mode" == approve ]] && before="$approve --agent cursor" || before="$notify --agent Cursor --event attention"
  local tmp; tmp="$(mktemp)"
  # stop = work finished (gated completion). dedup drops any prior entry pointing at either
  # of our scripts, so switching modes replaces cleanly.
  jq --arg bc "$before" --arg sc "$notify --agent Cursor --event complete" --arg np "$notify" --arg ap "$approve" '
    def clean: map(select((.command // "") | (contains($np) or contains($ap)) | not));
    .version = (.version // 1) | .hooks = (.hooks // {})
    | .hooks.beforeShellExecution = (((.hooks.beforeShellExecution) // []) | clean + [{"command":$bc}])
    | .hooks.beforeMCPExecution   = (((.hooks.beforeMCPExecution)   // []) | clean + [{"command":$bc}])
    | .hooks.stop                 = (((.hooks.stop)                 // []) | clean + [{"command":$sc}])
  ' "$cfg" > "$tmp" || { echo "jq failed for cursor" >&2; return 1; }
  mv "$tmp" "$cfg"
  done_msgs+=("$([[ $mode == approve ]] && echo 🔐 || echo 🔔) Cursor  →  $cfg (before*Execution → $mode, stop → complete)")
}

# ---------- dispatch ----------
G=0; { have gemini || [[ -d $HOME/.gemini ]]; } && G=1
C=0; { have cursor || have cursor-agent || [[ -d $HOME/.cursor ]]; } && C=1
X=0; { have codex  || [[ -d $HOME/.codex ]];  } && X=1
A=0; { have aider  || [[ -f $HOME/.aider.conf.yml ]]; } && A=1

# notifications: attention (needs-you, always fires) + completion (work done, only for
# projects on the approved list — curate with approved.sh).
# Claude: scope the attention banner to permission alerts so idle does NOT double with the
# gated Stop completion — otherwise every chat would ping on idle, ignoring the approved list.
merge_notify_hook "$HOME/.claude/settings.json" Notification "permission_prompt" "Claude Code" attention
merge_notify_hook "$HOME/.claude/settings.json" Stop "" "Claude Code" complete
if [[ $G -eq 1 ]]; then
  merge_notify_hook "$HOME/.gemini/settings.json" Notification "" "Gemini" attention
  merge_notify_hook "$HOME/.gemini/settings.json" AfterAgent "" "Gemini" complete
else done_msgs+=("—  Gemini not found, skipped"); fi
[[ $X -eq 1 ]] && wire_codex_notify || { [[ $X -eq 0 ]] && done_msgs+=("—  Codex not found, skipped"); }
[[ $A -eq 1 ]] && wire_aider        || { [[ $A -eq 0 ]] && done_msgs+=("—  Aider not found, skipped"); }
[[ $C -eq 1 ]] && wire_cursor "$([[ $WITH_APPROVE -eq 1 ]] && echo approve || echo notify)" \
               || { [[ $C -eq 0 ]] && done_msgs+=("—  Cursor not found, skipped"); }

# approval dialog (default on).
# Claude PermissionRequest fires ONLY when Claude would actually ask you — it respects the
# permission mode (silent in auto/bypassPermissions, skips edits in acceptEdits, fires in
# default/plan). So no matcher gymnastics and no over-prompting. Migrate off the old, too-
# frequent PreToolUse wiring first.
if [[ $WITH_APPROVE -eq 1 ]]; then
  strip_event "$HOME/.claude/settings.json" PreToolUse "$approve"
  merge_approve_hook "$HOME/.claude/settings.json" PermissionRequest ".*" claude
  [[ $G -eq 1 ]] && merge_approve_hook "$HOME/.gemini/settings.json" BeforeTool "run_shell_command|write_file|replace_file_section" gemini
  [[ $X -eq 1 ]] && merge_approve_hook "$HOME/.codex/hooks.json" PermissionRequest ".*" codex
fi

printf '\n'; for m in "${done_msgs[@]}"; do echo "  $m"; done; printf '\n'
echo "  Test:  $notify --test"
if [[ $WITH_APPROVE -eq 1 ]]; then
  echo "  Approve/Decline dialog: ON (Claude, Cursor, Gemini, Codex). Disable with  ./install.sh --no-approve"
else
  echo "  Notifications only. Enable the Approve/Decline dialog by re-running without --no-approve"
fi
echo "  Work-completed alerts fire only for APPROVED projects. Approve this one:"
echo "     $approved add        (then: $approved list | rm | clear)"
exit 0
