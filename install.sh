#!/usr/bin/env bash
# Wire agentnotify into every supported agent found on this machine (macOS/Linux).
# Safe, idempotent, backs up before touching any config.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
notify="$dir/notify.sh"
approve="$dir/approve.sh"
chmod +x "$notify" "$approve"
have() { command -v "$1" >/dev/null 2>&1; }
declare -a done_msgs=()

if ! have jq; then
  echo "agentnotify: this installer needs 'jq' to edit JSON configs safely." >&2
  echo "  macOS:  brew install jq        Debian/Ubuntu:  sudo apt install jq" >&2
  exit 1
fi

WITH_APPROVE=0
for a in "$@"; do [[ "$a" == "--approve" ]] && WITH_APPROVE=1; done

# Opt-in: Approve/Decline dialog for Claude Code via a PreToolUse hook. Fires for the
# matched tools and REPLACES Claude's in-terminal permission prompt with a dialog you
# can answer from any app. Off by default (it changes how every matched tool is gated).
wire_approve() {
  local settings="$HOME/.claude/settings.json"; [[ -f "$settings" ]] || echo '{}' > "$settings"
  cp "$settings" "$settings.bak.$(date +%s)"; chmod 600 "$settings.bak."* 2>/dev/null || true
  local tmp; tmp="$(mktemp)"
  jq --arg cmd "$approve" --arg m "Bash|Edit|Write|MultiEdit|NotebookEdit" '
    .hooks.PreToolUse =
      (((.hooks // {}).PreToolUse // [])
       | map(select((.hooks // []) | map(.command) | map(contains($cmd)) | any | not))
       + [{"matcher":$m,"hooks":[{"type":"command","command":$cmd}]}])
  ' "$settings" > "$tmp" || { echo "jq failed for approve" >&2; return 1; }
  mv "$tmp" "$settings"; chmod 600 "$settings"
  done_msgs+=("✅ Approve dialog  →  Claude Code PreToolUse (Bash|Edit|Write|MultiEdit|NotebookEdit)")
}

# --- Claude Code & Gemini CLI: JSON settings, hooks.Notification, stdin JSON ---
merge_json_hook() { # <settings-file> <agent-label>
  local settings="$1" label="$2"
  mkdir -p "$(dirname "$settings")"
  [[ -f "$settings" ]] || echo '{}' > "$settings"
  local bak="$settings.bak.$(date +%s)"; cp "$settings" "$bak"; chmod 600 "$bak"
  local tmp; tmp="$(mktemp)"
  jq --arg cmd "$notify --agent \"$label\"" --arg p "$notify" '
    .hooks.Notification =
      (((.hooks // {}).Notification // [])
       | map(select((.hooks // []) | map(.command) | map(contains($p)) | any | not))
       + [{"hooks":[{"type":"command","command":$cmd}]}])
  ' "$settings" > "$tmp" && mv "$tmp" "$settings"; chmod 600 "$settings"
  done_msgs+=("✅ $label  →  $settings  (backup: $bak)")
}

# --- Cursor: ~/.cursor/hooks.json — approval-time (before*Execution) + stop ---
wire_cursor() {
  local cfg="$HOME/.cursor/hooks.json"; mkdir -p "$HOME/.cursor"
  [[ -f "$cfg" ]] || echo '{"version":1,"hooks":{}}' > "$cfg"
  cp "$cfg" "$cfg.bak.$(date +%s)"
  local tmp; tmp="$(mktemp)"
  # beforeShellExecution / beforeMCPExecution fire the moment Cursor is about to run a
  # command — i.e. when it pauses for your approval (default settings). stop = your turn.
  jq --arg cmd "$notify --agent Cursor" --arg p "$notify" '
    .version = (.version // 1) | .hooks = (.hooks // {})
    | reduce ("beforeShellExecution","beforeMCPExecution","stop") as $e (.;
        .hooks[$e] = (((.hooks[$e]) // [])
          | map(select((.command // "") | contains($p) | not)) + [{"command":$cmd}]))
  ' "$cfg" > "$tmp" || { echo "jq failed for cursor" >&2; return 1; }
  mv "$tmp" "$cfg"
  done_msgs+=("✅ Cursor  →  $cfg  (beforeShellExecution, beforeMCPExecution, stop)")
}

# --- Codex CLI: ~/.codex/config.toml, top-level notify, JSON as trailing arg ---
wire_codex() {
  local cfg="$HOME/.codex/config.toml"; mkdir -p "$HOME/.codex"; [[ -f "$cfg" ]] || : > "$cfg"
  if grep -qE '^[[:space:]]*notify[[:space:]]*=' "$cfg"; then
    grep -qF "$notify" "$cfg" && { done_msgs+=("✅ Codex  →  already wired"); return; }
    done_msgs+=("⚠️  Codex  →  existing 'notify' in $cfg left untouched (edit manually)"); return
  fi
  cp "$cfg" "$cfg.bak.$(date +%s)" 2>/dev/null || true
  printf 'notify = ["%s", "--agent", "Codex"]\n%s' "$notify" "$(cat "$cfg")" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
  done_msgs+=("✅ Codex  →  $cfg")
}

# --- Aider: ~/.aider.conf.yml, notifications-command (no payload) ---
wire_aider() {
  local cfg="$HOME/.aider.conf.yml"; [[ -f "$cfg" ]] || : > "$cfg"
  if grep -qE '^[[:space:]]*notifications-command[[:space:]]*:' "$cfg"; then
    done_msgs+=("⚠️  Aider  →  existing 'notifications-command' left untouched"); return
  fi
  cp "$cfg" "$cfg.bak.$(date +%s)" 2>/dev/null || true
  printf '\nnotifications: true\nnotifications-command: %s --agent Aider\n' "$notify" >> "$cfg"
  done_msgs+=("✅ Aider  →  $cfg")
}

# --- wire whatever is installed (or already has a config dir) ---
merge_json_hook "$HOME/.claude/settings.json" "Claude Code"      # Claude is why we're here
{ have gemini || [[ -d $HOME/.gemini ]]; } && merge_json_hook "$HOME/.gemini/settings.json" "Gemini" || done_msgs+=("—  Gemini not found, skipped")
{ have cursor || have cursor-agent || [[ -d $HOME/.cursor ]]; } && wire_cursor || done_msgs+=("—  Cursor not found, skipped")
{ have codex || [[ -d $HOME/.codex ]]; } && wire_codex || done_msgs+=("—  Codex not found, skipped")
{ have aider || [[ -f $HOME/.aider.conf.yml ]]; } && wire_aider || done_msgs+=("—  Aider not found, skipped")
[[ $WITH_APPROVE -eq 1 ]] && wire_approve

printf '\n'; for m in "${done_msgs[@]}"; do echo "  $m"; done; printf '\n'
echo "  Test:  $notify --test"
[[ $WITH_APPROVE -eq 0 ]] && echo "  Approve/Decline from a dialog (Claude Code): re-run with  ./install.sh --approve"
exit 0
