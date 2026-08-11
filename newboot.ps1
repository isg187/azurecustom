<#
.SYNOPSIS
    Dynamically downloads all scripts from a GitHub repository folder.

.DESCRIPTION
    Bootstrap script that discovers and downloads every file under a given path
    in a GitHub repository (recursively). No hardcoded file list — when you add
    a new installer script to the repo, the next bootstrap run will pick it up
    automatically.

    Supports public and private repos, branch/tag selection, and optional
    automatic execution of Install-All.ps1 after download.

.PARAMETER Repo
    GitHub repository in the form "Owner/Repo" (e.g. "isg187/azurecustom").

.PARAMETER Branch
    Branch or tag to pull from. Default: "main".

.PARAMETER PathInRepo
    Folder inside the repository to download from.
    Use "" (empty) for the repository root.
    Default: "" (root) so it works whether scripts live at root or under a subfolder.

.PARAMETER Destination
    Local folder where the scripts will be placed.
    Default: C:\ProgramData\SoftwareInstallers\scripts (or current scripts folder if already present).

.PARAMETER Force
    Overwrite existing local files.

.PARAMETER FileFilter
    Only download files matching this wildcard. Default: "*.ps1"
    Set to "*" to download everything under PathInRepo.

.PARAMETER RunInstallAll
    After successful download, automatically execute Install-All.ps1 (if present).

.PARAMETER ForceInstall
    Passes -Force to Install-All.ps1 when -RunInstallAll is used.

.PARAMETER GitHubToken
    Optional token for private repositories.
    Can also be supplied via the GITHUB_TOKEN environment variable.

.EXAMPLE
    .\Bootstrap-FromGitHub.ps1 -Repo "isg187/azurecustom" -Branch "main"

.EXAMPLE
    .\Bootstrap-FromGitHub.ps1 -Repo "isg187/azurecustom" -PathInRepo "scripts" -Force -RunInstallAll
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Repo = "isg187/azurecustom",

    [string]$Branch = "main",

    [string]$PathInRepo = "",                 # empty = repository root

    [string]$Destination,

    [switch]$Force,

    [string]$FileFilter = "*.ps1",            # only .ps1 by default

    [switch]$RunInstallAll,

    [switch]$ForceInstall,

    [string]$GitHubToken
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Minimal logger (self-contained)
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
    if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot "install"))) {
        $Destination = $PSScriptRoot
    }
    else {
        $Destination = Join-Path $env:ProgramData "SoftwareInstallers\scripts"
    }
}

# Normalize PathInRepo (remove leading/trailing slashes)
$PathInRepo = ($PathInRepo -replace '^/+', '' -replace '/+$', '').Trim()

Write-BootstrapLog "===== GitHub Bootstrap (Dynamic) ====="
Write-BootstrapLog "Repo        : $Repo"
Write-BootstrapLog "Branch/Tag  : $Branch"
Write-BootstrapLog "PathInRepo  : $(if ($PathInRepo) { $PathInRepo } else { '(repository root)' })"
Write-BootstrapLog "Destination : $Destination"
Write-BootstrapLog "FileFilter  : $FileFilter"
Write-BootstrapLog "Force       : $Force"

# ---------------------------------------------------------------------------
# Headers
# ---------------------------------------------------------------------------
$headers = @{
    "User-Agent" = "PowerShell-Bootstrap-Script"
    "Accept"     = "application/vnd.github+json"
}
if ($GitHubToken) {
    $headers["Authorization"] = "Bearer $GitHubToken"
    Write-BootstrapLog "Using provided GitHub token."
}
elseif ($env:GITHUB_TOKEN) {
    $headers["Authorization"] = "Bearer $($env:GITHUB_TOKEN)"
    Write-BootstrapLog "Using GITHUB_TOKEN environment variable."
}

# ---------------------------------------------------------------------------
# Helper: Recursively list all files under a GitHub path via Contents API
# ---------------------------------------------------------------------------
function Get-GitHubFilesRecursive {
    param(
        [string]$Repo,
        [string]$Branch,
        [string]$Path,          # can be empty for root
        [hashtable]$Headers
    )

    $apiPath = if ($Path) {
        "https://api.github.com/repos/$Repo/contents/$Path`?ref=$Branch"
    }
    else {
        "https://api.github.com/repos/$Repo/contents`?ref=$Branch"
    }

    Write-BootstrapLog "Listing: $apiPath" -Level INFO

    try {
        $items = Invoke-RestMethod -Uri $apiPath -Headers $Headers -TimeoutSec 30
    }
    catch {
        throw "Failed to list GitHub contents at '$Path': $($_.Exception.Message)"
    }

    # API returns a single object when Path points to a file; normalize to array
    if ($items -isnot [System.Array]) {
        $items = @($items)
    }

    $files = @()

    foreach ($item in $items) {
        if ($item.type -eq 'file') {
            $files += [pscustomobject]@{
                Path        = $item.path          # full path from repo root
                DownloadUrl = $item.download_url
                Size        = $item.size
                Sha         = $item.sha
            }
        }
        elseif ($item.type -eq 'dir') {
            # Recurse into subdirectories
            $files += Get-GitHubFilesRecursive -Repo $Repo -Branch $Branch -Path $item.path -Headers $Headers
        }
    }

    return $files
}

# ---------------------------------------------------------------------------
# Helper: Download a single file
# ---------------------------------------------------------------------------
function Save-GitHubFile {
    param(
        [string]$DownloadUrl,
        [string]$LocalPath,
        [hashtable]$Headers
    )

    $dir = Split-Path $LocalPath -Parent
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if ((Test-Path $LocalPath) -and -not $Force) {
        Write-BootstrapLog "Already exists (skipping): $LocalPath" -Level WARN
        return $false
    }

    Write-BootstrapLog "Downloading: $DownloadUrl"
    try {
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $LocalPath -Headers $Headers -UseBasicParsing -TimeoutSec 60
        if ((Get-Item $LocalPath).Length -lt 50) {
            throw "Downloaded file is unexpectedly small."
        }
        Write-BootstrapLog "Saved: $LocalPath" -Level SUCCESS
        return $true
    }
    catch {
        Write-BootstrapLog "Failed: $($_.Exception.Message)" -Level ERROR
        throw
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
try {
    if (-not (Test-Path $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        Write-BootstrapLog "Created destination folder: $Destination"
    }

    # Discover all files under PathInRepo
    Write-BootstrapLog "Discovering files in repository..."
    $allFiles = Get-GitHubFilesRecursive -Repo $Repo -Branch $Branch -Path $PathInRepo -Headers $headers

    if (-not $allFiles -or $allFiles.Count -eq 0) {
        throw "No files found under path '$PathInRepo' in $Repo ($Branch)."
    }

    Write-BootstrapLog "Found $($allFiles.Count) file(s) total."

    # Apply filter
    $filesToGet = $allFiles | Where-Object {
        $name = Split-Path $_.Path -Leaf
        $name -like $FileFilter
    }

    if (-not $filesToGet -or $filesToGet.Count -eq 0) {
        throw "No files matched filter '$FileFilter'."
    }

    Write-BootstrapLog "After filter '$FileFilter': $($filesToGet.Count) file(s) will be downloaded."

    $downloaded = 0
    $skipped    = 0

    foreach ($file in $filesToGet) {
        # Calculate relative path from PathInRepo so local structure stays clean
        $relativePath = $file.Path
        if ($PathInRepo -and $relativePath.StartsWith("$PathInRepo/", [System.StringComparison]::OrdinalIgnoreCase)) {
            $relativePath = $relativePath.Substring($PathInRepo.Length + 1)
        }

        $localPath = Join-Path $Destination $relativePath

        $result = Save-GitHubFile -DownloadUrl $file.DownloadUrl -LocalPath $localPath -Headers $headers
        if ($result) { $downloaded++ } else { $skipped++ }
    }

    Write-BootstrapLog "----------------------------------------------"
    Write-BootstrapLog "Download complete. New/updated: $downloaded  | Skipped: $skipped" -Level SUCCESS

    # Optional: run Install-All.ps1
    if ($RunInstallAll) {
        $installAll = Join-Path $Destination "Install-All.ps1"
        if (-not (Test-Path $installAll)) {
            # Also check one level down in case structure differs
            $alt = Get-ChildItem -Path $Destination -Filter "Install-All.ps1" -Recurse -ErrorAction SilentlyContinue |
                   Select-Object -First 1
            if ($alt) { $installAll = $alt.FullName }
        }

        if (-not (Test-Path $installAll)) {
            Write-BootstrapLog "Install-All.ps1 not found after download — skipping auto-run." -Level WARN
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

    Write-BootstrapLog "===== Bootstrap finished =====" -Level SUCCESS
    exit 0
}
catch {
    Write-BootstrapLog "BOOTSTRAP FAILED: $($_.Exception.Message)" -Level ERROR
    exit 1
}
