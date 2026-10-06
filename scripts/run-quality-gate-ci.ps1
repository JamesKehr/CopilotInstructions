<#
  run-quality-gate-ci.ps1 - CI/local wrapper that owns its own setup so the quality-gate-check workflow step is a single
  script invocation (no inline multi-command run: block). Resolves the base/head SHAs fail-closed, points
  COPILOT_INSTRUCTIONS_CLONE at the repo root (this repo IS the instructions clone), and runs gate-runner.ps1
  -Verify -Mode full (read-only: no findings.csv append, no lock) over the whole-branch BaseRef..HEAD diff. gate-runner
  exits 1 on a BLOCKED gate_status (mechanical rg-battery findings present), which fails the job. HONEST CEILING: this
  runs gate-runner HEADLESS - it verifies only the mechanical rg-floor, NOT the QUALITY GATE block, the multi-model
  panel, or the verdict (all agent-asserted).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $BaseRef,
    [string] $RepoRoot = '',
    [switch] $CiMode
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/repo-root.psm1') -Force
function Write-WrapErr { param([string] $Msg) if ($CiMode) { Write-Host "::error::$Msg" } else { Write-Host $Msg -ForegroundColor Red } }
try {
    $RepoRoot = Resolve-RepoRoot -Explicit $RepoRoot -ScriptRoot $PSScriptRoot -Anchors @('scripts/run-quality-gate-ci.ps1') -RequireGitWorkTree
} catch {
    Write-WrapErr $_.Exception.Message
    exit 2
}

$base = (& git -C $RepoRoot merge-base $BaseRef HEAD 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $base) {
    Write-WrapErr "run-quality-gate-ci: cannot resolve the merge-base of '$BaseRef' and HEAD (gate-runner's base_sha contract) - refusing to run fail-open"
    exit 2
}
$head = (& git -C $RepoRoot rev-parse HEAD 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $head) {
    Write-WrapErr "run-quality-gate-ci: cannot resolve HEAD SHA - refusing to run fail-open"
    exit 2
}
$base = $base.Trim()
$head = $head.Trim()

try {
    Import-Module (Join-Path $PSScriptRoot 'lib/gate-runner-dependencies.psm1') -Force
    Initialize-GateRunnerDependencies -CiMode:$CiMode
    $pwshExe = (Get-Command pwsh -ErrorAction Stop).Source
} catch {
    Write-WrapErr "run-quality-gate-ci: $($_.Exception.Message)"
    exit 2
}

$env:COPILOT_INSTRUCTIONS_CLONE = $RepoRoot
$runner = Join-Path $RepoRoot '.github/pr-quality-gate/gate-runner.ps1'
& $pwshExe -NoProfile -File $runner -BaseSha $base -HeadSha $head -Mode full -Verify -ProjectRoot $RepoRoot
exit $LASTEXITCODE
