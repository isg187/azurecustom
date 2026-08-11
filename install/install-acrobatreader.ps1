<#
.SYNOPSIS
    Downloads and silently installs Adobe Acrobat Reader (Enterprise).

.DESCRIPTION
    Idempotent installer for Adobe Acrobat Reader DC / Continuous Track.
    Uses Adobe's official reader products API to resolve the latest enterprise download.
    Performs a quiet installation suitable for automation.

.PARAMETER Force
    Reinstall even if Acrobat Reader is already present.

.PARAMETER LogPath
    Full path to the log file.

.PARAMETER DownloadPath
    Temporary folder for the installer.

.EXAMPLE
    .\Install-AcrobatReader.ps1

.EXAMPLE
    .\Install-AcrobatReader.ps1 -Force
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [string]$LogPath,
    [string]$DownloadPath = (Join-Path $env:TEMP "AcrobatReaderInstall")
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
    $LogPath = Join-Path $logDir ("Install-AcrobatReader_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
}
$script:LogPath = $LogPath

Write-Log "===== Starting Adobe Acrobat Reader installation ====="
Write-Log "Log file : $LogPath"
Write-Log "Force    : $Force"

# ---------------------------------------------------------------------------
# Helper: Get currently installed Acrobat Reader version
# ---------------------------------------------------------------------------
function Get-InstalledAcrobatVersion {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($base in $paths) {
        $apps = Get-ItemProperty $base -ErrorAction SilentlyContinue |
        Where-Object {
            $_.PSObject.Properties['DisplayName'] -and
            ($_.DisplayName -match 'Adobe Acrobat (Reader|DC)' -or $_.DisplayName -match 'Adobe Reader')
        }

        foreach ($app in @($apps)) {
            if ($app.PSObject.Properties['DisplayVersion'] -and $app.DisplayVersion) {
                return $app.DisplayVersion
            }
        }
    }

    $exeCandidates = @(
        "${env:ProgramFiles}\Adobe\Acrobat DC\Acrobat\Acrobat.exe",
        "${env:ProgramFiles(x86)}\Adobe\Acrobat Reader DC\Reader\AcroRd32.exe",
        "${env:ProgramFiles}\Adobe\Acrobat Reader DC\Reader\AcroRd32.exe"
    )

    foreach ($exe in $exeCandidates) {
        if (Test-Path $exe) {
            return (Get-Item $exe).VersionInfo.ProductVersion
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Helper: Resolve latest Acrobat Reader download via Adobe API
# ---------------------------------------------------------------------------
function Get-AcrobatReaderDownloadInfo {
    Write-Log "Querying Adobe Reader products API..."

    $apiKey = "dc-get-adobereader-cdn"
    $productsUri = "https://rdc.adobe.io/reader/products?lang=en&site=enterprise&os=Windows%2010&country=US&nativeOs=Windows%2010&api_key=$apiKey"

    $versionResponse = Invoke-RestMethod -Uri $productsUri -TimeoutSec 30
    $reader = $versionResponse.products.reader

    if (-not $reader) {
        throw "Could not retrieve Reader product information from Adobe API."
    }

    $version = $reader.version
    $displayName = $reader.DisplayName

    Write-Log "Resolved version: $version ($displayName)"

    $downloadUri = "https://rdc.adobe.io/reader/downloadUrl?name=$([uri]::EscapeDataString($displayName))&nativeOs=Windows 10&os=Windows 10&site=enterprise&lang=en&accepted=cr&api_key=$apiKey"

    $downloadResponse = Invoke-RestMethod -Uri $downloadUri -TimeoutSec 30

    if (-not $downloadResponse.downloadURL) {
        throw "Adobe API did not return a download URL."
    }

    [pscustomobject]@{
        Version  = $version
        FileName = $downloadResponse.saveName
        Url      = $downloadResponse.downloadURL
    }
}

# ---------------------------------------------------------------------------
# Main logic
# ---------------------------------------------------------------------------
try {
    $installedVersion = Get-InstalledAcrobatVersion

    if ($installedVersion -and -not $Force) {
        Write-Log "Adobe Acrobat Reader is already installed (version $installedVersion). Skipping. Use -Force to reinstall." -Level SUCCESS
        exit 0
    }

    if ($installedVersion -and $Force) {
        Write-Log "Acrobat Reader version $installedVersion found. -Force specified, proceeding with reinstall." -Level WARN
    }
    else {
        Write-Log "Acrobat Reader not detected. Proceeding with fresh install."
    }

    if (-not (Test-Path $DownloadPath)) {
        New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null
    }

    $downloadInfo = Get-AcrobatReaderDownloadInfo
    $installerPath = Join-Path $DownloadPath $downloadInfo.FileName

    Write-Log "Downloading Acrobat Reader..."
    Write-Log "URL : $($downloadInfo.Url)"
    Write-Log "Dest: $installerPath"

    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $downloadInfo.Url -OutFile $installerPath -UseBasicParsing

    if (-not (Test-Path $installerPath) -or (Get-Item $installerPath).Length -lt 1MB) {
        throw "Download failed or file is too small."
    }

    $fileSizeMB = [math]::Round((Get-Item $installerPath).Length / 1MB, 2)
    Write-Log "Download complete ($fileSizeMB MB)" -Level SUCCESS

    Write-Log "Starting silent installation..."

    # Adobe Reader EXE typically supports /sAll /rs /rps /msi
    # or just /sAll for basic silent
    $process = Start-Process -FilePath $installerPath -ArgumentList "/sAll /rs /rps /msi /norestart /quiet" -Wait -PassThru

    if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
        Write-Log "Acrobat Reader installation completed successfully (ExitCode: $($process.ExitCode))" -Level SUCCESS
    }
    else {
        # Some Adobe installers return other success codes; treat non-zero carefully
        Write-Log "Installer exited with code $($process.ExitCode). Checking if application is present..." -Level WARN
    }

    Start-Sleep -Seconds 3
    $newVersion = Get-InstalledAcrobatVersion
    if ($newVersion) {
        Write-Log "Verified installed version: $newVersion" -Level SUCCESS
    }
    else {
        Write-Log "Installation may have completed but version could not be detected. Please verify manually." -Level WARN
    }

    Write-Log "Cleaning up downloaded installer..."
    Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue

    Write-Log "===== Acrobat Reader installation finished =====" -Level SUCCESS
    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)" -Level ERROR
    Write-Log $_.ScriptStackTrace -Level ERROR
    exit 1
}
