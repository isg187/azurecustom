<#
.SYNOPSIS
    Orchestrator that installs Chrome, Firefox, 7-Zip, and Adobe Acrobat Reader.

.DESCRIPTION
    Calls the individual installer scripts in a defined order.
    Stops on first failure by default (change $ContinueOnError if desired).

.PARAMETER Force
    Passes -Force to every individual installer.

.PARAMETER ContinueOnError
    Continues to the next package even if one fails.

.EXAMPLE
    .\Install-All.ps1

.EXAMPLE
    .\Install-All.ps1 -Force -ContinueOnError
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$ContinueOnError
)

#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Dot-source common logger
# ---------------------------------------------------------------------------
$commonPath = Join-Path $PSScriptRoot "common\Write-Log.ps1"
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

$logDir = Join-Path $PSScriptRoot "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$script:LogPath = Join-Path $logDir ("Install-All_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

Write-Log "=============================================="
Write-Log "  Software Installation Orchestrator"
Write-Log "=============================================="
Write-Log "Force            : $Force"
Write-Log "ContinueOnError  : $ContinueOnError"
Write-Log "Log              : $script:LogPath"
Write-Log ""

$installers = @(
    @{ Name = "Google Chrome";           Script = "install\Install-Chrome.ps1" },
    @{ Name = "Mozilla Firefox (ESR)";   Script = "install\Install-Firefox.ps1" },
    @{ Name = "7-Zip";                   Script = "install\Install-7Zip.ps1" },
    @{ Name = "Adobe Acrobat Reader";    Script = "install\Install-AcrobatReader.ps1" }
)

$results = @()
$overallSuccess = $true

foreach ($item in $installers) {
    $scriptPath = Join-Path $PSScriptRoot $item.Script

    Write-Log "--------------------------------------------------"
    Write-Log "Starting: $($item.Name)"
    Write-Log "Script  : $scriptPath"

    if (-not (Test-Path $scriptPath)) {
        Write-Log "Script not found: $scriptPath" -Level ERROR
        $results += [pscustomobject]@{ Name = $item.Name; Success = $false; Message = "Script missing" }
        $overallSuccess = $false
        if (-not $ContinueOnError) { break }
        continue
    }

    try {
        $argList = @()
        if ($Force) { $argList += "-Force" }

        $proc = Start-Process -FilePath "powershell.exe" `
            -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $scriptPath) + $argList `
            -Wait -PassThru -NoNewWindow

        if ($proc.ExitCode -eq 0) {
            Write-Log "$($item.Name) completed successfully." -Level SUCCESS
            $results += [pscustomobject]@{ Name = $item.Name; Success = $true; Message = "OK" }
        }
        else {
            Write-Log "$($item.Name) failed with exit code $($proc.ExitCode)." -Level ERROR
            $results += [pscustomobject]@{ Name = $item.Name; Success = $false; Message = "Exit code $($proc.ExitCode)" }
            $overallSuccess = $false
            if (-not $ContinueOnError) { break }
        }
    }
    catch {
        Write-Log "Exception while running $($item.Name): $($_.Exception.Message)" -Level ERROR
        $results += [pscustomobject]@{ Name = $item.Name; Success = $false; Message = $_.Exception.Message }
        $overallSuccess = $false
        if (-not $ContinueOnError) { break }
    }
}

Write-Log ""
Write-Log "=============================================="
Write-Log "  Summary"
Write-Log "=============================================="
$results | ForEach-Object {
    $status = if ($_.Success) { "SUCCESS" } else { "FAILED" }
    Write-Log ("{0,-30} {1}" -f $_.Name, $status)
}

if ($overallSuccess) {
    Write-Log "All requested software installed successfully." -Level SUCCESS
    exit 0
}
else {
    Write-Log "One or more installations failed. Review the logs." -Level ERROR
    exit 1
}
