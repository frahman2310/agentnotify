# agentnotify

Two things for AI coding agents, so you stop wasting time at a blocked terminal:

1. **Notifications** — a native popup when an agent needs you (approval or "your turn"), over whatever
   app is focused.
2. **Approve / Decline in the popup** — for agents that can process a decision, a floating
   **Approve/Decline** dialog pops over your current app and *actually allows or blocks* the command.
   No rerouting to the terminal.

macOS + Windows. Supported agents: **Claude Code, Codex CLI, Gemini CLI, Cursor, Aider.**

**Prerequisite (macOS/Linux install):** `jq` — `brew install jq` (macOS) or `apt install jq` (Debian/Ubuntu).

## Install

```bash
./install.sh                                             # macOS/Linux
powershell -ExecutionPolicy Bypass -File install.ps1     # Windows
```

Wires **every agent it finds installed** (skips the rest — re-run after installing more), backs up each
config first, and is idempotent. The Approve/Decline dialog is **on by default**; add `--no-approve`
(`-NoApprove` on Windows) for notifications only.

## How it works

Every agent can run a command at a lifecycle event. The installer points each event at one of two
scripts. **Notifications** ([`notify.sh`](notify.sh)/[`notify.ps1`](notify.ps1)) are fire-and-forget —
on macOS they post via `osascript`, attributed to a pre-authorized system app so they display reliably
on Tahoe (`terminal-notifier`/`alerter` banners get silently dropped there). **Approvals**
([`approve.sh`](approve.sh)/[`approve.ps1`](approve.ps1)) pop a floating `display dialog` with
Approve/Decline and return the decision to the agent. No daemon.

| Agent | Notify event | **Approve** event → what it does |
|---|---|---|
| Claude Code | `Notification` (idle/permission) | **`PermissionRequest`** → `decision.behavior: allow\|deny` |
| Cursor | `stop` | `beforeShellExecution`, `beforeMCPExecution` → `{"permission":"allow\|deny"}` |
| Gemini CLI | `Notification` | `BeforeTool` (shell/write/replace) → deny via `{"decision":"deny"}`, allow = default |
| Codex CLI | `config.toml` `notify` (turn complete) | `hooks.json` `PermissionRequest` → `decision.behavior: allow\|deny` |
| Aider | `notifications-command` | — (no decision channel; notify only) |

Approve → the command runs. Decline → it's blocked. **Timeout (120s) / Esc → defer** to the agent's own
prompt — a timeout **never** auto-approves (Gemini has no neutral channel, so its timeout denies), and
there is **no default button** so a stray Enter can't approve anything.

**Synced to Claude's permission mode.** Claude Code uses the `PermissionRequest` hook, which fires
**only when Claude itself would stop and ask** — it is silent in `auto`/`bypassPermissions`, skips
edits in `acceptEdits`, and fires in `default`/`plan`. So you're prompted only when the run genuinely
can't proceed without you, matching your current mode. (Cursor/Gemini expose no equivalent "only when
asking" event, so they fire before matched tools; if you run those with auto-run on, expect more
prompts.) On by default; `--no-approve` (`-NoApprove` on Windows) opts out.

**Bigger multi-option popup.** If a hook payload carries an `options`/`choices` array, the approver
shows a scrollable `choose from list` picker instead of Approve/Decline and returns your selection.
(Claude Code does not currently feed its own in-chat multiple-choice prompts to hooks, so this
auto-triggers for structured option sets — e.g. MCP elicitations — not free-form chat questions.)

## Test

```bash
./notify.sh --test                                          # notification
powershell -ExecutionPolicy Bypass -File notify.ps1 -Test   # Windows

# approver decision logic, no real dialog:
echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | AGENTNOTIFY_MOCK=1 AGENTNOTIFY_MOCK_CHOICE=Approve ./approve.sh --agent claude
```

## What's actually tested

| Thing | How it was verified |
|---|---|
| macOS + Claude Code notifications | ✅ live end-to-end (real `Notification` hook → banner) |
| Approver decision schemas (all 4 agents × allow/deny/timeout) | ✅ 12/12 on macOS `bash` and Windows `pwsh`; timeout defers, never auto-approves |
| Codex `v0.146` | ✅ real binary accepts our `config.toml` + `hooks.json` (`--strict-config doctor`); Codex asks to **trust** the hook on first run |
| Gemini `v0.53` | ✅ real binary loads our `settings.json` `Notification` + `BeforeTool` hooks, no error |
| Installer | ✅ cold start, idempotent, preserves existing config, `--no-approve`, fails cleanly without `jq` |
| Approval **fires end-to-end** for Codex/Gemini/Cursor | ⚠️ config accepted + doc-verified, but not run in a live authenticated session |
| Cursor | ⚠️ `hooks.json` schema validated vs Cursor's docs; GUI app, not executed |
| Aider | ⚠️ config valid YAML, matches docs; binary won't build on Python 3.14 here |
| Windows dialog/toast **display** | ⚠️ all logic passes on PowerShell 7.4; the WinRT toast + MessageBox rendering need real Windows |

⚠️ = not exercised against the live software/OS. Reports welcome.

Note: informational notifications (Codex "turn complete", Aider "waiting", Claude idle) are buttonless
banners; clicking one is an `osascript` no-op that opens Finder — cosmetic and unavoidable for banners.
The **approval** interaction is the dialog, which never reroutes.

Uninstall: restore a `*.bak.*` file next to any config, or delete the entry the installer added.

---

`docs/technical-design.md` is the deferred "daemon + plugin SDK + GUI" vision. This is the version that
works today.
