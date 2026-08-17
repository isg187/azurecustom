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

$Destination = "C:\ProgramData\SDL\scripts"
$temp = "C:\Temp\SoftwareInstall"
New-Item -ItemType Directory -Path $temp -Force | Out-Null
New-Item -ItemType Directory -Path $Destination -Force | Out-Null

# Download entire repo as zip
$zipUrl = "https://github.com/isg187/azurecustom/archive/refs/heads/main.zip"
$zipPath = "$temp\azurecustom.zip"
Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing

# Extract
Expand-Archive -Path $zipPath -DestinationPath $Destination -Force
$scriptRoot = Get-ChildItem -Path $Destination -Directory | Where-Object { $_.Name -eq "azurecustom-main" } | Select-Object -First 1 -ExpandProperty FullName

# Run the main script with desired parameters
& "$scriptRoot\install-all.ps1"

# Cleanup
Remove-Item -Path $temp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Windows Optimization completed."