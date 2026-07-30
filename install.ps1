<#
  Wire agentnotify into every supported agent found on this machine (Windows).
  Mirror of install.sh. Safe, idempotent, backs up before touching any config.
  Run:  powershell -ExecutionPolicy Bypass -File install.ps1
#>
$ErrorActionPreference = "Stop"
$dir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$notify = Join-Path $dir "notify.ps1"
$home_  = $env:USERPROFILE
$log    = @()

function Have($cmd) { $null -ne (Get-Command $cmd -ErrorAction SilentlyContinue) }
function RunCmd($label) { "powershell -ExecutionPolicy Bypass -File `"$notify`" -Agent `"$label`"" }

# --- Claude Code & Gemini CLI: JSON settings, hooks.Notification, stdin JSON ---
function Merge-JsonHook($settings, $label) {
  $d = Split-Path -Parent $settings; if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null }
  if (-not (Test-Path $settings)) { "{}" | Set-Content $settings }
  Copy-Item $settings "$settings.bak.$(Get-Date -UFormat %s)" -Force
  $cmd = RunCmd $label
  # -AsHashtable so mutated keys round-trip through ConvertTo-Json (Add-Member note
  # properties on a hashtable are dropped on serialization — that's a trap).
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
  $script:log += "OK  $label  ->  $settings"
}

# --- Cursor: hooks.json, 'stop' event ---
function Wire-Cursor {
  $cfg = Join-Path $home_ ".cursor\hooks.json"
  $d = Split-Path -Parent $cfg; if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null }
  if (-not (Test-Path $cfg)) { '{"version":1,"hooks":{}}' | Set-Content $cfg }
  Copy-Item $cfg "$cfg.bak.$(Get-Date -UFormat %s)" -Force
  $cmd = RunCmd "Cursor"
  $o = Get-Content $cfg -Raw | ConvertFrom-Json -AsHashtable
  if (-not $o) { $o = @{} }
  if (-not $o.ContainsKey('version')) { $o.version = 1 }
  if (($o.hooks -isnot [hashtable])) { $o.hooks = @{} }
  # before*Execution = approval-time (Cursor pauses to ask); stop = your turn.
  foreach ($e in 'beforeShellExecution','beforeMCPExecution','stop') {
    $ex = @()
    if ($o.hooks.ContainsKey($e)) { $ex = @($o.hooks[$e]) | Where-Object { ($_.command) -notlike "*$notify*" } }
    $o.hooks[$e] = @($ex) + @(@{ command = $cmd })
  }
  ($o | ConvertTo-Json -Depth 20) | Set-Content $cfg
  $script:log += "OK  Cursor  ->  $cfg (beforeShellExecution, beforeMCPExecution, stop)"
}

# --- Codex CLI: config.toml, top-level notify, JSON as trailing arg ---
function Wire-Codex {
  $cfg = Join-Path $home_ ".codex\config.toml"
  $d = Split-Path -Parent $cfg; if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null }
  if (-not (Test-Path $cfg)) { "" | Set-Content $cfg }
  if (Select-String -Path $cfg -Pattern '^\s*notify\s*=' -Quiet) {
    $script:log += "WARN Codex -> existing 'notify' left untouched ($cfg)"; return
  }
  Copy-Item $cfg "$cfg.bak.$(Get-Date -UFormat %s)" -Force
  $esc  = $notify -replace '\\','\\'
  $line = "notify = [`"powershell`", `"-ExecutionPolicy`", `"Bypass`", `"-File`", `"$esc`", `"-Agent`", `"Codex`"]"
  ($line + "`n" + (Get-Content $cfg -Raw)) | Set-Content $cfg
  $script:log += "OK  Codex  ->  $cfg"
}

# --- Aider: .aider.conf.yml ---
function Wire-Aider {
  $cfg = Join-Path $home_ ".aider.conf.yml"
  if ((Test-Path $cfg) -and (Select-String -Path $cfg -Pattern '^\s*notifications-command\s*:' -Quiet)) {
    $script:log += "WARN Aider -> existing 'notifications-command' left untouched"; return
  }
  Add-Content $cfg "`nnotifications: true`nnotifications-command: powershell -ExecutionPolicy Bypass -File `"$notify`" -Agent Aider"
  $script:log += "OK  Aider  ->  $cfg"
}

Merge-JsonHook (Join-Path $home_ ".claude\settings.json") "Claude Code"
if ((Have "gemini")      -or (Test-Path (Join-Path $home_ ".gemini")))  { Merge-JsonHook (Join-Path $home_ ".gemini\settings.json") "Gemini" } else { $log += "--  Gemini skipped" }
if ((Have "cursor")      -or (Test-Path (Join-Path $home_ ".cursor")))  { Wire-Cursor } else { $log += "--  Cursor skipped" }
if ((Have "codex")       -or (Test-Path (Join-Path $home_ ".codex")))   { Wire-Codex }  else { $log += "--  Codex skipped" }
if ((Have "aider")       -or (Test-Path (Join-Path $home_ ".aider.conf.yml"))) { Wire-Aider } else { $log += "--  Aider skipped" }

"`n" + ($log -join "`n") + "`n"
"Test:  powershell -ExecutionPolicy Bypass -File `"$notify`" -Test"
