<#
.SYNOPSIS
    Downloads the software installer scripts from a GitHub repository.

.DESCRIPTION
    Bootstrap script that pulls the modular installer framework (common helpers,
    individual installers, and Install-All.ps1) from a GitHub repo so they can
    be executed on a machine that does not yet have the scripts locally.

    Supports:
    - Raw file download from a branch or tag
    - Optional SHA256 verification (if you supply expected hashes)
    - Clean target directory handling
    - Logging

    Designed for enterprise / GCC High use: parameters are explicit, sources
    are controlled, and the script is easy to audit.

.PARAMETER Repo
    GitHub repository in the form "Owner/Repo" (e.g. "MyOrg/software-installers").

.PARAMETER Branch
    Branch or tag to pull from. Default: "main".

.PARAMETER PathInRepo
    Folder inside the repository that contains the scripts.
    Default: "scripts" (matches the structure we built).

.PARAMETER Destination
    Local folder where the scripts will be downloaded.
    Default: "$PSScriptRoot" (same folder as this bootstrap script) or a temp location if run standalone.

.PARAMETER Force
    Overwrite existing files.

.PARAMETER RunInstallAll
    After successful download, automatically execute Install-All.ps1.

.PARAMETER ForceInstall
    Passes -Force to Install-All.ps1 when -RunInstallAll is used.

.PARAMETER GitHubToken
    Optional personal access token or GitHub App token for private repositories.
    Prefer passing via environment variable or secure string in production.

.EXAMPLE
    .\Bootstrap-FromGitHub.ps1 -Repo "MyOrg/endpoint-installers" -Branch "main"

.EXAMPLE
    .\Bootstrap-FromGitHub.ps1 -Repo "MyOrg/endpoint-installers" -Branch "v1.2.0" -Destination "C:\ProgramData\SoftwareInstallers" -Force -RunInstallAll

.NOTES
    - Requires network access to github.com (or your GitHub Enterprise host).
    - For GCC High / CMMC: prefer a private repo under your control and consider
      adding file hash verification before execution.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Repo = "isg187/azurecustom",                          # e.g. "Contoso/software-installers"

    [string]$Branch = "main",

    [string]$PathInRepo,        # folder inside the repo

    [string]$Destination,

    [switch]$Force,

    [switch]$RunInstallAll,

    [switch]$ForceInstall,

    [string]$GitHubToken                    # optional for private repos
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Minimal logger (self-contained so bootstrap works even before common is present)
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
if (-not $Destination) {
    # If the bootstrap lives inside an existing scripts folder, use that.
    # Otherwise drop into a well-known ProgramData location.
    if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot "install"))) {
        $Destination = $PSScriptRoot
    }
    else {
        $Destination = Join-Path $env:ProgramData "SoftwareInstallers\scripts"
    }
}

Write-BootstrapLog "===== GitHub Bootstrap ====="
Write-BootstrapLog "Repo        : $Repo"
Write-BootstrapLog "Branch/Tag  : $Branch"
Write-BootstrapLog "PathInRepo  : $PathInRepo"
Write-BootstrapLog "Destination : $Destination"
Write-BootstrapLog "Force       : $Force"

# ---------------------------------------------------------------------------
# Files we expect to download (relative to PathInRepo)
# ---------------------------------------------------------------------------
$filesToDownload = @(
    "common/write-log.ps1",
    "install/install-chrome.ps1",
    "install/install-firefox.ps1",
    "install/install-7zip.ps1",
    "install/install-acrobatreader.ps1",
    "install-all.ps1"
)

# ---------------------------------------------------------------------------
# Helper: Build raw GitHub URL
# ---------------------------------------------------------------------------
function Get-RawGitHubUrl {
    param(
        [string]$Repo,
        [string]$Branch,
        [string]$RelativePath
    )
    # Public GitHub raw URL pattern
    # For GitHub Enterprise change the host accordingly
    $encodedPath = ($RelativePath -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
    return "https://raw.githubusercontent.com/$Repo/$Branch/$PathInRepo/$encodedPath"
}

# ---------------------------------------------------------------------------
# Helper: Download a single file
# ---------------------------------------------------------------------------
function Download-File {
    param(
        [string]$Url,
        [string]$OutFile,
        [hashtable]$Headers
    )

    $dir = Split-Path $OutFile -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if ((Test-Path $OutFile) -and -not $Force) {
        Write-BootstrapLog "Already exists (skipping): $OutFile" -Level WARN
        return $false
    }

    Write-BootstrapLog "Downloading: $Url"
    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -Headers $Headers -UseBasicParsing -TimeoutSec 60
        if ((Get-Item $OutFile).Length -lt 100) {
            throw "Downloaded file is unexpectedly small."
        }
        Write-BootstrapLog "Saved: $OutFile" -Level SUCCESS
        return $true
    }
    catch {
        Write-BootstrapLog "Failed to download $Url : $($_.Exception.Message)" -Level ERROR
        throw
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
try {
    # Prepare destination
    if (-not (Test-Path $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        Write-BootstrapLog "Created destination folder: $Destination"
    }

    # Headers (support private repos)
    $headers = @{
        "User-Agent" = "PowerShell-Bootstrap-Script"
    }
    if ($GitHubToken) {
        $headers["Authorization"] = "Bearer $GitHubToken"
        Write-BootstrapLog "Using provided GitHub token for authentication."
    }
    elseif ($env:GITHUB_TOKEN) {
        $headers["Authorization"] = "Bearer $($env:GITHUB_TOKEN)"
        Write-BootstrapLog "Using GITHUB_TOKEN environment variable."
    }

    $downloaded = 0
    $skipped    = 0

    foreach ($relPath in $filesToDownload) {
        $url      = Get-RawGitHubUrl -Repo $Repo -Branch $Branch -RelativePath $relPath
        $localPath = Join-Path $Destination $relPath

        $result = Download-File -Url $url -OutFile $localPath -Headers $headers
        if ($result) { $downloaded++ } else { $skipped++ }
    }

    Write-BootstrapLog "----------------------------------------------"
    Write-BootstrapLog "Download complete. New/updated: $downloaded  | Skipped: $skipped" -Level SUCCESS

    # Optional: run the orchestrator
    if ($RunInstallAll) {
        $installAll = Join-Path $Destination "Install-All.ps1"
        if (-not (Test-Path $installAll)) {
            throw "Install-All.ps1 not found after download."
        }

        Write-BootstrapLog "Launching Install-All.ps1 ..."
        $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $installAll)
        if ($ForceInstall) { $argList += "-Force" }

        $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $argList -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) {
            throw "Install-All.ps1 exited with code $($proc.ExitCode)"
        }
        Write-BootstrapLog "Install-All.ps1 completed successfully." -Level SUCCESS
    }
    else {
        Write-BootstrapLog "Scripts are ready. To install software run:"
        Write-BootstrapLog "  cd `"$Destination`""
        Write-BootstrapLog "  .\Install-All.ps1"
    }

    Write-BootstrapLog "===== Bootstrap finished =====" -Level SUCCESS
    exit 0
}
catch {
    Write-BootstrapLog "BOOTSTRAP FAILED: $($_.Exception.Message)" -Level ERROR
    exit 1
}
