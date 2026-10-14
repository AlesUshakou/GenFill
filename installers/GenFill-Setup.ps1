<#
.SYNOPSIS
    GenFill Setup: a graphical installer for artists.

.DESCRIPTION
    One window that installs (or updates, repairs, uninstalls) GenFill:
      1. downloads the latest GenFill from GitHub (or uses the repo it sits in),
      2. installs the plugin to %USERPROFILE%\.nuke\plugins\GenFill and adds the
         managed block to %USERPROFILE%\.nuke\init.py (same block as install.ps1,
         so the two installers are interchangeable),
      3. optionally installs the free Local AI right away by running the plugin's
         own genfill.localai.installer with Nuke's python.exe, streaming its
         progress into the window,
      4. registers GenFill under Windows "Installed apps" for uninstalling.

    Launch with GenFill-Setup.cmd (next to this file) or the GenFill-Setup.exe
    made by build_setup.ps1. Developers: install.ps1 is still the tests-first
    installer for builds from this repo.

.EXAMPLE
    .\GenFill-Setup.ps1
    .\GenFill-Setup.ps1 -Uninstall
    .\GenFill-Setup.ps1 -RenderIcon GenFill.ico     # used by build_setup.ps1
#>
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.
# Non-ASCII glyphs are written as XAML entities or [char] codes.
param(
    [switch]$Uninstall,
    [string]$RenderIcon = '',
    [string]$Snapshot = ''     # dev: render every page to PNGs in this folder and exit
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms
$Inv = [Globalization.CultureInfo]::InvariantCulture
[Threading.Thread]::CurrentThread.CurrentCulture = $Inv
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor
        [Net.SecurityProtocolType]::Tls12
} catch { }

# ------------------------------------------------------------------ constants
$GitHubRepo = 'iconnorthomas/GenFill'
$GitHubBranch = 'main'
$BeginMark = '# >>> GenFill (managed by GenFill installers\install.ps1 - edits here are overwritten) >>>'
$EndMark = '# <<< GenFill <<<'
$NukeHome = Join-Path $env:USERPROFILE '.nuke'
$InitPy = Join-Path $NukeHome 'init.py'
$DefaultTarget = Join-Path $NukeHome 'plugins\GenFill'
$ConfigDir = Join-Path $NukeHome 'genfill'
$SetupHome = Join-Path $env:LOCALAPPDATA 'GenFill\Setup'
$ArpKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\GenFill'
$LogPath = Join-Path $env:TEMP 'GenFill-Setup.log'
$IsExe = [bool]$env:GENFILL_SETUP_EXE
$SelfPath = if ($IsExe) { $env:GENFILL_SETUP_EXE } else { $PSCommandPath }

# Local AI: (id, label, model GB) - mirrors QUANTS in genfill/localai/installer.py
$Quants = @(
    @{ Id = 'Q4_K_S'; Name = 'Standard'; Gb = 6.8; For = '12 GB GPUs' },
    @{ Id = 'Q6_K'; Name = 'High'; Gb = 9.9; For = '16 GB+ GPUs' },
    @{ Id = 'Q8_0'; Name = 'Maximum'; Gb = 12.7; For = '24 GB+ GPUs' }
)
$AiOtherGb = 11.7     # T5 + CLIP + VAE + LaMa
$AiEnvGb = 7.0        # private Python + PyTorch
# Installer.STEPS in genfill/localai/installer.py, in order.
$AiSteps = @(
    @('Check GPU and disk space', 1), @('Get the Python environment tool', 1),
    @('Create the private Python environment', 3), @('Install PyTorch for your GPU (~3 GB)', 18),
    @('Install diffusers and model support', 6), @('Finish the environment', 3),
    @('Download FLUX.1 Fill, text encoders, VAE and LaMa', 55), @('Write model configs', 2),
    @('Self-test on your GPU', 8)
)

# ------------------------------------------------------------------ logo
function Get-SparkleData([double]$cx, [double]$cy, [double]$r) {
    $k = 0.16 * $r
    $p = @($cx, ($cy - $r), ($cx + $k), ($cy - $k), ($cx + $r), $cy, ($cx + $k), ($cy + $k),
        $cx, ($cy + $r), ($cx - $k), ($cy + $k), ($cx - $r), $cy, ($cx - $k), ($cy - $k))
    $s = $p | ForEach-Object { ([double]$_).ToString('0.##', $Inv) }
    return ('M{0},{1} Q{2},{3} {4},{5} Q{6},{7} {8},{9} Q{10},{11} {12},{13} Q{14},{15} {0},{1} Z' -f $s)
}
$Sparkles = (Get-SparkleData 41 59 27) + ' ' + (Get-SparkleData 71 29 13) + ' ' + (Get-SparkleData 73 71 8)
$LogoXaml = @"
<DrawingImage xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
  <DrawingImage.Drawing>
    <DrawingGroup>
      <GeometryDrawing>
        <GeometryDrawing.Brush>
          <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
            <GradientStop Color="#5B8CFF" Offset="0"/><GradientStop Color="#8E5BFF" Offset="1"/>
          </LinearGradientBrush>
        </GeometryDrawing.Brush>
        <GeometryDrawing.Geometry><RectangleGeometry Rect="0,0,100,100" RadiusX="24" RadiusY="24"/></GeometryDrawing.Geometry>
      </GeometryDrawing>
      <GeometryDrawing Brush="White" Geometry="$Sparkles"/>
    </DrawingGroup>
  </DrawingImage.Drawing>
</DrawingImage>
"@
$Logo = [Windows.Markup.XamlReader]::Parse($LogoXaml)

function Get-LogoBitmap([int]$size) {
    $dv = New-Object Windows.Media.DrawingVisual
    $dc = $dv.RenderOpen()
    $dc.DrawImage($Logo, (New-Object Windows.Rect 0, 0, $size, $size))
    $dc.Close()
    $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap $size, $size, 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($dv)
    return $bmp
}

if ($RenderIcon) {
    # .ico with PNG-compressed frames (Vista+), for the setup exe.
    $frames = foreach ($s in 256, 64, 48, 32, 24, 16) {
        $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create((Get-LogoBitmap $s)))
        $ms = New-Object IO.MemoryStream
        $enc.Save($ms)
        , @($s, $ms.ToArray())
    }
    $out = New-Object IO.MemoryStream
    $w = New-Object IO.BinaryWriter $out
    $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$frames.Count)
    $offset = 6 + 16 * $frames.Count
    foreach ($f in $frames) {
        $dim = if ($f[0] -ge 256) { 0 } else { $f[0] }
        $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
        $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$f[1].Length); $w.Write([uint32]$offset)
        $offset += $f[1].Length
    }
    foreach ($f in $frames) { $w.Write($f[1]) }
    $w.Flush()
    [IO.File]::WriteAllBytes([IO.Path]::GetFullPath($RenderIcon), $out.ToArray())
    return
}

# ------------------------------------------------------------------ system checks
function Get-NukeInstalls {
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, 'C:\Program Files') |
        Where-Object { $_ } | Select-Object -Unique
    $found = @()
    foreach ($root in $roots) {
        foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -Filter 'Nuke*' -ErrorAction SilentlyContinue)) {
            $exe = Get-ChildItem -LiteralPath $d.FullName -File -Filter 'Nuke*.exe' -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^Nuke\d+\.\d+\.exe$' } | Select-Object -First 1
            if (-not $exe) { continue }
            $ver = [version]'0.0.0'
            if ($d.Name -match 'Nuke(\d+)\.(\d+)v(\d+)') {
                $ver = [version]('{0}.{1}.{2}' -f $Matches[1], $Matches[2], $Matches[3])
            }
            $py = Join-Path $d.FullName 'python.exe'
            if (-not (Test-Path $py)) { $py = $null }
            $found += [pscustomobject]@{ Name = $d.Name; Exe = $exe.FullName; Python = $py; Version = $ver }
        }
    }
    return @($found | Sort-Object Version -Descending | Group-Object Exe | ForEach-Object { $_.Group[0] })
}

function Get-Gpu {
    try {
        $line = (& nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>$null |
            Select-Object -First 1)
        if ($line) {
            $parts = $line.Split(',')
            return [pscustomobject]@{ Name = $parts[0].Trim(); Vram = [math]::Round([double]$parts[1].Trim() / 1024, 1) }
        }
    } catch { }
    return $null
}

function Read-Json([string]$path) {
    try { if (Test-Path -LiteralPath $path) { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) } } catch { }
    return $null
}

function Get-PackageVersion([string]$pythonDir) {
    $init = Join-Path $pythonDir 'genfill\__init__.py'
    if ((Test-Path $init) -and ((Get-Content $init -Raw) -match '__version__\s*=\s*"([^"]+)"')) { return $Matches[1] }
    return $null
}

function Find-LocalRepo {
    $dir = Split-Path -Parent $SelfPath
    foreach ($c in @($dir, (Split-Path -Parent $dir))) {
        if ($c -and (Test-Path (Join-Path $c 'nuke\python\genfill\__init__.py'))) { return $c }
    }
    return $null
}

function Get-AiRoot {
    $cfg = Read-Json (Join-Path $ConfigDir 'config.json')
    if ($cfg -and $cfg.PSObject.Properties['local_ai'] -and $cfg.local_ai -and $cfg.local_ai.PSObject.Properties['root'] -and $cfg.local_ai.root) {
        return [string]$cfg.local_ai.root
    }
    return (Join-Path $env:USERPROFILE 'GenFill-LocalAI')
}

function Get-FolderGb([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return 0 }
    $sum = (Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    return [math]::Round(([double]$sum) / 1e9, 1)
}

$Nukes = @(Get-NukeInstalls)
# One entry per major.minor: the init.py block filters on (NUKE_VERSION_MAJOR, NUKE_VERSION_MINOR).
$NukeGroups = @($Nukes | Group-Object { '{0}.{1}' -f $_.Version.Major, $_.Version.Minor } | ForEach-Object {
    $builds = @($_.Group)
    [pscustomobject]@{ Key = $_.Name; Label = 'Nuke ' + $_.Name; Builds = $builds }
})

function Get-InitBlockFilter {
    # What the managed block loads in now: all, 'in' a list or 'notin' a list of major.minor.
    $r = @{ Present = $false; Mode = 'all'; List = @() }
    if (-not (Test-Path $InitPy)) { return $r }
    $text = [IO.File]::ReadAllText($InitPy)
    $m = [regex]::Match($text, '(?s)' + [regex]::Escape($BeginMark) + '(.*?)' + [regex]::Escape($EndMark))
    if (-not $m.Success) { return $r }
    $r.Present = $true
    $f = [regex]::Match($m.Groups[1].Value, 'NUKE_VERSION_MINOR\)\s+(not\s+in|in)\s*\[([^\]]*)\]')
    if ($f.Success) {
        $r.Mode = if ($f.Groups[1].Value -match 'not') { 'notin' } else { 'in' }
        $r.List = @([regex]::Matches($f.Groups[2].Value, '\((\d+)\s*,\s*(\d+)\)') | ForEach-Object { '{0}.{1}' -f $_.Groups[1].Value, $_.Groups[2].Value })
    }
    return $r
}
$InitFilter = Get-InitBlockFilter
$Python = ($Nukes | Where-Object { $_.Python } | Select-Object -First 1)
$Gpu = Get-Gpu
$LocalRepo = Find-LocalRepo
$Installed = $null
if (Test-Path (Join-Path $DefaultTarget 'python\genfill\__init__.py')) {
    $bi = Read-Json (Join-Path $DefaultTarget 'python\genfill\build_info.json')
    $Installed = if ($bi -and $bi.version) { [string]$bi.version } else { Get-PackageVersion (Join-Path $DefaultTarget 'python') }
}
$AiRootNow = Get-AiRoot
$AiManifest = Read-Json (Join-Path $AiRootNow 'manifest.json')
$AiReady = [bool]($AiManifest -and $AiManifest.PSObject.Properties['verified'] -and $AiManifest.verified)

# ------------------------------------------------------------------ window
[xml]$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="GenFill Setup" Width="848" Height="652" WindowStartupLocation="CenterScreen"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="CanMinimize"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13" Foreground="#E8EAF2"
        UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Resources>
    <LinearGradientBrush x:Key="Accent" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#5B8CFF" Offset="0"/><GradientStop Color="#8E5BFF" Offset="1"/>
    </LinearGradientBrush>
    <SolidColorBrush x:Key="Muted" Color="#8A90A6"/>
    <SolidColorBrush x:Key="Faint" Color="#5D6378"/>

    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="#E8EAF2"/>
      <Setter Property="Background" Value="#232838"/>
      <Setter Property="BorderBrush" Value="#30364A"/>
      <Setter Property="Padding" Value="20,0"/>
      <Setter Property="Height" Value="38"/>
      <Setter Property="MinWidth" Value="100"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border CornerRadius="9" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1"/>
              <Border x:Name="Hover" CornerRadius="9" Background="White" Opacity="0"/>
              <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Hover" Property="Opacity" Value="0.07"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Hover" Property="Opacity" Value="0.14"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="Foreground" Value="White"/>
    </Style>
    <Style x:Key="BtnDanger" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#E5484D"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="Foreground" Value="White"/>
    </Style>
    <Style x:Key="BtnGhost" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="Foreground" Value="#8A90A6"/>
      <Setter Property="FontWeight" Value="Normal"/>
      <Setter Property="Padding" Value="12,0"/>
      <Setter Property="MinWidth" Value="0"/>
    </Style>
    <Style x:Key="Chip" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Height" Value="30"/>
      <Setter Property="MinWidth" Value="0"/>
      <Setter Property="Padding" Value="12,0"/>
      <Setter Property="Margin" Value="0,0,8,8"/>
      <Setter Property="FontWeight" Value="Normal"/>
      <Setter Property="Background" Value="#1E2230"/>
      <Setter Property="BorderBrush" Value="#2C3144"/>
    </Style>
    <Style x:Key="WinBtn" TargetType="Button">
      <Setter Property="Width" Value="36"/>
      <Setter Property="Height" Value="28"/>
      <Setter Property="Margin" Value="0,8,6,0"/>
      <Setter Property="Foreground" Value="#8A90A6"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="Transparent" CornerRadius="7">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{Binding Tag, RelativeSource={RelativeSource TemplatedParent}}"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#181B26"/>
      <Setter Property="BorderBrush" Value="#242838"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="18,16"/>
    </Style>
    <Style x:Key="H1" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe UI Variable Display, Segoe UI"/>
      <Setter Property="FontSize" Value="26"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="Lead" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#8A90A6"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="LineHeight" Value="21"/>
    </Style>
    <Style x:Key="CardTitle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="Small" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#8A90A6"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#6E748A"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,14,0,7"/>
    </Style>

    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Width="42" Height="24" Background="Transparent">
              <Border x:Name="Track" CornerRadius="12" Background="#2A2F3F" BorderBrush="#3A4052" BorderThickness="1"/>
              <Ellipse x:Name="Knob" Width="16" Height="16" Fill="#AEB4C7" HorizontalAlignment="Left" Margin="4,0,0,0"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="{StaticResource Accent}"/>
                <Setter TargetName="Track" Property="BorderBrush" Value="Transparent"/>
                <Setter TargetName="Knob" Property="Fill" Value="White"/>
                <Setter TargetName="Knob" Property="Margin" Value="22,0,0,0"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Check" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#C9CDDA"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Background="Transparent">
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/></Grid.ColumnDefinitions>
              <Border x:Name="Box" Width="18" Height="18" CornerRadius="5" BorderBrush="#454B60" BorderThickness="1.5" VerticalAlignment="Top" Margin="0,1,0,0">
                <Path x:Name="Mark" Data="M3.2,7.6 L6.4,10.8 L12.2,4.4" Stroke="White" StrokeThickness="2" Visibility="Collapsed"
                      StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
              </Border>
              <ContentPresenter Grid.Column="1" Margin="10,0,0,0" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Box" Property="Background" Value="{StaticResource Accent}"/>
                <Setter TargetName="Box" Property="BorderBrush" Value="Transparent"/>
                <Setter TargetName="Mark" Property="Visibility" Value="Visible"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ChipCheck" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Foreground" Value="#8A90A6"/>
      <Setter Property="Margin" Value="0,0,8,8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="Bd" CornerRadius="16" Height="34" Padding="9,0,14,0" Background="#1D2130" BorderBrush="#2C3144" BorderThickness="1.5">
              <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                <Grid Width="18" Height="18" Margin="0,0,9,0">
                  <Ellipse x:Name="Dot" Stroke="#454B60" StrokeThickness="1.5"/>
                  <Ellipse x:Name="DotOn" Fill="{StaticResource Accent}" Visibility="Collapsed"/>
                  <Path x:Name="Mark" Data="M5,9.2 L7.8,12 L13,6.4" Stroke="White" StrokeThickness="1.7" Visibility="Collapsed"
                        StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
                </Grid>
                <ContentPresenter VerticalAlignment="Center"/>
              </StackPanel>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#3B4260"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="#5B6BD0"/>
                <Setter TargetName="Bd" Property="Background" Value="#20264A"/>
                <Setter TargetName="Dot" Property="Visibility" Value="Collapsed"/>
                <Setter TargetName="DotOn" Property="Visibility" Value="Visible"/>
                <Setter TargetName="Mark" Property="Visibility" Value="Visible"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.6"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SizeCard" TargetType="RadioButton">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Foreground" Value="#E8EAF2"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="Bd" CornerRadius="10" Background="#1D2130" BorderBrush="#2C3144" BorderThickness="1.5" Padding="12,10" Margin="0,0,8,0">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#3B4260"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource Accent}"/>
                <Setter TargetName="Bd" Property="Background" Value="#20264A"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Seg" TargetType="RadioButton">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Foreground" Value="#8A90A6"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="Bd" CornerRadius="7" Background="Transparent" Padding="14,6">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#2B3150"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Field" TargetType="TextBox">
      <Setter Property="Height" Value="36"/>
      <Setter Property="Foreground" Value="#E8EAF2"/>
      <Setter Property="CaretBrush" Value="White"/>
      <Setter Property="SelectionBrush" Value="#5B8CFF"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="Bd" CornerRadius="9" Background="#1D2130" BorderBrush="#2C3144" BorderThickness="1" Padding="10,0">
              <ScrollViewer x:Name="PART_ContentHost" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#5B8CFF"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Log" TargetType="TextBox">
      <Setter Property="Foreground" Value="#A9AFC2"/>
      <Setter Property="FontFamily" Value="Cascadia Mono, Consolas"/>
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="IsReadOnly" Value="True"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
      <Setter Property="SelectionBrush" Value="#5B8CFF"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border CornerRadius="12" Background="#0D0F15" BorderBrush="#222634" BorderThickness="1" Padding="12,10,4,10">
              <ScrollViewer x:Name="PART_ContentHost"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="10"/>
      <Setter Property="MinWidth" Value="10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.Thumb>
                <Thumb>
                  <Thumb.Template>
                    <ControlTemplate TargetType="Thumb"><Border CornerRadius="3" Background="#353B4F" Margin="2,0"/></ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal"><Setter Property="Visibility" Value="Collapsed"/></Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="Bar" TargetType="ProgressBar">
      <Setter Property="Height" Value="8"/>
      <Setter Property="Maximum" Value="100"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid>
              <Border x:Name="PART_Track" CornerRadius="4" Background="#232838"/>
              <Border x:Name="PART_Indicator" CornerRadius="4" HorizontalAlignment="Left" Background="{StaticResource Accent}"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border Margin="16" CornerRadius="14" Background="#12141C" BorderBrush="#272B3A" BorderThickness="1">
    <Border.Effect><DropShadowEffect BlurRadius="28" ShadowDepth="4" Opacity="0.6" Color="Black"/></Border.Effect>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="236"/><ColumnDefinition/></Grid.ColumnDefinitions>

      <!-- sidebar -->
      <Border x:Name="Sidebar" CornerRadius="13,0,0,13" BorderBrush="#20232F" BorderThickness="0,0,1,0">
        <Border.Background>
          <RadialGradientBrush GradientOrigin="0.1,0" Center="0.1,0" RadiusX="1.3" RadiusY="0.75">
            <GradientStop Color="#2C2F66" Offset="0"/><GradientStop Color="#1A1C2C" Offset="0.55"/><GradientStop Color="#151722" Offset="1"/>
          </RadialGradientBrush>
        </Border.Background>
        <Grid>
          <StackPanel Margin="28,34,20,0">
            <Image x:Name="LogoImg" Width="54" Height="54" HorizontalAlignment="Left"/>
            <TextBlock Text="GenFill" Style="{StaticResource H1}" Margin="0,18,0,0"/>
            <TextBlock Text="Generative Fill for Nuke" Foreground="{StaticResource Muted}" Margin="0,2,0,0"/>
            <StackPanel Margin="0,44,0,0">
              <StackPanel Orientation="Horizontal" Margin="0,0,0,18">
                <Border x:Name="NavDot0" Width="26" Height="26" CornerRadius="13" BorderThickness="1.5"><TextBlock x:Name="NavNum0" HorizontalAlignment="Center" VerticalAlignment="Center" FontSize="12" FontWeight="SemiBold"/></Border>
                <TextBlock x:Name="NavText0" Margin="12,0,0,0" VerticalAlignment="Center" FontSize="13.5"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal" Margin="0,0,0,18">
                <Border x:Name="NavDot1" Width="26" Height="26" CornerRadius="13" BorderThickness="1.5"><TextBlock x:Name="NavNum1" HorizontalAlignment="Center" VerticalAlignment="Center" FontSize="12" FontWeight="SemiBold"/></Border>
                <TextBlock x:Name="NavText1" Margin="12,0,0,0" VerticalAlignment="Center" FontSize="13.5"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal" Margin="0,0,0,18">
                <Border x:Name="NavDot2" Width="26" Height="26" CornerRadius="13" BorderThickness="1.5"><TextBlock x:Name="NavNum2" HorizontalAlignment="Center" VerticalAlignment="Center" FontSize="12" FontWeight="SemiBold"/></Border>
                <TextBlock x:Name="NavText2" Margin="12,0,0,0" VerticalAlignment="Center" FontSize="13.5"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal">
                <Border x:Name="NavDot3" Width="26" Height="26" CornerRadius="13" BorderThickness="1.5"><TextBlock x:Name="NavNum3" HorizontalAlignment="Center" VerticalAlignment="Center" FontSize="12" FontWeight="SemiBold"/></Border>
                <TextBlock x:Name="NavText3" Margin="12,0,0,0" VerticalAlignment="Center" FontSize="13.5"/>
              </StackPanel>
            </StackPanel>
          </StackPanel>
          <StackPanel VerticalAlignment="Bottom" Margin="28,0,20,24">
            <TextBlock FontSize="11.5" Foreground="{StaticResource Faint}">GenFill by
              <Hyperlink NavigateUri="https://github.com/iconnorthomas" Foreground="#9AA6E8" TextDecorations="None">Connor Thomas</Hyperlink></TextBlock>
            <TextBlock FontSize="11.5" Foreground="{StaticResource Faint}" Margin="0,3,0,0">Setup by
              <Hyperlink NavigateUri="https://www.linkedin.com/in/ales-ushakou" Foreground="#9AA6E8" TextDecorations="None">Ale&#353; Ushakou</Hyperlink></TextBlock>
            <TextBlock FontSize="11.5" Margin="0,10,0,0">
              <Hyperlink x:Name="CreditsLink" Foreground="#7C8DFF" TextDecorations="None">Credits</Hyperlink>
              <Run Text="  &#183;  " Foreground="#3F4458"/>
              <Hyperlink NavigateUri="https://github.com/iconnorthomas/GenFill" Foreground="#7C8DFF" TextDecorations="None">GitHub</Hyperlink>
              <Run x:Name="SideVersion" Text="" Foreground="#5D6378"/>
            </TextBlock>
          </StackPanel>
        </Grid>
      </Border>

      <!-- main -->
      <Grid Grid.Column="1">
        <Grid.RowDefinitions><RowDefinition Height="40"/><RowDefinition/><RowDefinition Height="78"/></Grid.RowDefinitions>

        <Grid x:Name="TitleBar" Background="Transparent">
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="BtnMin" Style="{StaticResource WinBtn}" Tag="#262A38">
              <Path Data="M0,0 L10,0" Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}" StrokeThickness="1.2"/>
            </Button>
            <Button x:Name="BtnClose" Style="{StaticResource WinBtn}" Tag="#E5484D">
              <Path Data="M0,0 L10,10 M10,0 L0,10" Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}" StrokeThickness="1.2"/>
            </Button>
          </StackPanel>
        </Grid>

        <Grid Grid.Row="1" Margin="40,4,40,0">

          <!-- welcome -->
          <StackPanel x:Name="PageWelcome">
            <TextBlock x:Name="WelcomeTitle" Style="{StaticResource H1}" Text="Welcome"/>
            <TextBlock Style="{StaticResource Lead}" Margin="0,10,0,0"
                       Text="Photoshop's Generative Fill as a Nuke node: draw a selection, type a prompt, pick a variation. This sets up the plugin and, if you like, a free AI that runs on your own GPU."/>
            <Border Style="{StaticResource Card}" Margin="0,26,0,0">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="104"/><ColumnDefinition/></Grid.ColumnDefinitions>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <TextBlock Text="Nuke" Foreground="{StaticResource Muted}" Margin="0,6,0,0"/>
                <WrapPanel x:Name="NukeChips" Grid.Column="1" Margin="0,0,0,6"/>
                <TextBlock Grid.Row="1" Text="GPU" Foreground="{StaticResource Muted}" Margin="0,8,0,0"/>
                <TextBlock x:Name="GpuText" Grid.Row="1" Grid.Column="1" Margin="0,8,0,0" TextWrapping="Wrap"/>
                <TextBlock Grid.Row="2" Text="Installed" Foreground="{StaticResource Muted}" Margin="0,14,0,0"/>
                <TextBlock x:Name="InstalledText" Grid.Row="2" Grid.Column="1" Margin="0,14,0,0" TextWrapping="Wrap"/>
                <TextBlock Grid.Row="3" Text="Latest" Foreground="{StaticResource Muted}" Margin="0,14,0,0"/>
                <TextBlock x:Name="LatestText" Grid.Row="3" Grid.Column="1" Margin="0,14,0,0" Foreground="{StaticResource Muted}" Text="checking GitHub..."/>
              </Grid>
            </Border>
          </StackPanel>

          <!-- options -->
          <ScrollViewer x:Name="PageOptions" VerticalScrollBarVisibility="Auto" Visibility="Collapsed" Margin="0,0,-16,0">
            <StackPanel Margin="0,0,16,16">
              <TextBlock Style="{StaticResource H1}" Text="Choose what to install"/>
              <Border x:Name="WarnNuke" Visibility="Collapsed" Margin="0,14,0,0" CornerRadius="10" Background="#2A2416" BorderBrush="#5A4A1E" BorderThickness="1" Padding="14,10">
                <TextBlock Foreground="#F5C561" TextWrapping="Wrap" Text="Nuke is open. You can install now, then restart Nuke to load the new build."/>
              </Border>
              <Border Style="{StaticResource Card}" Margin="0,18,0,0">
                <StackPanel>
                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <StackPanel>
                      <TextBlock Style="{StaticResource CardTitle}" Text="Nuke plugin"/>
                      <TextBlock Style="{StaticResource Small}" Margin="0,3,0,0" Text="Adds GenFill to the Nodes toolbar and Tab menu of the Nuke versions you pick."/>
                    </StackPanel>
                    <Border Grid.Column="1" CornerRadius="10" Background="#20264A" Padding="10,3" VerticalAlignment="Top">
                      <TextBlock Text="Required" FontSize="11" Foreground="#AFC0FF"/>
                    </Border>
                  </Grid>
                  <StackPanel x:Name="VersionsRow">
                    <TextBlock Style="{StaticResource Label}" Text="LOAD IN"/>
                    <WrapPanel x:Name="VersionChips" Margin="0,0,-8,-8"/>
                    <TextBlock x:Name="VersionsHint" Style="{StaticResource Small}" Margin="0,8,0,0"/>
                  </StackPanel>
                  <StackPanel x:Name="SourceRow" Visibility="Collapsed">
                    <TextBlock Style="{StaticResource Label}" Text="INSTALL FROM"/>
                    <Border Background="#1D2130" CornerRadius="9" Padding="3" HorizontalAlignment="Left">
                      <StackPanel Orientation="Horizontal">
                        <RadioButton x:Name="SrcGitHub" Style="{StaticResource Seg}" GroupName="src" Content="Latest from GitHub"/>
                        <RadioButton x:Name="SrcLocal" Style="{StaticResource Seg}" GroupName="src" Content="This folder"/>
                      </StackPanel>
                    </Border>
                  </StackPanel>
                  <TextBlock Style="{StaticResource Label}" Text="LOCATION"/>
                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <TextBox x:Name="TargetBox" Style="{StaticResource Field}"/>
                    <Button x:Name="TargetBrowse" Grid.Column="1" Style="{StaticResource Btn}" Height="36" MinWidth="0" Padding="14,0" Margin="8,0,0,0" Content="Browse"/>
                  </Grid>
                  <TextBlock x:Name="TargetError" Style="{StaticResource Small}" Foreground="#FF7A85" Margin="0,6,0,0" Visibility="Collapsed"/>
                </StackPanel>
              </Border>

              <Border Style="{StaticResource Card}" Margin="0,14,0,0">
                <StackPanel>
                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <StackPanel>
                      <StackPanel Orientation="Horizontal">
                        <TextBlock Style="{StaticResource CardTitle}" Text="Free local AI"/>
                        <Border x:Name="AiBadge" Margin="10,0,0,0" CornerRadius="10" Background="#173B2C" Padding="9,2" VerticalAlignment="Center" Visibility="Collapsed">
                          <TextBlock x:Name="AiBadgeText" FontSize="11" Foreground="#5BE0A0"/>
                        </Border>
                      </StackPanel>
                      <TextBlock x:Name="AiSub" Style="{StaticResource Small}" Margin="0,3,0,0"
                                 Text="FLUX.1 Fill and LaMa on your NVIDIA GPU. Offline, private, no tokens. One-time download."/>
                    </StackPanel>
                    <CheckBox x:Name="AiToggle" Grid.Column="1" Style="{StaticResource Switch}" VerticalAlignment="Top"/>
                  </Grid>
                  <StackPanel x:Name="AiOptions">
                    <TextBlock Style="{StaticResource Label}" Text="MODEL SIZE"/>
                    <UniformGrid Columns="3" Margin="0,0,-8,0">
                      <RadioButton x:Name="Q0" Style="{StaticResource SizeCard}" GroupName="q">
                        <StackPanel>
                          <TextBlock Text="Standard" FontWeight="SemiBold"/>
                          <TextBlock Style="{StaticResource Small}" Margin="0,3,0,0" Text="6.8 GB model"/>
                          <TextBlock Style="{StaticResource Small}" Text="for 12 GB GPUs"/>
                          <TextBlock x:Name="Q0Rec" Text="Best for your GPU" Foreground="#9DB1FF" FontSize="11.5" Margin="0,4,0,0" Visibility="Hidden"/>
                        </StackPanel>
                      </RadioButton>
                      <RadioButton x:Name="Q1" Style="{StaticResource SizeCard}" GroupName="q">
                        <StackPanel>
                          <TextBlock Text="High" FontWeight="SemiBold"/>
                          <TextBlock Style="{StaticResource Small}" Margin="0,3,0,0" Text="9.9 GB model"/>
                          <TextBlock Style="{StaticResource Small}" Text="for 16 GB+ GPUs"/>
                          <TextBlock x:Name="Q1Rec" Text="Best for your GPU" Foreground="#9DB1FF" FontSize="11.5" Margin="0,4,0,0" Visibility="Hidden"/>
                        </StackPanel>
                      </RadioButton>
                      <RadioButton x:Name="Q2" Style="{StaticResource SizeCard}" GroupName="q">
                        <StackPanel>
                          <TextBlock Text="Maximum" FontWeight="SemiBold"/>
                          <TextBlock Style="{StaticResource Small}" Margin="0,3,0,0" Text="12.7 GB model"/>
                          <TextBlock Style="{StaticResource Small}" Text="for 24 GB+ GPUs"/>
                          <TextBlock x:Name="Q2Rec" Text="Best for your GPU" Foreground="#9DB1FF" FontSize="11.5" Margin="0,4,0,0" Visibility="Hidden"/>
                        </StackPanel>
                      </RadioButton>
                    </UniformGrid>
                    <TextBlock Style="{StaticResource Label}" Text="LOCATION"/>
                    <Grid>
                      <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                      <TextBox x:Name="AiBox" Style="{StaticResource Field}"/>
                      <Button x:Name="AiBrowse" Grid.Column="1" Style="{StaticResource Btn}" Height="36" MinWidth="0" Padding="14,0" Margin="8,0,0,0" Content="Browse"/>
                    </Grid>
                    <TextBlock x:Name="AiDisk" Style="{StaticResource Small}" Margin="0,7,0,0"/>
                    <CheckBox x:Name="AiLicense" Style="{StaticResource Check}" Margin="0,14,0,0">
                      <TextBlock TextWrapping="Wrap" Foreground="#C9CDDA">I understand FLUX.1 Fill [dev] is licensed for non-commercial use only
                        (<Hyperlink x:Name="LicenseLink" Foreground="#7C8DFF">read the license</Hyperlink>).</TextBlock>
                    </CheckBox>
                  </StackPanel>
                </StackPanel>
              </Border>
            </StackPanel>
          </ScrollViewer>

          <!-- uninstall -->
          <StackPanel x:Name="PageUninstall" Visibility="Collapsed">
            <TextBlock Style="{StaticResource H1}" Text="Uninstall GenFill"/>
            <TextBlock Style="{StaticResource Lead}" Margin="0,10,0,0" Text="Removes GenFill from Nuke. Your scripts and the images GenFill generated are not touched."/>
            <Border Style="{StaticResource Card}" Margin="0,24,0,0">
              <StackPanel>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <StackPanel>
                    <TextBlock Style="{StaticResource CardTitle}" Text="Nuke plugin"/>
                    <TextBlock x:Name="UnPluginText" Style="{StaticResource Small}" Margin="0,3,0,0"/>
                  </StackPanel>
                  <CheckBox Grid.Column="1" Style="{StaticResource Switch}" IsChecked="True" IsEnabled="False" VerticalAlignment="Center"/>
                </Grid>
                <Border Height="1" Background="#242838" Margin="0,14"/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <StackPanel>
                    <TextBlock Style="{StaticResource CardTitle}" Text="Local AI"/>
                    <TextBlock x:Name="UnAiText" Style="{StaticResource Small}" Margin="0,3,0,0"/>
                  </StackPanel>
                  <CheckBox x:Name="UnAi" Grid.Column="1" Style="{StaticResource Switch}" VerticalAlignment="Center"/>
                </Grid>
                <Border Height="1" Background="#242838" Margin="0,14"/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <StackPanel>
                    <TextBlock Style="{StaticResource CardTitle}" Text="Settings and API keys"/>
                    <TextBlock x:Name="UnCfgText" Style="{StaticResource Small}" Margin="0,3,0,0"/>
                  </StackPanel>
                  <CheckBox x:Name="UnCfg" Grid.Column="1" Style="{StaticResource Switch}" VerticalAlignment="Center"/>
                </Grid>
              </StackPanel>
            </Border>
          </StackPanel>

          <!-- progress -->
          <Grid x:Name="PageProgress" Visibility="Collapsed">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition/></Grid.RowDefinitions>
            <TextBlock x:Name="ProgTitle" Style="{StaticResource H1}" Text="Installing GenFill"/>
            <TextBlock x:Name="ProgText" Grid.Row="1" Style="{StaticResource Small}" FontSize="12.5" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis" Margin="0,10,0,0" Text="Starting..."/>
            <Grid Grid.Row="2" Margin="0,14,0,18">
              <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="52"/></Grid.ColumnDefinitions>
              <ProgressBar x:Name="ProgBar" Style="{StaticResource Bar}" VerticalAlignment="Center"/>
              <TextBlock x:Name="ProgPct" Grid.Column="1" HorizontalAlignment="Right" FontWeight="SemiBold" Text="0%"/>
            </Grid>
            <Grid Grid.Row="3" Margin="0,0,0,8">
              <Border x:Name="StepCard" Style="{StaticResource Card}" Padding="18,16,6,4">
                <ScrollViewer x:Name="StepScroll" VerticalScrollBarVisibility="Auto">
                  <StackPanel x:Name="StepList" Margin="0,0,12,0"/>
                </ScrollViewer>
              </Border>
              <TextBox x:Name="LogBox" Style="{StaticResource Log}" Visibility="Collapsed"/>
            </Grid>
          </Grid>

          <!-- credits -->
          <ScrollViewer x:Name="PageCredits" VerticalScrollBarVisibility="Auto" Visibility="Collapsed" Margin="0,0,-16,0">
            <StackPanel Margin="0,0,16,16">
              <TextBlock Style="{StaticResource H1}" Text="Credits"/>
              <Border Style="{StaticResource Card}" Margin="0,20,0,0">
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions>
                  <StackPanel>
                    <TextBlock Style="{StaticResource Label}" Margin="0,0,0,6" Text="GENFILL"/>
                    <TextBlock FontSize="17" FontWeight="SemiBold" Text="Connor Thomas"/>
                    <TextBlock FontSize="12.5" Margin="0,4,0,0">
                      <Hyperlink NavigateUri="https://github.com/iconnorthomas" Foreground="#7C8DFF" TextDecorations="None">github.com/iconnorthomas</Hyperlink></TextBlock>
                  </StackPanel>
                  <StackPanel Grid.Column="1">
                    <TextBlock Style="{StaticResource Label}" Margin="0,0,0,6" Text="SETUP"/>
                    <TextBlock FontSize="17" FontWeight="SemiBold" Text="Ale&#353; Ushakou"/>
                    <TextBlock FontSize="12.5" Margin="0,4,0,0">
                      <Hyperlink NavigateUri="https://www.linkedin.com/in/ales-ushakou" Foreground="#7C8DFF" TextDecorations="None">linkedin.com/in/ales-ushakou</Hyperlink></TextBlock>
                  </StackPanel>
                </Grid>
              </Border>
              <Border Style="{StaticResource Card}" Margin="0,14,0,0">
                <StackPanel>
                  <TextBlock Style="{StaticResource CardTitle}" Text="Built on"/>
                  <ItemsControl x:Name="CreditList" Margin="0,6,0,0"/>
                </StackPanel>
              </Border>
              <TextBlock Style="{StaticResource Small}" Margin="2,14,0,0"
                         Text="Nuke is a trademark of The Foundry Visionmongers Ltd. GenFill is an independent project, not affiliated with or endorsed by Foundry, Black Forest Labs or Adobe."/>
            </StackPanel>
          </ScrollViewer>

          <!-- done -->
          <StackPanel x:Name="PageDone" Visibility="Collapsed">
            <Grid HorizontalAlignment="Left" Width="60" Height="60">
              <Ellipse x:Name="DoneCircle" Fill="{StaticResource Accent}"/>
              <Path x:Name="DoneOk" Data="M18,31 L26,39 L43,21" Stroke="White" StrokeThickness="3.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
              <Path x:Name="DoneFail" Data="M21,21 L39,39 M39,21 L21,39" Stroke="White" StrokeThickness="3.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Visibility="Collapsed"/>
            </Grid>
            <TextBlock x:Name="DoneTitle" Style="{StaticResource H1}" Margin="0,20,0,0"/>
            <TextBlock x:Name="DoneText" Style="{StaticResource Lead}" Margin="0,10,0,0"/>
            <Border x:Name="NextCard" Style="{StaticResource Card}" Margin="0,22,0,0">
              <StackPanel>
                <TextBlock Style="{StaticResource CardTitle}" Text="Next"/>
                <TextBlock x:Name="NextText" Style="{StaticResource Small}" FontSize="12.5" LineHeight="21" Margin="0,8,0,0"/>
                <StackPanel x:Name="LaunchRow">
                  <TextBlock Style="{StaticResource Label}" Text="START NUKE"/>
                  <WrapPanel x:Name="LaunchChips"/>
                </StackPanel>
              </StackPanel>
            </Border>
          </StackPanel>
        </Grid>

        <!-- footer -->
        <Border Grid.Row="2" BorderBrush="#20232F" BorderThickness="0,1,0,0" Padding="32,0,40,0">
          <Grid>
            <Button x:Name="BtnAlt" Style="{StaticResource BtnGhost}" HorizontalAlignment="Left" VerticalAlignment="Center"/>
            <TextBlock x:Name="FooterHint" Margin="12,0,0,0" VerticalAlignment="Center" Foreground="#F5C561" FontSize="12.5" Visibility="Collapsed"
                       Text=""/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
              <Button x:Name="BtnBack" Style="{StaticResource Btn}" Margin="0,0,10,0"/>
              <Button x:Name="BtnNext" Style="{StaticResource BtnPrimary}"/>
            </StackPanel>
          </Grid>
        </Border>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $Xaml))
$ui = @{}
foreach ($n in $Xaml.SelectNodes('//*[@*[local-name()="Name"]]')) {
    $name = $n.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
    if ($name) { $ui[$name] = $window.FindName($name) }
}
$ui.LogoImg.Source = $Logo
$window.Icon = Get-LogoBitmap 64

function Brush([string]$hex) { return (New-Object Windows.Media.BrushConverter).ConvertFromString($hex) }
function Res([string]$key) { return $window.FindResource($key) }

# ------------------------------------------------------------------ state
$S = @{
    Mode = 'install'; Page = ''; Busy = $false; Ok = $false
    Weights = @(); States = @(); Rows = @(); Frac = 0.0
    Version = $null; Latest = $null; LogTail = New-Object Text.StringBuilder
    PendingCleanup = $false
}
$sync = [hashtable]::Synchronized(@{
    Queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    Proc = $null; Cancel = $false; Latest = $null
})

function Write-SetupLog([string]$line) {
    try { [IO.File]::AppendAllText($LogPath, $line + "`r`n") } catch { }
}

# ------------------------------------------------------------------ navigation
$Check = [string][char]0x2713
function Set-Nav([string[]]$labels, [int]$active) {
    for ($i = 0; $i -lt 4; $i++) {
        $dot = $ui["NavDot$i"]; $num = $ui["NavNum$i"]; $txt = $ui["NavText$i"]
        $txt.Text = $labels[$i]
        if ($i -lt $active) {
            $dot.Background = Brush '#262C4C'; $dot.BorderBrush = Brush '#4E5BB0'
            $num.Text = $Check; $num.Foreground = Brush '#B6C3FF'; $txt.Foreground = Brush '#B9BED0'
        } elseif ($i -eq $active) {
            $dot.Background = Res 'Accent'; $dot.BorderBrush = Brush '#00000000'
            $num.Text = [string]($i + 1); $num.Foreground = Brush '#FFFFFF'; $txt.Foreground = Brush '#FFFFFF'
            $txt.FontWeight = 'SemiBold'
        } else {
            $dot.Background = Brush '#00000000'; $dot.BorderBrush = Brush '#363B4E'
            $num.Text = [string]($i + 1); $num.Foreground = Brush '#5D6378'; $txt.Foreground = Brush '#6E748A'
        }
        if ($i -ne $active) { $txt.FontWeight = 'Normal' }
    }
}

function Set-Button($btn, [string]$text, [string]$style) {
    if (-not $text) { $btn.Visibility = 'Collapsed'; return }
    $btn.Visibility = 'Visible'; $btn.Content = $text; $btn.IsEnabled = $true
    if ($style) { $btn.Style = Res $style }
}

$NavInstall = @('Welcome', 'Options', 'Install', 'Finish')
$NavRemove = @('Welcome', 'Uninstall', 'Remove', 'Finish')

function Show-Page([string]$page) {
    $S.Page = $page
    $ui.FooterHint.Visibility = 'Collapsed'
    foreach ($p in 'PageWelcome', 'PageOptions', 'PageUninstall', 'PageProgress', 'PageDone', 'PageCredits') {
        $ui[$p].Visibility = if ($p -eq "Page$page") { 'Visible' } else { 'Collapsed' }
    }
    $nav = if ($S.Mode -eq 'uninstall') { $NavRemove } else { $NavInstall }
    switch ($page) {
        'Welcome' {
            Set-Nav $NavInstall 0
            if ($Installed) { Set-Button $ui.BtnAlt 'Uninstall' 'BtnGhost' } else { Set-Button $ui.BtnAlt '' }
            Set-Button $ui.BtnBack ''
            Set-Button $ui.BtnNext $(if ($Installed) { 'Update or repair' } else { 'Get started' }) 'BtnPrimary'
        }
        'Options' {
            Set-Nav $nav 1
            Set-Button $ui.BtnAlt ''
            Set-Button $ui.BtnBack 'Back' 'Btn'
            Set-Button $ui.BtnNext $(if ($Installed) { 'Update' } else { 'Install' }) 'BtnPrimary'
            Update-Options
        }
        'Uninstall' {
            Set-Nav $nav 1
            Set-Button $ui.BtnAlt ''
            Set-Button $ui.BtnBack $(if ($Uninstall) { '' } else { 'Back' }) 'Btn'
            Set-Button $ui.BtnNext 'Uninstall' 'BtnDanger'
        }
        'Progress' {
            Set-Nav $nav 2
            Set-Button $ui.BtnAlt $(if ($ui.LogBox.Visibility -eq 'Visible') { 'Show steps' } else { 'Show details' }) 'BtnGhost'
            Set-Button $ui.BtnBack ''
            Set-Button $ui.BtnNext 'Cancel' 'Btn'
        }
        'Credits' {
            Set-Button $ui.BtnAlt ''
            Set-Button $ui.BtnBack ''
            Set-Button $ui.BtnNext 'Back' 'Btn'
        }
        'Done' {
            Set-Nav $nav 3
            Set-Button $ui.BtnAlt 'Open log' 'BtnGhost'
            if ($S.Ok) {
                Set-Button $ui.BtnBack ''
                Set-Button $ui.BtnNext 'Finish' 'BtnPrimary'
            } else {
                Set-Button $ui.BtnBack 'Close' 'Btn'
                Set-Button $ui.BtnNext 'Try again' 'BtnPrimary'
            }
        }
    }
}

# ------------------------------------------------------------------ welcome
function Add-Chip($panel, [string]$text, $tag, [bool]$primary) {
    $b = New-Object Windows.Controls.Button
    $b.Style = Res 'Chip'
    $b.Content = $text
    $b.Tag = $tag
    if ($primary) { $b.BorderBrush = Brush '#4E5BB0'; $b.Background = Brush '#20264A' }
    if (-not $tag) { $b.Cursor = [Windows.Input.Cursors]::Arrow; $b.IsHitTestVisible = $false }
    [void]$panel.Children.Add($b)
    return $b
}

if ($Nukes.Count -eq 0) {
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = 'Not found under Program Files. GenFill still installs; it loads in any Nuke 13 to 17.'
    $t.Foreground = Brush '#F5C561'; $t.TextWrapping = 'Wrap'; $t.Margin = '0,6,0,0'
    [void]$ui.NukeChips.Children.Add($t)
} else {
    foreach ($n in $Nukes) { [void](Add-Chip $ui.NukeChips ($n.Name -replace '^Nuke', 'Nuke ') $null $false) }
}
$ui.GpuText.Text = if ($Gpu) { '{0}  {2}  {1:0.#} GB' -f $Gpu.Name, $Gpu.Vram, [char]0x00B7 } else { 'No NVIDIA GPU found. Cloud models still work; the free local AI needs an NVIDIA GPU.' }
if (-not $Gpu) { $ui.GpuText.Foreground = Brush '#F5C561' }
$aiState = if ($AiReady) { 'local AI ready ({0})' -f $AiManifest.quant } elseif ($AiManifest) { 'local AI incomplete' } else { 'no local AI' }
$where = switch ($InitFilter.Mode) { 'in' { ', in Nuke ' + ($InitFilter.List -join ', ') } 'notin' { ', all Nuke except ' + ($InitFilter.List -join ', ') } default { '' } }
$ui.InstalledText.Text = if ($Installed) { "GenFill $Installed$where,  $aiState" } else { 'Not installed yet' }
if ($Installed) {
    $ui.WelcomeTitle.Text = 'GenFill is installed'
    $ui.InstalledText.Foreground = Brush '#5BE0A0'
}
$ui.SideVersion.Text = if ($Installed) { "  $([char]0x00B7)  v$Installed" } else { '' }

# Latest version on GitHub, fetched in the background.
$latestPs = [powershell]::Create()
[void]$latestPs.AddScript({
    param($sync, $url)
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $wc = New-Object Net.WebClient
        $wc.Headers['User-Agent'] = 'GenFill-Setup'
        $text = $wc.DownloadString($url)
        if ($text -match '__version__\s*=\s*"([^"]+)"') { $sync.Latest = $Matches[1] } else { $sync.Latest = '?' }
    } catch { $sync.Latest = 'offline' }
}).AddArgument($sync).AddArgument("https://raw.githubusercontent.com/$GitHubRepo/$GitHubBranch/nuke/python/genfill/__init__.py")
[void]$latestPs.BeginInvoke()

# ------------------------------------------------------------------ options
$ui.TargetBox.Text = $DefaultTarget
$VersionChecks = @{}
function New-ChipCheck([string]$text, [string]$tip, [bool]$checked) {
    $c = New-Object Windows.Controls.CheckBox
    $c.Style = Res 'ChipCheck'
    $c.Content = $text
    if ($tip) { $c.ToolTip = $tip }
    $c.IsChecked = $checked
    $c.Add_Click({ Update-Options })
    [void]$ui.VersionChips.Children.Add($c)
    return $c
}
foreach ($g in $NukeGroups) {
    $on = switch ($InitFilter.Mode) { 'in' { $InitFilter.List -contains $g.Key } 'notin' { $InitFilter.List -notcontains $g.Key } default { $true } }
    $VersionChecks[$g.Key] = New-ChipCheck $g.Label (($g.Builds | ForEach-Object { $_.Exe }) -join "`n") $on
    if ([int]($g.Key -split '\.')[0] -lt 13) {
        # Nuke 12 and older run Python 2: GenFill needs Nuke 13+.
        $VersionChecks[$g.Key].IsChecked = $false
        $VersionChecks[$g.Key].IsEnabled = $false
        $VersionChecks[$g.Key].ToolTip = 'GenFill needs Nuke 13 or newer (Python 3).'
    }
}
$OtherCheck = New-ChipCheck 'Other and future versions' 'Nuke versions not listed here, including ones you install later.' ($InitFilter.Mode -ne 'in')
if ($NukeGroups.Count -eq 0) { $OtherCheck.Content = 'Every Nuke version'; $OtherCheck.IsChecked = $true; $OtherCheck.IsEnabled = $false }
$ui.VersionsHint.Text = 'All Nuke versions read the same .nuke\init.py. GenFill adds a version check there, so it only loads where you want it.'

function Get-VersionChoice {
    $inc = @(); $exc = @()
    foreach ($g in $NukeGroups) { if ($VersionChecks[$g.Key].IsChecked) { $inc += $g.Key } else { $exc += $g.Key } }
    return @{ Include = $inc; Exclude = $exc; Other = [bool]$OtherCheck.IsChecked }
}
$ui.AiBox.Text = $AiRootNow
if ($LocalRepo) {
    $ui.SourceRow.Visibility = 'Visible'
    $ui.SrcLocal.Content = 'This folder  (' + (Split-Path -Leaf $LocalRepo) + ')'
    $ui.SrcLocal.ToolTip = $LocalRepo
    $ui.SrcLocal.IsChecked = $true
} else {
    $ui.SrcGitHub.IsChecked = $true
}
$recIdx = if (-not $Gpu -or $Gpu.Vram -lt 14) { 0 } elseif ($Gpu.Vram -lt 20) { 1 } else { 2 }
$ui["Q${recIdx}Rec"].Visibility = 'Visible'
$selIdx = $recIdx
if ($AiManifest -and $AiManifest.PSObject.Properties['quant']) {
    for ($i = 0; $i -lt 3; $i++) { if ($Quants[$i].Id -eq $AiManifest.quant) { $selIdx = $i } }
}
$ui["Q$selIdx"].IsChecked = $true

if (-not $Python) {
    $ui.AiToggle.IsChecked = $false; $ui.AiToggle.IsEnabled = $false
    $ui.AiSub.Text = "Needs Nuke's own Python, and no Nuke was found. Install it later in Nuke: GenFill > Local AI > Install / Repair."
} elseif ($AiReady) {
    $ui.AiToggle.IsChecked = $false
    $ui.AiBadge.Visibility = 'Visible'; $ui.AiBadgeText.Text = 'Installed'
    $ui.AiSub.Text = 'Already installed and working. Turn on to repair it or change the model size.'
} else {
    $ui.AiToggle.IsChecked = [bool]$Gpu
    if (-not $Gpu) { $ui.AiSub.Text = 'Needs an NVIDIA GPU with 8 GB+ VRAM, which was not found on this PC.' }
}
if ($AiReady) { $ui.AiLicense.IsChecked = $true }

function Get-SelectedQuant {
    for ($i = 0; $i -lt 3; $i++) { if ($ui["Q$i"].IsChecked) { return $Quants[$i] } }
    return $Quants[0]
}

function Update-Options {
    if ($S.Page -ne 'Options') { return }
    $ok = $true
    $target = $ui.TargetBox.Text.Trim()
    $err = ''
    if (-not $target) { $err = 'Choose a folder.' }
    elseif ((Split-Path $target -Leaf) -notmatch 'GenFill') { $err = "The folder name must contain 'GenFill': it is replaced on every update." }
    elseif ($LocalRepo -and ([IO.Path]::GetFullPath($target).TrimEnd('\') -eq (Join-Path $LocalRepo 'nuke'))) { $err = 'That is the repository itself. Pick another folder.' }
    $ui.TargetError.Text = $err
    $ui.TargetError.Visibility = if ($err) { 'Visible' } else { 'Collapsed' }
    if ($err) { $ok = $false }
    $hint = ''
    $vc = Get-VersionChoice
    if ($vc.Include.Count -eq 0 -and -not $vc.Other) { $ok = $false; $hint = 'Pick at least one Nuke version' }

    $on = [bool]$ui.AiToggle.IsChecked
    $ui.AiOptions.IsEnabled = $on
    $ui.AiOptions.Opacity = if ($on) { 1.0 } else { 0.45 }
    if ($on) {
        $q = Get-SelectedQuant
        $root = $ui.AiBox.Text.Trim()
        $need = $q.Gb + $AiOtherGb + $AiEnvGb
        $free = $null
        try { $free = (New-Object IO.DriveInfo ([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($root)))).AvailableFreeSpace / 1e9 } catch { }
        $ui.AiDisk.Foreground = Res 'Muted'
        if (-not $root) {
            $ui.AiDisk.Text = 'Choose a folder.'; $ok = $false
        } elseif ($root -match 'onedrive') {
            $ui.AiDisk.Text = 'Pick a folder outside OneDrive: about 30 GB would sync to the cloud.'
            $ui.AiDisk.Foreground = Brush '#FF7A85'; $ok = $false
        } elseif ($null -ne $free) {
            $drive = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($root)).TrimEnd('\')
            $ui.AiDisk.Text = 'Up to {0:0} GB on disk (already downloaded files are reused)  -  {1:0} GB free on {2}' -f $need, $free, $drive
            if ($free -lt 4) { $ui.AiDisk.Foreground = Brush '#FF7A85' } elseif ($free -lt $need + 2) { $ui.AiDisk.Foreground = Brush '#F5C561' }
        } else {
            $ui.AiDisk.Text = 'Up to {0:0} GB on disk.' -f $need
        }
        if (-not $ui.AiLicense.IsChecked) { $ok = $false }
    }
    if (-not $hint -and $on -and -not $ui.AiLicense.IsChecked) { $hint = 'Accept the FLUX license to continue' }
    $ui.FooterHint.Text = $hint
    $ui.FooterHint.Visibility = if ($hint) { 'Visible' } else { 'Collapsed' }
    $ui.BtnNext.IsEnabled = $ok
}

function Pick-Folder([string]$start, [string]$title) {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = $title
    $dlg.ShowNewFolderButton = $true
    $p = $start
    while ($p -and -not (Test-Path -LiteralPath $p)) { $p = Split-Path -Parent $p }
    if ($p) { $dlg.SelectedPath = $p }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
    return $null
}

$ui.TargetBox.Add_TextChanged({ Update-Options })
$ui.AiBox.Add_TextChanged({ Update-Options })
$ui.AiToggle.Add_Click({ Update-Options })
$ui.AiLicense.Add_Click({ Update-Options })
foreach ($i in 0, 1, 2) { $ui["Q$i"].Add_Checked({ Update-Options }) }
$ui.TargetBrowse.Add_Click({
    $p = Pick-Folder $ui.TargetBox.Text 'Where should the GenFill plugin go? A GenFill folder is created inside.'
    if ($p) {
        if ((Split-Path $p -Leaf) -notmatch 'GenFill') { $p = Join-Path $p 'GenFill' }
        $ui.TargetBox.Text = $p
    }
})
$ui.AiBrowse.Add_Click({
    $p = Pick-Folder $ui.AiBox.Text 'Where should the local AI go (about 30 GB)? A GenFill-LocalAI folder is created inside.'
    if ($p) {
        if ((Split-Path $p -Leaf) -notmatch 'GenFill') { $p = Join-Path $p 'GenFill-LocalAI' }
        $ui.AiBox.Text = $p
    }
})
$ui.LicenseLink.NavigateUri = [Uri]'https://huggingface.co/black-forest-labs/FLUX.1-Fill-dev/blob/main/LICENSE.md'

# ------------------------------------------------------------------ credits page
$Credits = @(
    @('FLUX.1 Fill [dev]', 'Black Forest Labs', 'FLUX.1 [dev] Non-Commercial License', 'https://huggingface.co/black-forest-labs/FLUX.1-Fill-dev'),
    @('FLUX.1 Fill GGUF quantizations', 'YarvixPA', 'FLUX.1 [dev] Non-Commercial License', 'https://huggingface.co/YarvixPA/FLUX.1-Fill-dev-gguf'),
    @('LaMa inpainting', 'Samsung AI Center (Suvorov et al.)', 'Apache 2.0', 'https://github.com/advimman/lama'),
    @('T5 v1.1 XXL text encoder', 'Google; bf16 encoder by city96', 'Apache 2.0', 'https://huggingface.co/city96/t5-v1_1-xxl-encoder-bf16'),
    @('CLIP ViT-L/14', 'OpenAI', 'MIT', 'https://huggingface.co/openai/clip-vit-large-patch14'),
    @('Diffusers, Transformers, Accelerate', 'Hugging Face', 'Apache 2.0', 'https://github.com/huggingface/diffusers'),
    @('gguf', 'ggml / llama.cpp authors', 'MIT', 'https://github.com/ggml-org/llama.cpp'),
    @('PyTorch', 'PyTorch Foundation', 'BSD-3-Clause', 'https://pytorch.org'),
    @('uv', 'Astral', 'Apache 2.0 / MIT', 'https://github.com/astral-sh/uv')
)
foreach ($c in $Credits) {
    $g = New-Object Windows.Controls.Grid
    $g.Margin = '0,10,0,0'
    foreach ($w in '*', 'Auto') {
        $cd = New-Object Windows.Controls.ColumnDefinition
        $cd.Width = (New-Object Windows.GridLengthConverter).ConvertFromString($w)
        $g.ColumnDefinitions.Add($cd)
    }
    $left = New-Object Windows.Controls.StackPanel
    $name = New-Object Windows.Controls.TextBlock
    $link = New-Object Windows.Documents.Hyperlink
    $link.Inlines.Add($c[0]); $link.NavigateUri = [Uri]$c[3]
    $link.Foreground = Brush '#E8EAF2'; $link.TextDecorations = $null
    $name.Inlines.Add($link)
    $by = New-Object Windows.Controls.TextBlock
    $by.Text = $c[1]; $by.Foreground = Res 'Muted'; $by.FontSize = 12; $by.Margin = '0,1,0,0'
    [void]$left.Children.Add($name); [void]$left.Children.Add($by)
    $lic = New-Object Windows.Controls.Border
    $lic.CornerRadius = 9; $lic.Padding = '9,2'; $lic.Background = Brush '#1F2333'; $lic.VerticalAlignment = 'Top'; $lic.Margin = '12,2,0,0'
    $lt = New-Object Windows.Controls.TextBlock
    $lt.Text = $c[2]; $lt.FontSize = 11; $lt.Foreground = Brush $(if ($c[2] -match 'Non-Commercial') { '#F5C561' } else { '#9AA0B5' })
    $lic.Child = $lt
    [Windows.Controls.Grid]::SetColumn($lic, 1)
    [void]$g.Children.Add($left); [void]$g.Children.Add($lic)
    [void]$ui.CreditList.Items.Add($g)
}
$window.AddHandler([Windows.Documents.Hyperlink]::RequestNavigateEvent, [Windows.Navigation.RequestNavigateEventHandler] {
    param($sender, $e)
    Start-Process $e.Uri.AbsoluteUri
    $e.Handled = $true
})
$ui.CreditsLink.Add_Click({
    if ($S.Page -ne 'Credits') { $S.PrevPage = $S.Page; Show-Page 'Credits' }
})

# ------------------------------------------------------------------ uninstall page
$ui.UnPluginText.Text = if ($Installed) { "GenFill $Installed in $DefaultTarget, and its line in init.py" } else { 'Not found in the default location; init.py is cleaned up anyway.' }
if (Test-Path -LiteralPath $AiRootNow) {
    $ui.UnAiText.Text = "$AiRootNow  -  measuring..."
    $ui.UnAi.IsChecked = $false
} else {
    $ui.UnAiText.Text = 'Not installed'
    $ui.UnAi.IsEnabled = $false
}
$ui.UnCfgText.Text = "$ConfigDir  -  keep it if you'll reinstall later"

# ------------------------------------------------------------------ progress page
$StepRowXaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="0,0,0,13">
  <Grid.ColumnDefinitions><ColumnDefinition Width="32"/><ColumnDefinition/></Grid.ColumnDefinitions>
  <Grid Width="20" Height="20" HorizontalAlignment="Left">
    <Ellipse x:Name="SPending" Stroke="#363B4E" StrokeThickness="1.5"/>
    <Grid x:Name="SRunning" Visibility="Collapsed">
      <Ellipse Stroke="#262B42" StrokeThickness="2"/>
      <Path Width="20" Height="20" Stroke="#7C8DFF" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
            Data="M10,1 A9,9 0 0 1 19,10" RenderTransformOrigin="0.5,0.5">
        <Path.RenderTransform><RotateTransform/></Path.RenderTransform>
        <Path.Triggers>
          <EventTrigger RoutedEvent="Loaded">
            <BeginStoryboard><Storyboard>
              <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(RotateTransform.Angle)" From="0" To="360" Duration="0:0:0.9" RepeatBehavior="Forever"/>
            </Storyboard></BeginStoryboard>
          </EventTrigger>
        </Path.Triggers>
      </Path>
    </Grid>
    <Grid x:Name="SDone" Visibility="Collapsed">
      <Ellipse Fill="#2BB673"/>
      <Path Data="M6,10.3 L8.8,13 L14.2,7.4" Stroke="White" StrokeThickness="1.8" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
    </Grid>
    <Grid x:Name="SFail" Visibility="Collapsed">
      <Ellipse Fill="#E5484D"/>
      <Path Data="M7,7 L13,13 M13,7 L7,13" Stroke="White" StrokeThickness="1.8" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
    </Grid>
    <Grid x:Name="SSkip" Visibility="Collapsed">
      <Ellipse Stroke="#363B4E" StrokeThickness="1.5"/>
      <Path Data="M6.5,10 L13.5,10" Stroke="#6E748A" StrokeThickness="1.8" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
    </Grid>
  </Grid>
  <TextBlock x:Name="SLabel" Grid.Column="1" VerticalAlignment="Center" FontSize="13.5" Foreground="#6E748A"/>
</Grid>
'@

function New-Steps($steps) {
    $ui.StepList.Children.Clear()
    $S.Rows = @(); $S.Weights = @(); $S.States = @(); $S.Frac = 0.0
    foreach ($st in $steps) {
        $row = [Windows.Markup.XamlReader]::Parse($StepRowXaml)
        $row.FindName('SLabel').Text = $st[0]
        [void]$ui.StepList.Children.Add($row)
        $S.Rows += $row; $S.Weights += [double]$st[1]; $S.States += 'pending'
    }
    $ui.ProgBar.Value = 0; $ui.ProgPct.Text = '0%'
    $ui.LogBox.Clear(); $ui.LogBox.Visibility = 'Collapsed'; $ui.StepCard.Visibility = 'Visible'
}

function Set-StepState([int]$i, [string]$state) {
    if ($i -lt 0 -or $i -ge $S.Rows.Count) { return }
    $S.States[$i] = $state
    if ($state -eq 'running') { $S.Frac = 0.0 }
    $row = $S.Rows[$i]
    foreach ($k in 'pending', 'running', 'done', 'failed', 'skipped') {
        $el = $row.FindName(@{ pending = 'SPending'; running = 'SRunning'; done = 'SDone'; failed = 'SFail'; skipped = 'SSkip' }[$k])
        $el.Visibility = if ($k -eq $state) { 'Visible' } else { 'Collapsed' }
    }
    $label = $row.FindName('SLabel')
    $label.Foreground = Brush $(switch ($state) { 'running' { '#FFFFFF' } 'done' { '#B9BED0' } 'failed' { '#FF7A85' } default { '#6E748A' } })
    $label.FontWeight = if ($state -eq 'running') { 'SemiBold' } else { 'Normal' }
    if ($state -eq 'running') { $row.BringIntoView() }
    Update-Overall
}

function Update-Overall {
    $total = 0.0; $done = 0.0
    for ($i = 0; $i -lt $S.Weights.Count; $i++) {
        $w = $S.Weights[$i]; $total += $w
        if ($S.States[$i] -in 'done', 'skipped') { $done += $w }
        elseif ($S.States[$i] -eq 'running') { $done += $w * $S.Frac }
    }
    $pct = if ($total -gt 0) { [math]::Min(100, 100.0 * $done / $total) } else { 0 }
    $ui.ProgBar.Value = $pct
    $ui.ProgPct.Text = '{0:0}%' -f [math]::Floor($pct)
}

# ------------------------------------------------------------------ worker (runs in a background runspace)
$Worker = {
    param($o, $sync)
    $ErrorActionPreference = 'Stop'
    [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

    function Emit([string]$kind, [hashtable]$d) { $d['kind'] = $kind; $sync.Queue.Enqueue($d) }
    function Log([string]$l) { Emit 'log' @{ line = $l } }
    function Prog($f, [string]$t) { Emit 'progress' @{ fraction = $f; text = $t } }
    function StepState([int]$i, [string]$s) { Emit 'step' @{ index = $i; state = $s } }
    function Write-Utf8NoBom([string]$path, [string]$text) {
        [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
    }
    function Remove-InitBlock([string]$text) {
        $pattern = '(?s)' + [regex]::Escape($o.BeginMark) + '.*?' + [regex]::Escape($o.EndMark) + '[ \t]*(\r?\n)?'
        return [regex]::Replace($text, $pattern, '')
    }
    function Backup-InitPy {
        if (Test-Path $o.InitPy) {
            Copy-Item -LiteralPath $o.InitPy -Destination "$($o.InitPy).genfill-backup" -Force
            Log "backed up init.py to $($o.InitPy).genfill-backup"
        }
    }
    function Assert-Safe([string]$path) {
        if ((Split-Path $path -Leaf) -notmatch 'GenFill') { throw "Refusing to delete '$path': its name must contain GenFill." }
    }
    function Stop-AiHelper([string]$root) {
        if (-not $root) { return }
        $full = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
        foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
            $path = $null
            try { $path = $p.Path } catch { }
            if ($path -and $path.StartsWith($full, [StringComparison]::OrdinalIgnoreCase)) {
                Log "stopping AI helper process $($p.Id) ($path)"
                try { $p.Kill(); $p.WaitForExit(5000) | Out-Null } catch { }
            }
        }
    }

    $cur = 0
    $ok = $false; $message = ''; $aiMessage = ''
    try {
        if ($o.Mode -eq 'install') {
            # ---- 0: get the source
            $cur = 0; StepState 0 'running'
            $commit = ''
            if ($o.Source -eq 'local') {
                $src = $o.LocalRepo
                $origin = $src
                Log "using the GenFill source in $src"
                try {
                    $c = & git -C $src rev-parse --short HEAD 2>$null
                    if ($LASTEXITCODE -eq 0 -and $c) { $commit = "$c".Trim() }
                    $st = & git -C $src status --porcelain 2>$null
                    if ("$st".Trim()) { $commit += '*' }
                } catch { }
            } else {
                $tmp = Join-Path $env:TEMP ('GenFill-Setup-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
                New-Item -ItemType Directory -Path $tmp | Out-Null
                $zip = Join-Path $tmp 'GenFill.zip'
                $url = "https://codeload.github.com/$($o.Repo)/zip/refs/heads/$($o.Branch)"
                Prog 0.15 'Downloading GenFill from GitHub...'
                Log "GET $url"
                $wc = New-Object Net.WebClient
                $wc.Headers['User-Agent'] = 'GenFill-Setup'
                try { $wc.DownloadFile($url, $zip) }
                catch { throw "Couldn't download GenFill from GitHub. Check your internet connection. ($($_.Exception.Message))" }
                Log ('downloaded {0:0.0} MB' -f ((Get-Item $zip).Length / 1MB))
                Prog 0.7 'Unpacking...'
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                [IO.Compression.ZipFile]::ExtractToDirectory($zip, (Join-Path $tmp 'x'))
                $src = (Get-ChildItem (Join-Path $tmp 'x') -Directory | Select-Object -First 1).FullName
                $origin = "github.com/$($o.Repo) ($($o.Branch))"
                try {
                    $api = New-Object Net.WebClient
                    $api.Headers['User-Agent'] = 'GenFill-Setup'
                    $api.Headers['Accept'] = 'application/vnd.github.sha'
                    $sha = $api.DownloadString("https://api.github.com/repos/$($o.Repo)/commits/$($o.Branch)")
                    if ($sha -match '^[0-9a-f]{7,}') { $commit = $sha.Substring(0, 7) }
                } catch { Log 'could not read the commit id (GitHub API); that is fine' }
            }
            $pkgInit = Join-Path $src 'nuke\python\genfill\__init__.py'
            if (-not (Test-Path $pkgInit)) { throw "This doesn't look like GenFill: $pkgInit is missing." }
            $version = '?'
            if ((Get-Content $pkgInit -Raw) -match '__version__\s*=\s*"([^"]+)"') { $version = $Matches[1] }
            Emit 'meta' @{ version = $version }
            Log "GenFill $version $commit"
            StepState 0 'done'

            # ---- 1: plugin + init.py + Windows registration
            $cur = 1; StepState 1 'running'
            $target = $o.Target
            Assert-Safe $target
            Prog 0.1 "Copying the plugin to $target"
            if (Test-Path -LiteralPath $target) {
                try { Remove-Item -LiteralPath $target -Recurse -Force }
                catch { throw "Couldn't replace the previous build in $target ($($_.Exception.Message)). Close Nuke and try again." }
            }
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            Copy-Item -Path (Join-Path $src 'nuke\*') -Destination $target -Recurse -Force
            Get-ChildItem -LiteralPath $target -Recurse -Directory -Filter '__pycache__' | Remove-Item -Recurse -Force
            $info = [ordered]@{
                version = $version; commit = $commit.TrimEnd('*'); dirty = $commit.EndsWith('*')
                built = (Get-Date -Format 'yyyy-MM-dd HH:mm'); mode = 'copy'; source = $origin
            }
            Write-Utf8NoBom (Join-Path $target 'python\genfill\build_info.json') ($info | ConvertTo-Json)
            Log "copied the plugin to $target"

            Prog 0.5 'Adding GenFill to your Nuke init.py'
            if (-not (Test-Path $o.NukeHome)) { New-Item -ItemType Directory -Path $o.NukeHome | Out-Null }
            Backup-InitPy
            $text = if (Test-Path $o.InitPy) { [IO.File]::ReadAllText($o.InitPy) } else { '' }
            $text = Remove-InitBlock $text
            $lines = @($text -split '\r?\n')
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $l = $lines[$i]
                if ($l -match 'pluginAddPath' -and $l -match 'GenFill' -and $l -notmatch '^\s*#') {
                    Log "disabled an older GenFill line so it doesn't load twice: $($l.Trim())"
                    $lines[$i] = '# (disabled by GenFill installer) ' + $l
                }
            }
            $body = ($lines -join "`r`n").TrimEnd()
            $add = 'nuke.pluginAddPath(r"{0}")' -f $target.TrimEnd('\')
            $tuples = { param($keys) '[' + ((@($keys) | ForEach-Object { '({0}, {1})' -f ($_ -split '\.') }) -join ', ') + ']' }
            if ($o.Other -and @($o.Exclude).Count -eq 0) {
                $load = @($add)
                Log 'GenFill loads in every Nuke version'
            } elseif ($o.Other) {
                $load = @(('if (nuke.NUKE_VERSION_MAJOR, nuke.NUKE_VERSION_MINOR) not in {0}:' -f (& $tuples $o.Exclude)), "    $add")
                Log ('GenFill loads in every Nuke version except ' + (@($o.Exclude) -join ', '))
            } else {
                $load = @(('if (nuke.NUKE_VERSION_MAJOR, nuke.NUKE_VERSION_MINOR) in {0}:' -f (& $tuples $o.Include)), "    $add")
                Log ('GenFill loads only in Nuke ' + (@($o.Include) -join ', '))
            }
            $block = (@($o.BeginMark, 'import nuke') + $load + @($o.EndMark)) -join "`r`n"
            if ($body) { $new = $body + "`r`n`r`n" + $block + "`r`n" } else { $new = $block + "`r`n" }
            Write-Utf8NoBom $o.InitPy $new
            Log "updated $($o.InitPy)"

            Prog 0.8 'Registering GenFill in Windows'
            try {
                New-Item -ItemType Directory -Path $o.SetupHome -Force | Out-Null
                $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                if ($o.IsExe) {
                    $dst = Join-Path $o.SetupHome 'GenFill-Setup.exe'
                    if ([IO.Path]::GetFullPath($o.SelfPath) -ne [IO.Path]::GetFullPath($dst)) { Copy-Item -LiteralPath $o.SelfPath -Destination $dst -Force }
                    $uninst = "`"$dst`" -Uninstall"; $modify = "`"$dst`""; $icon = "$dst,0"
                } else {
                    $dst = Join-Path $o.SetupHome 'GenFill-Setup.ps1'
                    if ([IO.Path]::GetFullPath($o.SelfPath) -ne [IO.Path]::GetFullPath($dst)) { Copy-Item -LiteralPath $o.SelfPath -Destination $dst -Force }
                    $run = "`"$ps`" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$dst`""
                    $uninst = "$run -Uninstall"; $modify = $run; $icon = ''
                }
                $key = $o.ArpKey
                New-Item -Path $key -Force | Out-Null
                $props = @{
                    DisplayName = 'GenFill for Nuke'; DisplayVersion = $version; Publisher = 'GenFill'
                    UninstallString = $uninst; QuietUninstallString = $uninst; ModifyPath = $modify
                    InstallLocation = $target; URLInfoAbout = "https://github.com/$($o.Repo)"
                    HelpLink = "https://github.com/$($o.Repo)#troubleshooting"
                    InstallDate = (Get-Date -Format 'yyyyMMdd'); Comments = 'Generative Fill node for Nuke'
                }
                if ($icon) { $props['DisplayIcon'] = $icon }
                foreach ($k in $props.Keys) { New-ItemProperty -Path $key -Name $k -Value $props[$k] -PropertyType String -Force | Out-Null }
                New-ItemProperty -Path $key -Name 'NoRepair' -Value 1 -PropertyType DWord -Force | Out-Null
                $kb = [int]((Get-ChildItem -LiteralPath $target -Recurse -File | Measure-Object Length -Sum).Sum / 1KB)
                New-ItemProperty -Path $key -Name 'EstimatedSize' -Value $kb -PropertyType DWord -Force | Out-Null
                Log 'added GenFill to Windows Settings > Apps (for uninstalling)'
            } catch { Log "could not register in Windows Apps: $($_.Exception.Message) (GenFill itself is installed)" }
            StepState 1 'done'

            if ($tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

            # ---- 2..: local AI via the plugin's own installer, run with Nuke's python
            if ($o.AiEnabled) {
                $cur = 2
                $driver = Join-Path $env:TEMP 'genfill_setup_localai.py'
                Write-Utf8NoBom $driver @'
import json, sys
sys.path.insert(0, sys.argv[1])
from genfill.localai.installer import Installer

def event(kind, **kw):
    kw["kind"] = kind
    sys.stdout.write(json.dumps(kw) + "\n")
    sys.stdout.flush()

ok = Installer(base=sys.argv[2], quant=sys.argv[3] or None, on_event=event).run()
sys.exit(0 if ok else 1)
'@
                $psi = New-Object Diagnostics.ProcessStartInfo
                $psi.FileName = $o.Python
                $psi.Arguments = ('-u -B "{0}" "{1}" "{2}" "{3}"' -f $driver, (Join-Path $target 'python'), $o.AiRoot, $o.AiQuant)
                $psi.UseShellExecute = $false
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                $psi.CreateNoWindow = $true
                $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
                foreach ($v in 'PYTHONPATH', 'PYTHONHOME', 'PYTHONSTARTUP') { if ($psi.EnvironmentVariables.ContainsKey($v)) { $psi.EnvironmentVariables.Remove($v) } }
                $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
                Log "running the Local AI installer with $($o.Python)"
                $p = [Diagnostics.Process]::Start($psi)
                $sync.Proc = $p
                $errTask = $p.StandardError.ReadToEndAsync()
                $aiOk = $false
                while ($null -ne ($line = $p.StandardOutput.ReadLine())) {
                    $e = $null
                    if ($line.StartsWith('{')) { try { $e = $line | ConvertFrom-Json } catch { } }
                    if (-not $e) { Log $line; continue }
                    switch ($e.kind) {
                        'step' { $cur = 2 + [int]$e.index; StepState $cur $e.state }
                        'progress' { Prog $e.fraction $e.text }
                        'log' { Log $e.line }
                        'finished' { $aiOk = [bool]$e.ok; $aiMessage = [string]$e.message }
                    }
                }
                $p.WaitForExit()
                $sync.Proc = $null
                $stderr = $errTask.Result
                if ($stderr -and $stderr.Trim()) { Log $stderr.TrimEnd() }
                if ($sync.Cancel) { throw 'Cancelled. Run setup again to continue where it stopped: finished downloads are kept.' }
                if (-not $aiOk) {
                    if (-not $aiMessage) { $aiMessage = "The Local AI installer stopped (exit code $($p.ExitCode))." }
                    throw $aiMessage
                }
            }
            $ok = $true
            $message = "GenFill $version is installed."
        } else {
            # ---- uninstall
            $cur = 0; StepState 0 'running'
            Stop-AiHelper $o.AiRoot
            StepState 0 'done'

            $cur = 1; StepState 1 'running'
            if ((Test-Path $o.InitPy) -and ([IO.File]::ReadAllText($o.InitPy)).Contains($o.BeginMark)) {
                Backup-InitPy
                Write-Utf8NoBom $o.InitPy ((Remove-InitBlock ([IO.File]::ReadAllText($o.InitPy))).TrimEnd() + "`r`n")
                Log "removed the GenFill block from $($o.InitPy)"
            } else { Log 'no GenFill block in init.py' }
            Assert-Safe $o.Target
            if (Test-Path -LiteralPath $o.Target) {
                try { Remove-Item -LiteralPath $o.Target -Recurse -Force }
                catch { throw "Couldn't delete $($o.Target) ($($_.Exception.Message)). Close Nuke and try again." }
                Log "deleted $($o.Target)"
            }
            StepState 1 'done'

            $cur = 2
            if ($o.UnAi) {
                StepState 2 'running'
                Assert-Safe $o.AiRoot
                Prog $null "Deleting $($o.AiRoot)..."
                if (Test-Path -LiteralPath $o.AiRoot) { Remove-Item -LiteralPath $o.AiRoot -Recurse -Force }
                Log "deleted $($o.AiRoot)"
                StepState 2 'done'
            } else { StepState 2 'skipped'; Log "kept the local AI in $($o.AiRoot)" }

            $cur = 3
            if ($o.UnCfg) {
                StepState 3 'running'
                if (Test-Path -LiteralPath $o.ConfigDir) { Remove-Item -LiteralPath $o.ConfigDir -Recurse -Force }
                Log "deleted $($o.ConfigDir)"
                StepState 3 'done'
            } else { StepState 3 'skipped'; Log "kept settings and API keys in $($o.ConfigDir)" }

            $cur = 4; StepState 4 'running'
            if (Test-Path $o.ArpKey) { Remove-Item -Path $o.ArpKey -Recurse -Force; Log 'removed GenFill from Windows Apps' }
            StepState 4 'done'
            $ok = $true
            $message = 'GenFill was removed from Nuke.'
        }
    } catch {
        $message = $_.Exception.Message
        Log ("ERROR: " + $message)
        if ($_.ScriptStackTrace -and -not $sync.Cancel) { Log $_.ScriptStackTrace }
        StepState $cur 'failed'
    }
    Emit 'finished' @{ ok = $ok; message = $message; ai = $aiMessage }
}

function Start-Work([hashtable]$opts) {
    $S.Busy = $true; $S.Ok = $false
    $sync.Cancel = $false
    while ($sync.Queue.Count) { $tmp = $null; [void]$sync.Queue.TryDequeue([ref]$tmp) }
    Write-SetupLog ("`r`n==== GenFill Setup {0}: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), $opts.Mode)
    $common = @{
        Repo = $GitHubRepo; Branch = $GitHubBranch; BeginMark = $BeginMark; EndMark = $EndMark
        InitPy = $InitPy; NukeHome = $NukeHome; ConfigDir = $ConfigDir; SetupHome = $SetupHome
        ArpKey = $ArpKey; SelfPath = $SelfPath; IsExe = $IsExe; LocalRepo = $LocalRepo
    }
    foreach ($k in $common.Keys) { $opts[$k] = $common[$k] }
    $ps = [powershell]::Create()
    [void]$ps.AddScript($Worker).AddArgument($opts).AddArgument($sync)
    $S.WorkerPs = $ps
    $S.WorkerHandle = $ps.BeginInvoke()
    Show-Page 'Progress'
}

function Start-Install {
    $S.Mode = 'install'
    $ai = [bool]$ui.AiToggle.IsChecked
    $steps = @(
        @($(if ($ui.SrcLocal.IsChecked -and $LocalRepo) { 'Read GenFill from this folder' } else { 'Download the latest GenFill' }), 3),
        @('Install the Nuke plugin', 3)
    )
    if ($ai) { $steps += $AiSteps }
    New-Steps $steps
    $vc = Get-VersionChoice
    $S.Include = $vc.Include
    # The local AI installer runs on Nuke's python.exe: prefer a version GenFill is installed for.
    $py = $null
    foreach ($g in $NukeGroups) {
        if ($vc.Include -contains $g.Key) { $py = $g.Builds | Where-Object { $_.Python } | Select-Object -First 1; if ($py) { break } }
    }
    if (-not $py) { $py = $Python }
    $ui.ProgTitle.Text = if ($Installed) { 'Updating GenFill' } else { 'Installing GenFill' }
    $ui.ProgText.Text = 'Starting...'
    Start-Work @{
        Mode = 'install'
        Source = $(if ($ui.SrcLocal.IsChecked -and $LocalRepo) { 'local' } else { 'github' })
        Target = [IO.Path]::GetFullPath($ui.TargetBox.Text.Trim())
        AiEnabled = $ai
        AiRoot = $(if ($ai) { [IO.Path]::GetFullPath($ui.AiBox.Text.Trim()) } else { '' })
        AiQuant = (Get-SelectedQuant).Id
        Python = $(if ($py) { $py.Python } else { '' })
        Include = $vc.Include; Exclude = $vc.Exclude; Other = $vc.Other
    }
}

function Start-Uninstall {
    $S.Mode = 'uninstall'
    New-Steps @(@('Stop the GenFill AI helper', 1), @('Remove the plugin from Nuke', 2),
        @('Delete the local AI', 6), @('Delete settings and API keys', 1), @('Remove from Windows Apps', 1))
    $ui.ProgTitle.Text = 'Removing GenFill'
    $ui.ProgText.Text = 'Starting...'
    Start-Work @{
        Mode = 'uninstall'; Target = $DefaultTarget; AiRoot = $AiRootNow
        UnAi = [bool]$ui.UnAi.IsChecked; UnCfg = [bool]$ui.UnCfg.IsChecked
    }
}

function Stop-Work {
    $sync.Cancel = $true
    $p = $sync.Proc
    if ($p) {
        try { & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-Null } catch { }
    }
    $ui.ProgText.Text = 'Cancelling...'
    $ui.BtnNext.IsEnabled = $false
}

function Show-Done([hashtable]$e) {
    $S.Busy = $false
    $S.Ok = [bool]$e.ok
    if ($S.Ok) {
        $ui.DoneCircle.Fill = Res 'Accent'; $ui.DoneOk.Visibility = 'Visible'; $ui.DoneFail.Visibility = 'Collapsed'
    } else {
        $ui.DoneCircle.Fill = Brush '#E5484D'; $ui.DoneOk.Visibility = 'Collapsed'; $ui.DoneFail.Visibility = 'Visible'
    }
    $ui.LaunchChips.Children.Clear()
    if ($S.Mode -eq 'uninstall') {
        $ui.DoneTitle.Text = if ($S.Ok) { 'GenFill was removed' } else { "Couldn't finish removing GenFill" }
        $ui.DoneText.Text = $e.message
        $ui.NextCard.Visibility = 'Collapsed'
        if ($S.Ok) { $S.PendingCleanup = $true }
    } else {
        $ui.NextCard.Visibility = 'Visible'
        if ($S.Ok) {
            $ui.DoneTitle.Text = "You're all set"
            $text = $e.message
            if ($e.ai) { $text += ' ' + $e.ai }
            $ui.DoneText.Text = $text
            $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^Nuke\d' }).Count -gt 0
            $lines = @()
            $lines += $(if ($running) { '1.  Restart Nuke so it loads the new build.' } else { '1.  Start Nuke.' })
            $lines += '2.  Nodes toolbar > GenFill > Generative Fill, or press Tab and type "Generative Fill".'
            $lines += '3.  Draw a selection, type a prompt (or leave it empty to remove), press Generate.'
            $hasAi = $AiReady -or ($e.ai -and $S.Ok -and $S.Rows.Count -gt 2)
            if (-not $hasAi) { $lines += 'Free local AI: in Nuke, GenFill > Local AI > Install / Repair, or run this setup again.' }
            $ui.NextText.Text = $lines -join "`n"
            $launch = @($Nukes | Where-Object { $S.Include -contains ('{0}.{1}' -f $_.Version.Major, $_.Version.Minor) })
            $ui.LaunchRow.Visibility = if ($launch.Count) { 'Visible' } else { 'Collapsed' }
            $first = $true
            foreach ($n in $launch) {
                $b = Add-Chip $ui.LaunchChips ($n.Name -replace '^Nuke', 'Nuke ') $n.Exe $first
                $b.Add_Click({ Start-Process -FilePath $this.Tag; $window.Close() })
                $first = $false
            }
        } else {
            $ui.DoneTitle.Text = "Setup didn't finish"
            $ui.DoneText.Text = $e.message
            $ui.NextText.Text = "Try again resumes where it stopped: finished steps and downloads are kept.`nThe details are in the log (Open log). Please attach it to a bug report."
            $ui.LaunchRow.Visibility = 'Collapsed'
        }
    }
    Show-Page 'Done'
}

# ------------------------------------------------------------------ event pump
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(80)
$timer.Add_Tick({
    try {
        if ($sync.Latest -and -not $S.Latest) {
            $S.Latest = $sync.Latest
            if ($S.Latest -eq 'offline') {
                $ui.LatestText.Text = "Couldn't reach GitHub. Check your internet connection to install."
                $ui.LatestText.Foreground = Brush '#F5C561'
            } else {
                $ui.LatestText.Text = "GenFill $($S.Latest) on GitHub"
                if ($Installed -and $Installed -eq $S.Latest) { $ui.LatestText.Text += '  -  you have the latest' }
                elseif ($Installed) { $ui.LatestText.Text += '  -  update available'; $ui.LatestText.Foreground = Brush '#9DB1FF' }
                else { $ui.LatestText.Foreground = Brush '#E8EAF2' }
            }
        }
        $logs = New-Object Text.StringBuilder
        $e = $null; $n = 0
        while ($n -lt 400 -and $sync.Queue.TryDequeue([ref]$e)) {
            $n++
            switch ($e.kind) {
                'log' { [void]$logs.AppendLine($e.line) }
                'step' { Set-StepState ([int]$e.index) ([string]$e.state) }
                'progress' {
                    if ($null -ne $e.fraction) { $S.Frac = [double]$e.fraction; Update-Overall }
                    if ($e.text) { $ui.ProgText.Text = $e.text }
                }
                'meta' { $S.Version = $e.version }
                'finished' {
                    if ($logs.Length) { Write-SetupLog $logs.ToString().TrimEnd(); $ui.LogBox.AppendText($logs.ToString()); [void]$logs.Clear() }
                    Write-SetupLog ("==== {0}: {1}" -f $(if ($e.ok) { 'OK' } else { 'FAILED' }), $e.message)
                    Show-Done $e
                }
            }
        }
        if ($logs.Length) {
            Write-SetupLog $logs.ToString().TrimEnd()
            $ui.LogBox.AppendText($logs.ToString())
            if ($ui.LogBox.Text.Length -gt 400000) { $ui.LogBox.Text = $ui.LogBox.Text.Substring($ui.LogBox.Text.Length - 200000) }
            $ui.LogBox.ScrollToEnd()
        }
    } catch {
        Write-SetupLog ("UI error: " + $_.Exception.Message)
    }
})
$timer.Start()

# ------------------------------------------------------------------ buttons
$ui.TitleBar.Add_MouseLeftButtonDown({ try { $window.DragMove() } catch { } })
$ui.Sidebar.Add_MouseLeftButtonDown({ try { $window.DragMove() } catch { } })
$ui.BtnMin.Add_Click({ $window.WindowState = 'Minimized' })
$ui.BtnClose.Add_Click({ $window.Close() })

$ui.BtnNext.Add_Click({
    switch ($S.Page) {
        'Welcome' {
            $ui.WarnNuke.Visibility = if (@(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^Nuke\d' }).Count) { 'Visible' } else { 'Collapsed' }
            Show-Page 'Options'
        }
        'Options' { Start-Install }
        'Uninstall' { Start-Uninstall }
        'Progress' { Stop-Work }
        'Done' { if ($S.Ok) { $window.Close() } elseif ($S.Mode -eq 'uninstall') { Start-Uninstall } else { Start-Install } }
        'Credits' { Show-Page $S.PrevPage }
    }
})
$ui.BtnBack.Add_Click({
    switch ($S.Page) {
        'Options' { Show-Page 'Welcome' }
        'Uninstall' { Show-Page 'Welcome' }
        'Done' { $window.Close() }
    }
})
$ui.BtnAlt.Add_Click({
    switch ($S.Page) {
        'Welcome' {
            $S.Mode = 'uninstall'
            Show-Page 'Uninstall'
            if ($ui.UnAi.IsEnabled) {
                $ui.UnAiText.Text = '{0}  -  {1:0.0} GB' -f $AiRootNow, (Get-FolderGb $AiRootNow)
            }
        }
        'Progress' {
            $showLog = $ui.LogBox.Visibility -ne 'Visible'
            $ui.LogBox.Visibility = if ($showLog) { 'Visible' } else { 'Collapsed' }
            $ui.StepCard.Visibility = if ($showLog) { 'Collapsed' } else { 'Visible' }
            $ui.BtnAlt.Content = if ($showLog) { 'Show steps' } else { 'Show details' }
            if ($showLog) { $ui.LogBox.ScrollToEnd() }
        }
        'Done' { if (Test-Path $LogPath) { Start-Process notepad.exe -ArgumentList "`"$LogPath`"" } }
    }
})

$window.Add_Closing({
    param($sender, $e)
    if ($S.Busy) {
        $r = [Windows.MessageBox]::Show($window, "Setup is still running. Stop it and quit?`n`nRunning setup again later continues where it stopped.",
            'GenFill Setup', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { $e.Cancel = $true; return }
        Stop-Work
    }
})
$window.Add_Closed({
    $timer.Stop()
    if ($S.PendingCleanup -and (Test-Path -LiteralPath $SetupHome)) {
        # The setup copy may be what's running: delete it a moment after we exit.
        Start-Process -FilePath cmd.exe -WindowStyle Hidden -ArgumentList ('/c ping 127.0.0.1 -n 3 >nul & rmdir /s /q "{0}"' -f $SetupHome)
    }
})
$window.Dispatcher.Add_UnhandledException({
    param($sender, $e)
    Write-SetupLog ("Unhandled UI error: " + $e.Exception.Message)
    $e.Handled = $true
})

# ------------------------------------------------------------------ snapshot (dev)
function Save-Snapshot([string]$name) {
    $window.UpdateLayout()
    $el = $window.Content
    $dpi = 1.25
    $w = $el.ActualWidth + $el.Margin.Left + $el.Margin.Right
    $h = $el.ActualHeight + $el.Margin.Top + $el.Margin.Bottom
    $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap ([int]($w * $dpi)), ([int]($h * $dpi)), (96 * $dpi), (96 * $dpi), ([Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($el)
    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $fs = [IO.File]::Create((Join-Path $Snapshot "$name.png"))
    try { $enc.Save($fs) } finally { $fs.Close() }
}
if ($Snapshot) {
    New-Item -ItemType Directory -Force -Path $Snapshot | Out-Null
    $window.Add_ContentRendered({
        $timer.Stop()
        $sync.Latest = $null; $S.Latest = '0.7.1'; $ui.LatestText.Text = 'GenFill 0.7.1 on GitHub'
        # Neutral sample data, so screenshots don't show this machine's user, paths or hardware.
        $fake = 'C:\Users\artist'
        $script:Installed = $null; $script:AiReady = $false
        $ui.BtnAlt.Visibility = 'Collapsed'; $ui.BtnNext.Content = 'Get started'
        $ui.GpuText.Text = 'NVIDIA GeForce RTX 4090  {0}  24 GB' -f [char]0x00B7
        $ui.GpuText.Foreground = Brush '#E8EAF2'
        $ui.InstalledText.Text = 'Not installed yet'; $ui.InstalledText.Foreground = Brush '#E8EAF2'
        $ui.WelcomeTitle.Text = 'Welcome'; $ui.SideVersion.Text = ''
        $ui.SourceRow.Visibility = 'Collapsed'; $ui.SrcGitHub.IsChecked = $true
        $ui.WarnNuke.Visibility = 'Collapsed'
        $ui.TargetBox.Text = "$fake\.nuke\plugins\GenFill"
        $ui.AiBox.Text = "$fake\GenFill-LocalAI"
        $ui.AiToggle.IsChecked = $true; $ui.AiToggle.IsEnabled = $true
        $ui.AiBadge.Visibility = 'Collapsed'
        $ui.AiSub.Text = 'FLUX.1 Fill and LaMa on your NVIDIA GPU. Offline, private, no tokens. One-time download.'
        foreach ($i in 0, 1, 2) { $ui["Q${i}Rec"].Visibility = 'Hidden' }
        $ui.Q2Rec.Visibility = 'Visible'; $ui.Q2.IsChecked = $true; $ui.AiLicense.IsChecked = $false
        foreach ($c in $VersionChecks.Values) { $c.IsChecked = $true }; $OtherCheck.IsChecked = $true
        $ui.UnPluginText.Text = "GenFill 0.7.1 in $fake\.nuke\plugins\GenFill, and its line in init.py"
        $ui.UnAiText.Text = "$fake\GenFill-LocalAI  -  31.2 GB"; $ui.UnAi.IsEnabled = $true
        $ui.UnCfgText.Text = "$fake\.nuke\genfill  -  keep it if you'll reinstall later"
        Show-Page 'Welcome'; Save-Snapshot '1-welcome'
        Show-Page 'Options'; $ui.AiDisk.Text = 'Up to 31 GB on disk (already downloaded files are reused)  -  412 GB free on C:'
        $ui.AiDisk.Foreground = Res 'Muted'; Save-Snapshot '2-options'
        $VersionChecks[$NukeGroups[-1].Key].IsChecked = $false; $OtherCheck.IsChecked = $false; Update-Options
        Save-Snapshot '2a-options-versions'
        $VersionChecks[$NukeGroups[-1].Key].IsChecked = $true; $OtherCheck.IsChecked = $true; Update-Options
        $ui.AiDisk.Text = 'Up to 31 GB on disk (already downloaded files are reused)  -  412 GB free on C:'
        $ui.AiDisk.Foreground = Res 'Muted'
        $ui.PageOptions.ScrollToEnd(); Save-Snapshot '2b-options-scrolled'
        New-Steps (@(@('Download the latest GenFill', 3), @('Install the Nuke plugin', 3)) + $AiSteps)
        Show-Page 'Progress'
        Set-StepState 0 'done'; Set-StepState 1 'done'
        for ($i = 2; $i -lt 8; $i++) { Set-StepState $i 'done' }
        Set-StepState 8 'running'; $S.Frac = 0.42; Update-Overall
        $ui.ProgText.Text = 'Downloading t5 model.safetensors: 4.01 GB of 9.52 GB  (87 MB/s)'
        Save-Snapshot '3-progress'
        $ui.LogBox.AppendText("10:21:04 --- Download FLUX.1 Fill, text encoders, VAE and LaMa`n10:21:04 downloaded models/flux/flux1-fill-dev-Q8_0.gguf (12.70 GB)`n")
        $ui.LogBox.Visibility = 'Visible'; $ui.StepCard.Visibility = 'Collapsed'; Save-Snapshot '3b-log'
        $S.Mode = 'install'; $S.Rows = @(1, 2, 3); $S.Include = @($NukeGroups | ForEach-Object { $_.Key })
        Show-Done @{ ok = $true; message = 'GenFill 0.7.1 is installed.'; ai = "Local AI is ready on your GPU. Pick 'Local: FLUX.1 Fill' in a GenerativeFill node." }
        Save-Snapshot '4-done'
        Show-Done @{ ok = $false; message = "Couldn't download GenFill from GitHub. Check your internet connection."; ai = '' }
        Save-Snapshot '4b-failed'
        $S.Mode = 'uninstall'; Show-Page 'Uninstall'; Save-Snapshot '5-uninstall'
        $S.PrevPage = 'Uninstall'; Show-Page 'Credits'; Save-Snapshot '6-credits'
        $S.Busy = $false; $window.Close()
    })
}

# ------------------------------------------------------------------ go
if ($Uninstall) {
    $S.Mode = 'uninstall'
    Show-Page 'Uninstall'
    if ($ui.UnAi.IsEnabled) { $ui.UnAiText.Text = '{0}  -  {1:0.0} GB' -f $AiRootNow, (Get-FolderGb $AiRootNow) }
} else {
    Show-Page 'Welcome'
}
[void]$window.ShowDialog()
if ($S.WorkerPs) { try { $S.WorkerPs.Stop() } catch { } }
