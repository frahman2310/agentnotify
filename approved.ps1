<#
  agentnotify (Windows) — manage which chats (projects) get "work completed" toasts.
  Completion alerts fire ONLY for approved projects; curate this as priorities shift.
    .\approved.ps1 list            list approved projects
    .\approved.ps1 add  [dir]      approve a project (default: current directory)
    .\approved.ps1 rm   [dir]      remove a project  (default: current directory)
    .\approved.ps1 clear           remove all
#>
param([string]$Cmd = "list", [string]$Dir = "")
$ErrorActionPreference = "Stop"

$file = if ($env:AGENTNOTIFY_APPROVED) { $env:AGENTNOTIFY_APPROVED } else { Join-Path $env:USERPROFILE ".agentnotify\approved" }
$d = Split-Path -Parent $file
if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null }
if (-not (Test-Path $file)) { "" | Set-Content $file }
function Resolve-Dir($p) { if (-not $p) { $p = (Get-Location).Path }; try { (Resolve-Path $p -ErrorAction Stop).Path } catch { $p } }
function Lines { Get-Content $file | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') } }

switch ($Cmd) {
  { $_ -in 'list','ls' } {
    Write-Output "Approved chats (work-completed notifications):"
    $l = @(Lines); if ($l.Count) { $l | ForEach-Object { "  - $_" } } else { "  (none - 'approved.ps1 add' to approve this project)" }
  }
  'add' {
    $p = Resolve-Dir $Dir
    if (-not (@(Lines) -contains $p)) { Add-Content $file $p }
    "approved: $p"
  }
  { $_ -in 'rm','remove' } {
    $p = Resolve-Dir $Dir
    @(Get-Content $file | Where-Object { $_ -ne $p }) | Set-Content $file
    "removed: $p"
  }
  'clear' { "" | Set-Content $file; "cleared all approved chats" }
  default { Write-Error "usage: approved.ps1 [list|add [dir]|rm [dir]|clear]" }
}
