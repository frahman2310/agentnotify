# AgentNotify — Technical Design Document (Phase 1)

**Status:** Draft for review · **Date:** 2026-07-30 · **Author:** Engineering
**Decision requested:** Approve scope tiering + architecture before Phase 2 (diagrams) and Phase 4 (implementation).

---

## 0. TL;DR for the reviewer

The spec is ~120 features. Roughly **15 of them deliver 90% of the value**; the rest are either
free consequences of a good architecture, or genuinely later. This document does the Phase 1 job:
research the platform reality, then propose an architecture and an honest scope tiering so we don't
build a cathedral before the doorbell works.

Three findings drive every decision below:

1. **The primary integration is events, not parsing.** Claude Code, and increasingly other agents,
   emit structured lifecycle events (Claude Code: `Notification` / `Stop` / `PreToolUse` hooks). We
   subscribe to those. Terminal-output parsing is a *fallback* for agents without hooks, and it is
   inherently fragile — it must never be the headline path.
2. **Native notifications are platform-hostile to CLI tools.** On macOS a bare binary **cannot** post
   a `UserNotifications` notification (`bundleProxyForCurrentProcess is nil`); it needs a signed `.app`
   bundle or an AppleScript shim. On Windows, toasts need a registered `AppUserModelID`. This is the
   hardest plumbing in the project and it lives in a tiny, well-tested platform layer.
3. **Inline "Approve from the notification" is a Windows-only luxury for v1.** Windows toasts support
   action buttons + text input. macOS notification actions from a non-bundled tool are unreliable, and
   *actually approving* means writing to the agent's stdin/control channel, which is unsafe to automate
   blindly. Default behavior everywhere: **notification → click → focus the exact terminal session.**
   Inline approve is opt-in, capability-gated, Windows-first.

If you agree with the tiering in §8, Phase 2/3 proceed against the **v0.1 (MVP)** column only.

---

## 1. Problem statement (unchanged, sharpened)

AI coding agents block on human approval while the human is in another window. The wasted time is the
gap between "agent blocked" and "human notices." We close that gap with an **instant, native, correctly
-routed** notification, and a **one-click return to the exact session** that is waiting.

Success is measured, not vibed:

| Metric | Target | How measured |
|---|---|---|
| Event → notification visible | < 300 ms p95 (spec says <100ms; see §7) | in-process timestamp span |
| Click → correct terminal focused | < 500 ms, correct session ≥ 95% of the time | manual matrix + telemetry (opt-in) |
| Idle CPU | ~0% (event-driven, no poll) | `top` over 1h soak |
| Idle RAM (daemon, no GUI) | < 40 MB | RSS sample |
| False/duplicate notifications | ~0 after dedup | dedup unit + soak tests |

---

## 2. Research summary

### 2.1 Notification delivery

| Platform | Mechanism | Action buttons? | Constraint |
|---|---|---|---|
| macOS | `UserNotifications` (`UNUserNotificationCenter`) | Yes, *if bundled* | **Requires a signed `.app` bundle**; bare CLI fails. `NSUserNotification` deprecated. AppleScript `display notification` works but has **no buttons** and is styled as Script Editor. |
| macOS (fallback) | `terminal-notifier` model = ship our own `.app` helper | Limited | The proven pattern; the helper carries the bundle id, entitlements, and the notification-center identity. |
| Windows | WinRT Toast via `winrt-toast-reborn` | **Yes** (buttons + text input) | Needs a registered `AppUserModelID` (a Start-menu shortcut) or it impersonates PowerShell. |
| Linux (later) | `notify-rust` → D-Bus `org.freedesktop.Notifications` | Depends on DE | Action support varies by desktop environment. |

**Decision:** the notification backend is a **native, per-OS module behind one trait**, not a generic
cross-platform crate. Windows uses `winrt-toast-reborn` directly. macOS ships a minimal signed helper
`.app` and talks to it. We do **not** use Tauri's notification plugin (desktop action buttons are
mobile-only there — it cannot do our core feature).

### 2.2 GUI

Tauri v2 (Rust core, system WebView, no Electron) for the optional GUI **shell only** — dashboard,
settings, history, diagnostics. The GUI is a *client* of the daemon over IPC; it is **not** on the
notification hot path. This means the notification + CLI + daemon can ship and be fully useful with
**zero GUI**, and the GUI is genuinely a later tier.

### 2.3 Agent integration

| Agent | Structured events today | Integration tier |
|---|---|---|
| Claude Code | **Yes** — `Notification`, `Stop`, `PreToolUse`/`PermissionRequest` hooks invoke a shell command with JSON on stdin | Tier 2 (structured) — primary path |
| Codex CLI | Partial / evolving | Tier 2 if hooks exist, else Tier 3 (parse) |
| Gemini CLI | Partial / evolving | Tier 2 if hooks exist, else Tier 3 |
| Aider | No first-class hooks | Tier 3 (output parsing / `--notifications` command shim) |

**Key reframe of the spec's detection priority:** for Claude Code the "structured plugin event" tier is
*already the fastest and most reliable*, and it's a documented public API. The MVP integration for
Claude Code is: install a hook that runs `agentnotify emit --stdin`, done. No polling, no parsing.

Prior art (all naive, single-purpose, no session routing, no dedup, no multi-agent):
`terminal-notifier`, `claude-notify`, `agentbell`, `ccnudge`. We are the general, routed, multi-agent
layer these hint at.

---

## 3. Architectural decisions (ADRs, condensed)

- **ADR-1: Rust + Tokio.** One language for daemon, CLI, plugin host, native FFI. Single static-ish
  binary per platform. GUI in Tauri v2 reuses the same core crate.
- **ADR-2: Do we need a daemon at all for MVP?** The absolute minimum — hook → `agentnotify notify` →
  post toast → exit — needs **no daemon**. A daemon is required only for features that outlive a single
  event: **reminders/escalation, cross-event dedup/rate-limit, history, GUI, click-routing state.**
  Because reminders and dedup are core to the product's promise, **v0.1 includes a lightweight daemon**,
  but the notifier path is designed to degrade to daemonless if the daemon is down (see §6 failure).
- **ADR-3: Native notification layer, not a wrapper.** Per §2.1.
- **ADR-4: Plugins are in-process trait objects for v1, out-of-process for untrusted later.** Real
  sandboxing (separate process / WASM) is a large subsystem. v1 plugins are first-party, compiled in or
  loaded as trusted dylibs behind a stable trait. The trait is designed so an out-of-process transport
  can be slotted under it later **without changing plugin code** (§4.4). We do not ship a fake sandbox.
- **ADR-5: IPC = length-prefixed JSON over a local socket** (Unix domain socket / Windows named pipe).
  Boring, debuggable, language-agnostic so future non-Rust plugins/clients work. No custom binary ABI
  in v1.
- **ADR-6: Config = layered, typed, versioned.** `serde` structs; sources merged CLI > env > user file
  (YAML **or** JSON) > defaults. A `config_version` field drives forward migrations from day one.

---

## 4. Module architecture

Single Cargo workspace. Each crate = one responsibility. No god crate.

```
agentnotify/
├─ crates/
│  ├─ core/            # domain types: Event, Notification, Session, Capability. No I/O.
│  ├─ daemon/          # tokio service: event bus, dedup, reminder scheduler, IPC server, history
│  ├─ notify/          # trait Notifier + per-OS backends (macos/, windows/, linux/)
│  ├─ session/         # capture terminal identity; resolve + focus on click (per-OS)
│  ├─ plugins/         # Plugin trait + first-party plugins (claude_code, codex, gemini, aider)
│  ├─ config/          # layered load, validation, versioned migration
│  ├─ ipc/             # framed JSON socket/pipe transport (shared by daemon, cli, gui, plugins)
│  ├─ cli/             # `agentnotify …` — thin client over ipc, plus daemonless notify path
│  └─ telemetry/       # structured logging (tracing) + opt-in OTel; OFF by default
└─ apps/
   └─ gui/             # Tauri v2 shell (later tier) — pure ipc client
```

### 4.1 Core domain types (the contract everything shares)

```
Event        { agent_id, kind: NeedsApproval|Finished|Error|Info,
               project, task, session: SessionRef, created_at, dedup_key }
Notification { title, body, buttons: Vec<Action>, urgency, sound, session: SessionRef }
SessionRef   { pid, ppid, tty, cwd, terminal_app, term_session_id, extra: Map }
Capability   { InlineApprove, FocusSession, Buttons, Sound, TextReply }  // negotiated per platform+agent
```

`SessionRef` is captured **at event time** (env vars are only truthful in the agent's own process tree)
and is the payload that makes click-to-focus possible later.

### 4.2 Detection / event ingress (the spec's "detection engine")

One trait, strategies tried in priority order, all can run at once:

1. **Native/structured events** — hook invokes `agentnotify emit` with JSON (Claude Code today).
2. **Plugin-emitted events** — a plugin that speaks an agent's own protocol.
3. **Output parsing** — a PTY wrapper reading agent stdout against declared patterns.
4. **Built-in pattern matching** — shipped regexes per agent.
5. **User regex** — config-defined rules.

Everything normalizes to `core::Event`. The daemon never knows which strategy produced an event.

### 4.3 Notification layer

```
trait Notifier {
    fn capabilities(&self) -> CapabilitySet;
    async fn post(&self, n: &Notification) -> Result<NotificationHandle>;
    async fn update(&self, h: &NotificationHandle, n: &Notification) -> Result<()>; // reminders
    async fn dismiss(&self, h: &NotificationHandle) -> Result<()>;
}
```

Backends: `MacNotifier` (bundled helper), `WinNotifier` (`winrt-toast-reborn`), `LinuxNotifier`
(`notify-rust`, later). Click and button events flow back to the daemon over IPC → routed to
`session::focus()` or the agent's approve channel.

### 4.4 Plugin system

```
trait AgentPlugin {
    fn metadata(&self) -> PluginMeta;               // id, version, semver-compat range
    fn capabilities(&self) -> CapabilitySet;
    fn detect(&self, raw: &RawSignal) -> Option<Event>;   // detection hook
    fn on_notify(&self, e: &Event) -> Notification;       // presentation hook
    fn approve(&self, s: &SessionRef, decision: Decision) -> Result<()>; // optional, capability-gated
}
```

"New agent in < 100 lines" test: a plugin implementing `metadata` + `detect` + `on_notify` against the
hook path is ~60–80 lines. Kept honest by shipping the Aider plugin as the reference and counting it.

The trait is transport-agnostic: v1 calls it in-process; a future out-of-process host implements the
same trait as a proxy that serializes over IPC — **no first-party plugin changes.** That is the whole
sandboxing-readiness story, with none of the sandbox built yet.

### 4.5 Session tracking & click-routing (the hard, valuable part)

Capture at event time: `pid, ppid` chain (via `sysinfo`), `tty`, `cwd`, and terminal-identifying env
(`TERM_PROGRAM`, `TERM_SESSION_ID`, `WT_SESSION`, `KITTY_WINDOW_ID`, iTerm/tmux vars, `SSH_TTY`).

On click, resolve terminal → focus:

| Terminal | Focus mechanism | Confidence |
|---|---|---|
| iTerm2 | AppleScript: select the window/tab/session by `TERM_SESSION_ID` | High |
| Terminal.app | AppleScript select window by tty | High |
| Windows Terminal | Activate window by pid; tab focus best-effort | Medium |
| VS Code integrated | Focus VS Code window for the workspace (`cwd`) | Medium |
| Warp / Ghostty / Kitty / WezTerm / Alacritty / Hyper | Activate app; session-precision varies | Low–Med |
| tmux/screen inside any | `tmux select-window`/`select-pane` by captured target | High (when present) |
| SSH | Focus the local terminal holding the SSH session | Medium |

**Honest stance:** perfect tab-precision is not universally possible. Contract = "focus the *app and
window*, and the *exact pane* wherever the terminal exposes an addressing API; degrade to app-activation
otherwise, and say so in `doctor`." We never open a fresh terminal.

---

## 5. Data flow (happy path)

```
Claude Code blocks on approval
  └─ Notification hook runs:  agentnotify emit --stdin   (JSON: agent, cwd, tool, session env)
        └─ cli builds core::Event (captures SessionRef)  →  ipc → daemon
              ├─ dedup / rate-limit  (drop if duplicate of an unacked event)
              ├─ plugin.on_notify(event) → Notification
              ├─ notify::post()  → native toast/alert appears           ← user sees it
              └─ reminder scheduler arms 30s/1m/2m/5m escalation
User clicks toast (or Approve button on Windows)
  └─ native backend → ipc → daemon → session::focus(SessionRef)   [or plugin.approve()]
        └─ terminal window/pane brought to foreground; reminders cancelled
```

If the daemon isn't running, `agentnotify emit` posts the notification **directly** and skips
reminders (degraded but never silent). See §6.

---

## 6. Failure handling

- **Notification post fails** → try next backend (native → AppleScript on mac; toast → balloon on win)
  → log structured error → never panic the daemon.
- **Daemon down** when event arrives → CLI posts directly (no reminders/dedup) and logs a warning;
  `doctor` flags it.
- **Session unresolvable on click** → focus the terminal *app*; if even that fails, surface a copyable
  `cd <cwd>` hint. Never open a new terminal, never guess wrong silently.
- **Plugin panics / hangs** → wrapped in `catch_unwind` + timeout; the offending plugin is disabled for
  the session and reported; core stays up.
- **Crash recovery** → daemon persists minimal state (active reminders, unacked events) to a small
  on-disk journal; on restart it restores pending reminders. State file is versioned.

---

## 7. Performance stance (and one honest correction to the spec)

The spec's "<100ms notification latency" and "<200ms cold start" are good *daemon-warm* targets and we
design for them (event-driven, no polling, preloaded backends). But the **first** notification on macOS
that has to launch/talk to the helper `.app`, or a Windows toast registering its AUMID, can exceed
100 ms on a cold machine. **Proposed contract: <300 ms p95 end-to-end warm, <100 ms daemon-internal
(event→post call).** We benchmark both numbers separately so regressions are visible. Flagging this now
rather than quietly missing a headline number.

Idle: zero polling anywhere; the daemon parks on the event bus + socket. Reminders use a single timer
wheel, not a task-per-notification.

---

## 8. Scope tiering — **the actual decision on this page**

| # | Feature | v0.1 MVP | v1.0 | Later |
|---|---|:--:|:--:|:--:|
| Core Event/Notification/Session domain | ✅ | | |
| Claude Code integration via hooks | ✅ | | |
| Native notification: macOS (bundled helper) + Windows (WinRT) | ✅ | | |
| Click → focus exact session (iTerm2, Terminal.app, Win Terminal, tmux, VS Code) | ✅ | | |
| CLI: `start stop status doctor emit test logs version` | ✅ | | |
| Daemon: dedup + rate-limit + reminder/escalation (30s/1m/2m/5m) | ✅ | | |
| Layered versioned config (YAML/JSON/env/flags) | ✅ | | |
| Structured logging + `doctor` diagnostics | ✅ | | |
| Plugin trait + Aider/Codex/Gemini plugins | | ✅ | |
| Inline Approve/Reject (Windows action buttons, capability-gated) | | ✅ | |
| Notification history + search + pin | | ✅ | |
| Quiet hours / DND / project & agent filtering / templates | | ✅ | |
| Tauri v2 GUI (dashboard, settings, history, diagnostics) | | ✅ | |
| Linux backend | | ✅ | |
| Accessibility pass (keyboard, screen reader, contrast, reduced motion) | | ✅ | |
| Auto-update (signed, opt-in, rollback) | | ✅ | |
| CI: cross-platform build/test, lint, CodeQL, Dependabot, SBOM, signing | | ✅ | |
| Out-of-process plugin sandbox | | | ✅ |
| Opt-in OpenTelemetry export | | | ✅ |
| Fuzz/chaos/soak harnesses | | | ✅ |
| Phone/watch/Slack/Discord/Teams/web/remote-approval | | | ✅ (all plugins, no core rewrite) |
| Homebrew/Winget/Cargo/npm/installers | | | ✅ |

**MVP thesis:** with the v0.1 column alone, a Claude Code user on macOS or Windows gets an instant
native notification the moment the agent blocks, and one click drops them back into the exact waiting
pane, with smart reminders if they miss it. That is the entire product promise, shippable and testable.
Everything to its right is additive and plugin- or client-shaped, exactly as the spec's "future =
plugins, not rewrites" demands.

---

## 9. Security & privacy posture (v0.1)

- No network calls at all in MVP. Telemetry crate compiled in but inert unless explicitly enabled.
- Secrets/tokens never logged; `SessionRef` env capture allowlists specific vars, never dumps the full
  environment (which can hold secrets).
- IPC socket is user-owned, `0600` / per-user named pipe; no remote surface.
- macOS helper `.app` and Windows binaries: design for signing/notarization in CI (v1.0), but do not
  block MVP on it — unsigned local dev builds are fine, releases are signed.
- Least privilege: no accessibility/automation permission requested beyond what click-to-focus needs,
  and that is requested lazily on first click, not at install.

---

## 10. Testing strategy (proportional to tier)

- **v0.1:** unit tests on domain, config merge/migration, dedup, reminder scheduler (with a mock
  clock), event normalization; a `Notifier` mock so the daemon is testable headlessly; one real
  smoke test per OS that posts an actual notification behind a feature flag. Target: meaningful
  coverage of logic, not a vanity 95% that counts FFI stubs.
- **v1.0:** integration tests per plugin, terminal-detection matrix, GUI e2e (Tauri), CI on
  macOS+Windows+Linux runners.
- **Later:** fuzz the parsers, chaos-kill the daemon under load (crash-recovery assertion), 24h soak
  for leaks/RSS.

The one non-negotiable from day one: **every piece of non-trivial logic ships with a runnable check.**

---

## 11. Open questions for the reviewer (blocking Phase 2)

1. **Approve the tiering in §8?** Phase 2/3 will be scoped to the v0.1 column only unless you say
   otherwise.
2. **macOS notification path:** ship our own signed helper `.app` (best UX, needs an Apple Developer
   ID for release) vs. AppleScript-only for MVP (no buttons, uglier, zero signing cost). Recommendation:
   **AppleScript for the very first walking skeleton, helper `.app` before v0.1 ships.** Your call on
   whether you have a Developer ID available.
3. **Inline approve:** confirm it stays **Windows-only + opt-in** for v1 and that macOS/Linux default to
   focus-only. (Auto-approving by injecting into an agent's stdin is a footgun we should not ship
   casually.)
4. **Daemon autostart:** launchd (mac) / Scheduled Task or Startup (win) at login — in v0.1 or v1.0?
   Recommendation: **v1.0**; MVP starts the daemon on first `agentnotify` use and via the hook.
5. **Name:** `AgentNotify` vs working dir `NotifyAI`. Architecture keeps the name in exactly one config
   constant, so this is cosmetic and decide-later.

---

**Next step on approval:** Phase 2 — module dependency graph, event/notification/plugin lifecycle
diagrams, session-resolution state machine, and the failure-recovery flow — scoped to the v0.1 column.
```
