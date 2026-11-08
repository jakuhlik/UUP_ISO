# C:\Windows\Setup\Scripts\install-apps.ps1

# Enable logging
$LogPath = "C:\Windows\Setup\Scripts\winget-install.log"
Start-Transcript -Path $LogPath -Append

# List with apps installed under machine scope
$AppsFileMachine = "C:\Windows\Setup\Scripts\apps.machine.txt"

# Wait a few second until winget command is available
$retry = 0
while (!(Get-Command winget -ErrorAction SilentlyContinue) -and $retry -lt 10) {
    Start-Sleep -Seconds 3
    $retry++
}
if (!(Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Output "ERROR: winget not found"
    Stop-Transcript
    Exit 1
}

# Fix winget msstore certificate error on a fresh system
Write-Output "Fixing certificate error on a fresh system"
$Attempts = 6
while ($true) {
    try {
	Write-Host "Trying to update winget"
        winget settings --enable BypassCertificatePinningForMicrosoftStore | Out-Null
	winget upgrade Microsoft.AppInstaller --accept-source-agreements --accept-package-agreements | Out-Null
	winget settings --disable BypassCertificatePinningForMicrosoftStore | Out-Null
        break
    } catch {
        if ($Attempts -le 0) {
            Write-Host "ERROR: Unable to update winget!" -ForegroundColor Red
            Stop-Transcript
            Exit 1
        }
    }
    Write-Host "WARNING: Unable to update winget. Trying again in 10s" -ForegroundColor Yellow
    Start-Sleep -Seconds 10
    $Attempts--
}
Write-Output "Done"

Write-Output "Starting apps install using winget..."
Copy-Item "C:\Windows\Setup\Scripts\settings.json" "$env:LOCALAPPDATA\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\settings.json"

function Winget-Install($AppList, $Scope) {
    foreach ($App in $(Get-Content -Path $AppList | Where-Object { $_ -match '\S' })) {
        Write-Output "Installing: $App"
    
        & winget install --id $App --silent --scope $Scope --accept-package-agreements --accept-source-agreements

        if ($LASTEXITCODE -eq 0) {
            Write-Output "$App was successfully installed."
        } else {
            Write-Output "Installation of $App failed with error: $LASTEXITCODE"
        }
    }
}

if (Test-Path $AppsFileMachine) {
    Winget-Install $AppsFileMachine "machine"
}

Write-Output "Installation finished."
Stop-Transcript
