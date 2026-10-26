# Povolení instalace z lokálních manifestů (nutné pro offline Winget)
winget settings --enable LocalManifestFiles

# Definujeme cestu, kde Windows po instalaci schová stažené soubory
$LocalDir = "C:\Windows\Setup\Scripts\Installers"

# Vyhledáme všechny stažené .yaml soubory manifestů v této složce
$Manifests = Get-ChildItem -Path $LocalDir -Filter "*.yaml"

# Projdeme manifest po manifestu a nainstalujeme je offline
foreach ($Manifest in $Manifests) {
    Write-Output "Instaluji aplikaci z manifestu: $($Manifest.Name)"
    
    # Instalace na pozadí přímo z lokálního souboru
    winget install --manifest $Manifest.FullName --silent --accept-package-agreements --accept-source-agreements
}

# Smažeme celou podsložku s .exe/.msi/.yaml instalátory, které už nepotřebujeme
$InstallerDir = "C:\Windows\Setup\Scripts\Installers"
if (Test-Path $InstallerDir) {
    Remove-Item -Path $InstallerDir -Recurse -Force
}
