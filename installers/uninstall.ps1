<#
.SYNOPSIS
    Remove GenFill from Nuke: deletes the installed build and the managed block
    in %USERPROFILE%\.nuke\init.py (backed up first). Your API keys in
    %USERPROFILE%\.nuke\genfill\config.json and generated images are kept.
#>
[CmdletBinding()]
param(
    [string]$Target = (Join-Path $env:USERPROFILE '.nuke\plugins\GenFill')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
. (Join-Path $PSScriptRoot 'common.ps1')

Write-Step 'Removing GenFill from init.py'
$text = Read-InitPy
if ($text -and $text.Contains($script:BeginMark)) {
    $backup = Backup-InitPy
    Write-Utf8NoBom $script:InitPy ((Remove-GenFillInitBlock $text).TrimEnd() + "`r`n")
    Write-Ok "done (backup: $backup)"
} else {
    Write-Ok 'no GenFill block found'
}

Assert-SafeTarget $Target
Write-Step "Removing installed build $Target"
if (Test-Path $Target) {
    Remove-Item -LiteralPath $Target -Recurse -Force
    Write-Ok 'removed'
} else {
    Write-Ok 'not installed there'
}
Write-Host ''
Write-Host 'GenFill uninstalled. Restart Nuke.' -ForegroundColor Green
exit 0
