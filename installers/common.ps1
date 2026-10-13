# Shared helpers for the GenFill installer scripts (dot-sourced).
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.

$script:BeginMark = '# >>> GenFill (managed by GenFill installers\install.ps1 - edits here are overwritten) >>>'
$script:EndMark = '# <<< GenFill <<<'
$script:NukeHome = Join-Path $env:USERPROFILE '.nuke'
$script:InitPy = Join-Path $script:NukeHome 'init.py'

function Write-Step([string]$msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg) { Write-Host "    $msg" -ForegroundColor Gray }
function Write-Warn([string]$msg) { Write-Host "    $msg" -ForegroundColor Yellow }
function Write-Fail([string]$msg) { Write-Host "    $msg" -ForegroundColor Red }

function Write-Utf8NoBom([string]$path, [string]$text) {
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-Native([scriptblock]$block) {
    # Windows PowerShell turns native stderr into terminating errors when
    # $ErrorActionPreference is Stop and stderr is redirected; relax it here.
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $block } finally { $ErrorActionPreference = $old }
}

function Get-NukeInstalls {
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, 'C:\Program Files') |
        Where-Object { $_ } | Select-Object -Unique
    $found = @()
    foreach ($root in $roots) {
        $dirs = Get-ChildItem -LiteralPath $root -Directory -Filter 'Nuke*' -ErrorAction SilentlyContinue
        foreach ($d in $dirs) {
            $exe = Get-ChildItem -LiteralPath $d.FullName -File -Filter 'Nuke*.exe' -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^Nuke\d+\.\d+\.exe$' } | Select-Object -First 1
            if (-not $exe) { continue }
            $ver = [version]'0.0.0'
            if ($d.Name -match 'Nuke(\d+)\.(\d+)v(\d+)') {
                $ver = [version]("{0}.{1}.{2}" -f $Matches[1], $Matches[2], $Matches[3])
            }
            $py = Join-Path $d.FullName 'python.exe'
            if (-not (Test-Path $py)) { $py = $null }
            $found += [pscustomobject]@{
                Name = $d.Name; Dir = $d.FullName; Exe = $exe.FullName; Python = $py; Version = $ver
            }
        }
    }
    return @($found | Sort-Object Version -Descending | Group-Object Exe | ForEach-Object { $_.Group[0] })
}

function Find-Python($nukes) {
    foreach ($n in $nukes) { if ($n.Python) { return $n.Python } }
    foreach ($name in @('py', 'python', 'python3')) {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue |
            Where-Object { $_.Source -notmatch 'WindowsApps' } | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }
    return $null
}

function Invoke-Tests([string]$python, [string]$repo) {
    Push-Location $repo
    try {
        # Out-Host keeps the test output on screen instead of in the return value.
        Invoke-Native { & $python -B -m unittest discover -s tests | Out-Host }
        return [int]$LASTEXITCODE
    } finally {
        Pop-Location
    }
}

function Get-GitInfo([string]$repo) {
    $info = [pscustomobject]@{ Commit = ''; Dirty = $false }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $info }
    if (-not (Test-Path (Join-Path $repo '.git'))) { return $info }
    $commit = Invoke-Native { git -C $repo rev-parse --short HEAD 2>$null }
    if ($LASTEXITCODE -eq 0 -and $commit) { $info.Commit = "$commit".Trim() }
    $status = Invoke-Native { git -C $repo status --porcelain 2>$null }
    $info.Dirty = [bool]("$status".Trim())
    return $info
}

function Assert-SafeTarget([string]$target) {
    $leaf = Split-Path $target -Leaf
    if ($leaf -notmatch 'GenFill') {
        throw "Refusing to use '$target' as the install folder: its name must contain 'GenFill' (it gets deleted and replaced on every install)."
    }
    $repoNuke = Join-Path (Split-Path -Parent $PSScriptRoot) 'nuke'
    if ((Resolve-Path -LiteralPath $target -ErrorAction SilentlyContinue) -and
        ((Resolve-Path -LiteralPath $target).Path -eq (Resolve-Path -LiteralPath $repoNuke).Path)) {
        throw 'The install folder cannot be the repository itself. Use -Mode dev for that.'
    }
}

function Remove-GenFillInitBlock([string]$text) {
    $pattern = '(?s)' + [regex]::Escape($script:BeginMark) + '.*?' + [regex]::Escape($script:EndMark) + '[ \t]*(\r?\n)?'
    return [regex]::Replace($text, $pattern, '')
}

function Read-InitPy {
    if (Test-Path $script:InitPy) { return [System.IO.File]::ReadAllText($script:InitPy) }
    return ''
}

function Backup-InitPy {
    if (-not (Test-Path $script:InitPy)) { return $null }
    $backup = "$($script:InitPy).genfill-backup"
    Copy-Item -LiteralPath $script:InitPy -Destination $backup -Force
    return $backup
}

function Set-GenFillInitBlock([string]$pluginPath) {
    if (-not (Test-Path $script:NukeHome)) { New-Item -ItemType Directory -Path $script:NukeHome | Out-Null }
    $backup = Backup-InitPy
    $text = Remove-GenFillInitBlock (Read-InitPy)

    # Comment out hand-written GenFill pluginAddPath lines (e.g. from the README)
    # so the plugin isn't loaded twice from two places.
    $disabled = @()
    $lines = @($text -split '\r?\n')
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l -match 'pluginAddPath' -and $l -match 'GenFill' -and $l -notmatch '^\s*#') {
            $disabled += $l.Trim()
            $lines[$i] = '# (disabled by GenFill installer) ' + $l
        }
    }
    $body = ($lines -join "`r`n").TrimEnd()

    $block = @(
        $script:BeginMark,
        'import nuke',
        ('nuke.pluginAddPath(r"{0}")' -f $pluginPath.TrimEnd('\')),
        $script:EndMark
    ) -join "`r`n"
    if ($body) { $new = $body + "`r`n`r`n" + $block + "`r`n" } else { $new = $block + "`r`n" }
    Write-Utf8NoBom $script:InitPy $new
    return [pscustomobject]@{ InitPy = $script:InitPy; Backup = $backup; Disabled = $disabled }
}
