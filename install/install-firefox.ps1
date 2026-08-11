<#
.SYNOPSIS
    Downloads and silently installs Mozilla Firefox (Enterprise MSI).

.DESCRIPTION
    Idempotent installer for Firefox 64-bit MSI.
    Defaults to the latest ESR (Extended Support Release) which is preferred in enterprise environments.
    - Checks if Firefox is already installed.
    - Downloads the official MSI from Mozilla.
    - Performs a quiet installation.
    - Cleans up after success.

.PARAMETER Force
    Reinstall even if Firefox is already present.

.PARAMETER Regular
    Install the regular (non-ESR) release instead of ESR.

.PARAMETER LogPath
    Full path to the log file.

.PARAMETER DownloadPath
    Temporary folder for the MSI.

.EXAMPLE
    .\Install-Firefox.ps1

.EXAMPLE
    .\Install-Firefox.ps1 -Regular -Force
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$Regular,          # Use regular release instead of ESR
    [string]$LogPath,
    [string]$DownloadPath = (Join-Path $env:TEMP "FirefoxInstall")
)

#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Dot-source common helpers
# ---------------------------------------------------------------------------
$commonPath = Join-Path $PSScriptRoot "..\common\Write-Log.ps1"
if (Test-Path $commonPath) {
    . $commonPath
}
else {
    function Write-Log {
        param([string]$Message, [string]$Level = 'INFO')
        $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Write-Host "[$ts] [$Level] $Message"
    }
}

# ---------------------------------------------------------------------------
# Initialize logging
# ---------------------------------------------------------------------------
if (-not $LogPath) {
    $logDir = Join-Path $PSScriptRoot "..\logs"
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $LogPath = Join-Path $logDir ("Install-Firefox_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
}
$script:LogPath = $LogPath

Write-Log "===== Starting Firefox installation ====="
Write-Log "Log file : $LogPath"
Write-Log "Force    : $Force"
Write-Log "Release  : $(if ($Regular) { 'Regular' } else { 'ESR' })"

# ---------------------------------------------------------------------------
# Helper: Get currently installed Firefox version
# ---------------------------------------------------------------------------
function Get-InstalledFirefoxVersion {
    $paths = @(
        'HKLM:\SOFTWARE\Mozilla\Mozilla Firefox',
        'HKLM:\SOFTWARE\WOW6432Node\Mozilla\Mozilla Firefox',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Mozilla Firefox*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Mozilla Firefox*'
    )

    foreach ($p in $paths) {
        $item = Get-ItemProperty -Path $p -ErrorAction Ignore | Select-Object -First 1
        if ($item) {
            if ($item.CurrentVersion) { return $item.CurrentVersion }
            if ($item.DisplayVersion) { return $item.DisplayVersion }
        }
    }

    $exePaths = @(
        "${env:ProgramFiles}\Mozilla Firefox\firefox.exe",
        "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe"
    )
    foreach ($exe in $exePaths) {
        if (Test-Path $exe -ErrorAction Ignore) {
            return (Get-Item $exe).VersionInfo.ProductVersion
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Helper: Resolve latest Firefox version + MSI URL
# ---------------------------------------------------------------------------
function Get-FirefoxDownloadInfo {
    param([switch]$Esr)

    Write-Log "Resolving latest Firefox version..."

    $version = $null

    try {
        $page = Invoke-WebRequest -Uri "https://www.mozilla.org/en-US/firefox/enterprise/" -UseBasicParsing -TimeoutSec 30

        if ($Esr) {
            $match = [regex]::Match($page.Content, 'data-esr-versions="([0-9.]+)"')
            if ($match.Success) {
                $version = $match.Groups[1].Value + "esr"
            }
        }
        else {
            $match = [regex]::Match($page.Content, 'data-latest-firefox="([0-9.]+)"')
            if ($match.Success) {
                $version = $match.Groups[1].Value
            }
        }
    }
    catch {
        Write-Log "Primary version detection failed: $($_.Exception.Message)" -Level WARN
    }

    # Fallback: scrape FTP directory
    if (-not $version) {
        Write-Log "Falling back to FTP directory listing..."
        $ftp = Invoke-WebRequest -Uri "https://ftp.mozilla.org/pub/firefox/releases/" -UseBasicParsing -TimeoutSec 30
        $pattern = if ($Esr) { '((?>(?>[0-9]+[\.])+[0-9])+esr)' } else { '((?>(?>[0-9]+[\.])+[0-9])+(?!esr))' }

        $versions = [regex]::Matches($ftp.Content, $pattern) |
            ForEach-Object { $_.Groups[1].Value } |
            ForEach-Object {
                $clean = $_ -replace 'esr$', ''
                try { [version]$clean } catch { $null }
            } |
            Where-Object { $_ } |
            Sort-Object -Descending

        if ($versions) {
            $version = if ($Esr) { "$($versions[0])esr" } else { $versions[0].ToString() }
        }
    }

    if (-not $version) {
        throw "Unable to determine latest Firefox version."
    }

    Write-Log "Resolved version: $version"

    $fileName = "Firefox Setup $version.msi"
    $url = "https://download-installer.cdn.mozilla.net/pub/firefox/releases/$version/win64/en-US/Firefox%20Setup%20$version.msi"

    [pscustomobject]@{
        Version  = $version
        FileName = $fileName
        Url      = $url
    }
}

# ---------------------------------------------------------------------------
# Main logic
# ---------------------------------------------------------------------------
try {
    $installedVersion = Get-InstalledFirefoxVersion

    if ($installedVersion -and -not $Force) {
        Write-Log "Firefox is already installed (version $installedVersion). Skipping. Use -Force to reinstall." -Level SUCCESS
        exit 0
    }

    if ($installedVersion -and $Force) {
        Write-Log "Firefox version $installedVersion found. -Force specified, proceeding with reinstall." -Level WARN
    }
    else {
        Write-Log "Firefox not detected. Proceeding with fresh install."
    }

    if (-not (Test-Path $DownloadPath)) {
        New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null
    }

    $useEsr = -not $Regular
    $downloadInfo = Get-FirefoxDownloadInfo -Esr:$useEsr
    $msiPath = Join-Path $DownloadPath $downloadInfo.FileName

    Write-Log "Downloading Firefox MSI..."
    Write-Log "URL : $($downloadInfo.Url)"
    Write-Log "Dest: $msiPath"

    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $downloadInfo.Url -OutFile $msiPath -UseBasicParsing

    if (-not (Test-Path $msiPath) -or (Get-Item $msiPath).Length -lt 1MB) {
        throw "Download failed or file is too small."
    }

    $fileSizeMB = [math]::Round((Get-Item $msiPath).Length / 1MB, 2)
    Write-Log "Download complete ($fileSizeMB MB)" -Level SUCCESS

    Write-Log "Starting silent MSI installation..."

    $msiArgs = @(
        "/i `"$msiPath`""
        "/qn"
        "/norestart"
        "/L*v `"$($msiPath).install.log`""
    )

    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru

    if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
        Write-Log "Firefox installation completed successfully (ExitCode: $($process.ExitCode))" -Level SUCCESS
    }
    else {
        throw "msiexec returned non-zero exit code: $($process.ExitCode). See $($msiPath).install.log"
    }

    Start-Sleep -Seconds 2
    $newVersion = Get-InstalledFirefoxVersion
    if ($newVersion) {
        Write-Log "Verified installed version: $newVersion" -Level SUCCESS
    }
    else {
        Write-Log "Installation reported success but Firefox version could not be detected afterwards." -Level WARN
    }

    Write-Log "Cleaning up downloaded MSI..."
    Remove-Item -Path $msiPath -Force -ErrorAction SilentlyContinue

    Write-Log "===== Firefox installation finished =====" -Level SUCCESS
    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)" -Level ERROR
    Write-Log $_.ScriptStackTrace -Level ERROR
    exit 1
}
