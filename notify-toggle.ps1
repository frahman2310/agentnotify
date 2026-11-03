<#
  agentnotify (Windows) — per-chat on/off switch. Mirror of notify-toggle.sh.
  A session listed here is MUTED (no AgentNotify popups). "on" = active; "off" = muted.
    notify-toggle.ps1 <session-id> status   # print on|off
    notify-toggle.ps1 <session-id> on|off|toggle
#>
param([string]$Sid = "", [string]$Action = "toggle")
$ErrorActionPreference = "Stop"
if (-not $Sid) { Write-Error "usage: notify-toggle.ps1 <session-id> [status|on|off|toggle]"; exit 2 }

$file = if ($env:AGENTNOTIFY_MUTED) { $env:AGENTNOTIFY_MUTED } else { Join-Path $env:USERPROFILE ".agentnotify\muted-sessions" }
$d = Split-Path -Parent $file
if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null }
if (-not (Test-Path $file)) { "" | Set-Content $file }

function Is-Muted { @(Get-Content $file | Where-Object { $_.Trim() -eq $Sid }).Count -gt 0 }
function Mute   { if (-not (Is-Muted)) { Add-Content $file $Sid } }
function Unmute { @(Get-Content $file | Where-Object { $_.Trim() -ne $Sid }) | Set-Content $file }

switch ($Action) {
  "status" { if (Is-Muted) { "off" } else { "on" } }
  "on"     { Unmute; "on" }
  "off"    { Mute;   "off" }
  "toggle" { if (Is-Muted) { Unmute; "on" } else { Mute; "off" } }
  default  { Write-Error "usage: notify-toggle.ps1 <session-id> [status|on|off|toggle]"; exit 2 }
}
