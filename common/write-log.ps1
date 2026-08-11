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
