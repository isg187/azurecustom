<#
.SYNOPSIS
    Installs Box Drive, Box Tools (admin MSI), and Box for Office.

.PARAMETER Force
    Reinstall even if already present.

.PARAMETER Drive
    Install Box Drive only. If no product switch is set, all three install.

.PARAMETER Tools
    Install Box Tools only.

.PARAMETER Office
    Install Box for Office only.

.EXAMPLE
    .\install-box.ps1

.EXAMPLE
    .\install-box.ps1 -Drive -Tools
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$Drive,
    [switch]$Tools,
    [switch]$Office,
    [string]$LogPath,
    [string]$DownloadPath = (Join-Path $env:TEMP 'BoxInstall')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ConfirmPreference = 'None'

if (-not $Drive -and -not $Tools -and -not $Office) {
    $Drive = $true
    $Tools = $true
    $Office = $true
}

function Write-Log {
    param(
        [Parameter(Position = 0)]
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )

    if (-not $script:LogPath) {
        $script:LogPath = Join-Path $env:TEMP ("SoftwareInstall_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
    }

    $entry = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'ERROR'   { Write-Host $entry -ForegroundColor Red }
        'WARN'    { Write-Host $entry -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $entry -ForegroundColor Green }
        default   { Write-Host $entry }
    }

    $logDir = Split-Path $script:LogPath -Parent
    if ($logDir -and -not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    Add-Content -Path $script:LogPath -Value $entry
}

function Get-UninstallEntry {
    param([string]$DisplayNameMatch)

    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($props.DisplayName -match $DisplayNameMatch) {
                return $props
            }
        }
    }
    return $null
}

function Test-MsiIntegrity {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Integrity check failed: file not found: $Path"
    }

    $sig = Get-AuthenticodeSignature -FilePath $Path
    if ($sig.Status -ne 'Valid') {
        Write-Log ('Authenticode not valid ({0})' -f $sig.Status) -Level WARN
        return
    }

    $subject = $sig.SignerCertificate.Subject
    if ($subject -notlike '*Box*') {
        throw "Unexpected publisher. Subject='$subject'"
    }
}

function Install-BoxMsi {
    param(
        [string]$Name,
        [string]$Url,
        [string]$FileName,
        [string]$DetectPattern
    )

    $existing = Get-UninstallEntry -DisplayNameMatch $DetectPattern
    if ($existing -and -not $Force) {
        $ver = $existing.DisplayVersion
        if (-not $ver) { $ver = $existing.DisplayName }
        Write-Log ('{0} already installed: {1}' -f $Name, $ver) -Level SUCCESS
        return
    }

    if ($existing -and $Force) {
        Write-Log ('{0} found; Force specified' -f $Name) -Level WARN
    }

    $msiPath = Join-Path $DownloadPath $FileName
    Write-Log ('Downloading {0}' -f $Name)
    Invoke-WebRequest -Uri $Url -OutFile $msiPath -UseBasicParsing

    if (-not (Test-Path $msiPath) -or (Get-Item $msiPath).Length -lt 500KB) {
        throw ("{0} download failed or file is too small." -f $Name)
    }

    Test-MsiIntegrity -Path $msiPath
    Write-Log ('Installing {0}' -f $Name)

    $msiArgs = @(
        '/i'
        ('"{0}"' -f $msiPath)
        '/qn'
        '/norestart'
        'ALLUSERS=1'
    )
    $processParams = @{
        FilePath     = Join-Path $env:SystemRoot 'System32\msiexec.exe'
        ArgumentList = ($msiArgs -join ' ')
        Wait         = $true
        PassThru     = $true
    }
    $process = Start-Process @processParams

    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
        throw ("{0} MSI returned exit code {1}" -f $Name, $process.ExitCode)
    }

    $installed = Get-UninstallEntry -DisplayNameMatch $DetectPattern
    if ($installed) {
        $ver = $installed.DisplayVersion
        if (-not $ver) { $ver = $installed.DisplayName }
        Write-Log ('{0} installed: {1}' -f $Name, $ver) -Level SUCCESS
    }
    else {
        Write-Log ('{0} installer finished but product was not detected.' -f $Name) -Level WARN
    }

    if ($process.ExitCode -eq 3010) {
        Write-Log ('{0} completed with reboot pending.' -f $Name) -Level WARN
    }

    Remove-Item -Path $msiPath -Force -ErrorAction SilentlyContinue
}

if ($LogPath) {
    $script:LogPath = $LogPath
}
else {
    $logDir = 'C:\ProgramData\SDL\scripts\logs'
    $script:LogPath = Join-Path $logDir ("Install-Box_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
}

Write-Log 'Starting Box product install'

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    if (-not (Test-Path $DownloadPath)) {
        New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null
    }

    if ($Drive) {
        Install-BoxMsi -Name 'Box Drive' -Url 'https://e3.boxcdn.net/box-installers/desktop/releases/win/Box-x64.msi' -FileName 'Box-x64.msi' -DetectPattern '^Box Drive|^Box$'
    }

    if ($Tools) {
        Install-BoxMsi -Name 'Box Tools' -Url 'https://e3.boxcdn.net/box-installers/boxedit/win/currentrelease/BoxToolsInstaller-AdminInstall.msi' -FileName 'BoxToolsInstaller-AdminInstall.msi' -DetectPattern 'Box Tools|Box Edit'
    }

    if ($Office) {
        Install-BoxMsi -Name 'Box for Office' -Url 'https://e3.boxcdn.net/box-installers/boxforoffice/currentrelease/BoxForOffice.msi' -FileName 'BoxForOffice.msi' -DetectPattern 'Box for Office'
    }

    Write-Log 'Install finished' -Level SUCCESS
    exit 0
}
catch {
    Write-Log $_.Exception.Message -Level ERROR
    exit 1
}
