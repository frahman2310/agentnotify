<#
  agentnotify approve (Windows) — inline Approve/Decline for AI coding agents. Mirror of approve.sh.
  Pops a Yes/No dialog and returns the decision to the agent:
  Yes → allow · No → deny · Cancel / dialog-fails → defer to the agent's own prompt.
  Reads the agent's hook JSON on stdin; prints that agent's decision on stdout.
    -Agent claude|cursor|gemini|codex   (default: claude) — picks the decision schema
#>
param([string]$Agent = "claude")
$ErrorActionPreference = "Stop"

$raw = (@($input) -join "`n")
$tool = "command"; $detail = ""; $proj = ""
if ($raw.Trim()) {
  try {
    $o = $raw | ConvertFrom-Json
    if ($o.tool_name) { $tool = [string]$o.tool_name }
    if ($o.tool_input.command)   { $detail = [string]$o.tool_input.command }
    elseif ($o.command)          { $detail = [string]$o.command }            # Cursor beforeShellExecution
    elseif ($o.tool_input.file_path) { $detail = [string]$o.tool_input.file_path }
    elseif ($o.tool_input.path)  { $detail = [string]$o.tool_input.path }
    if ($o.cwd) { $proj = " - " + (Split-Path -Leaf ([string]$o.cwd)) }
  } catch { }
}
$summary = if ($detail) { "$tool - $detail" } else { $tool }
if ($summary.Length -gt 300) { $summary = $summary.Substring(0, 300) }
$name = switch ($Agent) { "cursor" { "Cursor" } "gemini" { "Gemini" } "codex" { "Codex" } default { "Claude" } }
$msg = "$name wants to run: $summary"
$caption = "Approve$proj?"   # project in the title → distinguishable when stacked

function Emit-Allow {
  switch ($Agent) {
    "cursor" { Write-Output '{"permission":"allow"}' }
    "gemini" { }   # allow is Gemini's default: print nothing
    "codex"  { Write-Output '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}' }
    default  { Write-Output '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"Approved via AgentNotify"}}' }
  }
  exit 0
}
function Emit-Deny {
  switch ($Agent) {
    "cursor" { Write-Output '{"permission":"deny","agentMessage":"Declined via AgentNotify"}' }
    "gemini" { Write-Output '{"decision":"deny","reason":"Declined via AgentNotify"}' }
    "codex"  { Write-Output '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Declined via AgentNotify"}}}' }
    default  { Write-Output '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Declined via AgentNotify"}}' }
  }
  exit 0
}
function Emit-Defer {
  switch ($Agent) {
    "gemini" { Write-Output '{"decision":"deny","reason":"No response — declined by AgentNotify"}' }  # gemini has no 'ask'; timeout→deny to avoid auto-approve
    "cursor" { Write-Output '{"permission":"ask"}' }   # hand back to Cursor's own approval UI
    # claude, codex: no stdout → the agent's normal prompt handles it
  }
  exit 0
}

$choice = $env:AGENTNOTIFY_MOCK_CHOICE
if (-not $env:AGENTNOTIFY_MOCK) {
  try {
    Add-Type -AssemblyName System.Windows.Forms
    # Default to No (Decline) so a stray Enter can't auto-approve.
    $r = [System.Windows.Forms.MessageBox]::Show($msg, $caption,
      [System.Windows.Forms.MessageBoxButtons]::YesNo,
      [System.Windows.Forms.MessageBoxIcon]::Question,
      [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
    switch ("$r") { "Yes" { $choice = "Approve" } "No" { $choice = "Decline" } default { $choice = "" } }
  } catch { $choice = "" }   # can't show a dialog → defer (never auto-approve)
}

switch ($choice) { "Approve" { Emit-Allow } "Decline" { Emit-Deny } default { Emit-Defer } }
