<#
  agentnotify (Windows) — control "work completed" toasts. They fire only when BOTH gates pass:
    1) the AGENT is enabled    (approved.ps1 agent add claude|cursor|gemini|codex|aider|'*')
    2) the PROJECT is approved (approved.ps1 add [dir])
  Both lists start empty, so completion is OFF until you opt in.
    .\approved.ps1                  show both gates
    .\approved.ps1 add  [dir]       approve a project (default: current directory)
    .\approved.ps1 rm   [dir]       remove a project
    .\approved.ps1 clear            remove all projects
    .\approved.ps1 agent add NAME   enable an agent
    .\approved.ps1 agent rm  NAME   disable an agent
    .\approved.ps1 agent clear      disable all agents
#>
param([string]$Cmd = "list", [string]$A = "", [string]$B = "")
$ErrorActionPreference = "Stop"

$approved = if ($env:AGENTNOTIFY_APPROVED) { $env:AGENTNOTIFY_APPROVED } else { Join-Path $env:USERPROFILE ".agentnotify\approved" }
$agents   = if ($env:AGENTNOTIFY_AGENTS)   { $env:AGENTNOTIFY_AGENTS }   else { Join-Path $env:USERPROFILE ".agentnotify\agents" }
$d = Split-Path -Parent $approved
if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null }
foreach ($f in @($approved, $agents)) { if (-not (Test-Path $f)) { "" | Set-Content $f } }
function Resolve-Dir($p) { if (-not $p) { $p = (Get-Location).Path }; try { (Resolve-Path $p -ErrorAction Stop).Path } catch { $p } }
function Lines($f) { Get-Content $f | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') } }

switch ($Cmd) {
  { $_ -in 'list','ls' } {
    $ag = @(Lines $agents); Write-Output ("Enabled agents:  " + $(if ($ag.Count) { $ag -join ',' } else { "(none - completion OFF)" }))
    $pr = @(Lines $approved); Write-Output "Approved projects:"
    if ($pr.Count) { $pr | ForEach-Object { "  - $_" } } else { "  (none - completion OFF)" }
    "-> a 'done' alert fires only when the agent is enabled AND the project is approved."
  }
  'add'   { $p = Resolve-Dir $A; if (-not (@(Lines $approved) -contains $p)) { Add-Content $approved $p }; "project approved: $p" }
  { $_ -in 'rm','remove' } { $p = Resolve-Dir $A; @(Get-Content $approved | Where-Object { $_ -ne $p }) | Set-Content $approved; "removed project: $p" }
  'clear' { "" | Set-Content $approved; "cleared all approved projects" }
  { $_ -in 'agent','agents' } {
    $name = $B.ToLower()
    switch ($A) {
      { $_ -in '', 'list','ls' } { $ag = @(Lines $agents); Write-Output ("Enabled agents: " + $(if ($ag.Count) { $ag -join ',' } else { "(none)" })) }
      'add'   { if (-not $name) { Write-Error "usage: approved.ps1 agent add <name>"; break }; if (-not (@(Lines $agents) -contains $name)) { Add-Content $agents $name }; "agent enabled: $name" }
      { $_ -in 'rm','remove' } { @(Get-Content $agents | Where-Object { $_ -ne $name }) | Set-Content $agents; "agent disabled: $name" }
      'clear' { "" | Set-Content $agents; "disabled all agents" }
      default { Write-Error "usage: approved.ps1 agent [list|add NAME|rm NAME|clear]" }
    }
  }
  default { Write-Error "usage: approved.ps1 [list|add [dir]|rm [dir]|clear|agent ...]" }
}
