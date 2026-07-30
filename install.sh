#!/usr/bin/env bash
# Wire agentnotify into every supported agent found on this machine (macOS/Linux).
# Safe, idempotent, backs up before touching any config.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
notify="$dir/notify.sh"
chmod +x "$notify"
have() { command -v "$1" >/dev/null 2>&1; }
declare -a done_msgs=()

# --- Claude Code & Gemini CLI: JSON settings, hooks.Notification, stdin JSON ---
merge_json_hook() { # <settings-file> <agent-label>
  local settings="$1" label="$2"
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

printf '\n'; for m in "${done_msgs[@]}"; do echo "  $m"; done; printf '\n'
have terminal-notifier || echo "  ℹ️  For click-to-focus: brew install terminal-notifier"
echo "  Test:  $notify --test"
