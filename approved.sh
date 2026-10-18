#!/usr/bin/env bash
# agentnotify — manage the list of chats (projects) that get "work completed" notifications.
# Completion alerts fire ONLY for approved projects, so you curate this as priorities shift.
#
#   ./approved.sh            list approved projects
#   ./approved.sh add [dir]  approve a project (default: current directory)
#   ./approved.sh rm  [dir]  remove a project  (default: current directory)
#   ./approved.sh clear      remove all
set -euo pipefail

APPROVED="${AGENTNOTIFY_APPROVED:-$HOME/.agentnotify/approved}"
mkdir -p "$(dirname "$APPROVED")"; [[ -f "$APPROVED" ]] || : > "$APPROVED"

cmd="${1:-list}"
abspath() { cd "$1" 2>/dev/null && pwd || echo "$1"; }

case "$cmd" in
  list|ls)
    echo "Approved chats (work-completed notifications):"
    if grep -qvE '^[[:space:]]*(#|$)' "$APPROVED" 2>/dev/null; then
      grep -vE '^[[:space:]]*(#|$)' "$APPROVED" | sed 's/^/  • /'
    else
      echo "  (none — no completion alerts will fire. 'approved.sh add' to approve this project)"
    fi ;;
  add)
    dir="$(abspath "${2:-$PWD}")"
    grep -qxF "$dir" "$APPROVED" 2>/dev/null || printf '%s\n' "$dir" >> "$APPROVED"
    echo "✅ approved: $dir" ;;
  rm|remove)
    dir="$(abspath "${2:-$PWD}")"
    tmp="$(mktemp)"; grep -vxF "$dir" "$APPROVED" > "$tmp" 2>/dev/null || true; mv "$tmp" "$APPROVED"
    echo "removed: $dir" ;;
  clear)
    : > "$APPROVED"; echo "cleared all approved chats" ;;
  *)
    echo "usage: approved.sh [list|add [dir]|rm [dir]|clear]" >&2; exit 2 ;;
esac
