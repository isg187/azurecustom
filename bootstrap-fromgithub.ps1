<#
.SYNOPSIS
    Downloads the entire GitHub repository as a zip, extracts it, and optionally runs Install-All.ps1.

.DESCRIPTION
    Simple, reliable bootstrap designed for Azure Image Builder and similar environments.
    Downloads the repo zip (no GitHub API, no per-file requests), extracts it, then
    optionally executes the orchestrator.

.PARAMETER Repo
    GitHub repository in the form "Owner/Repo" (e.g. "isg187/azurecustom").

.PARAMETER Branch
    Branch or tag to download. Default: "main".

.PARAMETER Destination
    Local folder where the extracted scripts will be placed.
    Default: C:\ProgramData\SoftwareInstallers\scripts

.PARAMETER TempPath
    Temporary working folder for the zip download and extraction.
    Default: C:\Temp\SoftwareInstallers

.PARAMETER Force
    Overwrite existing destination files.

.PARAMETER RunInstallAll
    After extraction, automatically execute Install-All.ps1.

.PARAMETER ForceInstall
    Passes -Force to Install-All.ps1 when -RunInstallAll is used.

.PARAMETER KeepTemp
    Do not delete the temporary download/extract folder.

.EXAMPLE
    .\Bootstrap-FromGitHub.ps1 -Repo "isg187/azurecustom"

.EXAMPLE
    .\Bootstrap-FromGitHub.ps1 -Repo "isg187/azurecustom" -Branch "main" -RunInstallAll -Force
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Repo,

    [string]$Branch = "main",

    [string]$Destination = "C:\ProgramData\SDL\scripts",

    [string]$TempPath = "C:\Temp\SoftwareInstallers",

    [switch]$Force,

    [switch]$RunInstallAll,

    [switch]$ForceInstall,

    [switch]$KeepTemp
)

$ErrorActionPreference = "Stop"

function Write-BootstrapLog {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$ts] [$Level] $Message"
    switch ($Level) {
        'ERROR'   { Write-Host $entry -ForegroundColor Red }
        'WARN'    { Write-Host $entry -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $entry -ForegroundColor Green }
        default   { Write-Host $entry }
    }
}

try {
    Write-BootstrapLog "===== GitHub Bootstrap (Zip) ====="
    Write-BootstrapLog "Repo        : $Repo"
    Write-BootstrapLog "Branch      : $Branch"
    Write-BootstrapLog "Destination : $Destination"
    Write-BootstrapLog "TempPath    : $TempPath"
    Write-BootstrapLog "Force       : $Force"
    Write-BootstrapLog "RunInstallAll : $RunInstallAll"

    # Prepare temp folder
    if (Test-Path $TempPath) {
        Remove-Item -Path $TempPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $TempPath -Force | Out-Null

    # Download entire repo as zip
    $zipUrl  = "https://github.com/$Repo/archive/refs/heads/$Branch.zip"
    $zipPath = Join-Path $TempPath "repo.zip"

    Write-BootstrapLog "Downloading: $zipUrl"
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing

    if (-not (Test-Path $zipPath) -or (Get-Item $zipPath).Length -lt 1KB) {
        throw "Download failed or zip file is empty."
    }
    Write-BootstrapLog "Download complete ($([math]::Round((Get-Item $zipPath).Length / 1MB, 2)) MB)" -Level SUCCESS

    # Extract
    Write-BootstrapLog "Extracting zip..."
    Expand-Archive -Path $zipPath -DestinationPath $TempPath -Force

    # GitHub names the extracted folder Owner-Repo-Branch
    $extractedRoot = Get-ChildItem -Path $TempPath -Directory | Where-Object { $_.Name -like "*-*" } | Select-Object -First 1 -ExpandProperty FullName

    if (-not $extractedRoot) {
        throw "Could not find extracted repository folder under $TempPath"
    }
    Write-BootstrapLog "Extracted to: $extractedRoot"

    # Determine source of scripts
    # Prefer a "scripts" subfolder if it exists, otherwise use the repo root
    $scriptsSource = Join-Path $extractedRoot "scripts"
    if (-not (Test-Path $scriptsSource)) {
        $scriptsSource = $extractedRoot
    }
    Write-BootstrapLog "Scripts source: $scriptsSource"

    # Prepare destination
    if (Test-Path $Destination) {
        if ($Force) {
            Write-BootstrapLog "Removing existing destination (Force)..." -Level WARN
            Remove-Item -Path $Destination -Recurse -Force -ErrorAction SilentlyContinue
        }
        else {
            Write-BootstrapLog "Destination already exists. Use -Force to overwrite." -Level WARN
        }
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null

    # Copy everything from scripts source into destination
    Write-BootstrapLog "Copying scripts to $Destination ..."
    Copy-Item -Path (Join-Path $scriptsSource "*") -Destination $Destination -Recurse -Force
    Write-BootstrapLog "Copy complete." -Level SUCCESS

    # Optional: run Install-All.ps1
    if ($RunInstallAll) {
        $installAll = Join-Path $Destination "Install-All.ps1"
        if (-not (Test-Path $installAll)) {
            # Fallback: search one level deeper
            $found = Get-ChildItem -Path $Destination -Filter "Install-All.ps1" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $installAll = $found.FullName }
        }

        if (-not (Test-Path $installAll)) {
            Write-BootstrapLog "Install-All.ps1 not found after extraction — skipping auto-run." -Level WARN
        }
        else {
            Write-BootstrapLog "Launching Install-All.ps1 ..."
            $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $installAll)
            if ($ForceInstall) { $argList += "-Force" }

            $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $argList -Wait -PassThru -NoNewWindow
            if ($proc.ExitCode -ne 0) {
                throw "Install-All.ps1 exited with code $($proc.ExitCode)"
            }
            Write-BootstrapLog "Install-All.ps1 completed successfully." -Level SUCCESS
        }
    }
    else {
        Write-BootstrapLog "Scripts are ready. To install software run:"
        Write-BootstrapLog "  cd `"$Destination`""
        Write-BootstrapLog "  .\Install-All.ps1"
    }

    # Cleanup
    if (-not $KeepTemp) {
        Write-BootstrapLog "Cleaning up temp folder..."
        Remove-Item -Path $TempPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-BootstrapLog "===== Bootstrap finished =====" -Level SUCCESS
    exit 0
}
catch {
    Write-BootstrapLog "BOOTSTRAP FAILED: $($_.Exception.Message)" -Level ERROR
    exit 1
}
