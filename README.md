# agentnotify

Native desktop notification when **any AI coding agent needs you** approval or your turn — popped over whatever app you're in, so you don't sit wasting time at a blocked terminal. macOS + Windows.

Supported agents: **Claude Code, Codex CLI, Gemini CLI, Cursor, Aider.**

### What's actually tested

| Thing | How it was verified |
|---|---|
| macOS + Claude Code | ✅ live end-to-end (real `Notification` hook → banner) |
| macOS notifications | ✅ fired reliably via `osascript` (attributed to a pre-authorized app) |
| Codex CLI `v0.146` | ✅ real binary accepts our `config.toml` — `codex --strict-config doctor`, no complaint |
| Gemini CLI `v0.53` | ✅ real binary loads our `settings.json` hooks with no error |
| Aider | ⚠️ config is valid YAML and matches Aider's docs exactly; binary not run here (won't build on Python 3.14) |
| Cursor | ⚠️ `hooks.json` schema validated against Cursor's docs; GUI app, not executed |
| Approve/Decline (macOS) | ✅ decision logic 20/20; a dialog timeout **defers**, never auto-approves |
| Windows notifier + installer + approver | ⚠️ logic validated on PowerShell 7.4; the toast/dialog *display* needs real Windows hardware |
| Installer | ✅ cold start, idempotent (double-run), preserves existing config, fails cleanly without `jq` |

⚠️ = not exercised against the live software/OS. Reports from those environments are welcome.

**Prerequisite (macOS/Linux install):** `jq` — `brew install jq` (macOS) or `apt install jq` (Debian/Ubuntu).

## Install

macOS / Linux:

```bash
./install.sh
```

Windows (PowerShell):

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

The installer wires **every agent it finds installed** (and skips the rest — re-run after installing
more). It backs up each config first and is idempotent.

Notifications post via `osascript` on macOS — attributed to a pre-authorized system app, so they
display reliably on macOS Tahoe (`terminal-notifier` is silently dropped there unless authorized).

## Approve / Decline from the popup (Claude Code, opt-in)

```bash
./install.sh --approve                                        # macOS/Linux
powershell -ExecutionPolicy Bypass -File install.ps1 -Approve # Windows
```

Adds a `PreToolUse` hook so that before Claude Code runs a matched tool
(`Bash|Edit|Write|MultiEdit|NotebookEdit`) an **Approve / Decline** dialog pops over whatever app
you're in. Approve → the tool runs; Decline → it's blocked; **Open Terminal / timeout / Esc** → falls
through to Claude's normal in-terminal prompt (a timeout **never** auto-approves). This **replaces**
Claude's in-terminal permission prompt for those tools, so it's off by default — enable it deliberately.

Only Claude Code supports this: its `PreToolUse` hook can return a decision. The other agents' notify
hooks are fire-and-forget, so they can notify but not approve inline.

## Test

```bash
./notify.sh --test                                    # macOS/Linux
powershell -ExecutionPolicy Bypass -File notify.ps1 -Test   # Windows
```

## How it works

Every agent can run a command when it's blocked on you. The installer points each one at the notifier
([`notify.sh`](notify.sh) / [`notify.ps1`](notify.ps1)), which reads the event and posts a native
notification. No daemon, no background process.

| Agent | Config it wires | Event | Payload |
|---|---|---|---|
| Claude Code | `~/.claude/settings.json` → `hooks.Notification` | permission / idle | stdin JSON |
| Gemini CLI | `~/.gemini/settings.json` → `hooks.Notification` | tool permission | stdin JSON |
| Cursor | `~/.cursor/hooks.json` → `beforeShellExecution`, `beforeMCPExecution`, `stop` | about to run a command / your turn¹ | stdin JSON |
| Codex CLI | `~/.codex/config.toml` → `notify` | turn complete | JSON arg |
| Aider | `~/.aider.conf.yml` → `notifications-command` | waiting for input | none |

¹ Cursor has no hook that fires *only* when it's blocked on command approval yet
([open request](https://forum.cursor.com/t/fire-a-hook-when-agent-waits-for-command-tool-approval/166947)).
`beforeShellExecution` / `beforeMCPExecution` fire the moment Cursor is about to run a command — i.e.
when it pauses to ask you (default settings). If you run Cursor with command auto-run enabled, these
fire per command without a real stall, so you'll get more notifications; `stop` alone is quieter.

Uninstall: restore a `*.bak.*` file next to any config, or delete the entry the installer added.

---

`docs/technical-design.md` is the deferred "daemon + plugin SDK + GUI" vision. This is the version that
works today.
