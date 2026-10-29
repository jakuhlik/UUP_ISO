# Počkáme maximálně 30 sekund, než bude příkaz winget v systému dostupný
$retry = 0
while (!(Get-Command winget -ErrorAction SilentlyContinue) -and $retry -lt 100) {
    Start-Sleep -Seconds 3
    $retry++
}

# Zapnutí lokálních manifestů
winget settings --enable LocalManifestFiles

# Zbytek vašeho původního skriptu...
$LocalDir = "C:\Windows\Setup\Scripts\Installers"
$Manifests = Get-ChildItem -Path $LocalDir -Filter "*.yaml"

foreach ($Manifest in $Manifests) {
    Write-Output "Instaluji aplikaci z manifestu: $($Manifest.Name)"
    # Přidány offline parametry pro jistotu
    winget install --manifest $Manifest.FullName --silent --accept-package-agreements --accept-source-agreements
}

# Úklid instalátorů
if (Test-Path $LocalDir) {
    Remove-Item -Path $LocalDir -Recurse -Force
}
