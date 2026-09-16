<#
.SYNOPSIS
    Downloads and silently installs Adobe Acrobat Reader (Enterprise).

.PARAMETER Force
    Reinstall even if Acrobat Reader is already present.

.PARAMETER LogPath
    Full path to the log file.

.PARAMETER DownloadPath
    Temporary folder for the installer.

.PARAMETER ExpectedSha256
    Optional SHA-256 to enforce.

.EXAMPLE
    .\install-acrobatreader.ps1

.EXAMPLE
    .\install-acrobatreader.ps1 -Force
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$Force,
    [string]$LogPath,
    [string]$DownloadPath = (Join-Path $env:TEMP 'AcrobatReaderInstall'),
    [string]$ExpectedSha256
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowEmptyString()]
        [string]$Message = '',
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )

    if (-not $script:LogPath) {
        $script:LogPath = Join-Path $env:TEMP ("SoftwareInstall_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
    }

    $entry = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message

    switch ($Level) {
        'ERROR' { Write-Host $entry -ForegroundColor Red }
        'WARN' { Write-Host $entry -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $entry -ForegroundColor Green }
        default { Write-Host $entry }
    }

    $dir = Split-Path $script:LogPath -Parent
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Add-Content -Path $script:LogPath -Value $entry
}

function Test-InstallerIntegrity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string[]]$ExpectedPublishers,
        [string]$ExpectedSha256
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Integrity check failed: file not found $Path"
    }

    if ($ExpectedSha256) {
        $actualHash = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToUpperInvariant()
        $expected = $ExpectedSha256.Trim().ToUpperInvariant()
        if ($actualHash -ne $expected) {
            throw "SHA-256 mismatch. Expected $expected but got $actualHash"
        }
    }

    $sig = Get-AuthenticodeSignature -FilePath $Path
    if ($sig.Status -ne 'Valid') {
        throw "Authenticode signature is not valid $($sig.Status)"
    }

    $subject = $sig.SignerCertificate.Subject
    $matched = $false
    foreach ($pub in $ExpectedPublishers) {
        if ($subject -like "*$pub*") {
            $matched = $true
            break
        }
    }
    if (-not $matched) {
        throw "Unexpected publisher $subject"
    }
}

function Get-InstalledAcrobatVersion {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($base in $paths) {
        $apps = Get-ItemProperty $base -ErrorAction SilentlyContinue |
        Where-Object {
            $_.DisplayName -and
            ($_.DisplayName -match 'Adobe Acrobat' -or $_.DisplayName -match 'Adobe Reader')
        }

        foreach ($app in @($apps)) {
            if ($app.DisplayVersion) { return $app.DisplayVersion }
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

function Get-AcrobatReaderDownloadInfo {
    Write-Log 'Querying Adobe Reader products API'

    $apiKey = 'dc-get-adobereader-cdn'
    $productsUri = 'https://rdc.adobe.io/reader/products?lang=en&site=enterprise&os=Windows%2010&country=US&nativeOs=Windows%2010&api_key=' + $apiKey

    $versionResponse = Invoke-RestMethod -Uri $productsUri -TimeoutSec 30
    $reader = $versionResponse.products.reader
    if (-not $reader) {
        throw 'Could not retrieve Reader product information from Adobe API.'
    }

    $version = $reader.version
    $displayName = $reader.DisplayName
    Write-Log ('Resolved version: {0}' -f $version)

    $downloadUri = 'https://rdc.adobe.io/reader/downloadUrl?name=' + [uri]::EscapeDataString($displayName) + '&nativeOs=Windows%2010&os=Windows%2010&site=enterprise&lang=en&accepted=cr&api_key=' + $apiKey

    $downloadResponse = Invoke-RestMethod -Uri $downloadUri -TimeoutSec 30
    if (-not $downloadResponse.downloadURL) {
        throw 'Adobe API did not return a download URL.'
    }

    [pscustomobject]@{
        Version  = $version
        FileName = $downloadResponse.saveName
        Url      = $downloadResponse.downloadURL
    }
}

if ($LogPath) {
    $script:LogPath = $LogPath
}
else {
    $logDir = 'C:\ProgramData\SDL\scripts\logs'
    $script:LogPath = Join-Path $logDir ("Install-AcrobatReader_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
}

Write-Log 'Starting Acrobat Reader install'

try {
    $installedVersion = Get-InstalledAcrobatVersion

    if ($installedVersion -and -not $Force) {
        Write-Log ('Acrobat Reader already installed: {0}' -f $installedVersion) -Level SUCCESS
        Write-Log 'Install finished' -Level SUCCESS
        exit 0
    }

    if ($installedVersion -and $Force) {
        Write-Log ('Acrobat Reader {0} found; Force specified' -f $installedVersion) -Level WARN
    }
    else {
        Write-Log 'Acrobat Reader not detected; installing latest'
    }

    if (-not (Test-Path $DownloadPath)) {
        New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null
    }

    $downloadInfo = Get-AcrobatReaderDownloadInfo
    $installerPath = Join-Path $DownloadPath $downloadInfo.FileName
    Write-Log ('Downloading Acrobat Reader {0}' -f $downloadInfo.Version)

    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $downloadInfo.Url -OutFile $installerPath -UseBasicParsing

    if (-not (Test-Path $installerPath) -or (Get-Item $installerPath).Length -lt 1MB) {
        throw 'Download failed or file is too small.'
    }

    $integrityParams = @{
        Path               = $installerPath
        ExpectedPublishers = @('Adobe', 'Adobe Systems')
    }
    if ($ExpectedSha256) {
        $integrityParams['ExpectedSha256'] = $ExpectedSha256
    }
    Test-InstallerIntegrity @integrityParams

    Write-Log 'Installing Acrobat Reader'
    $processParams = @{
        FilePath     = $installerPath
        ArgumentList = '/sAll /rs /msi  EULA_ACCEPT=YES LANG_LIST=en_US UPDATE_MODE=0 DISABLE_ARM_SERVICE_INSTALL=1 ADD_THUMBNAILPREVIEW=YES'
        Wait         = $true
        PassThru     = $true
    }
    $process = Start-Process @processParams

    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
        Write-Log ('Installer exited with code {0}; checking if app is present' -f $process.ExitCode) -Level WARN
    }

    Start-Sleep -Seconds 3
    $newVersion = Get-InstalledAcrobatVersion
    if ($newVersion) {
        Write-Log ('Acrobat Reader installed: {0}' -f $newVersion) -Level SUCCESS
    }
    else {
        Write-Log 'Installer finished but Acrobat Reader version was not detected.' -Level WARN
    }

    Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue
    Write-Log 'Install finished' -Level SUCCESS
    exit 0
}
catch {
    Write-Log $_.Exception.Message -Level ERROR
    exit 1
}
