#!/usr/bin/env bash
# agentnotify — per-chat on/off switch. Driven by the Spare Cycles panel toggle (which
# passes the Claude Code session id), or run by hand. A session listed here is MUTED:
# it gets no AgentNotify popups (notifications silenced, approval dialogs defer to the
# terminal). "on" = active (not muted); "off" = muted.
#
#   notify-toggle.sh <session-id> status    # print on|off
#   notify-toggle.sh <session-id> on        # un-mute (active)
#   notify-toggle.sh <session-id> off       # mute
#   notify-toggle.sh <session-id>           # toggle, print the new state
set -euo pipefail

MUTED="${AGENTNOTIFY_MUTED:-$HOME/.agentnotify/muted-sessions}"
mkdir -p "$(dirname "$MUTED")"; [[ -f "$MUTED" ]] || : > "$MUTED"

sid="${1:-}"; action="${2:-toggle}"
[[ -n "$sid" ]] || { echo "usage: notify-toggle.sh <session-id> [status|on|off|toggle]" >&2; exit 2; }

is_muted() { grep -qxF "$sid" "$MUTED" 2>/dev/null; }
mute()     { is_muted || printf '%s\n' "$sid" >> "$MUTED"; }
unmute()   { local t; t="$(mktemp)"; grep -vxF "$sid" "$MUTED" > "$t" 2>/dev/null || true; mv "$t" "$MUTED"; }

case "$action" in
  status) is_muted && echo off || echo on ;;
  on)     unmute; echo on ;;
  off)    mute;   echo off ;;
  toggle) if is_muted; then unmute; echo on; else mute; echo off; fi ;;
  *)      echo "usage: notify-toggle.sh <session-id> [status|on|off|toggle]" >&2; exit 2 ;;
esac
