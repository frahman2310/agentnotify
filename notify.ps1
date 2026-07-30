<#
  agentnotify (Windows) — native toast when any AI coding agent needs you.
  Mirror of notify.sh. Uses WinRT toast (no external module required).

    Claude / Gemini / Cursor : pipe event JSON on stdin
    Codex                    : passes event JSON as the final argument
    Aider                    : no payload — generic message

    powershell -ExecutionPolicy Bypass -File notify.ps1 -Agent "Claude Code"
    powershell -ExecutionPolicy Bypass -File notify.ps1 -Test
#>
param(
  [string]$Agent = "AI agent",
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

$msg = ""; $proj = ""
if ($raw.Trim()) {
  try {
    $o = $raw | ConvertFrom-Json
    $has = { param($k) $o.PSObject.Properties.Name -contains $k -and $o.$k }
    if     (& $has 'message')              { $msg = [string]$o.'message' }
    elseif ($o.notification.message)       { $msg = [string]$o.notification.message }
    elseif (& $has 'last-assistant-message') { $msg = [string]$o.'last-assistant-message' }
    elseif (& $has 'prompt')               { $msg = [string]$o.'prompt' }
    elseif (& $has 'command')              { $msg = "about to run: " + [string]$o.'command' }
    elseif ($o.tool_input.command)         { $msg = "about to run: " + [string]$o.tool_input.command }
    if ($o.cwd) { $proj = " · " + (Split-Path -Leaf ([string]$o.cwd)) }
  } catch { }
}
if (-not $msg) { $msg = "needs your attention" }
$msg = ($msg -replace "`r?`n", " ")
if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 200) }
$title = "$Agent$proj"

if ($DryRun) { Write-Output "$title`n$msg"; exit 0 }

# --- post WinRT toast -------------------------------------------------------
$null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]
$null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType=WindowsRuntime]

function Esc($s) { [System.Security.SecurityElement]::Escape([string]$s) }
$xml = @"
<toast><visual><binding template="ToastGeneric">
<text>$(Esc $title)</text>
<text>$(Esc $msg)</text>
</binding></visual><audio src="ms-winsoundevent:Notification.Default"/></toast>
"@

$doc = New-Object Windows.Data.Xml.Dom.XmlDocument
$doc.LoadXml($xml)
$toast = New-Object Windows.UI.Notifications.ToastNotification $doc
# Borrow PowerShell's registered AppUserModelID so toasts show without registering our own.
$appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
