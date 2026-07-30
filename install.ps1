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
function RunCmd($label)  { "powershell -ExecutionPolicy Bypass -File `"$notify`" -Agent `"$label`"" }
function ApproveCmd($ag) { "powershell -ExecutionPolicy Bypass -File `"$approveScript`" -Agent $ag" }

# --- notify: Claude & Gemini hooks.Notification ---
function Merge-JsonHook($settings, $label) {
  $d = Split-Path -Parent $settings; if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null }
  if (-not (Test-Path $settings)) { "{}" | Set-Content $settings }
  Copy-Item $settings "$settings.bak.$(Get-Date -UFormat %s)" -Force
  $cmd = RunCmd $label
  $o = Get-Content $settings -Raw | ConvertFrom-Json -AsHashtable
  if (-not $o) { $o = @{} }
  if (($o.hooks -isnot [hashtable])) { $o.hooks = @{} }
  $existing = @()
  if ($o.hooks.ContainsKey('Notification')) {
    $existing = @($o.hooks.Notification) | Where-Object {
      $c = @(); if ($_.hooks) { $c = @($_.hooks | ForEach-Object { $_.command }) }
      ($c -join ' ') -notlike "*$notify*"
    }
  }
  $o.hooks.Notification = @($existing) + @(@{ hooks = @(@{ type = 'command'; command = $cmd }) })
  ($o | ConvertTo-Json -Depth 20) | Set-Content $settings
  $script:log += "notify  $label  ->  $settings"
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

# --- Cursor: before*Execution -> approve (or notify); stop -> notify ---
function Wire-Cursor($mode) {
  $cfg = Join-Path $home_ ".cursor\hooks.json"
  $d = Split-Path -Parent $cfg; if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null }
  if (-not (Test-Path $cfg)) { '{"version":1,"hooks":{}}' | Set-Content $cfg }
  Copy-Item $cfg "$cfg.bak.$(Get-Date -UFormat %s)" -Force
  $before = if ($mode -eq 'approve') { ApproveCmd 'cursor' } else { RunCmd 'Cursor' }
  $stop = RunCmd 'Cursor'
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
  $line = "notify = [`"powershell`", `"-ExecutionPolicy`", `"Bypass`", `"-File`", `"$esc`", `"-Agent`", `"Codex`"]"
  ($line + "`n" + (Get-Content $cfg -Raw)) | Set-Content $cfg
  $script:log += "notify  Codex  ->  $cfg"
}

# --- Aider: notifications-command (notify only) ---
function Wire-Aider {
  $cfg = Join-Path $home_ ".aider.conf.yml"
  if ((Test-Path $cfg) -and (Select-String -Path $cfg -Pattern '^\s*notifications-command\s*:' -Quiet)) {
    $script:log += "WARN Aider notifications-command left untouched"; return
  }
  Add-Content $cfg "`nnotifications: true`nnotifications-command: powershell -ExecutionPolicy Bypass -File `"$notify`" -Agent Aider"
  $script:log += "notify  Aider  ->  $cfg"
}

# --- dispatch ---
$G = (Have "gemini") -or (Test-Path (Join-Path $home_ ".gemini"))
$C = (Have "cursor") -or (Test-Path (Join-Path $home_ ".cursor"))
$X = (Have "codex")  -or (Test-Path (Join-Path $home_ ".codex"))
$A = (Have "aider")  -or (Test-Path (Join-Path $home_ ".aider.conf.yml"))
$doApprove = -not $NoApprove
$cursorMode = if ($doApprove) { 'approve' } else { 'notify' }

Merge-JsonHook (Join-Path $home_ ".claude\settings.json") "Claude Code"
if ($G) { Merge-JsonHook (Join-Path $home_ ".gemini\settings.json") "Gemini" } else { $log += "--  Gemini skipped" }
if ($X) { Wire-CodexNotify } else { $log += "--  Codex skipped" }
if ($A) { Wire-Aider } else { $log += "--  Aider skipped" }
if ($C) { Wire-Cursor $cursorMode } else { $log += "--  Cursor skipped" }

if ($doApprove) {
  Merge-ApproveHook (Join-Path $home_ ".claude\settings.json") "PreToolUse" "Bash|Edit|Write|MultiEdit|NotebookEdit" "claude"
  if ($G) { Merge-ApproveHook (Join-Path $home_ ".gemini\settings.json") "BeforeTool" "run_shell_command|write_file|replace_file_section" "gemini" }
  if ($X) { Merge-ApproveHook (Join-Path $home_ ".codex\hooks.json") "PermissionRequest" ".*" "codex" }
}

"`n" + ($log -join "`n") + "`n"
"Test:  powershell -ExecutionPolicy Bypass -File `"$notify`" -Test"
if ($doApprove) { "Approve/Decline dialog: ON (Claude, Cursor, Gemini, Codex). Disable with  -NoApprove" }
else { "Notifications only. Re-run without -NoApprove to enable the Approve/Decline dialog" }
