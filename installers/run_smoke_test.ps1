<#
.SYNOPSIS
    Run the GenFill smoke test in Nuke's terminal mode (no GUI) and print the
    result. Results go to <repo>\test_output\report.json.

.NOTES
    Terminal mode (nuke -t) needs a Nuke license that allows it. If your
    license doesn't (e.g. some Indie / Non-commercial setups), run the test from
    inside Nuke instead: GenFill > Developer > Run Smoke Test. That version also
    captures a screenshot of the panel.
#>
[CmdletBinding()]
param([string]$NukeExe = '')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
. (Join-Path $PSScriptRoot 'common.ps1')

if (-not $NukeExe) {
    $nukes = @(Get-NukeInstalls)
    if ($nukes.Count -eq 0) { Write-Fail 'No Nuke found. Pass -NukeExe "C:\path\to\Nuke15.1.exe".'; exit 1 }
    $NukeExe = $nukes[0].Exe
}
$entry = Join-Path $PSScriptRoot 'nuke_smoke_test.py'
Write-Step "Running smoke test with $NukeExe"
Invoke-Native { & $NukeExe -t $entry | Out-Host }
$code = [int]$LASTEXITCODE
$report = Join-Path (Split-Path -Parent $PSScriptRoot) 'test_output\report.json'
Write-Host ''
if ($code -eq 0) {
    Write-Host 'Smoke test PASSED' -ForegroundColor Green
} else {
    Write-Host "Smoke test FAILED (exit $code)" -ForegroundColor Red
}
if (Test-Path $report) { Write-Ok "Report: $report" }
exit $code
