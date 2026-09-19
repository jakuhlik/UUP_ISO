param(
    [Parameter(Mandatory)][string]$ConverterDir,
    [Parameter(Mandatory)][string]$WorkDir,
    [Parameter(Mandatory)][string]$Edition
)

$ErrorActionPreference = "Stop"

# Load System.Web for URL encoding
Add-Type -AssemblyName System.Web

# --- Helper: Search Microsoft Update Catalog ---

function Search-UpdateCatalog {
    param([string]$Query, [int]$MaxRetries = 3)

    $searchUrl = "https://www.catalog.update.microsoft.com/Search.aspx"
    $headers = @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" }

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        Write-Host "Catalog search attempt $attempt/$MaxRetries..."
        try {
            $response = Invoke-WebRequest -Uri $searchUrl -Method Post `
                -Body "q=$([System.Web.HttpUtility]::UrlEncode($Query))" `
                -ContentType "application/x-www-form-urlencoded" `
                -Headers $headers -UseBasicParsing

            if ($response.StatusCode -ne 200) {
                Write-Warning "Catalog returned status $($response.StatusCode)"
                Start-Sleep -Seconds (30 * $attempt)
                continue
            }

            $html = $response.Content
            Write-Host "Response size: $($html.Length) chars"

            # Extract GUID + title from the same <a> tag containing goToDetails
            $pattern = '<a[^>]*goToDetails\("([a-f0-9\-]+)"\)[^>]*>\s*(.*?)\s*</a>'
            $catalogMatches = [regex]::Matches($html, $pattern, `
                [System.Text.RegularExpressions.RegexOptions]::Singleline)

            Write-Host "Catalog matches: $($catalogMatches.Count)"

            if ($catalogMatches.Count -eq 0) {
                if ($html.Length -lt 5000) {
                    Write-Warning "Response too short, catalog may be blocking or rate-limiting"
                }
                Write-Warning "No results found, retrying in $(30 * $attempt)s..."
                Start-Sleep -Seconds (30 * $attempt)
                continue
            }

            $results = @()
            foreach ($m in $catalogMatches) {
                $results += [PSCustomObject]@{
                    GUID  = $m.Groups[1].Value
                    Title = ($m.Groups[2].Value -replace '<[^>]+>', '').Trim()
                }
            }
            return $results
        } catch {
            Write-Warning "Catalog request failed: $_"
            Start-Sleep -Seconds (30 * $attempt)
        }
    }

    Write-Warning "Catalog search failed after $MaxRetries attempts"
    return @()
}

# --- Helper: Pick the newest matching catalog entry ---
# Catalog result order is not guaranteed, so rank by the "YYYY-MM" title prefix, then by
# the OS build in the title, then by KB number, instead of trusting the first row.

function Select-LatestCatalogUpdate {
    param(
        [array]$Entries,
        [string]$MustMatch,
        [string[]]$Exclude = @()
    )

    $candidates = @($Entries | Where-Object { $_.Title -match $MustMatch })
    foreach ($pattern in $Exclude) {
        $candidates = @($candidates | Where-Object { $_.Title -notmatch $pattern })
    }
    if ($candidates.Count -eq 0) { return $null }

    $ranked = $candidates | ForEach-Object {
        $yearMonth = 0
        if ($_.Title -match '^\s*(\d{4})-(\d{2})') { $yearMonth = [int]$Matches[1] * 100 + [int]$Matches[2] }
        # Newer catalog titles also carry the resulting OS build, e.g. "(KB5129235) (26100.33451)"
        $build = 0
        if ($_.Title -match '\((\d{5})\.(\d+)\)') { $build = [long]$Matches[1] * 1000000 + [long]$Matches[2] }
        $kb = 0
        if ($_.Title -match 'KB(\d+)') { $kb = [long]$Matches[1] }
        [PSCustomObject]@{ Entry = $_; YearMonth = $yearMonth; Build = $build; KB = $kb }
    } | Sort-Object -Property @{ Expression = 'YearMonth'; Descending = $true }, @{ Expression = 'Build'; Descending = $true }, @{ Expression = 'KB'; Descending = $true }

    return ($ranked | Select-Object -First 1).Entry
}

# --- Helper: Get download URLs for a catalog entry ---

function Get-CatalogDownloadUrls {
    param([string]$GUID)

    $downloadUrl = "https://www.catalog.update.microsoft.com/DownloadDialog.aspx"
    $postBody = @{ updateIDs = "[{`"size`":0,`"languages`":`"`",`"uidInfo`":`"$GUID`",`"updateID`":`"$GUID`"}]" }

    $dlResponse = Invoke-WebRequest -Uri $downloadUrl -Method Post -Body $postBody -UseBasicParsing
    $dlHtml = $dlResponse.Content

    $urlMatches = [regex]::Matches($dlHtml, "https?://[^'""]+\.msu")
    $urls = @($urlMatches | ForEach-Object { $_.Value } | Select-Object -Unique)
    if ($urls.Count -eq 0) {
        # Also try .cab files
        $urlMatches = [regex]::Matches($dlHtml, "https?://[^'""]+\.(msu|cab)")
        $urls = @($urlMatches | ForEach-Object { $_.Value } | Select-Object -Unique)
    }
    if ($urls.Count -eq 0) {
        Write-Host "DownloadDialog response (first 2000 chars):"
        Write-Host $dlHtml.Substring(0, [Math]::Min(2000, $dlHtml.Length))
    }
    return $urls
}

# --- Helper: Read build.UBR from a mounted image ---

function Get-MountedImageVersion {
    param([string]$MountDir)

    $softwareHive = Join-Path $MountDir "Windows\System32\config\SOFTWARE"
    & reg load "HKLM\OfflineImage" $softwareHive | Out-Null
    try {
        $ntCurrent = Get-ItemProperty "HKLM:\OfflineImage\Microsoft\Windows NT\CurrentVersion"
        return "$($ntCurrent.CurrentBuildNumber).$($ntCurrent.UBR)"
    } finally {
        & reg unload "HKLM\OfflineImage" | Out-Null
    }
}

# --- Step 0: Validate inputs ---

$iso = Get-ChildItem "$ConverterDir\*.iso" | Select-Object -First 1
if (-not $iso) {
    Write-Error "No ISO file found in $ConverterDir"
    exit 1
}
Write-Host "Found ISO: $($iso.Name)"

$cdimage = Join-Path $ConverterDir "bin\cdimage.exe"
if (-not (Test-Path $cdimage)) {
    Write-Error "cdimage.exe not found at $cdimage"
    exit 1
}

# UUP dump edition IDs -> image names used by Microsoft media.
# SERVERSTANDARD / SERVERDATACENTER are the Desktop Experience (GUI) editions,
# the *CORE IDs are Server Core (no GUI), whose image name has no suffix.
$editionNameMap = @{
    "SERVERSTANDARD"         = "Windows Server 2025 Standard (Desktop Experience)"
    "SERVERSTANDARDCORE"     = "Windows Server 2025 Standard"
    "SERVERDATACENTER"       = "Windows Server 2025 Datacenter (Desktop Experience)"
    "SERVERDATACENTERCORE"   = "Windows Server 2025 Datacenter"
}

if (-not $editionNameMap.ContainsKey($Edition)) {
    Write-Error "Unknown edition: $Edition. Valid: $($editionNameMap.Keys -join ', ')"
    exit 1
}
$editionName = $editionNameMap[$Edition]
Write-Host "Target edition: $editionName"

# --- Step 1: Extract the base ISO ---

$extractDir = Join-Path $WorkDir "iso_contents"
New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
Write-Host "Extracting ISO to $extractDir..."
7z x $iso.FullName -o"$extractDir" -y
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to extract ISO"
    exit 1
}
Write-Host "ISO extracted"

# --- Step 2: Search Microsoft Update Catalog for latest Server 2025 LCU ---

$updateDir = Join-Path $WorkDir "updates"
New-Item -ItemType Directory -Path $updateDir -Force | Out-Null

$searchQuery = "Cumulative Update for Microsoft server operating system, version 24H2 for x64-based Systems"
Write-Host "Searching Microsoft Update Catalog for: $searchQuery"

$updates = Search-UpdateCatalog -Query $searchQuery
Write-Host "Found $($updates.Count) catalog entries"

if ($updates.Count -gt 0) {
    Write-Host "First 5 entries:"
    $updates | Select-Object -First 5 | ForEach-Object { Write-Host "  [$($_.GUID)] $($_.Title)" }
}

if ($updates.Count -eq 0) {
    Write-Error "No updates found in Microsoft Update Catalog"
    exit 1
}

# Newest non-Preview, non-Out-of-Band OS cumulative update (exclude .NET and Dynamic Update rows)
$selectedUpdate = Select-LatestCatalogUpdate -Entries $updates -MustMatch "Cumulative Update" `
    -Exclude @("Preview", "Out-of-Band", "\.NET", "Dynamic")

if (-not $selectedUpdate) {
    Write-Warning "No non-Preview cumulative update found after filtering, relaxing filters"
    $selectedUpdate = Select-LatestCatalogUpdate -Entries $updates -MustMatch "Cumulative Update" -Exclude @("\.NET", "Dynamic")
}

if (-not $selectedUpdate) {
    Write-Error "Failed to select a cumulative update from catalog results"
    exit 1
}

Write-Host "Selected update: $($selectedUpdate.Title)"
Write-Host "  GUID: $($selectedUpdate.GUID)"

# --- Get download URLs from DownloadDialog ---

$downloadUrls = Get-CatalogDownloadUrls -GUID $selectedUpdate.GUID

if ($downloadUrls.Count -eq 0) {
    Write-Error "No download URLs found for update $($selectedUpdate.GUID)"
    exit 1
}

Write-Host "Found $($downloadUrls.Count) download URL(s):"
foreach ($url in $downloadUrls) {
    Write-Host "  $url"
}

# Download all update files
Write-Host "Downloading updates to $updateDir..."
foreach ($url in $downloadUrls) {
    $fileName = [System.IO.Path]::GetFileName(($url -split '\?')[0])
    Write-Host "Downloading $fileName..."
    aria2c --max-connection-per-server=16 --split=16 -d $updateDir -o $fileName $url
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to download $url"
        exit 1
    }
}

$updateFiles = Get-ChildItem $updateDir -File
Write-Host "Downloaded $($updateFiles.Count) update file(s):"
$updateFiles | ForEach-Object { Write-Host "  $($_.Name) ($([math]::Round($_.Length / 1MB, 1)) MB)" }

# --- Step 3: Mount install.wim and apply updates ---

$wimPath = Join-Path $extractDir "sources\install.wim"
if (-not (Test-Path $wimPath)) {
    Write-Error "install.wim not found at $wimPath"
    exit 1
}

# Remove read-only attribute (ISO extraction sets it)
Set-ItemProperty -Path $wimPath -Name IsReadOnly -Value $false

$mountDir = Join-Path $WorkDir "mount"
New-Item -ItemType Directory -Path $mountDir -Force | Out-Null

# Get WIM image info and find the target index
$wimInfo = @(Get-WindowsImage -ImagePath $wimPath)
Write-Host "WIM images:"
foreach ($img in $wimInfo) {
    Write-Host "  Index $($img.ImageIndex): $($img.ImageName)"
}

$targetImage = $wimInfo | Where-Object { $_.ImageName -eq $editionName } | Select-Object -First 1
if (-not $targetImage -and $wimInfo.Count -eq 1) {
    # The converter only builds the requested edition, so a single-image WIM is the target
    Write-Warning "Image name '$($wimInfo[0].ImageName)' does not match '$editionName'; using the only image in the WIM"
    $targetImage = $wimInfo[0]
}
if (-not $targetImage) {
    Write-Error "Could not find WIM index matching edition '$editionName'"
    Write-Host "Available images: $($wimInfo | ForEach-Object { $_.ImageName } | Out-String)"
    exit 1
}

$targetIndex = $targetImage.ImageIndex
Write-Host "Patching WIM index $targetIndex ($($targetImage.ImageName))..."

# Mount the image
Write-Host "Mounting WIM..."
Mount-WindowsImage -ImagePath $wimPath -Index $targetIndex -Path $mountDir

$baseVersion = Get-MountedImageVersion -MountDir $mountDir
Write-Host "Base image version: $baseVersion"

# Apply updates (point to folder so DISM discovers checkpoints automatically)
Write-Host "Applying updates via DISM (this may take a while)..."
try {
    Add-WindowsPackage -Path $mountDir -PackagePath $updateDir -ErrorAction Stop
    Write-Host "Updates applied successfully"
} catch {
    Write-Warning "Add-WindowsPackage encountered an error: $_"
    Write-Warning "Attempting to continue - some updates may have been applied"
}

# Extract actual version from patched image registry
Write-Host "Reading patched image version..."
$patchedVersion = Get-MountedImageVersion -MountDir $mountDir
Write-Host "Patched image version: $patchedVersion"

if ($patchedVersion -eq $baseVersion) {
    # UUP dump refreshes Windows Server 2025 builds monthly, so the base image is often
    # already at (or past) the newest catalog LCU. Nothing changed: keep the original ISO.
    Write-Host "Base image already contains the latest cumulative update ($baseVersion); keeping original ISO"
    Dismount-WindowsImage -Path $mountDir -Discard

    if ($env:GITHUB_OUTPUT) {
        "patched_version=$patchedVersion" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
        "patched_iso_name=$($iso.Name)" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
        "update_title=$($selectedUpdate.Title)" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
    }

    Write-Host "Cleaning up work directory..."
    Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Host "Cumulative update integration skipped (already current)."
    Write-Host "  ISO: $($iso.Name)"
    Write-Host "  Version: $patchedVersion"
    exit 0
}

# Dismount and remount to clear pending state before cleanup
Write-Host "Dismounting WIM (saving changes)..."
Dismount-WindowsImage -Path $mountDir -Save
Write-Host "Remounting WIM for cleanup..."
Mount-WindowsImage -ImagePath $wimPath -Index $targetIndex -Path $mountDir

# Cleanup to reduce image size
Write-Host "Running DISM cleanup with ResetBase..."
& dism /Image:$mountDir /Cleanup-Image /StartComponentCleanup /ResetBase
if ($LASTEXITCODE -ne 0) {
    Write-Warning "DISM cleanup returned exit code $LASTEXITCODE (non-zero may be acceptable)"
}

# Unmount and save
Write-Host "Dismounting WIM (saving changes)..."
Dismount-WindowsImage -Path $mountDir -Save
Write-Host "WIM updated successfully"

# --- Step 4: Rebuild ISO with cdimage.exe ---

Write-Host "Rebuilding ISO with cdimage.exe..."

$bootEtfs = Join-Path $extractDir "boot\etfsboot.com"
$bootEfi = Join-Path $extractDir "efi\Microsoft\boot\efisys.bin"

if (-not (Test-Path $bootEtfs)) {
    Write-Error "BIOS boot file not found: $bootEtfs"
    exit 1
}
if (-not (Test-Path $bootEfi)) {
    Write-Error "EFI boot file not found: $bootEfi"
    exit 1
}

# Remove read-only attributes from extracted files (cdimage needs write access for some operations)
Get-ChildItem $extractDir -Recurse -File | ForEach-Object {
    if ($_.IsReadOnly) { $_.IsReadOnly = $false }
}

$outputIso = Join-Path $ConverterDir "ServerUpdated.iso"

# Build BIOS + UEFI hybrid bootable ISO
$bootdataArg = "-bootdata:2#p0,e,b${bootEtfs}#pEF,e,b${bootEfi}"
& $cdimage $bootdataArg -o -m -u2 -udfver102 -lSERVER2025 $extractDir $outputIso

if ($LASTEXITCODE -ne 0) {
    Write-Error "cdimage failed with exit code $LASTEXITCODE"
    exit 1
}

if (-not (Test-Path $outputIso)) {
    Write-Error "cdimage did not produce output ISO"
    exit 1
}

# Replace original ISO with updated one, renamed to reflect patched version
$updatedSize = [math]::Round((Get-Item $outputIso).Length / 1GB, 2)
Write-Host "Updated ISO size: ${updatedSize} GB"

Remove-Item $iso.FullName -Force
$newIsoName = "WindowsServer2025_${patchedVersion}_amd64_${Edition}.iso"
$newIsoPath = Join-Path $ConverterDir $newIsoName
Move-Item $outputIso $newIsoPath
Write-Host "Created patched ISO: $newIsoName"

# Set GitHub Actions output
if ($env:GITHUB_OUTPUT) {
    "patched_version=$patchedVersion" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
    "patched_iso_name=$newIsoName" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
    "update_title=$($selectedUpdate.Title)" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
}

# Cleanup work directory
Write-Host "Cleaning up work directory..."
Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Cumulative update integration complete!"
Write-Host "  ISO: $newIsoName"
Write-Host "  Version: $patchedVersion"
Write-Host "  Update: $($selectedUpdate.Title)"
