#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Initialize-GateRunnerDependencies {
    [CmdletBinding()]
    param([switch] $CiMode)

    if (-not (Get-Command rg -ErrorAction SilentlyContinue)) {
        if ($CiMode -and $env:RUNNER_OS -eq 'Linux') {
            Write-Host 'ripgrep (rg) not found on the CI runner; installing via apt-get...'
            & sudo apt-get update -qq 2>&1 | Out-Null
            & sudo apt-get install -y -qq ripgrep 2>&1 | Out-Null
        }
        if (-not (Get-Command rg -ErrorAction SilentlyContinue)) {
            throw 'ripgrep (rg) is required by gate-runner but is not on PATH (install ripgrep - e.g. apt-get install ripgrep / winget install BurntSushi.ripgrep.MSVC - and retry)'
        }
    }
}

Export-ModuleMember -Function Initialize-GateRunnerDependencies
