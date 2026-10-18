<#
  Wire agentnotify into every supported agent found on this machine (Windows).
  Mirror of install.sh. Notifications + an inline Approve/Decline dialog (default on).
  Run:  powershell -ExecutionPolicy Bypass -File install.ps1 [-NoApprove]
  -NoApprove wires notifications only (skips the Approve/Decline dialog hooks).
#>
param([switch]$NoApprove)
$ErrorActionPreference = "Stop"
$dir           = Split-Path -Parent $MyInvocation.MyCommand.Path
$notify        = Join-Path $dir "notify.ps1"
$approveScript = Join-Path $dir "approve.ps1"   # not $approve: case-insensitive param clash
$home_         = $env:USERPROFILE
$log = @()

function Have($cmd) { $null -ne (Get-Command $cmd -ErrorAction SilentlyContinue) }
function RunCmd($label, $nevent)  { "powershell -ExecutionPolicy Bypass -File `"$notify`" -Agent `"$label`" -Event $nevent" }
function ApproveCmd($ag) { "powershell -ExecutionPolicy Bypass -File `"$approveScript`" -Agent $ag" }

# --- notify: Claude & Gemini JSON settings, wire <event> (optional <matcher>) with --event
# attention (always) or complete (notifier only fires complete for approved projects) ---
function Merge-NotifyHook($settings, $event, $matcher, $label, $nevent) {
  $d = Split-Path -Parent $settings; if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null }
  if (-not (Test-Path $settings)) { "{}" | Set-Content $settings }
  Copy-Item $settings "$settings.bak.$(Get-Date -UFormat %s)" -Force
  $cmd = RunCmd $label $nevent
  $o = Get-Content $settings -Raw | ConvertFrom-Json -AsHashtable
  if (-not $o) { $o = @{} }
  if (($o.hooks -isnot [hashtable])) { $o.hooks = @{} }
  $existing = @()
  if ($o.hooks.ContainsKey($event)) {
    $existing = @($o.hooks[$event]) | Where-Object {
      $c = @(); if ($_.hooks) { $c = @($_.hooks | ForEach-Object { $_.command }) }
      ($c -join ' ') -notlike "*$notify*"
    }
  }
  $entry = @{ hooks = @(@{ type = 'command'; command = $cmd }) }
  if ($matcher) { $entry.matcher = $matcher }
  $o.hooks[$event] = @($existing) + @($entry)
  ($o | ConvertTo-Json -Depth 20) | Set-Content $settings
  $script:log += "$label $nevent  ->  $settings ($event)"
}

# --- approve: Claude (PreToolUse), Gemini (BeforeTool), Codex hooks.json (PermissionRequest) ---
function Merge-ApproveHook($settings, $event, $matcher, $ag) {
  $d = Split-Path -Parent $settings; if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null }
  if (-not (Test-Path $settings)) { "{}" | Set-Content $settings }
  Copy-Item $settings "$settings.bak.$(Get-Date -UFormat %s)" -Force
  $cmd = ApproveCmd $ag
  $o = Get-Content $settings -Raw | ConvertFrom-Json -AsHashtable
  if (-not $o) { $o = @{} }
  if (($o.hooks -isnot [hashtable])) { $o.hooks = @{} }
  $existing = @()
  if ($o.hooks.ContainsKey($event)) {
    $existing = @($o.hooks[$event]) | Where-Object {
      $c = @(); if ($_.hooks) { $c = @($_.hooks | ForEach-Object { $_.command }) }
      ($c -join ' ') -notlike "*$approveScript*"
    }
  }
  $o.hooks[$event] = @($existing) + @(@{ matcher = $matcher; hooks = @(@{ type = 'command'; command = $cmd }) })
  ($o | ConvertTo-Json -Depth 20) | Set-Content $settings
  $script:log += "approve $ag  ->  $settings ($event)"
}

function Strip-Event($settings, $event, $needle) {
  if (-not (Test-Path $settings)) { return }
  $o = Get-Content $settings -Raw | ConvertFrom-Json -AsHashtable
  if (-not $o -or ($o.hooks -isnot [hashtable]) -or -not $o.hooks.ContainsKey($event)) { return }
  $o.hooks[$event] = @(@($o.hooks[$event]) | Where-Object {
    $c = @(); if ($_.hooks) { $c = @($_.hooks | ForEach-Object { $_.command }) }
    ($c -join ' ') -notlike "*$needle*"
  })
  ($o | ConvertTo-Json -Depth 20) | Set-Content $settings
}

# --- Cursor: before*Execution -> approve (or notify); stop -> notify ---
function Wire-Cursor($mode) {
  $cfg = Join-Path $home_ ".cursor\hooks.json"
  $d = Split-Path -Parent $cfg; if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null }
  if (-not (Test-Path $cfg)) { '{"version":1,"hooks":{}}' | Set-Content $cfg }
  Copy-Item $cfg "$cfg.bak.$(Get-Date -UFormat %s)" -Force
  $before = if ($mode -eq 'approve') { ApproveCmd 'cursor' } else { RunCmd 'Cursor' 'attention' }
  $stop = RunCmd 'Cursor' 'complete'   # stop = work finished (gated completion)
  $o = Get-Content $cfg -Raw | ConvertFrom-Json -AsHashtable
  if (-not $o) { $o = @{} }
  if (-not $o.ContainsKey('version')) { $o.version = 1 }
  if (($o.hooks -isnot [hashtable])) { $o.hooks = @{} }
  $map = @{ beforeShellExecution = $before; beforeMCPExecution = $before; stop = $stop }
  foreach ($e in $map.Keys) {
    $ex = @()
    if ($o.hooks.ContainsKey($e)) { $ex = @($o.hooks[$e]) | Where-Object { ($_.command -notlike "*$notify*") -and ($_.command -notlike "*$approveScript*") } }
    $o.hooks[$e] = @($ex) + @(@{ command = $map[$e] })
  }
  ($o | ConvertTo-Json -Depth 20) | Set-Content $cfg
  $script:log += "cursor  ->  $cfg (before*Execution -> $mode, stop -> notify)"
}

# --- Codex: config.toml notify (turn-complete) ---
function Wire-CodexNotify {
  $cfg = Join-Path $home_ ".codex\config.toml"
  $d = Split-Path -Parent $cfg; if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null }
  if (-not (Test-Path $cfg)) { "" | Set-Content $cfg }
  if (Select-String -Path $cfg -Pattern '^\s*notify\s*=' -Quiet) { $script:log += "WARN Codex notify left untouched ($cfg)"; return }
  Copy-Item $cfg "$cfg.bak.$(Get-Date -UFormat %s)" -Force
  $esc  = $notify -replace '\\','\\'
  $line = "notify = [`"powershell`", `"-ExecutionPolicy`", `"Bypass`", `"-File`", `"$esc`", `"-Agent`", `"Codex`", `"-Event`", `"complete`"]"
  ($line + "`n" + (Get-Content $cfg -Raw)) | Set-Content $cfg
  $script:log += "Codex complete  ->  $cfg"
}

# --- Aider: notifications-command (notify only) ---
function Wire-Aider {
  $cfg = Join-Path $home_ ".aider.conf.yml"
  if ((Test-Path $cfg) -and (Select-String -Path $cfg -Pattern '^\s*notifications-command\s*:' -Quiet)) {
    $script:log += "WARN Aider notifications-command left untouched"; return
  }
  Add-Content $cfg "`nnotifications: true`nnotifications-command: powershell -ExecutionPolicy Bypass -File `"$notify`" -Agent Aider -Event complete"
  $script:log += "Aider complete  ->  $cfg"
}

# --- dispatch ---
$G = (Have "gemini") -or (Test-Path (Join-Path $home_ ".gemini"))
$C = (Have "cursor") -or (Test-Path (Join-Path $home_ ".cursor"))
$X = (Have "codex")  -or (Test-Path (Join-Path $home_ ".codex"))
$A = (Have "aider")  -or (Test-Path (Join-Path $home_ ".aider.conf.yml"))
$doApprove = -not $NoApprove
$cursorMode = if ($doApprove) { 'approve' } else { 'notify' }

Merge-NotifyHook (Join-Path $home_ ".claude\settings.json") "Notification" "permission_prompt" "Claude Code" "attention"
Merge-NotifyHook (Join-Path $home_ ".claude\settings.json") "Stop" "" "Claude Code" "complete"
if ($G) {
  Merge-NotifyHook (Join-Path $home_ ".gemini\settings.json") "Notification" "" "Gemini" "attention"
  Merge-NotifyHook (Join-Path $home_ ".gemini\settings.json") "AfterAgent" "" "Gemini" "complete"
} else { $log += "--  Gemini skipped" }
if ($X) { Wire-CodexNotify } else { $log += "--  Codex skipped" }
if ($A) { Wire-Aider } else { $log += "--  Aider skipped" }
if ($C) { Wire-Cursor $cursorMode } else { $log += "--  Cursor skipped" }

if ($doApprove) {
  # Claude PermissionRequest fires only when Claude would actually ask (respects the mode).
  Strip-Event (Join-Path $home_ ".claude\settings.json") "PreToolUse" $approveScript
  Merge-ApproveHook (Join-Path $home_ ".claude\settings.json") "PermissionRequest" ".*" "claude"
  if ($G) { Merge-ApproveHook (Join-Path $home_ ".gemini\settings.json") "BeforeTool" "run_shell_command|write_file|replace_file_section" "gemini" }
  if ($X) { Merge-ApproveHook (Join-Path $home_ ".codex\hooks.json") "PermissionRequest" ".*" "codex" }
}

"`n" + ($log -join "`n") + "`n"
"Test:  powershell -ExecutionPolicy Bypass -File `"$notify`" -Test"
if ($doApprove) { "Approve/Decline dialog: ON (Claude, Cursor, Gemini, Codex). Disable with  -NoApprove" }
else { "Notifications only. Re-run without -NoApprove to enable the Approve/Decline dialog" }
$approvedScript = Join-Path $dir "approved.ps1"
"Work-completed alerts fire only for APPROVED projects. Approve this one:"
"   powershell -ExecutionPolicy Bypass -File `"$approvedScript`" add    (then: list | rm | clear)"
