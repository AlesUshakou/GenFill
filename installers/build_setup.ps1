<#
.SYNOPSIS
    Build dist\GenFill-Setup.exe from installers\GenFill-Setup.ps1.

.DESCRIPTION
    Uses only what ships with Windows: the .NET Framework C# compiler (csc.exe)
    and Windows PowerShell 5.1. The exe embeds GenFill-Setup.ps1 and runs it
    in-process, with the GenFill icon rendered from the same vector logo the
    setup window uses. Attach the exe to a GitHub release for artists.

.EXAMPLE
    .\build_setup.ps1
#>
[CmdletBinding()]
param(
    [string]$OutDir = ''
)
$ErrorActionPreference = 'Stop'
if (-not $OutDir) { $OutDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'dist' }

$setup = Join-Path $PSScriptRoot 'GenFill-Setup.ps1'
$source = Join-Path $PSScriptRoot 'setup\GenFillSetup.cs'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw 'The .NET Framework 4 C# compiler (csc.exe) was not found.' }
$sma = [PSObject].Assembly.Location     # System.Management.Automation.dll

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$ico = Join-Path $OutDir 'GenFill.ico'
$exe = Join-Path $OutDir 'GenFill-Setup.exe'

Write-Host '==> Rendering the icon' -ForegroundColor Cyan
& powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File $setup -RenderIcon $ico
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $ico)) { throw 'Icon rendering failed.' }

Write-Host '==> Compiling' -ForegroundColor Cyan
& $csc /nologo /target:winexe /optimize+ /platform:anycpu "/out:$exe" "/win32icon:$ico" `
    "/reference:$sma" /reference:System.Windows.Forms.dll `
    "/resource:$setup,GenFill-Setup.ps1" $source
if ($LASTEXITCODE -ne 0) { throw "csc failed (exit $LASTEXITCODE)." }

$version = '?'
$init = Join-Path (Split-Path -Parent $PSScriptRoot) 'nuke\python\genfill\__init__.py'
if ((Get-Content $init -Raw) -match '__version__\s*=\s*"([^"]+)"') { $version = $Matches[1] }
Write-Host ''
Write-Host ("Built {0}  ({1:0} KB, GenFill {2})" -f $exe, ((Get-Item $exe).Length / 1KB), $version) -ForegroundColor Green
Write-Host 'The exe always installs the latest GenFill from GitHub (or the repo folder it is run from).'
