<#
.SYNOPSIS
    Downloads and silently installs 7-Zip (x64).

.DESCRIPTION
    Idempotent installer for 7-Zip 64-bit.
    Prefers the MSI when available; falls back to EXE.
    Source: official GitHub releases (ip7z/7zip).

.PARAMETER Force
    Reinstall even if 7-Zip is already present.

.PARAMETER PreferExe
    Force the .exe installer instead of MSI.

.PARAMETER LogPath
    Full path to the log file.

.PARAMETER DownloadPath
    Temporary folder for the installer.

.EXAMPLE
    .\Install-7Zip.ps1

.EXAMPLE
    .\Install-7Zip.ps1 -Force
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$PreferExe,
    [string]$LogPath,
    [string]$DownloadPath = (Join-Path $env:TEMP "7ZipInstall")
)

#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
# Initialize logging
$logDir = "C:\ProgramData\SDL\scripts\logs"
$LogPath = Join-Path $logDir ("Install-7Zip_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
Write-Log "===== Starting 7-Zip installation ====="
Write-Log "Log file : $LogPath"
Write-Log "Force    : $Force"

# Helper: Get currently installed 7-Zip version
function Get-Installed7ZipVersion {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\7-Zip',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\7-Zip'
    )

    foreach ($p in $paths) {
        if (Test-Path $p) {
            $ver = (Get-ItemProperty -Path $p -ErrorAction SilentlyContinue).DisplayVersion
            if ($ver) { return $ver }
        }
    }

    $exe = "${env:ProgramFiles}\7-Zip\7z.exe"
    if (Test-Path $exe) {
        return (Get-Item $exe).VersionInfo.ProductVersion
    }
    return $null
}

# Helper: Get latest 7-Zip download info from GitHub
function Get-7ZipDownloadInfo {
    param([switch]$PreferExe)

    $repo = "ip7z/7zip"
    Write-Log "Querying GitHub releases for $repo..."

    $headers = @{
        "User-Agent" = "PowerShell-7Zip-Installer"
        "Accept"     = "application/vnd.github+json"
    }

    $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers $headers -TimeoutSec 30

    $version = $releases.tag_name -replace '^v', ''
    Write-Log "Latest version: $version"

    $assets = $releases.assets

    # Prefer MSI x64, then EXE x64
    $msi = $assets | Where-Object { $_.name -match 'x64.*\.msi$' -or $_.name -match '7z.*-x64\.msi$' } | Select-Object -First 1
    $exe = $assets | Where-Object { $_.name -match 'x64\.exe$' -or $_.name -match '7z.*-x64\.exe$' } | Select-Object -First 1

    if ($PreferExe -and $exe) {
        $chosen = $exe
        $type = 'EXE'
    }
    elseif ($msi) {
        $chosen = $msi
        $type = 'MSI'
    }
    elseif ($exe) {
        $chosen = $exe
        $type = 'EXE'
    }
    else {
        throw "Could not find a suitable x64 installer asset in the latest release."
    }

    [pscustomobject]@{
        Version  = $version
        FileName = $chosen.name
        Url      = $chosen.browser_download_url
        Type     = $type
    }
}

# Main trigger
try {
    $installedVersion = Get-Installed7ZipVersion

    if ($installedVersion -and -not $Force) {
        Write-Log "7-Zip is already installed (version $installedVersion). Skipping. Use -Force to reinstall." -Level SUCCESS
        exit 0
    }

    if ($installedVersion -and $Force) {
        Write-Log "7-Zip version $installedVersion found. -Force specified, proceeding with reinstall." -Level WARN
    }
    else {
        Write-Log "7-Zip not detected. Proceeding with fresh install."
    }

    if (-not (Test-Path $DownloadPath)) {
        New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null
    }

    $downloadInfo = Get-7ZipDownloadInfo -PreferExe:$PreferExe
    $installerPath = Join-Path $DownloadPath $downloadInfo.FileName

    Write-Log "Downloading 7-Zip ($($downloadInfo.Type))..."
    Write-Log "URL : $($downloadInfo.Url)"
    Write-Log "Dest: $installerPath"

    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $downloadInfo.Url -OutFile $installerPath -UseBasicParsing

    if (-not (Test-Path $installerPath) -or (Get-Item $installerPath).Length -lt 500KB) {
        throw "Download failed or file is too small."
    }

    $fileSizeMB = [math]::Round((Get-Item $installerPath).Length / 1MB, 2)
    Write-Log "Download complete ($fileSizeMB MB)" -Level SUCCESS

    Write-Log "Starting silent installation..."

    if ($downloadInfo.Type -eq 'MSI') {
        $args = @(
            "/i `"$installerPath`""
            "/qn"
            "/norestart"
            "/L*v `"$($installerPath).install.log`""
        )
        $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $args -Wait -PassThru
    }
    else {
        # 7-Zip EXE silent switch
        $process = Start-Process -FilePath $installerPath -ArgumentList "/S" -Wait -PassThru
    }

    if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
        Write-Log "7-Zip installation completed successfully (ExitCode: $($process.ExitCode))" -Level SUCCESS
    }
    else {
        throw "Installer returned non-zero exit code: $($process.ExitCode)"
    }

    Start-Sleep -Seconds 2
    $newVersion = Get-Installed7ZipVersion
    if ($newVersion) {
        Write-Log "Verified installed version: $newVersion" -Level SUCCESS
    }
    else {
        Write-Log "Installation reported success but 7-Zip version could not be detected afterwards." -Level WARN
    }

    Write-Log "Cleaning up downloaded installer..."
    Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue

    Write-Log "===== 7-Zip installation finished =====" -Level SUCCESS
    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)" -Level ERROR
    Write-Log $_.ScriptStackTrace -Level ERROR
    exit 1
}
