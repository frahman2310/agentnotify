<#
  agentnotify (Windows) — native toast when an AI coding agent needs you or finishes work.
  Mirror of notify.sh. Uses WinRT toast (no external module required).

    -Agent NAME        which agent (title)
    -Event attention   (default) needs-you / permission alert — always fires
    -Event complete    work-finished alert — fires ONLY for approved projects
    Claude / Gemini / Cursor : pipe event JSON on stdin
    Codex                    : passes event JSON as the final argument
    Aider                    : no payload — generic message
#>
param(
  [string]$Agent = "AI agent",
  [string]$Event = "attention",
  [switch]$Test,
  [switch]$DryRun    # print the computed title/message and skip the toast (for debugging)
)
$ErrorActionPreference = "Stop"

# --- gather JSON ------------------------------------------------------------
$raw = ""
if ($Test) {
  $raw = '{"message":"needs your permission to run: git push origin main","cwd":"C:\\proj"}'
} else {
  $stdin = (@($input) -join "`n")                 # Claude/Gemini/Cursor pipe JSON on stdin
  if ($stdin.Trim()) { $raw = $stdin }
  elseif ($args.Count -gt 0) { $raw = $args[-1] } # Codex passes JSON as the trailing arg
}

$o = $null; $cwd = ""
if ($raw.Trim()) { try { $o = $raw | ConvertFrom-Json; if ($o.cwd) { $cwd = [string]$o.cwd } } catch { } }
if (-not $cwd) { $cwd = (Get-Location).Path }
$proj = if ($cwd) { Split-Path -Leaf $cwd } else { "" }

# "Work completed" alerts require BOTH gates: agent enabled AND project approved (approved.ps1).
function Is-Approved($dir) {
  $file = if ($env:AGENTNOTIFY_APPROVED) { $env:AGENTNOTIFY_APPROVED } else { Join-Path $env:USERPROFILE ".agentnotify\approved" }
  if (-not (Test-Path $file)) { return $false }
  foreach ($line in Get-Content $file) {
    $l = $line.Trim(); if (-not $l -or $l.StartsWith('#')) { continue }
    if ($l.Contains('*')) { if ($dir -like $l) { return $true } }
    elseif ($dir -eq $l -or $dir.StartsWith("$l/") -or $dir.StartsWith("$l\")) { return $true }
  }
  return $false
}
function Is-AgentEnabled($a) {
  $file = if ($env:AGENTNOTIFY_AGENTS) { $env:AGENTNOTIFY_AGENTS } else { Join-Path $env:USERPROFILE ".agentnotify\agents" }
  if (-not (Test-Path $file)) { return $false }
  foreach ($line in Get-Content $file) {
    $l = $line.Trim(); if (-not $l -or $l.StartsWith('#')) { continue }
    if ($l -eq $a -or $l -eq '*') { return $true }
  }
  return $false
}

$has = { param($k) $o -and ($o.PSObject.Properties.Name -contains $k) -and $o.$k }
if ($Event -eq "complete") {
  $akey = ($Agent -split '\s+')[0].ToLower()
  if (-not (Is-AgentEnabled $akey)) { if ($DryRun) { Write-Output "SILENT (agent '$akey' not enabled)" }; exit 0 }
  if (-not (Is-Approved $cwd)) { if ($DryRun) { Write-Output "SILENT (project not approved): $cwd" }; exit 0 }
  if     (& $has 'last-assistant-message') { $msg = [string]$o.'last-assistant-message' }
  elseif (& $has 'message')                { $msg = [string]$o.'message' }
  else                                     { $msg = "finished — your turn" }
  $title = "OK: $Agent done" + $(if ($proj) { " - $proj" } else { "" })
  $sound = "ms-winsoundevent:Notification.SMS"
} else {
  if     (& $has 'message')                { $msg = [string]$o.'message' }
  elseif ($o.notification.message)         { $msg = [string]$o.notification.message }
  elseif (& $has 'last-assistant-message') { $msg = [string]$o.'last-assistant-message' }
  elseif (& $has 'prompt')                 { $msg = [string]$o.'prompt' }
  elseif (& $has 'command')                { $msg = "about to run: " + [string]$o.'command' }
  elseif ($o.tool_input.command)           { $msg = "about to run: " + [string]$o.tool_input.command }
  else                                     { $msg = "needs your attention" }
  $title = "$Agent" + $(if ($proj) { " - $proj" } else { "" })
  $sound = "ms-winsoundevent:Notification.Default"
}
$msg = ($msg -replace "`r?`n", " ")
if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 200) }

if ($DryRun) { Write-Output "FIRE [$Event] $title :: $msg"; exit 0 }

# --- post WinRT toast -------------------------------------------------------
$null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]
$null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType=WindowsRuntime]
function Esc($s) { [System.Security.SecurityElement]::Escape([string]$s) }
$xml = @"
<toast><visual><binding template="ToastGeneric">
<text>$(Esc $title)</text>
<text>$(Esc $msg)</text>
</binding></visual><audio src="$sound"/></toast>
"@
$doc = New-Object Windows.Data.Xml.Dom.XmlDocument
$doc.LoadXml($xml)
$toast = New-Object Windows.UI.Notifications.ToastNotification $doc
$appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
