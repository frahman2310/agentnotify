<#
  agentnotify — Windows parity test suite (PowerShell). Headless: approve.ps1 uses
  AGENTNOTIFY_MOCK, notify.ps1 uses -DryRun, state files redirected via env. Mirrors
  tests/agentnotify_test.sh. Run from the repo root:
    pwsh -NoProfile -File tests/agentnotify_test.ps1
#>
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$notify = Join-Path $root "notify.ps1"; $approve = Join-Path $root "approve.ps1"
$toggle = Join-Path $root "notify-toggle.ps1"; $approved = Join-Path $root "approved.ps1"
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("an_" + [guid]::NewGuid())
New-Item -ItemType Directory -Force $tmp | Out-Null
$env:AGENTNOTIFY_APPROVED = Join-Path $tmp "approved"; $env:AGENTNOTIFY_AGENTS = Join-Path $tmp "agents"; $env:AGENTNOTIFY_MUTED = Join-Path $tmp "muted"
"" | Set-Content $env:AGENTNOTIFY_APPROVED; "" | Set-Content $env:AGENTNOTIFY_AGENTS; "" | Set-Content $env:AGENTNOTIFY_MUTED

$script:pass = 0; $script:fail = 0
function Eq($lbl,$got,$want){ if ($got -eq $want){$script:pass++} else {$script:fail++; Write-Output "FAIL: $lbl"; Write-Output "  got : [$got]"; Write-Output "  want: [$want]"} }
function Has($lbl,$got,$sub){ if ([string]$got -and ([string]$got).Contains($sub)){$script:pass++} else {$script:fail++; Write-Output "FAIL: $lbl — [$got] lacks [$sub]"} }
function Appr($agent,$choice,$payload){ $env:AGENTNOTIFY_MOCK="1"; $env:AGENTNOTIFY_MOCK_CHOICE=$choice; $r = ($payload | pwsh -NoProfile -File $approve -Agent $agent); $env:AGENTNOTIFY_MOCK=$null; $env:AGENTNOTIFY_MOCK_CHOICE=$null; return ($r -join "`n") }
function Noti($agent,$event,$payload){ $r = ($payload | pwsh -NoProfile -File $notify -Agent $agent -Event $event -DryRun); return ($r -join "`n") }
function Tog($sid,$act){ (pwsh -NoProfile -File $toggle $sid $act) -join "" }
function Reset(){ "" | Set-Content $env:AGENTNOTIFY_APPROVED; "" | Set-Content $env:AGENTNOTIFY_AGENTS; "" | Set-Content $env:AGENTNOTIFY_MUTED }

$P = '{"tool_name":"Bash","tool_input":{"command":"git push"},"cwd":"C:\\app","session_id":"s1"}'
Write-Output "## 1. approve.ps1 decision schemas"
Eq "claude allow"  (Appr "claude" "Approve" $P) '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
Eq "claude deny"   (Appr "claude" "Decline" $P) '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}'
Eq "claude defer"  (Appr "claude" "" $P) ''
Eq "codex allow"   (Appr "codex" "Approve" $P)  '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
Eq "cursor allow"  (Appr "cursor" "Approve" $P) '{"permission":"allow"}'
Eq "cursor deny"   (Appr "cursor" "Decline" $P) '{"permission":"deny","agentMessage":"Declined via AgentNotify"}'
Eq "cursor defer"  (Appr "cursor" "" $P) '{"permission":"ask"}'
Eq "gemini allow"  (Appr "gemini" "Approve" $P) ''
Eq "gemini deny"   (Appr "gemini" "Decline" $P) '{"decision":"deny","reason":"Declined via AgentNotify"}'

Write-Output "## 2. approve.ps1 per-chat mute → defer"
"s-muted" | Set-Content $env:AGENTNOTIFY_MUTED
Eq "muted → defer (empty)" (Appr "claude" "Approve" '{"tool_name":"Bash","session_id":"s-muted"}') ''
"" | Set-Content $env:AGENTNOTIFY_MUTED

Write-Output "## 3. notify.ps1 attention + completion gates"
Has "attention fires" (Noti "Claude Code" "attention" '{"cwd":"C:\\p","message":"needs you","session_id":"a1"}') "FIRE [attention"
Reset
$C = '{"cwd":"C:\\p\\app","last-assistant-message":"done","session_id":"c1"}'
Has "both empty → silent(agent)" (Noti "Claude Code" "complete" $C) "SILENT (agent"
"C:\p\app" | Set-Content $env:AGENTNOTIFY_APPROVED
Has "project only → silent(agent)" (Noti "Claude Code" "complete" $C) "SILENT (agent"
"claude" | Set-Content $env:AGENTNOTIFY_AGENTS
Has "agent+project → FIRE" (Noti "Claude Code" "complete" $C) "FIRE [complete"
Has "diff project → silent(project)" (Noti "Claude Code" "complete" '{"cwd":"C:\\other","last-assistant-message":"d","session_id":"c3"}') "SILENT (project"

Write-Output "## 4. notify.ps1 mute silences; other chat unaffected"
Reset; "C:\p\app" | Set-Content $env:AGENTNOTIFY_APPROVED; "claude" | Set-Content $env:AGENTNOTIFY_AGENTS
Tog "muteme" "off" | Out-Null
Has "muted → complete silent" (Noti "Claude Code" "complete" '{"cwd":"C:\\p\\app","last-assistant-message":"d","session_id":"muteme"}') "SILENT (chat muted"
Has "other chat → fires" (Noti "Claude Code" "attention" '{"cwd":"C:\\p\\app","message":"m","session_id":"other"}') "FIRE [attention"

Write-Output "## 5. notify-toggle.ps1 status/on/off/toggle"
"" | Set-Content $env:AGENTNOTIFY_MUTED
Eq "default on" (Tog "cA" "status") "on"
Eq "off" (Tog "cA" "off") "off"
Eq "status off" (Tog "cA" "status") "off"
Eq "cB independent" (Tog "cB" "status") "on"
Eq "on" (Tog "cA" "on") "on"

Write-Output "## 6. approved.ps1 project + agent CLI"
Reset
pwsh -NoProfile -File $approved add "C:\proj\one" | Out-Null
Has "project listed" ((pwsh -NoProfile -File $approved list) -join "`n") "proj\one"
pwsh -NoProfile -File $approved agent add claude | Out-Null
Has "agent listed" ((pwsh -NoProfile -File $approved agent list) -join "`n") "claude"

Write-Output ""
Write-Output "==================================================="
Write-Output "  RESULT: $($script:pass) passed, $($script:fail) failed"
Write-Output "==================================================="
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
if ($script:fail -gt 0) { exit 1 }
