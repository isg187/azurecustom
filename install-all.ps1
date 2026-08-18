<#
.SYNOPSIS
    Dynamically runs every installer script found in the install\ folder.

.DESCRIPTION
    Discovers all *.ps1 files under the install directory and executes them
    one by one. No hardcoded list — when you add a new Install-*.ps1 script
    it is automatically included on the next run.

.PARAMETER Force
    Passes -Force to every individual installer.

.PARAMETER ContinueOnError
    Continues to the next package even if one fails.

.PARAMETER InstallDir
    Folder containing the individual installer scripts.
    Default: .\install (relative to this script)

.EXAMPLE
    .\Install-All.ps1

.EXAMPLE
    .\Install-All.ps1 -Force -ContinueOnError
#>
$ErrorActionPreference = 'Stop'

# Logging setup
function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS', 'DEBUG')]
        [string]$Level = 'INFO',

        [string]$LogPath = $script:LogPath
    )

    if (-not $LogPath) {
        $LogPath = Join-Path $env:TEMP "SoftwareInstall_$(Get-Date -Format 'yyyyMMdd').log"
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$timestamp] [$Level] $Message"

    # Console output with color
    switch ($Level) {
        'ERROR'   { Write-Host $entry -ForegroundColor Red }
        'WARN'    { Write-Host $entry -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $entry -ForegroundColor Green }
        'DEBUG'   { if ($VerbosePreference -eq 'Continue') { Write-Host $entry -ForegroundColor Gray } }
        default   { Write-Host $entry }
    }

    # File output
    try {
        $logDir = Split-Path $LogPath -Parent
        if ($logDir -and -not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        Add-Content -Path $LogPath -Value $entry -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to write to log file: $($_.Exception.Message)"
    }
}
$logDir = "C:\ProgramData\SDL\scripts\logs"
$script:LogPath = Join-Path $logDir ("Install-All_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
$InstallDir = "C:\ProgramData\SDL\scripts\install"

Write-Log "=============================================="
Write-Log "  Software Installation Orchestrator (Dynamic)"
Write-Log "=============================================="
Write-Log "Force            : $Force"
Write-Log "ContinueOnError  : $ContinueOnError"
Write-Log "InstallDir       : $InstallDir"
Write-Log "Log              : $script:LogPath"

# ---------------------------------------------------------------------------
# Discover installer scripts
# ---------------------------------------------------------------------------
$installerScripts = Get-ChildItem -Path $InstallDir -Filter "*.ps1" -File | Sort-Object Name
Write-Log "Discovered $($installerScripts.Count) installer script(s):"
$installerScripts | ForEach-Object { Write-Log "  - $($_.Name)" }

# ---------------------------------------------------------------------------
# Run each installer
# ---------------------------------------------------------------------------
$results = @()
$overallSuccess = $true

foreach ($scriptFile in $installerScripts) {
    $scriptPath = $scriptFile.FullName
    $name = $scriptFile.BaseName   # e.g. Install-Chrome

    Write-Log "--------------------------------------------------"
    Write-Log "Starting: $name"
    Write-Log "Script  : $scriptPath"

    try {
        $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $scriptPath)
        if ($Force) { $argList += "-Force" }

        $proc = Start-Process -FilePath "powershell.exe" `
            -ArgumentList $argList `
            -Wait -PassThru -NoNewWindow

        if ($proc.ExitCode -eq 0) {
            Write-Log "$name completed successfully." -Level SUCCESS
            $results += [pscustomobject]@{ Name = $name; Success = $true; Message = "OK" }
        }
        else {
            Write-Log "$name failed with exit code $($proc.ExitCode)." -Level ERROR
            $results += [pscustomobject]@{ Name = $name; Success = $false; Message = "Exit code $($proc.ExitCode)" }
            $overallSuccess = $false
            if (-not $ContinueOnError) { break }
        }
    }
    catch {
        Write-Log "Exception while running $name : $($_.Exception.Message)" -Level ERROR
        $results += [pscustomobject]@{ Name = $name; Success = $false; Message = $_.Exception.Message }
        $overallSuccess = $false
        if (-not $ContinueOnError) { break }
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Log "=============================================="
Write-Log "  Summary"
Write-Log "=============================================="
$results | ForEach-Object {
    $status = if ($_.Success) { "SUCCESS" } else { "FAILED" }
    Write-Log ("{0,-40} {1}" -f $_.Name, $status)
}

if ($overallSuccess) {
    Write-Log "All discovered installers completed successfully." -Level SUCCESS
    exit 0
}
else {
    Write-Log "One or more installations failed. Review the logs." -Level ERROR
    exit 1
}
