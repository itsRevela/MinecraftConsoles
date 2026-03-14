#Requires -Version 5.1
<#
.SYNOPSIS
    Builds a zip, updates the Nightly GitHub release, and archives locally.
.DESCRIPTION
    1. Fetches the latest commit hash.
    2. Zips x64\Release contents directly into the archive folder (excluding .pch files).
    3. Deletes old assets from the Nightly release on GitHub.
    4. Uploads LCEWindows64.zip, Minecraft.Client.exe, and Minecraft.Client.pdb.
    5. Updates the release title with the latest commit hash (first 7 chars).
.NOTES
    Requires GITHUB_TOKEN environment variable to be set.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- Configuration ---
$RepoOwner       = "itsRevela"
$RepoName        = "MinecraftConsoles"
$ReleaseTag      = "Nightly"
$ReleaseDir      = Join-Path $PSScriptRoot "x64\Release"
$ZipName         = "LCEWindows64.zip"
$ArchiveRoot     = "C:\Users\rexma\Documents\Minecraft\itsRevelaReleases"
$ApiBase         = "https://api.github.com/repos/$RepoOwner/$RepoName"

$Token = $env:GITHUB_TOKEN
if (-not $Token) {
    Write-Error "GITHUB_TOKEN environment variable is not set. Generate a token at https://github.com/settings/tokens with 'repo' scope."
    exit 1
}

$Headers = @{
    Authorization = "token $Token"
    Accept        = "application/vnd.github+json"
}

# --- Step 1: Get latest commit hash (needed for archive folder and title) ---
Write-Host "==> Fetching latest commit hash..." -ForegroundColor Cyan

$latestCommit = Invoke-RestMethod -Uri "$ApiBase/commits?per_page=1" -Headers $Headers -Method Get
$fullHash = $latestCommit[0].sha
$shortHash = $fullHash.Substring(0, 7)
Write-Host "    Latest commit: $shortHash"

# --- Step 2: Create archive folder and zip directly into it ---
Write-Host "==> Creating $ZipName in archive folder..." -ForegroundColor Cyan

$dateStr = (Get-Date).ToString("MM-dd-yyyy")
$archiveFolder = Join-Path $ArchiveRoot "${dateStr}_${shortHash}"

if (-not (Test-Path $archiveFolder)) {
    New-Item -ItemType Directory -Path $archiveFolder -Force | Out-Null
}

$ZipPath = Join-Path $archiveFolder $ZipName

if (Test-Path $ZipPath) {
    Remove-Item $ZipPath -Force
}

# Gather all files/folders, excluding .pch files and any existing zip
$itemsToZip = Get-ChildItem -Path $ReleaseDir -Exclude "*.pch", "*.zip"

Compress-Archive -Path $itemsToZip.FullName -DestinationPath $ZipPath -CompressionLevel Optimal
Write-Host "    Created: $ZipPath" -ForegroundColor Green

# --- Step 3: Get the Nightly release info ---
Write-Host "==> Fetching Nightly release info..." -ForegroundColor Cyan

$release = Invoke-RestMethod -Uri "$ApiBase/releases/tags/$ReleaseTag" -Headers $Headers -Method Get
$releaseId = $release.id
$currentTitle = $release.name
Write-Host "    Release ID: $releaseId"
Write-Host "    Current title: $currentTitle"

# --- Step 4: Delete existing assets ---
Write-Host "==> Deleting old assets..." -ForegroundColor Cyan

foreach ($asset in $release.assets) {
    Write-Host "    Deleting: $($asset.name) (ID: $($asset.id))"
    Invoke-RestMethod -Uri "$ApiBase/releases/assets/$($asset.id)" -Headers $Headers -Method Delete
}

# --- Step 5: Upload new assets ---
Write-Host "==> Uploading new assets..." -ForegroundColor Cyan

$uploadBase = "https://uploads.github.com/repos/$RepoOwner/$RepoName/releases/$releaseId/assets"

$filesToUpload = @(
    @{ Path = $ZipPath;                                         Name = $ZipName;                ContentType = "application/zip" }
    @{ Path = Join-Path $ReleaseDir "Minecraft.Client.exe";     Name = "Minecraft.Client.exe";  ContentType = "application/octet-stream" }
    @{ Path = Join-Path $ReleaseDir "Minecraft.Client.pdb";     Name = "Minecraft.Client.pdb";  ContentType = "application/octet-stream" }
)

foreach ($file in $filesToUpload) {
    $filePath = $file.Path
    if (-not (Test-Path $filePath)) {
        Write-Error "File not found: $filePath"
        exit 1
    }

    $uploadUrl = "$uploadBase`?name=$($file.Name)"
    $fileBytes = [System.IO.File]::ReadAllBytes($filePath)
    $sizeMB = [math]::Round($fileBytes.Length / 1MB, 2)
    Write-Host "    Uploading: $($file.Name) ($sizeMB MB)..."

    Invoke-RestMethod -Uri $uploadUrl -Headers @{
        Authorization = "token $Token"
        Accept        = "application/vnd.github+json"
        "Content-Type" = $file.ContentType
    } -Method Post -Body $fileBytes | Out-Null

    Write-Host "    Uploaded: $($file.Name)" -ForegroundColor Green
}

# --- Step 6: Update release title with latest commit hash ---
Write-Host "==> Updating release title..." -ForegroundColor Cyan

# Replace the old 7-char hash in the title with the new one
# Title format: "Latest:  8bd6690 (+Hardcore Mode)"
$newTitle = $currentTitle -replace '(?<=Latest:\s{1,4})[0-9a-f]{7}', $shortHash

if ($newTitle -eq $currentTitle -and $currentTitle -notmatch $shortHash) {
    # Fallback if regex didn't match — just set a reasonable title
    $newTitle = "Latest:  $shortHash"
    Write-Host "    Warning: Could not parse existing title format, using fallback." -ForegroundColor Yellow
}

Write-Host "    New title: $newTitle"

$body = @{ name = $newTitle } | ConvertTo-Json
Invoke-RestMethod -Uri "$ApiBase/releases/$releaseId" -Headers $Headers -Method Patch -Body $body -ContentType "application/json" | Out-Null
Write-Host "    Title updated." -ForegroundColor Green

# --- Done ---
Write-Host ""
Write-Host "==> Nightly release updated successfully!" -ForegroundColor Green
Write-Host "    Commit: $shortHash"
Write-Host "    Title:  $newTitle"
Write-Host "    Assets: $ZipName, Minecraft.Client.exe, Minecraft.Client.pdb"
Write-Host "    Archive: $archiveFolder\$ZipName"
