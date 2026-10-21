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
$savedGitShimExecutable = $env:GATE_RUNNER_TEST_GIT_EXE
$savedGitShimArgument = $env:GATE_RUNNER_TEST_GIT_ARG

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
        $env:GATE_RUNNER_TEST_GIT_EXE = $gitPath
        [IO.File]::WriteAllText((Join-Path $missingPwshProbeRoot 'git.cmd'), "@echo off`r`n`"%GATE_RUNNER_TEST_GIT_EXE%`" %*`r`nexit /b %ERRORLEVEL%`r`n", [Text.ASCIIEncoding]::new())
        [IO.File]::WriteAllText((Join-Path $missingPwshProbeRoot 'rg.cmd'), "@echo off`r`n`"$rgPath`" %*`r`nexit /b %ERRORLEVEL%`r`n", [Text.ASCIIEncoding]::new())
        $syntheticGitRoot = New-TestTempDirectory -Prefix ('non-ascii-percent-git-' + [char]0xE9 + '-%PATH%')
        $syntheticGitPath = Join-Path $syntheticGitRoot 'git.cmd'
        [IO.File]::WriteAllText($syntheticGitPath, "@echo off`r`necho unicode-percent-git-path-preserved %~1`r`nexit /b 17`r`n", [Text.ASCIIEncoding]::new())
        $env:GATE_RUNNER_TEST_GIT_EXE = $syntheticGitPath
        $env:GATE_RUNNER_TEST_GIT_ARG = 'literal-%PATH%-argument'
        $syntheticGitOutput = @(& (Join-Path $missingPwshProbeRoot 'git.cmd') '%GATE_RUNNER_TEST_GIT_ARG%' 2>&1)
        $syntheticGitExit = $LASTEXITCODE
        Assert-True ($syntheticGitPath.Contains([string]([char]0xE9))) 'synthetic Git executable path contains a non-ASCII character'
        Assert-True ($syntheticGitPath.Contains('%PATH%')) 'synthetic Git executable path contains a literal percent token'
        Assert-Equal 17 $syntheticGitExit 'ASCII shim propagates the synthetic Git exit code'
        Assert-Equal 'unicode-percent-git-path-preserved literal-%PATH%-argument' (($syntheticGitOutput -join "`n").Trim()) 'ASCII shim preserves non-ASCII path and literal percent tokens in path and arguments' -CaseSensitive
        $env:GATE_RUNNER_TEST_GIT_EXE = $gitPath
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

    $boundsSource = @'
using System;
using System.Collections.Generic;

internal static class BoundaryCases
{
    internal static int Guarded(int[] numbers)
    {
        if (numbers.Length == 0) return 0;
        const int second = 1;
        if (numbers.Length <= second) return 0;
        return numbers[0] + numbers[second] + numbers[1 - 1] + numbers[^1] + numbers[^second];
    }

    internal static int Unguarded(int[] numbers)
    {
        return numbers[0] + numbers[^1];
    }

    internal static int Ranked(int[,] plane, int[,,] volume)
    {
        if (plane.GetLowerBound(0) > 0 || plane.GetUpperBound(0) < 0 ||
            plane.GetLowerBound(1) > 1 || plane.GetUpperBound(1) < 1 ||
            volume.GetLowerBound(0) > 0 || volume.GetUpperBound(0) < 0 ||
            volume.GetLowerBound(1) > 1 || volume.GetUpperBound(1) < 1 ||
            volume.GetLowerBound(2) > 2 || volume.GetUpperBound(2) < 2) return 0;
        return plane[0, 1] + volume[0, 1, 2];
    }

    internal static int ZeroBased(int[,] plane)
    {
        if (plane.GetLowerBound(0) != 0 || plane.GetLowerBound(1) != 0 ||
            plane.GetLength(0) == 0 || plane.GetLength(1) < 2) return 0;
        return plane[0, 1];
    }

    internal static int UnsafeRank(int[,] plane, int[,,] volume)
    {
        return plane[0, 1] + volume[0, 1, 2];
    }

    internal static int VariableGuard(int[] numbers, int position)
    {
        if (position < 0 || position >= numbers.Length) return 0;
        return numbers[position];
    }

    internal static int SoleGuard(int[] values)
    {
        if (values.Length == 0) return 0;
        return values[0];
    }

    internal static int Mixed(int[,] plane, int row)
    {
        return plane[row, 0];
    }

    internal static int Variable(int[] numbers, int position, Index coordinate)
    {
        return numbers[position - 1] + numbers[^position] +
            numbers[coordinate] + numbers[numbers.Length - 1];
    }

    internal static int Sliced(int[] numbers, int position)
    {
        return numbers[position..^1].Length;
    }

    internal static void Positional(List<int> numbers, int position)
    {
        numbers.Insert(position, 0);
        numbers.RemoveAt(position);
        numbers.CopyTo(position, new int[0], 0, 0);
    }

    internal static bool Compared(int index, int length)
    {
        return index <= length;
    }

    internal static int Keyed(Dictionary<string, int> values)
    {
        return values["first"];
    }

    internal static int NonzeroBase()
    {
        Array values = Array.CreateInstance(typeof(int), new[] { 2 }, new[] { 1 });
        return (int)values.GetValue(1);
    }

    internal static int Buffers(int count)
    {
        Span<byte> fixedSize = stackalloc byte[256];
        const int MaxStackBytes = 128;
        Span<byte> capped = stackalloc byte[Math.Max(0, Math.Min(count, MaxStackBytes))];
        for (int iteration = 0; iteration < count; iteration++)
        {
            Span<byte> repeated = stackalloc byte[MaxStackBytes];
            fixedSize[0] += repeated[0];
        }
        return fixedSize.Length + capped.Length;
    }
}
'@
    $boundsHead = New-TestCommit -Directory $fixture -File 'Indexes.cs' -Content $boundsSource -Message 'Add boundary examples'
    $otherLanguage = @'
def read_positions(values, position):
    return values[0], values[-1], values[position], values[position:]
'@
    $nonCSharpHead = New-TestCommit -Directory $fixture -File 'Indexes.py' -Content $otherLanguage -Message 'Add language-aware examples'
    Assert-True ($boundsHead -ne $head -and $boundsHead -ne $nonCSharpHead) 'fixture records separate C# and non-C# additions'
    $guardChangedSource = $boundsSource.Replace('if (numbers.Length == 0) return 0;', 'if (numbers.Length < 0) return 0;').Replace(
        'if (position < 0 || position >= numbers.Length) return 0;',
        'if (position < 0 || position > numbers.Length) return 0;')
    $guardHead = New-TestCommit -Directory $fixture -File 'Indexes.cs' -Content $guardChangedSource -Message 'Change boundary proofs'
    $guardDiff = @(git -C $fixture diff --unified=0 "$nonCSharpHead..$guardHead" -- Indexes.cs) -join "`n"
    Assert-True ($guardDiff -match '\+.*numbers\.Length < 0' -and $guardDiff -match '\+.*position > numbers\.Length') 'guard-only change alters constant and variable proofs'
    Assert-False ($guardDiff -match '(?m)^\+[^+].*numbers\[(0|position)\]') 'guard-only change leaves both indexed accesses unchanged'
    $deletedGuardSource = $guardChangedSource.Replace('if (values.Length == 0) return 0;', '')
    $deletedGuardHead = New-TestCommit -Directory $fixture -File 'Indexes.cs' -Content $deletedGuardSource -Message 'Remove sole constant-index guard'
    $deletedGuardDiff = @(git -C $fixture diff --unified=0 "$guardHead..$deletedGuardHead" -- Indexes.cs) -join "`n"
    $soleGuardBody = [regex]::Match($deletedGuardSource, '(?s)internal static int SoleGuard\(int\[\] values\)\s*\{(?<body>.*?)\}')
    Assert-True ($deletedGuardDiff -match '(?m)^-[^-].*if \(values\.Length == 0\) return 0;' -and
        $soleGuardBody.Success -and $soleGuardBody.Groups['body'].Value -notmatch '\bif\s*\(' -and
        $soleGuardBody.Groups['body'].Value -match 'return values\[0\]') 'deleting the sole guard exposes an unchanged constant access'
    Assert-False ($deletedGuardDiff -match '(?m)^\+[^+].*values\[0\]') 'deleted guard leaves the constant access out of the diff'
    $legacyPattern = '\b\w+\[0\]|stackalloc \w+\[\w+\.Length\]'
    $legacyCount = & rg --count-matches -- $legacyPattern (Join-Path $fixture 'Indexes.cs')
    Assert-True ($LASTEXITCODE -eq 0 -and [int]$legacyCount -gt 0) 'old matcher nonvacuously hits a guarded constant index'

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
    $catalogPath = Join-Path $instructionsClone '.github/pr-quality-gate/pattern-catalog.md'
    $sourceCatalogPath = Join-Path $repoRoot '.github/pr-quality-gate/pattern-catalog.sources/00-catalog.md'
    $catalog = [IO.File]::ReadAllText($catalogPath)
    $sourceCatalog = [IO.File]::ReadAllText($sourceCatalogPath)
    $sourceCatalogBytes = [IO.File]::ReadAllBytes($sourceCatalogPath)
    $catalogBytes = [IO.File]::ReadAllBytes($catalogPath)
    Assert-False ($sourceCatalogBytes.Length -ge 3 -and $sourceCatalogBytes[0] -eq 0xEF -and
        $sourceCatalogBytes[1] -eq 0xBB -and $sourceCatalogBytes[2] -eq 0xBF) 'catalog source has no UTF-8 BOM'
    Assert-False ($catalogBytes.Length -ge 3 -and $catalogBytes[0] -eq 0xEF -and
        $catalogBytes[1] -eq 0xBB -and $catalogBytes[2] -eq 0xBF) 'generated catalog has no UTF-8 BOM'
    $catalogBanner = "<!-- GENERATED from pattern-catalog.sources/ - edit the source, then run scripts/generate-pattern-catalog.ps1 -->`n`n"
    $normalizedSourceCatalog = $sourceCatalog -replace "`r`n|`r", "`n"
    $normalizedCatalog = $catalog -replace "`r`n|`r", "`n"
    Assert-True ([string]::Equals(($catalogBanner + $normalizedSourceCatalog), $normalizedCatalog, [StringComparison]::Ordinal)) 'generated catalog matches source after both line endings are normalized'
    $sourceCrLfCopy = $normalizedSourceCatalog.Replace("`n", "`r`n")
    $generatedCrLfCopy = $normalizedCatalog.Replace("`n", "`r`n")
    Assert-True ($sourceCrLfCopy.Contains("`r`n") -and $generatedCrLfCopy.Contains("`r`n") -and
        [string]::Equals(($catalogBanner + ($sourceCrLfCopy -replace "`r`n|`r", "`n")),
            ($generatedCrLfCopy -replace "`r`n|`r", "`n"), [StringComparison]::Ordinal)) 'CRLF source and generated copies simulate a fresh Windows checkout'
    $sourceCrCopy = $normalizedSourceCatalog.Replace("`n", "`r")
    $generatedCrCopy = $normalizedCatalog.Replace("`n", "`r")
    Assert-True ([string]::Equals(($catalogBanner + ($sourceCrCopy -replace "`r`n|`r", "`n")),
        ($generatedCrCopy -replace "`r`n|`r", "`n"), [StringComparison]::Ordinal)) 'standalone CR source and generated copies normalize identically'
    $highIndex = [IO.File]::ReadAllText((Join-Path $instructionsClone '.github/pr-quality-gate/HIGH-TIER-SLUGS.md'))
    $boundsSlugs = @('bounds-empty-collection', 'off-by-one-bounds')
    $prompts = @{}
    foreach ($slug in $boundsSlugs) {
        $rowPattern = "(?m)^\| $([regex]::Escape($slug)) \|[^\r\n]*"
        $sourceRow = [regex]::Match($sourceCatalog, $rowPattern)
        $generatedRow = [regex]::Match($catalog, $rowPattern)
        Assert-True ($sourceRow.Success -and $sourceRow.Value -ceq $generatedRow.Value) "source and generated catalog agree on $slug"
        $cells = @($generatedRow.Value -split '(?<!\\)\|')
        Assert-Equal 8 $cells.Count "$slug has exactly six unescaped cells"
        Assert-Equal 'review-pass-only' $cells[2].Trim() "$slug uses semantic review only"
        Assert-Equal '{}' $cells[3].Trim() "$slug has no regex params"
        Assert-Equal 'MEDIUM' $cells[6].Trim() "$slug is included in triage"
        $prompts[$slug] = $cells[4].Trim()
        Assert-False ($highIndex.Contains("### ``$slug``")) "$slug is not in the HIGH-tier index"
    }
    $constantBoundaryPhrase = 'EACH coordinate is either a C# compile-time constant integral expression valid for the indexed operand (literal, const identifier, or constant arithmetic) OR a `System.Index`/from-end expression with compile-time constant integral operand accepted by that indexer, plus ALL C# `stackalloc`.'
    $ownedScopes = @{}
    foreach ($slug in $boundsSlugs) {
        Assert-Equal 1 ([regex]::Matches($prompts[$slug], [regex]::Escape($constantBoundaryPhrase)).Count) "$slug generated prompt shares the exact constant-index boundary"
        $cedeStart = $prompts[$slug].IndexOf('Cede to the owning rule:', [StringComparison]::Ordinal)
        Assert-True ($cedeStart -gt 0) "$slug separates owned cases from ceded cases"
        $ownedScopes[$slug] = $prompts[$slug].Substring(0, $cedeStart)
    }
    foreach ($clause in @(
        'EACH coordinate', 'compile-time constant integral', 'Do NOT assume multidimensional arrays accept `Index`',
        'GetLowerBound(d)<=coord<=GetUpperBound(d)', 'cited lower-bound-zero invariant', 'ALL C# `stackalloc`',
        'IN LOOPS per-iteration cap AND bounded cumulative use/fallback', 'guard/fill/capacity/alias proof changes/deletes',
        'probing_evidence', 'count including zero', 'EVERY `file:line`', 'Cede to the owning rule: `off-by-one-bounds`'
    )) {
        Assert-True ($prompts['bounds-empty-collection'].Contains($clause)) "constant-index prompt retains: $clause"
    }
    foreach ($clause in @(
        'ANY variable/computed coordinate', 'Range/slice endpoints', 'positional APIs', 'non-loop comparisons',
        'ALL non-C# indexes', 'negative indexing', 'keyed/map N/A ONLY with cited type/contract',
        'guard/fill/capacity/alias proof changes/deletes', 'Cede to the owning rule: `bounds-empty-collection`'
    )) {
        Assert-True ($prompts['off-by-one-bounds'].Contains($clause)) "variable-index prompt retains: $clause"
    }
    $ownershipCases = @(
        @{ File = $boundsSource; Site = 'numbers[0]'; Owner = 'bounds-empty-collection'; Clause = 'C# SINGLE/RANK-N' },
        @{ File = $boundsSource; Site = 'return values[0];'; Owner = 'bounds-empty-collection'; Clause = '1D ordinary' },
        @{ File = $boundsSource; Site = 'numbers[second]'; Owner = 'bounds-empty-collection'; Clause = 'const identifier' },
        @{ File = $boundsSource; Site = 'numbers[1 - 1]'; Owner = 'bounds-empty-collection'; Clause = 'constant arithmetic' },
        @{ File = $boundsSource; Site = 'numbers[^second]'; Owner = 'bounds-empty-collection'; Clause = 'compile-time constant integral operand' },
        @{ File = $boundsSource; Site = 'plane[0, 1]'; Owner = 'bounds-empty-collection'; Clause = 'GetLowerBound(d)' },
        @{ File = $boundsSource; Site = 'volume[0, 1, 2]'; Owner = 'bounds-empty-collection'; Clause = 'rank-N dimension d' },
        @{ File = $boundsSource; Site = 'stackalloc byte[256]'; Owner = 'bounds-empty-collection'; Clause = 'ALL C# `stackalloc`' },
        @{ File = $boundsSource; Site = 'stackalloc byte[MaxStackBytes]'; Owner = 'bounds-empty-collection'; Clause = 'IN LOOPS per-iteration cap' },
        @{ File = $boundsSource; Site = 'plane[row, 0]'; Owner = 'off-by-one-bounds'; Clause = 'ANY variable/computed coordinate' },
        @{ File = $boundsSource; Site = 'numbers[coordinate]'; Owner = 'off-by-one-bounds'; Clause = '`Index` variable' },
        @{ File = $boundsSource; Site = 'numbers[position..^1]'; Owner = 'off-by-one-bounds'; Clause = 'Range/slice endpoints' },
        @{ File = $boundsSource; Site = 'numbers.RemoveAt(position)'; Owner = 'off-by-one-bounds'; Clause = 'positional APIs (`Insert`, `RemoveAt`, `CopyTo`)' },
        @{ File = $boundsSource; Site = 'index <= length'; Owner = 'off-by-one-bounds'; Clause = 'non-loop comparisons' },
        @{ File = $otherLanguage; Site = 'values[0]'; Owner = 'off-by-one-bounds'; Clause = 'ALL non-C# indexes' },
        @{ File = $otherLanguage; Site = 'values[-1]'; Owner = 'off-by-one-bounds'; Clause = 'negative indexing' }
    )
    foreach ($ownershipCase in $ownershipCases) {
        Assert-True ($ownershipCase.File.Contains($ownershipCase.Site)) "ownership fixture contains $($ownershipCase.Site)"
        $matchingOwners = @($boundsSlugs | Where-Object { $ownedScopes[$_].Contains($ownershipCase.Clause) })
        Assert-Equal $ownershipCase.Owner ($matchingOwners -join ',') "exactly one owning rule covers $($ownershipCase.Site)"
        $nonOwner = @($boundsSlugs | Where-Object { $_ -ne $ownershipCase.Owner })[0]
        Assert-False ($ownedScopes[$nonOwner].Contains($ownershipCase.Clause)) "nonowner lacks the owning clause for $($ownershipCase.Site)"
    }
    Assert-True ($prompts['bounds-empty-collection'].Contains('Keyed/map with cited contract N/A') -and
        $prompts['off-by-one-bounds'].Contains('keyed/map N/A ONLY with cited type/contract') -and
        $boundsSource.Contains('values["first"]')) 'keyed access requires a cited type and contract, not a positional finding'
    Assert-True ($boundsSource.Contains('Array.CreateInstance') -and $boundsSource.Contains('values.GetValue(1)') -and
        $prompts['bounds-empty-collection'].Contains('Do NOT assume multidimensional arrays accept `Index`')) 'nonzero-based array uses an API, not illegal multidimensional Index syntax'
    $semanticSlugs = @('dispose-leak', 'regex-instance-without-matchtimeout-allows-catastrophic-backtracking')
    foreach ($slug in $semanticSlugs) {
        Assert-True ($catalog -match "(?m)^\| $slug \| review-pass-only \|") "catalog retains semantic authority: $slug"
        Assert-True ($highIndex.Contains("### ``$slug``")) "HIGH-tier semantic authority includes $slug"
    }
    $findingsPath = Join-Path $instructionsClone '.github/pr-quality-gate/data/findings.csv'
    $findingsBefore = (Get-FileHash -LiteralPath $findingsPath -Algorithm SHA256).Hash
    $env:COPILOT_INSTRUCTIONS_CLONE = $instructionsClone
    $runner = Join-Path $instructionsClone '.github/pr-quality-gate/gate-runner.ps1'
    $launcher = Join-Path $instructionsClone '.github/pr-quality-gate/invoke-panel.ps1'
    $noteRef = 'refs/notes/copilot-audit-precommit'
    Assert-Equal '' (@(git -C $instructionsClone for-each-ref --format='%(refname)' $noteRef) -join '') 'fixture clone starts without inherited audit notes'
    Assert-Equal '' (@(git -C $instructionsClone config --local --get core.hooksPath 2>$null) -join '') 'fixture clone starts without an installed hooks path'
    $savedErrorActionPreference = $ErrorActionPreference
    $runnerCases = @(
        @{ Name = 'unchanged semantic candidates'; Base = $base; Head = $head; Mode = 'full' },
        @{ Name = 'added indexes'; Base = $head; Head = $nonCSharpHead; Mode = 'full' },
        @{ Name = 'added indexes'; Base = $head; Head = $nonCSharpHead; Mode = 'triage' },
        @{ Name = 'added indexes'; Base = $head; Head = $nonCSharpHead; Mode = 'lint-only' },
        @{ Name = 'changed guards'; Base = $nonCSharpHead; Head = $guardHead; Mode = 'full' },
        @{ Name = 'changed guards'; Base = $nonCSharpHead; Head = $guardHead; Mode = 'triage' },
        @{ Name = 'changed guards'; Base = $nonCSharpHead; Head = $guardHead; Mode = 'lint-only' },
        @{ Name = 'deleted sole guard'; Base = $guardHead; Head = $deletedGuardHead; Mode = 'full' },
        @{ Name = 'deleted sole guard'; Base = $guardHead; Head = $deletedGuardHead; Mode = 'triage' },
        @{ Name = 'deleted sole guard'; Base = $guardHead; Head = $deletedGuardHead; Mode = 'lint-only' }
    )
    foreach ($runnerCase in $runnerCases) {
        try {
            $ErrorActionPreference = 'Continue'
            $runnerOutput = @(& $pwsh -NoProfile -File $runner -BaseSha $runnerCase.Base -HeadSha $runnerCase.Head -Mode $runnerCase.Mode -Verify -ProjectRoot $fixture 2>&1)
            $runnerExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $savedErrorActionPreference
        }
        $runnerText = $runnerOutput -join "`n"
        if ($runnerExit -ne 0) { Write-Host ($runnerText.Substring(0, [Math]::Min(2000, $runnerText.Length))) }
        $caseName = "$($runnerCase.Name), $($runnerCase.Mode)"
        Assert-Equal 0 $runnerExit "$caseName runner exits successfully"
        Assert-True ($runnerText -match '(?m)^  gate_status: READY\r?$') "$caseName mechanical gate remains READY pending semantic review"
        Assert-False ($runnerText -match '(?m)^\s+hits: [1-9][0-9]*\s*$') "$caseName has no numeric regex findings"
        $requiredAck = [regex]::Match($runnerText, '(?m)^  required_rule_ack: \[([^\r\n]*)\]')
        Assert-True $requiredAck.Success "$caseName emits a required-rule roster"
        $ackSlugs = @($requiredAck.Groups[1].Value -split ',\s*')
        foreach ($slug in @('resource-cleanup', 'regex-validation')) {
            Assert-False ($runnerText -match "(?m)^\s+- pattern: $slug\r?$") "$caseName excludes removed coarse rule $slug"
        }
        foreach ($slug in $semanticSlugs) {
            Assert-True ($ackSlugs -contains $slug) "$caseName retains HIGH-tier acknowledgement for $slug"
            Assert-True ($runnerText -match "(?m)^\s+- pattern: $slug\r?\n\s+scope_mode: review-pass-only\r?\n\s+tier: HIGH\r?\n\s+hits: review-required") "$caseName retains semantic review for $slug"
        }
        foreach ($slug in $boundsSlugs) {
            if ($runnerCase.Mode -eq 'lint-only') {
                Assert-False ($ackSlugs -contains $slug) "$caseName omits MEDIUM acknowledgement for $slug"
                Assert-False ($runnerText -match "(?m)^\s+- pattern: $slug\r?$") "$caseName omits MEDIUM findings for $slug"
            } else {
                Assert-True ($ackSlugs -contains $slug) "$caseName requires MEDIUM acknowledgement for $slug"
                Assert-True ($runnerText -match "(?m)^\s+- pattern: $slug\r?\n\s+scope_mode: review-pass-only\r?\n\s+tier: MEDIUM\r?\n\s+hits: review-required") "$caseName requires semantic review for $slug"
            }
        }
    }
    foreach ($mode in @('full', 'lite', 'triage', 'lint-only')) {
        try {
            $ErrorActionPreference = 'Continue'
            $panelOutput = @(& $pwsh -NoProfile -File $launcher -BaseSha $head -HeadSha $nonCSharpHead -Mode $mode -AskUserReceipt "${mode}-acknowledged" -AskUserCallRef 'fixture-call-ref' 2>&1)
            $panelExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $savedErrorActionPreference
        }
        $panelText = $panelOutput -join "`n"
        if ($panelExit -ne 0) { Write-Host ($panelText.Substring(0, [Math]::Min(2000, $panelText.Length))) }
        Assert-Equal 0 $panelExit "$mode launcher produces a contract"
        if ($mode -eq 'lint-only') {
            Assert-True ($panelText -match '(?m)^  panel_invoked: false\r?$') 'lint-only launcher explicitly reports no reviewer'
        }
        foreach ($slug in $boundsSlugs + $semanticSlugs) {
            $prompt = if ($boundsSlugs -contains $slug) { $prompts[$slug] } else {
                $semanticRow = [regex]::Match($sourceCatalog, "(?m)^\| $([regex]::Escape($slug)) \|[^\r\n]*")
                @($semanticRow.Value -split '(?<!\\)\|')[4].Trim()
            }
            $tier = if ($boundsSlugs -contains $slug) { 'MEDIUM' } else { 'HIGH' }
            $forwarded = "    - **${slug}** [tier=${tier}]: $prompt"
            $forwardCount = [regex]::Matches($panelText, [regex]::Escape($forwarded)).Count
            if ($mode -eq 'lint-only') {
                Assert-Equal 0 $forwardCount "$mode omits $slug without claiming reviewer coverage"
            } else {
                Assert-Equal 1 $forwardCount "$mode forwards exact source prompt once for $slug"
                Assert-True ($panelText -match "(?m)^  required_rule_ack: \[[^\r\n]*\b$slug\b") "$mode launch requires acknowledgement for $slug"
            }
        }
    }
    git -C $instructionsClone config core.hooksPath .githooks
    git -C $instructionsClone -c user.name=tester -c user.email=t@t.t notes --ref=$noteRef add -m 'fixture receipt' HEAD
    Assert-Equal 0 $LASTEXITCODE 'fixture can install hooks and an audit note locally'
    Assert-Equal '.githooks' (@(git -C $instructionsClone config --local --get core.hooksPath) -join '') 'fixture has an installed hooks path'
    Assert-Equal $noteRef (@(git -C $instructionsClone for-each-ref --format='%(refname)' $noteRef) -join '') 'fixture has a local audit note'
    try {
        $ErrorActionPreference = 'Continue'
        $notedOutput = @(& $pwsh -NoProfile -File $runner -BaseSha $guardHead -HeadSha $deletedGuardHead -Mode full -Verify -ProjectRoot $fixture 2>&1)
        $notedExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    Assert-Equal 0 $notedExit 'runner works with inherited hooks and audit note'
    Assert-True (($notedOutput -join "`n") -match '(?m)^  gate_status: READY\r?$') 'local audit note does not alter semantic gate status'
    Assert-Equal $findingsBefore (Get-FileHash -LiteralPath $findingsPath -Algorithm SHA256).Hash '-Verify leaves findings.csv unchanged'
} finally {
    $env:COPILOT_INSTRUCTIONS_CLONE = $savedClone
    $env:GATE_RUNNER_TEST_GIT_EXE = $savedGitShimExecutable
    $env:GATE_RUNNER_TEST_GIT_ARG = $savedGitShimArgument
    Remove-TestTempDirectories
}

Complete-TestRun
