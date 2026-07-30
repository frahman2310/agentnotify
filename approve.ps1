<#
  agentnotify approve (Windows) — Claude Code PreToolUse approver. Mirror of approve.sh.
  Pops a Yes/No/Cancel dialog and returns the decision to Claude Code:
  Yes → allow · No → deny · Cancel / dialog-fails → defer to Claude's normal prompt.
  Reads PreToolUse JSON on stdin; prints a PreToolUse permission decision on stdout.
#>
$ErrorActionPreference = "Stop"

$raw = (@($input) -join "`n")
$tool = "a tool"; $detail = ""; $proj = ""
if ($raw.Trim()) {
  try {
    $o = $raw | ConvertFrom-Json
    if ($o.tool_name) { $tool = [string]$o.tool_name }
    foreach ($k in 'command','file_path','path') { if ($o.tool_input.$k) { $detail = [string]$o.tool_input.$k; break } }
    if ($o.cwd) { $proj = " · " + (Split-Path -Leaf ([string]$o.cwd)) }
  } catch { }
}
$summary = if ($detail) { "$tool - $detail" } else { $tool }
if ($summary.Length -gt 300) { $summary = $summary.Substring(0, 300) }
$msg = "Claude$proj wants to use: $summary"

function Emit-Allow { Write-Output '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"Approved via AgentNotify"}}'; exit 0 }
function Emit-Deny  { Write-Output '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Declined via AgentNotify"}}';  exit 0 }
function Emit-Defer { exit 0 }   # no stdout → Claude's normal permission prompt

$choice = $env:AGENTNOTIFY_MOCK_CHOICE
if (-not $env:AGENTNOTIFY_MOCK) {
  try {
    Add-Type -AssemblyName System.Windows.Forms
    $r = [System.Windows.Forms.MessageBox]::Show($msg, "Approve tool use?", "YesNoCancel", "Question")
    switch ("$r") { "Yes" { $choice = "Approve" } "No" { $choice = "Decline" } default { $choice = "" } }
  } catch { $choice = "" }   # can't show a dialog → defer (never auto-approve)
}

switch ($choice) { "Approve" { Emit-Allow } "Decline" { Emit-Deny } default { Emit-Defer } }
