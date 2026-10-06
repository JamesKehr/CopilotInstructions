#Requires -Version 5.1
[CmdletBinding()]
param([switch] $CiMode)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'test-common.ps1')
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib/gate-runner-dependencies.psm1') -Force

$script:Pass = 0
$script:Fail = 0
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$savedClone = $env:COPILOT_INSTRUCTIONS_CLONE

try {
    Initialize-GateRunnerDependencies -CiMode:$CiMode
    Assert-True ([bool](Get-Command rg -ErrorAction SilentlyContinue)) 'dependency helper accepts available ripgrep'
    $savedPath = $env:PATH
    $savedRunnerOs = $env:RUNNER_OS
    $missingMessage = ''
    try {
        $env:PATH = ''
        $env:RUNNER_OS = 'Linux'
        try { Initialize-GateRunnerDependencies } catch { $missingMessage = $_.Exception.Message }
    } finally {
        $env:PATH = $savedPath
        $env:RUNNER_OS = $savedRunnerOs
    }
    Assert-Equal 'ripgrep (rg) is required by gate-runner but is not on PATH (install ripgrep - e.g. apt-get install ripgrep / winget install BurntSushi.ripgrep.MSVC - and retry)' $missingMessage 'missing ripgrep throws the exact caller-neutral hint without attempting a local install' -CaseSensitive
    $missingPwshProbeRoot = New-TestTempDirectory -Prefix 'missing-pwsh'
    $gitPath = (Get-Command git -ErrorAction Stop).Source
    $rgPath = (Get-Command rg -ErrorAction Stop).Source
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        [IO.File]::WriteAllText((Join-Path $missingPwshProbeRoot 'git.cmd'), "@echo off`r`n`"$gitPath`" %*`r`nexit /b %ERRORLEVEL%`r`n", [Text.ASCIIEncoding]::new())
        [IO.File]::WriteAllText((Join-Path $missingPwshProbeRoot 'rg.cmd'), "@echo off`r`n`"$rgPath`" %*`r`nexit /b %ERRORLEVEL%`r`n", [Text.ASCIIEncoding]::new())
    } else {
        [IO.File]::WriteAllText((Join-Path $missingPwshProbeRoot 'git'), "#!/bin/sh`n" + ('exec "{0}" "$@"' -f ($gitPath -replace '"','\"')) + "`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $missingPwshProbeRoot 'rg'), "#!/bin/sh`n" + ('exec "{0}" "$@"' -f ($rgPath -replace '"','\"')) + "`n", [Text.UTF8Encoding]::new($false))
        & chmod +x (Join-Path $missingPwshProbeRoot 'git') (Join-Path $missingPwshProbeRoot 'rg')
        if ($LASTEXITCODE -ne 0) { throw 'Cannot make the missing-pwsh dependency shims executable.' }
    }
    $missingPwshProbe = Join-Path $missingPwshProbeRoot 'probe.ps1'
    [IO.File]::WriteAllText($missingPwshProbe, @'
param([string] $Wrapper,[string] $RepositoryRoot,[string] $FilteredPath)
$env:PATH = $FilteredPath
& $Wrapper -BaseRef HEAD -RepoRoot $RepositoryRoot
exit $LASTEXITCODE
'@, [Text.UTF8Encoding]::new($false))
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $wrapperOutput = @(& $pwsh -NoProfile -File $missingPwshProbe -Wrapper (Join-Path $repoRoot 'scripts/run-quality-gate-ci.ps1') -RepositoryRoot $repoRoot -FilteredPath $missingPwshProbeRoot 2>&1)
        $wrapperExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    $wrapperText = $wrapperOutput -join "`n"
    Assert-Equal 2 $wrapperExit 'missing pwsh fails through the wrapper dependency boundary'
    Assert-True ($wrapperText -match 'run-quality-gate-ci:.*pwsh') 'missing pwsh keeps the wrapper diagnostic prefix'
    Assert-False ($wrapperText -match 'INVOCATION_FAILED') 'missing pwsh preserves Git long enough to reach the dependency boundary'
    Assert-False ($wrapperText -match '(?m)^QUALITY GATE$|\[gate-runner') 'missing pwsh stops before gate-runner output'

    $fixture = New-TestGitRepository -Prefix 'semantic-candidates'
    git -C $fixture config core.autocrlf false
    git -C $fixture config core.safecrlf false
    $source = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text.RegularExpressions;

internal static class SemanticCandidates
{
    internal static bool Matches(string path, string value)
    {
        using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read))
        {
            var startInfo = new ProcessStartInfo("tool");
            var expression = new Regex(
                "^[a-z]+$",
                RegexOptions.CultureInvariant,
                TimeSpan.FromSeconds(1));
            return stream.CanRead && startInfo.FileName.Length > 0 && expression.IsMatch(value);
        }
    }
}
'@
    $base = New-TestCommit -Directory $fixture -File 'SemanticCandidates.cs' -Content $source -Message 'Add semantic candidates'
    $head = New-TestCommit -Directory $fixture -File 'unrelated.txt' -Content 'Unrelated text change' -Message 'Update unrelated text'
    Assert-True ($base -match '^[0-9a-f]{40}$' -and $head -match '^[0-9a-f]{40}$' -and $base -ne $head) 'fixture has distinct base and head commits'
    $fixtureSource = [IO.File]::ReadAllText((Join-Path $fixture 'SemanticCandidates.cs'))
    foreach ($constructor in @('new FileStream(', 'new ProcessStartInfo(', 'new Regex(')) {
        Assert-True ($fixtureSource.Contains($constructor)) "fixture contains exact constructor spelling: $constructor"
    }
    $changedFiles = @(git -C $fixture diff --name-only "$base..$head")
    Assert-Equal 'unrelated.txt' ($changedFiles -join ',') 'review diff is non-empty and leaves the C# candidates unchanged'

    $instructionsClone = New-TestTempDirectory -Prefix 'semantic-instructions'
    git -c core.autocrlf=false -c core.safecrlf=false clone --quiet --no-hardlinks $repoRoot $instructionsClone
    if ($LASTEXITCODE -ne 0) { throw 'Cannot create the temporary instruction clone.' }
    git -C $instructionsClone config core.autocrlf false
    git -C $instructionsClone config core.safecrlf false
    git -C $instructionsClone remote set-url origin 'https://github.com/jschick04/CopilotInstructions.git'
    if ($LASTEXITCODE -ne 0) { throw 'Cannot set the canonical instruction clone origin.' }
    foreach ($artifact in @('pattern-catalog.md', 'HIGH-TIER-SLUGS.md')) {
        $relativePath = ".github/pr-quality-gate/$artifact"
        Copy-Item -LiteralPath (Join-Path $repoRoot $relativePath) -Destination (Join-Path $instructionsClone $relativePath)
    }
    $catalog = [IO.File]::ReadAllText((Join-Path $instructionsClone '.github/pr-quality-gate/pattern-catalog.md'))
    $semanticSlugs = @('dispose-leak', 'regex-instance-without-matchtimeout-allows-catastrophic-backtracking')
    foreach ($slug in $semanticSlugs) {
        Assert-True ($catalog -match "(?m)^\| $slug \| review-pass-only \|") "catalog retains semantic authority: $slug"
    }
    $findingsPath = Join-Path $instructionsClone '.github/pr-quality-gate/data/findings.csv'
    $findingsBefore = (Get-FileHash -LiteralPath $findingsPath -Algorithm SHA256).Hash
    $env:COPILOT_INSTRUCTIONS_CLONE = $instructionsClone
    $runner = Join-Path $instructionsClone '.github/pr-quality-gate/gate-runner.ps1'
    $savedErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $pwsh -NoProfile -File $runner -BaseSha $base -HeadSha $head -Mode full -Verify -ProjectRoot $fixture 2>&1)
        $runnerExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    $outputText = $output -join "`n"
    if ($runnerExit -ne 0) { Write-Host $outputText }
    Assert-Equal 0 $runnerExit 'full gate accepts correctly managed semantic candidates'
    Assert-True ($outputText -match '(?m)^  gate_status: READY\r?$') 'mechanical gate status is READY'
    Assert-False ($outputText -match '(?m)^\s+hits: [1-9][0-9]*\s*$') 'no positive numeric findings remain'
    foreach ($slug in @('resource-cleanup', 'regex-validation')) {
        Assert-False ($outputText -match "(?m)^\s+- pattern: $slug\r?$") "removed coarse rule has no findings row: $slug"
    }
    foreach ($slug in $semanticSlugs) {
        Assert-True ($outputText -match "(?m)^  required_rule_ack: \[[^\r\n]*\b$slug\b") "semantic authority remains in required_rule_ack: $slug"
        Assert-True ($outputText -match "(?m)^\s+- pattern: $slug\r?\n\s+scope_mode: review-pass-only\r?\n\s+tier: HIGH\r?\n\s+hits: review-required") "semantic authority still requires review: $slug"
    }
    Assert-Equal $findingsBefore (Get-FileHash -LiteralPath $findingsPath -Algorithm SHA256).Hash '-Verify leaves findings.csv unchanged'
} finally {
    $env:COPILOT_INSTRUCTIONS_CLONE = $savedClone
    Remove-TestTempDirectories
}

Complete-TestRun
