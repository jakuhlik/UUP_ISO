param(
    [Parameter(Mandatory)][string]$Product,
    [Parameter(Mandatory)][string]$Channel,
    [Parameter(Mandatory)][string]$Milestone,
    [Parameter(Mandatory)][string]$Architecture,
    [Parameter(Mandatory)][string]$Language,
    [Parameter(Mandatory)][string]$Edition,
    [string]$Aria2File = "D:\aria2_download_list.txt",
    [switch]$QueryOnly
)

$ErrorActionPreference = "Stop"

$baseUrl = "https://api.uupdump.net"

# Seconds to wait between consecutive UUP dump API calls (the API is rate limited per IP)
$apiPauseSec = 10

# --- Helpers -------------------------------------------------------------------

# Calls the UUP dump JSON API. Known API errors (NO_UPDATE_FOUND, ...) come back as
# HTTP 4xx/5xx with a JSON body; they are returned to the caller as a normal response
# object with response.error set. Rate limits and upstream Windows Update failures are
# retried with a growing delay. Only transport errors without a JSON body throw.
function Invoke-ApiWithRetry {
    param(
        [string]$Uri,
        [int]$MaxRetries = 5,
        [int]$BaseDelaySec = 15
    )
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        $resp = $null
        try {
            $resp = Invoke-RestMethod -Uri $Uri -Method Get
        } catch {
            $body = "$($_.ErrorDetails.Message)"
            if ($body) {
                try { $resp = $body | ConvertFrom-Json } catch { $resp = $null }
            }
            if (-not $resp) {
                if ($attempt -lt $MaxRetries) {
                    $delay = $BaseDelaySec * $attempt
                    Write-Warning "Request failed ($($_.Exception.Message)), retrying in ${delay}s (attempt $attempt/$MaxRetries)..."
                    Start-Sleep -Seconds $delay
                    continue
                }
                throw
            }
        }

        $apiError = "$($resp.response.error)"
        if ($apiError -match "RATE_LIMITED") {
            $delay = $BaseDelaySec * $attempt
            Write-Warning "Rate limited (attempt $attempt/$MaxRetries), waiting ${delay}s..."
            Start-Sleep -Seconds $delay
            continue
        }
        if ($apiError -eq "WU_REQUEST_FAILED" -and $attempt -lt 3) {
            # Upstream Windows Update hiccup: retry twice, then let the caller try its next candidate
            $delay = $BaseDelaySec * $attempt
            Write-Warning "Windows Update request failed upstream (attempt $attempt/3), waiting ${delay}s..."
            Start-Sleep -Seconds $delay
            continue
        }
        return $resp
    }
    throw "API still failing after $MaxRetries attempts on $Uri"
}

# listid.php returns "builds" either as a JSON array or as an object keyed by index
# (PHP re-indexing after filtering). Normalize to a plain list.
function ConvertTo-BuildList {
    param($Builds)
    if ($null -eq $Builds) { return @() }
    if ($Builds -is [System.Array]) { return @($Builds) }
    return @($Builds.PSObject.Properties | ForEach-Object { $_.Value })
}

# Searches the UUP dump database (builds already fetched by UUP dump itself).
# Results are newest first. Returns the first entry matching arch/title/build.
function Find-ListIdBuild {
    param(
        [string]$Search,
        [string]$TitlePattern,
        [string]$BuildPattern,
        [string]$Arch
    )
    $url = "$baseUrl/listid.php?search=$([uri]::EscapeDataString($Search))&sortByDate=1"
    Write-Host "Searching UUP dump database: $url"
    $resp = Invoke-ApiWithRetry -Uri $url
    if ($resp.response.error) {
        Write-Warning "listid returned $($resp.response.error)"
        return $null
    }
    foreach ($b in (ConvertTo-BuildList $resp.response.builds)) {
        if ($b.arch -ne $Arch) { continue }
        if ("$($b.title)" -notmatch $TitlePattern) { continue }
        if ("$($b.build)" -notmatch $BuildPattern) { continue }
        return $b
    }
    return $null
}

# Picks the OS build out of a fetchupd updateArray (skips .NET, OOBE, servicing stack, ...).
# Titles starting with "Windows 11" (feature updates / Insider flights) are preferred over
# other OS packages such as "Preview Update for Windows 11 (...)".
function Select-OsUpdate {
    param(
        $Updates,
        [string]$BuildPattern,
        [string]$Arch
    )
    $skipTitles = 'Framework|Stack Package|Servicing Stack|OOBE|Feature Experience Pack|Autopilot|Microsoft Edge|Malicious Software|Hotpatch|Defender|Safe OS|Dynamic Update'
    foreach ($preferFeatureUpdate in @($true, $false)) {
        foreach ($u in $Updates) {
            $title = "$($u.updateTitle)"
            $foundBuild = "$($u.foundBuild)"
            if ($Arch -and $u.arch -and $u.arch -ne $Arch) { continue }
            if ($foundBuild -notmatch '^\d{5}\.\d+$') { continue }
            if ($foundBuild -notmatch $BuildPattern) { continue }
            if ($title -match $skipTitles) { continue }
            if ($preferFeatureUpdate -and $title -notlike "Windows 11*") { continue }
            return $u
        }
    }
    return $null
}

# One fetchupd.php call. Returns the matching OS update or $null.
function Invoke-FetchUpd {
    param(
        [string]$Arch,
        [string]$Ring,
        [string]$Build,
        [string]$BuildPattern,
        [string]$WantArch
    )
    $url = "$baseUrl/fetchupd.php?arch=$Arch&ring=$Ring"
    if ($Build) { $url += "&build=$Build" }
    Write-Host "Querying fetchupd API: $url"

    $resp = Invoke-ApiWithRetry -Uri $url
    if ($resp.response.error) {
        Write-Host "  API returned: $($resp.response.error)"
        return $null
    }
    $updates = @($resp.response.updateArray)
    if ($updates.Count -eq 0) {
        Write-Host "  No updateArray in response"
        return $null
    }
    Write-Host "  $($updates.Count) update(s): $(($updates | ForEach-Object { "$($_.updateTitle) [$($_.arch)]" }) -join '; ')"
    return Select-OsUpdate -Updates $updates -BuildPattern $BuildPattern -Arch $WantArch
}

# Tries each candidate base build for the requested architecture, then repeats the
# candidates with arch=all (Windows Update refuses some arm64-only offers, e.g. 26H1 and
# the Insider flights, unless the request is made for all architectures and filtered
# afterwards).
function Find-FetchUpdBuild {
    param(
        [string]$Ring,
        [string[]]$BuildCandidates,
        [string]$BuildPattern,
        [string]$Arch
    )
    foreach ($archMode in @($Arch, "all")) {
        foreach ($build in $BuildCandidates) {
            $found = Invoke-FetchUpd -Arch $archMode -Ring $Ring -Build $build -BuildPattern $BuildPattern -WantArch $Arch
            if ($found) {
                Write-Host "Matched via ring=$Ring build=$build arch=$archMode"
                return $found
            }
            Write-Host "  No matching build (pattern $BuildPattern), waiting ${apiPauseSec}s before next query..."
            Start-Sleep -Seconds $apiPauseSec
        }
    }
    return $null
}

# --- Input validation ---------------------------------------------------------

if ($Product -notin @("Windows 11", "Windows 10", "Windows Server")) {
    Write-Error "Invalid product: '$Product'. Must be 'Windows 11', 'Windows 10', or 'Windows Server'"
    exit 1
}

# Validate product/edition combinations
$serverEditions = @("SERVERSTANDARD", "SERVERSTANDARDCORE", "SERVERDATACENTER", "SERVERDATACENTERCORE")
$clientEditions = @("PROFESSIONAL", "CORE")

if ($Product -eq "Windows Server" -and $Edition -notin $serverEditions) {
    Write-Error "Invalid edition '$Edition' for Windows Server. Must be one of: $($serverEditions -join ', ')"
    exit 1
}
if ($Product -in @("Windows 11", "Windows 10") -and $Edition -notin $clientEditions) {
    Write-Error "Invalid edition '$Edition' for $Product. Must be one of: $($clientEditions -join ', ')"
    exit 1
}

# Validate architecture
if ($Architecture -notin @("amd64", "arm64", "x86")) {
    Write-Error "Invalid architecture: '$Architecture'. Must be amd64, arm64 or x86"
    exit 1
}
if ($Product -eq "Windows Server" -and $Architecture -ne "amd64") {
    Write-Error "Windows Server 2025 is only available for amd64."
    exit 1
}
if ($Product -eq "Windows 11" -and $Architecture -eq "x86") {
    Write-Error "Windows 11 is not available for x86."
    exit 1
}

# Validate language code format (UUP dump uses lowercase xx-xx codes, plus sr-latn-rs)
$Language = $Language.Trim().ToLowerInvariant()
if ($Language -notmatch '^[a-z]{2,3}(-[a-z]{2,4}){1,2}$') {
    Write-Error "Invalid language code format: '$Language'. Expected format: xx-xx (e.g., en-us, zh-cn, sr-latn-rs)"
    exit 1
}

Write-Host "Product: $Product"
Write-Host "Channel: $Channel"
Write-Host "Milestone: $Milestone"
Write-Host "Architecture: $Architecture"
Write-Host "Language: $Language"
Write-Host "Edition: $Edition"
Write-Host ""

# --- Step 1: Get UUID based on product and channel ------------------------------

$uuid = $null
$updateTitle = $null
$channelLabel = $Channel

if ($Product -eq "Windows 10") {
    # Windows 10: always use Feature Update for 22H2
    Write-Host "Querying listid API for Windows 10 22H2 Feature Update..."
    $matched = Find-ListIdBuild -Search "Feature update to Windows 10, version 22H2" `
        -TitlePattern '^Feature update to Windows 10, version 22H2 \(' -BuildPattern '^19045\.' -Arch $Architecture

    if (-not $matched) {
        Write-Error "No matching Feature Update found for Windows 10 22H2 ($Architecture)"
        exit 1
    }

    $uuid = $matched.uuid
    $updateTitle = $matched.title
    Write-Host "Found: $updateTitle (UUID: $uuid)"
}
elseif ($Product -eq "Windows Server") {
    # Windows Server: always use Server 2025 (24H2, build 26100)
    Write-Host "Querying listid API for Windows Server 2025..."
    $matched = Find-ListIdBuild -Search "Windows Server 2025" `
        -TitlePattern '^Windows Server 2025 \(' -BuildPattern '^26100\.' -Arch $Architecture

    if (-not $matched) {
        Write-Error "No matching build found for Windows Server 2025 ($Architecture)"
        exit 1
    }

    $uuid = $matched.uuid
    $updateTitle = $matched.title
    Write-Host "Found: $updateTitle (UUID: $uuid)"
}
else {
    # Windows 11 ------------------------------------------------------------------
    #
    # UUP dump fetchupd.php ring values (see git.uupdump.net/uup-dump/api):
    #   RETAIL  - public release channel
    #   RP      - Release Preview channel
    #   BETA    - Beta channel (alias of the old WIS ring)
    #   DEV     - Experimental channel (alias of the old WIF ring). Since April 2026 the
    #             Dev and Canary channels are merged into "Experimental". The ring may carry
    #             a target release suffix (FlightUpgradeTarget device attribute):
    #               DEV:0  -> Experimental for the current Windows core (26H2 / 26H1 builds)
    #               DEV:-1 -> Experimental (Future Platforms), the 29xxx series
    #
    # The "build" parameter is the OS version the fake client reports. Windows Update
    # answers with what such a device would be offered, so:
    #   - a build from the PREVIOUS platform triggers the cross-version upgrade path and
    #     returns the official retail build of the requested version (once it is GA);
    #   - a build from the SAME platform triggers the cumulative-update path and returns
    #     the newest servicing build of that version (works before GA as well);
    #   - "NNNNN.latest" lets UUP dump substitute the newest patch level it knows.
    $milestoneConfig = @{
        "27H2" = @{
            # Windows 11 27H2 has no retail build yet; the 29xxx "Future Platforms" series is
            # only flighted in the Experimental channel.
            Label         = "Future Platforms"
            RetailBuilds  = @()
            RetailPattern = '^(29|3\d)\d{3}\.'
            ExpRing       = "DEV:-1"
            ExpBuilds     = @("26300.1", "latest")
            ExpPattern    = '^(29|3\d)\d{3}\.'
        }
        "26H2" = @{
            Label         = "26H2"
            RetailBuilds  = @("26200.1", "26300.latest", "26300.1")
            RetailPattern = '^26300\.'
            ExpRing       = "DEV:0"
            ExpBuilds     = @("26300.1", "26300.latest", "26200.1")
            ExpPattern    = '^26[3-9]\d{2}\.'
        }
        "26H1" = @{
            # 26H1 (build 28000, "Bromine") ships only pre-installed on new arm64 devices
            # (Snapdragon X2 / NVIDIA N1X); it is not offered as an upgrade to any device.
            Label         = "26H1"
            RetailBuilds  = @("28000.1", "28000.latest")
            RetailPattern = '^28000\.'
            RetailArch    = "arm64"
            ExpRing       = "DEV:0"
            ExpBuilds     = @("28120.1", "28100.1", "28000.latest", "28000.1")
            ExpPattern    = '^28\d{3}\.'
        }
        "25H2" = @{
            Label         = "25H2"
            RetailBuilds  = @("26100.1", "26200.latest", "26200.1")
            RetailPattern = '^26200\.'
            ExpRing       = "DEV:0"
            ExpBuilds     = @("26300.1", "26300.latest", "26200.1")
            ExpPattern    = '^26[3-9]\d{2}\.'
        }
        "24H2" = @{
            Label         = "24H2"
            RetailBuilds  = @("22631.1", "26100.latest", "26100.1")
            RetailPattern = '^26100\.'
            ExpRing       = "DEV:0"
            ExpBuilds     = @("26300.1", "26300.latest", "26200.1")
            ExpPattern    = '^26[3-9]\d{2}\.'
        }
    }

    $config = $milestoneConfig[$Milestone]
    if (-not $config) {
        Write-Error "Unknown milestone: $Milestone. Supported: $($milestoneConfig.Keys -join ', ')"
        exit 1
    }

    $matched = $null

    switch ($Channel) {
        { $_ -in @("Retail", "ReleasePreview") } {
            $ring = if ($Channel -eq "Retail") { "RETAIL" } else { "RP" }

            if ($config.RetailBuilds.Count -eq 0) {
                Write-Error "Windows 11 $Milestone ($($config.Label)) is not available in the $Channel channel. Use the Experimental channel."
                exit 1
            }
            if ($config.RetailArch -and $Architecture -ne $config.RetailArch) {
                Write-Error "Windows 11 $Milestone is only available for $($config.RetailArch) in the $Channel channel (it ships only on new Arm devices). Select architecture '$($config.RetailArch)'."
                exit 1
            }

            $matched = Find-FetchUpdBuild -Ring $ring -BuildCandidates $config.RetailBuilds `
                -BuildPattern $config.RetailPattern -Arch $Architecture

            if (-not $matched) {
                # Fall back to the builds UUP dump has already collected for this version
                Write-Warning "fetchupd returned nothing usable, falling back to the UUP dump build database..."
                $matched = Find-ListIdBuild -Search "Windows 11, version $Milestone" `
                    -TitlePattern "^Windows 11, version $Milestone \(" -BuildPattern $config.RetailPattern -Arch $Architecture
                if ($matched) {
                    $matched = [PSCustomObject]@{ updateId = $matched.uuid; updateTitle = $matched.title; foundBuild = $matched.build }
                }
            }
            $channelLabel = if ($Channel -eq "Retail") { "Retail" } else { "Release Preview" }
        }
        "Beta" {
            # The Beta channel follows its own build series (26220 today); the milestone
            # input does not apply. Try the current series first, then the next likely one.
            Write-Host "Beta channel: milestone '$Milestone' is not used (Beta has a single build series)"
            $matched = Find-FetchUpdBuild -Ring "BETA" -BuildCandidates @("26220.1", "26220.latest", "26320.1", "26200.1") `
                -BuildPattern '^26[2-9]\d{2}\.' -Arch $Architecture

            if (-not $matched) {
                Write-Warning "fetchupd returned nothing usable, falling back to the UUP dump build database..."
                $matched = Find-ListIdBuild -Search "Windows 11 Insider Preview" `
                    -TitlePattern '^Windows 11 Insider Preview' -BuildPattern '^26[2-3]\d{2}\.' -Arch $Architecture
                if ($matched) {
                    $matched = [PSCustomObject]@{ updateId = $matched.uuid; updateTitle = $matched.title; foundBuild = $matched.build }
                }
            }
            $channelLabel = "Beta"
        }
        "Experimental" {
            $matched = Find-FetchUpdBuild -Ring $config.ExpRing -BuildCandidates $config.ExpBuilds `
                -BuildPattern $config.ExpPattern -Arch $Architecture

            if (-not $matched) {
                Write-Warning "fetchupd returned nothing usable, falling back to the UUP dump build database..."
                $matched = Find-ListIdBuild -Search "Windows 11 Insider Preview" `
                    -TitlePattern '^Windows 11 Insider Preview' -BuildPattern $config.ExpPattern -Arch $Architecture
                if ($matched) {
                    $matched = [PSCustomObject]@{ updateId = $matched.uuid; updateTitle = $matched.title; foundBuild = $matched.build }
                }
            }
            $channelLabel = "Experimental ($($config.Label))"
        }
        default {
            Write-Error "Unknown channel: $Channel. Supported: Retail, ReleasePreview, Beta, Experimental (Dev and Canary were merged into Experimental in April 2026)"
            exit 1
        }
    }

    if (-not $matched) {
        Write-Error "No matching build found for Windows 11 $Milestone ($Architecture) in the $Channel channel"
        exit 1
    }

    $uuid = $matched.updateId
    $updateTitle = $matched.updateTitle
    Write-Host "Found: $updateTitle (UUID: $uuid) [$channelLabel]"
}

# --- Step 2: Get file list ------------------------------------------------------

if (-not $QueryOnly) {

Write-Host ""
Write-Host "Waiting ${apiPauseSec}s before fetching the file list..."
Start-Sleep -Seconds $apiPauseSec
Write-Host "Fetching file list for UUID: $uuid..."
$getUrl = "$baseUrl/get.php?id=$uuid&lang=$Language&edition=$Edition"
$fileResponse = Invoke-ApiWithRetry -Uri $getUrl

if ($fileResponse.response.error) {
    Write-Error "API error getting files: $($fileResponse.response.error)"
    exit 1
}

$files = $fileResponse.response.files
if (-not $files) {
    Write-Error "No files returned for this build/language/edition combination"
    exit 1
}

# --- Step 2b: Get Store App packages if available --------------------------------

if ($fileResponse.response.appxPresent -eq $true) {
    Write-Host "Store App packages detected, fetching app file list..."
    $appUrl = "$baseUrl/get.php?id=$uuid&lang=neutral&edition=APP"
    $maxRetries = 3
    $appFiles = $null

    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        Write-Host "Waiting ${apiPauseSec}s before API call (attempt $attempt/$maxRetries)..."
        Start-Sleep -Seconds $apiPauseSec

        try {
            $appResponse = Invoke-ApiWithRetry -Uri $appUrl
            if ($appResponse.response.error) {
                Write-Warning "API returned error: $($appResponse.response.error)"
            } else {
                $appFiles = $appResponse.response.files
                break
            }
        } catch {
            Write-Warning "Request failed: $_"
        }
    }

    if (-not $appFiles) {
        Write-Error "Failed to fetch Store App packages after $maxRetries attempts"
        exit 1
    }

    $appCount = 0
    foreach ($prop in $appFiles.PSObject.Properties) {
        $appCount++
        $files | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
    }
    Write-Host "Added $appCount app package files"
}

# --- Step 3: Generate aria2 input file -------------------------------------------

$fileCount = 0
$totalSize = 0
$aria2Content = New-Object System.Text.StringBuilder

foreach ($prop in $files.PSObject.Properties) {
    $fileName = $prop.Name
    $fileInfo = $prop.Value

    $url = $fileInfo.url
    $sha1 = $fileInfo.sha1
    $size = $fileInfo.size

    if (-not $url) { continue }

    [void]$aria2Content.AppendLine($url)
    [void]$aria2Content.AppendLine("  out=$fileName")
    if ($sha1) {
        [void]$aria2Content.AppendLine("  checksum=sha-1=$sha1")
    }
    [void]$aria2Content.AppendLine("")

    $fileCount++
    $totalSize += [long]$size
}

if ($fileCount -eq 0) {
    Write-Error "No downloadable files in the file list (all entries lack URLs)"
    exit 1
}

$aria2Content.ToString() | Out-File -FilePath $Aria2File -Encoding utf8 -NoNewline
$totalSizeGB = [math]::Round($totalSize / 1GB, 2)
Write-Host "Generated aria2 input file: $fileCount files, ~${totalSizeGB} GB total"

} else {
    Write-Host "QueryOnly: skipping file list and aria2 input generation"
}

# --- Step 4: Extract build number from title ---------------------------------------

$buildNumber = "unknown"
if ($updateTitle -match '(\d{5}\.\d+)') {
    $buildNumber = $Matches[1]
} elseif ($updateTitle -match '(\d{5})') {
    $buildNumber = $Matches[1]
}

# .NET Framework 3.5 is no longer part of Windows 11 builds 27965 and later
# (the converter skips it automatically for those builds).
$buildMajor = 0
if ($buildNumber -match '^(\d{5})') { $buildMajor = [int]$Matches[1] }
$netfx3 = if ($buildMajor -ge 27965) { "false" } else { "true" }

# Release tag suffix so Insider builds never collide with a Retail build of the same number
$tagSuffix = ""
if ($Product -eq "Windows 11" -and $Channel -ne "Retail") {
    $tagSuffix = "-$Channel"
}

$buildDate = Get-Date -Format "yyyyMMdd"

# Create a clean release title by stripping common prefixes; tag Insider builds with their channel
$releaseTitle = $updateTitle -replace '^Feature update to ', ''
if ($Product -eq "Windows 11" -and $Channel -ne "Retail") {
    $releaseTitle = "$releaseTitle [$channelLabel]"
}

# Output to GITHUB_OUTPUT
"update_title=$updateTitle" >> $env:GITHUB_OUTPUT
"release_title=$releaseTitle" >> $env:GITHUB_OUTPUT
"build_number=$buildNumber" >> $env:GITHUB_OUTPUT
"build_date=$buildDate" >> $env:GITHUB_OUTPUT
"uuid=$uuid" >> $env:GITHUB_OUTPUT
"channel_label=$channelLabel" >> $env:GITHUB_OUTPUT
"netfx3=$netfx3" >> $env:GITHUB_OUTPUT
"language=$Language" >> $env:GITHUB_OUTPUT
"tag_suffix=$tagSuffix" >> $env:GITHUB_OUTPUT

Write-Host ""
Write-Host "Build: $updateTitle"
Write-Host "Release Title: $releaseTitle"
Write-Host "Build Number: $buildNumber"
Write-Host "Channel: $channelLabel"
Write-Host ".NET 3.5 available: $netfx3"
Write-Host "Date: $buildDate"
Write-Host "UUID: $uuid"
