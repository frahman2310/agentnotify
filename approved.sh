#!/usr/bin/env bash
# agentnotify — control "work completed" notifications. They fire only when BOTH gates pass:
#   1) the AGENT is enabled    (approved.sh agent add claude|cursor|gemini|codex|aider | '*')
#   2) the PROJECT is approved (approved.sh add [dir])
# Both lists start empty, so completion is OFF until you opt in. Curate as priorities shift.
#
#   ./approved.sh                 show both gates
#   ./approved.sh add [dir]       approve a project (default: current directory)
#   ./approved.sh rm  [dir]       remove a project
#   ./approved.sh clear           remove all projects
#   ./approved.sh agent add NAME  enable an agent (NAME: claude|cursor|gemini|codex|aider|'*')
#   ./approved.sh agent rm  NAME  disable an agent
#   ./approved.sh agent clear     disable all agents
set -euo pipefail

APPROVED="${AGENTNOTIFY_APPROVED:-$HOME/.agentnotify/approved}"
AGENTS="${AGENTNOTIFY_AGENTS:-$HOME/.agentnotify/agents}"
mkdir -p "$(dirname "$APPROVED")"; [[ -f "$APPROVED" ]] || : > "$APPROVED"; [[ -f "$AGENTS" ]] || : > "$AGENTS"
abspath() { cd "$1" 2>/dev/null && pwd || echo "$1"; }
items() { grep -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null || true; }

case "${1:-list}" in
  list|ls)
    echo "Enabled agents:  $(items "$AGENTS" | paste -sd, - | sed 's/^$/(none — completion OFF)/')"
    echo "Approved projects:"
    if [[ -n "$(items "$APPROVED")" ]]; then items "$APPROVED" | sed 's/^/  • /'; else echo "  (none — completion OFF)"; fi
    echo "→ a 'done' alert fires only when the agent is enabled AND the project is approved." ;;
  add)
    dir="$(abspath "${2:-$PWD}")"
    grep -qxF "$dir" "$APPROVED" 2>/dev/null || printf '%s\n' "$dir" >> "$APPROVED"
    echo "✅ project approved: $dir" ;;
  rm|remove)
    dir="$(abspath "${2:-$PWD}")"; tmp="$(mktemp)"
    grep -vxF "$dir" "$APPROVED" > "$tmp" 2>/dev/null || true; mv "$tmp" "$APPROVED"
    echo "removed project: $dir" ;;
  clear) : > "$APPROVED"; echo "cleared all approved projects" ;;
  agent|agents)
    sub="${2:-list}"; name="$(printf '%s' "${3:-}" | tr '[:upper:]' '[:lower:]')"
    case "$sub" in
      list|ls) echo "Enabled agents: $(items "$AGENTS" | paste -sd, - | sed 's/^$/(none)/')" ;;
      add)   [[ -n "$name" ]] || { echo "usage: approved.sh agent add <claude|cursor|gemini|codex|aider|'*'>" >&2; exit 2; }
             grep -qxF "$name" "$AGENTS" 2>/dev/null || printf '%s\n' "$name" >> "$AGENTS"; echo "✅ agent enabled: $name" ;;
      rm|remove) tmp="$(mktemp)"; grep -vxF "$name" "$AGENTS" > "$tmp" 2>/dev/null || true; mv "$tmp" "$AGENTS"; echo "agent disabled: $name" ;;
      clear) : > "$AGENTS"; echo "disabled all agents" ;;
      *) echo "usage: approved.sh agent [list|add NAME|rm NAME|clear]" >&2; exit 2 ;;
    esac ;;
  *) echo "usage: approved.sh [list|add [dir]|rm [dir]|clear|agent ...]" >&2; exit 2 ;;
esac
