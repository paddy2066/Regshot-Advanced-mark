<#
.SYNOPSIS
    Capture an application install with Regshot Advanced and turn it into a
    deployable .msi (for PDQ Deploy, Intune, GPO, etc.).

.DESCRIPTION
    A guided wizard around the whole pipeline:

        1. Configures Regshot (regshot.ini) to capture registry + files and to
           export a value-complete "UNL" report to a known folder.
        2. Launches Regshot and prompts you to take the FIRST shot.
        3. Waits while you install the application (or launches an installer you
           pass with -InstallerPath).
        4. Prompts you to take the SECOND shot; Regshot auto-compares and writes
           the .unl capture.
        5. Runs regshot2msi.py to produce a WiX .wxs.
        6. Runs 'wix build' to produce the final .msi.

    Regshot has no command-line automation, so the three shot/compare clicks are
    manual; everything before and after them is automated. Your original
    regshot.ini is backed up and restored when the wizard finishes.

.PARAMETER RegshotExe
    Path to the Regshot executable. Auto-detected from common locations / PATH
    if omitted.

.PARAMETER Title
    Product name. Also used as the Regshot report name and the MSI install
    folder. Default: "CapturedApp".

.PARAMETER Manufacturer
    Manufacturer string embedded in the MSI.

.PARAMETER Version
    Product version (w.x.y.z). Default: 1.0.0.0.

.PARAMETER InstallerPath
    Optional. If given, the wizard launches this installer for you (and waits
    for it) instead of asking you to install manually.

.PARAMETER WorkDir
    Folder where Regshot writes its snapshots and the .unl capture.
    Default: %TEMP%\regshot2msi_capture.

.PARAMETER OutputMsi
    Path of the .msi to produce. Default: <current dir>\<Title>.msi.

.PARAMETER InstallRoot
    MSI root directory for staged files (ProgramFiles64Folder, ProgramFilesFolder, ...).

.PARAMETER StripPrefix
    Capture path prefix to strip before staging files (see regshot2msi.py).

.PARAMETER Python
    Python executable. Auto-detected (python / py) if omitted.

.PARAMETER Wix
    WiX executable. Auto-detected if omitted. If WiX is not found the wizard
    still produces the .wxs and tells you how to build it.

.PARAMETER KeepIntermediate
    Keep the intermediate .wxs and capture folder after a successful build.

.EXAMPLE
    .\Build-CapturedMsi.ps1 -Title "7zip" -Manufacturer "Igor Pavlov"

.EXAMPLE
    .\Build-CapturedMsi.ps1 -Title "MyApp" -InstallerPath "C:\dl\MyAppSetup.exe" -OutputMsi "C:\pkg\MyApp.msi"
#>
[CmdletBinding()]
param(
    [string]$RegshotExe,
    [string]$Title = "CapturedApp",
    [string]$Manufacturer = "Repackaged with regshot2msi",
    [string]$Version = "1.0.0.0",
    [string]$InstallerPath,
    [string]$WorkDir = (Join-Path $env:TEMP "regshot2msi_capture"),
    [string]$OutputMsi,
    [string]$InstallRoot = "ProgramFiles64Folder",
    [string]$StripPrefix,
    [string]$Python,
    [string]$Wix,
    [switch]$KeepIntermediate
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Regshot reads/writes regshot.ini as ANSI (system code page). Pin that encoding
# so we round-trip the file identically on both Windows PowerShell 5.1 (ANSI) and
# PowerShell 7 (whose ::Default is UTF-8).
try {
    $script:IniEncoding = [System.Text.Encoding]::GetEncoding(
        [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage)
} catch {
    $script:IniEncoding = [System.Text.Encoding]::Default
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Step  { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Info  { param([string]$m) Write-Host "    $m" -ForegroundColor Gray }
function Write-Good  { param([string]$m) Write-Host "    $m" -ForegroundColor Green }
function Write-Warn2 { param([string]$m) Write-Host "    $m" -ForegroundColor Yellow }

function Pause-For {
    param([string]$Prompt)
    Write-Host ""
    Write-Host ">>> $Prompt" -ForegroundColor White
    [void](Read-Host "    Press ENTER to continue")
}

# Section-aware INI writer that preserves the rest of the file and its (ANSI)
# encoding, matching how Regshot reads/writes regshot.ini on Windows.
function Set-IniValue {
    param([string]$Path, [string]$Section, [string]$Key, [string]$Value)

    $enc = $script:IniEncoding
    if (Test-Path -LiteralPath $Path) {
        $lines = [System.IO.File]::ReadAllLines($Path, $enc)
    } else {
        $lines = @("[$Section]")
    }

    $out = New-Object System.Collections.Generic.List[string]
    $inSection = $false
    $done = $false
    $sectionFound = $false
    $keyPattern = '^\s*' + [regex]::Escape($Key) + '\s*='

    foreach ($line in $lines) {
        $trim = $line.Trim()
        if ($trim -match '^\[(.+)\]$') {
            if ($inSection -and -not $done) { $out.Add("$Key=$Value"); $done = $true }
            $inSection = ($matches[1] -eq $Section)
            if ($inSection) { $sectionFound = $true }
            $out.Add($line)
            continue
        }
        if ($inSection -and -not $done -and ($line -match $keyPattern)) {
            $out.Add("$Key=$Value"); $done = $true
            continue
        }
        $out.Add($line)
    }
    if ($inSection -and -not $done) { $out.Add("$Key=$Value"); $done = $true }
    if (-not $sectionFound) {
        $out.Add("[$Section]"); $out.Add("$Key=$Value")
    }
    [System.IO.File]::WriteAllLines($Path, $out, $enc)
}

function Get-IniValue {
    param([string]$Path, [string]$Section, [string]$Key, [int]$Default = 0)
    if (-not (Test-Path -LiteralPath $Path)) { return $Default }
    $enc = $script:IniEncoding
    $lines = [System.IO.File]::ReadAllLines($Path, $enc)
    $inSection = $false
    foreach ($line in $lines) {
        $trim = $line.Trim()
        if ($trim -match '^\[(.+)\]$') { $inSection = ($matches[1] -eq $Section); continue }
        if ($inSection -and $trim -match ('^\s*' + [regex]::Escape($Key) + '\s*=\s*(.*)$')) {
            return $matches[1].Trim()
        }
    }
    return $Default
}

function Find-Executable {
    param([string[]]$Names, [string[]]$SearchPaths)
    foreach ($n in $Names) {
        $cmd = Get-Command $n -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    foreach ($p in $SearchPaths) {
        if ($p -and (Test-Path -LiteralPath $p)) { return (Resolve-Path $p).Path }
    }
    return $null
}

function Select-UnlFile {
    param([string]$Root, [datetime]$Since)
    $candidates = @()
    if (Test-Path -LiteralPath $Root) {
        $candidates = Get-ChildItem -LiteralPath $Root -Recurse -Filter *.unl -ErrorAction SilentlyContinue |
                      Where-Object { $_.LastWriteTime -ge $Since } |
                      Sort-Object LastWriteTime -Descending
    }
    if ($candidates.Count -ge 1) { return $candidates[0].FullName }

    # Fallback: let the user pick.
    Write-Warn2 "Could not auto-locate the .unl capture under $Root."
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = "Regshot UNL capture (*.unl)|*.unl|All files (*.*)|*.*"
        $dlg.Title = "Select the .unl capture Regshot produced"
        if (Test-Path -LiteralPath $Root) { $dlg.InitialDirectory = $Root }
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.FileName }
    } catch { }
    return $null
}

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

Write-Host "Regshot -> MSI capture wizard" -ForegroundColor White
Write-Host "=============================" -ForegroundColor White

if (-not $OutputMsi) { $OutputMsi = Join-Path (Get-Location).Path ("{0}.msi" -f $Title) }

$converter = Join-Path $scriptDir "regshot2msi.py"
if (-not (Test-Path -LiteralPath $converter)) {
    throw "Cannot find regshot2msi.py next to this script ($converter)."
}

Write-Step "Checking prerequisites"

if (-not $RegshotExe) {
    # Prefer an explicit name on PATH, then glob the repo/build folders. The exe
    # name depends on how it was built (e.g. Regshot-x64-Unicode.exe or
    # <project>-x64-Unicode.exe), so match on a pattern and prefer 64-bit Unicode.
    $RegshotExe = Find-Executable -Names @("Regshot-x64-Unicode.exe", "Regshot-x86-Unicode.exe", "regshot.exe") -SearchPaths @()
    if (-not $RegshotExe) {
        $repoRoot = (Resolve-Path (Join-Path $scriptDir "..\..")).Path
        $hits = Get-ChildItem -Path $repoRoot -Recurse -Filter "*egshot*.exe" -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch 'dbg' } |
                Sort-Object `
                    @{ Expression = { if ($_.Name -match 'x64')     { 0 } else { 1 } } }, `
                    @{ Expression = { if ($_.Name -match 'Unicode') { 0 } else { 1 } } }, `
                    @{ Expression = { $_.LastWriteTime }; Descending = $true }
        if ($hits.Count -ge 1) { $RegshotExe = $hits[0].FullName }
    }
}
if (-not $RegshotExe -or -not (Test-Path -LiteralPath $RegshotExe)) {
    throw "Regshot executable not found. Pass -RegshotExe <path to Regshot.exe>."
}
$RegshotExe = (Resolve-Path $RegshotExe).Path
Write-Good "Regshot:  $RegshotExe"

if (-not $Python) { $Python = Find-Executable -Names @("python", "py") -SearchPaths @() }
if (-not $Python) { throw "Python not found. Install Python 3 or pass -Python <path>." }
Write-Good "Python:   $Python"

if (-not $Wix) { $Wix = Find-Executable -Names @("wix") -SearchPaths @() }
if ($Wix) { Write-Good "WiX:      $Wix" }
else { Write-Warn2 "WiX not found. The wizard will stop at the .wxs and show the build command." }
Write-Info "         (install WiX with:  dotnet tool install --global wix)"

$iniPath = Join-Path (Split-Path -Parent $RegshotExe) "regshot.ini"
$iniBackup = "$iniPath.regshot2msi.bak"

# ---------------------------------------------------------------------------
# Configure Regshot
# ---------------------------------------------------------------------------

$restoreNeeded = $false
try {
    Write-Step "Configuring Regshot for capture"

    if (Test-Path -LiteralPath $iniPath) {
        Copy-Item -LiteralPath $iniPath -Destination $iniBackup -Force
        $restoreNeeded = $true
        Write-Info "Backed up regshot.ini -> $iniBackup"
    }

    if (Test-Path -LiteralPath $WorkDir) { Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

    # Ensure filesystem scanning (Flag bit 0x08) while preserving other bits.
    $flag = 1
    try { $flag = [int](Get-IniValue -Path $iniPath -Section "Setup" -Key "Flag" -Default 1) } catch { $flag = 1 }
    $flag = $flag -bor 0x08

    Set-IniValue -Path $iniPath -Section "Setup"  -Key "Title"                       -Value $Title
    Set-IniValue -Path $iniPath -Section "Setup"  -Key "BaseDir"                     -Value $WorkDir
    Set-IniValue -Path $iniPath -Section "Setup"  -Key "Flag"                        -Value $flag
    Set-IniValue -Path $iniPath -Section "Setup"  -Key "AutoCompare"                 -Value 1
    Set-IniValue -Path $iniPath -Section "Setup"  -Key "SaveSettingsOnExit"          -Value 0
    Set-IniValue -Path $iniPath -Section "Setup"  -Key "DontDisplayInfoAfterShot"    -Value 1
    Set-IniValue -Path $iniPath -Section "Setup"  -Key "DontDisplayInfoAfterComparison" -Value 1

    Set-IniValue -Path $iniPath -Section "Registry-Scan" -Key "HKEY_LOCAL_MACHINE"   -Value 1
    Set-IniValue -Path $iniPath -Section "Registry-Scan" -Key "HKEY_CURRENT_USER"    -Value 1
    Set-IniValue -Path $iniPath -Section "Registry-Scan" -Key "HKEY_USERS"           -Value 1

    Set-IniValue -Path $iniPath -Section "Output" -Key "UNLFile"                     -Value 1
    Set-IniValue -Path $iniPath -Section "Output" -Key "OpenEditor"                  -Value 0

    # NoVals=1 would strip the registry value data the MSI needs - force it off.
    Set-IniValue -Path $iniPath -Section "UNL"    -Key "NoVals"                      -Value 0

    Write-Good "regshot.ini configured (UNL + values + registry + files, output -> $WorkDir)"

    # -----------------------------------------------------------------------
    # Guided capture
    # -----------------------------------------------------------------------

    Write-Step "Starting Regshot"
    Start-Process -FilePath $RegshotExe | Out-Null
    Start-Sleep -Seconds 1
    $captureStart = Get-Date

    Pause-For "In the Regshot window, click [ 1st shot ] -> [ Shot ] and wait until it finishes."

    if ($InstallerPath) {
        if (-not (Test-Path -LiteralPath $InstallerPath)) { throw "InstallerPath not found: $InstallerPath" }
        Write-Step "Running the application installer"
        Write-Info $InstallerPath
        Start-Process -FilePath $InstallerPath -Wait
        Write-Good "Installer exited."
    } else {
        Pause-For "Now INSTALL your application. Let it finish completely, then come back here."
    }

    Pause-For "In Regshot, click [ 2nd shot ] -> [ Shot and Compare ]. It will write the capture. Wait for it to finish."

    # -----------------------------------------------------------------------
    # Locate the capture and convert
    # -----------------------------------------------------------------------

    Write-Step "Locating the capture"
    $unl = Select-UnlFile -Root $WorkDir -Since $captureStart
    if (-not $unl) { throw "No .unl capture was found. Make sure the 2nd shot + compare completed and UNL output is enabled." }
    Write-Good "Capture: $unl"

    Write-Step "Converting capture to WiX source"
    $wxs = Join-Path $WorkDir ("{0}.wxs" -f $Title)
    $convArgs = @($converter, $unl, "-o", $wxs,
                  "--title", $Title, "--manufacturer", $Manufacturer,
                  "--version", $Version, "--install-root", $InstallRoot)
    if ($StripPrefix) { $convArgs += @("--strip-prefix", $StripPrefix) }
    & $Python @convArgs
    if ($LASTEXITCODE -ne 0) { throw "regshot2msi.py failed (exit $LASTEXITCODE)." }
    if (-not (Test-Path -LiteralPath $wxs)) { throw "Converter did not produce $wxs." }
    Write-Good "WiX source: $wxs"

    Write-Step "Building the MSI"
    if ($Wix) {
        & $Wix build $wxs -o $OutputMsi
        if ($LASTEXITCODE -ne 0) { throw "wix build failed (exit $LASTEXITCODE). See messages above." }
        Write-Good "MSI built: $OutputMsi"

        if (-not $KeepIntermediate) {
            Remove-Item -LiteralPath $wxs -Force -ErrorAction SilentlyContinue
        }

        Write-Host ""
        Write-Host "Done. Deploy with PDQ:" -ForegroundColor Green
        Write-Host "    PDQ Deploy -> New Package -> Install step -> select:" -ForegroundColor Green
        Write-Host "        $OutputMsi" -ForegroundColor Green
        Write-Host "    (silent by default; parameters: /qn /norestart)" -ForegroundColor Green
    } else {
        Write-Warn2 "WiX not installed - stopping at the WiX source."
        Write-Host ""
        Write-Host "Finish the build on a machine with WiX:" -ForegroundColor Yellow
        Write-Host "    dotnet tool install --global wix" -ForegroundColor Yellow
        Write-Host "    wix build `"$wxs`" -o `"$OutputMsi`"" -ForegroundColor Yellow
    }
}
finally {
    if ($restoreNeeded -and (Test-Path -LiteralPath $iniBackup)) {
        Copy-Item -LiteralPath $iniBackup -Destination $iniPath -Force
        Remove-Item -LiteralPath $iniBackup -Force -ErrorAction SilentlyContinue
        Write-Info "Restored your original regshot.ini."
    }
}
