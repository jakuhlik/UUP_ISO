# UUP ISO Builder

GitHub Actions workflows that build Windows ISOs from UUP (Unified Update Platform) files. They download UUP files via the [UUP dump](https://uupdump.net/) API, convert them to a bootable ISO with integrated updates, and upload split archives to GitHub Releases.

## Supported Products

| Workflow | What it builds |
|----------|----------------|
| **Build Windows 11 ISO** | Latest build of a chosen version from the Retail, Release Preview, Beta or Experimental channel |
| **Build Windows 10 ISO** | Latest 22H2 Feature Update (amd64, arm64 or x86, with ESU patches) |
| **Build Windows Server ISO** | Windows Server 2025 (24H2) with the newest cumulative update from the Microsoft Update Catalog |
| **Build Windows 11 LTSC 2024 ISO** | LTSC 2024 base ISO (you supply the URL) refreshed with the newest cumulative update, .NET 3.5 and optional drivers |

### Windows 11 channels and versions

Microsoft restructured the Windows Insider Program in April 2026: the **Dev** and **Canary** channels were merged into a single **Experimental** channel, **Beta** was refreshed, and **Release Preview** continues. The Windows 11 workflow mirrors that:

| Channel | Milestone | Builds you get | Notes |
|---------|-----------|----------------|-------|
| Retail / ReleasePreview | 24H2 | 26100.xxxx | |
| Retail / ReleasePreview | 25H2 | 26200.xxxx | Current general-availability version |
| Retail / ReleasePreview | 26H2 | 26300.xxxx | Enablement-package release; in Release Preview since August 2026, GA expected late 2026 |
| Retail / ReleasePreview | 26H1 | 28000.xxxx | **arm64 only.** 26H1 ships pre-installed on new Snapdragon X2 / NVIDIA N1X devices and is never offered as an upgrade |
| Beta | *(ignored)* | 26220.xxxx | Beta has a single build series, the milestone input is not used |
| Experimental | 24H2 / 25H2 / 26H2 | 26340.xxxx | Experimental on the current (26H2) Windows core, the successor of the Dev channel |
| Experimental | 26H1 | 28120.xxxx | Experimental (26H1), the successor of the Canary 28000 series (amd64 and arm64) |
| Experimental | 27H2 | 29xxx.1000 | Experimental (Future Platforms), the successor of the Canary 29500 series; the earliest preview of the next platform, not aligned to a retail version |

`27H2` is only valid with the Experimental channel, and `26H1` requires `arm64` in the Retail / ReleasePreview channels.

## Features

- Fetches the latest builds from UUP dump (always uses Feature Updates, never standalone Cumulative Updates)
- Integrates cumulative updates into the image
- Includes all pre-installed Microsoft Store apps (Windows Terminal, Calculator, Photos, etc.)
- Runs DISM component cleanup and ResetBase for smaller images
- Integrates .NET Framework 3.5 (not available in Windows 11 builds 27965 and later, where Microsoft removed the feature)
- Optional driver integration via URL at build time
- Splits the final ISO into 1.9 GB 7z parts for GitHub Releases
- Fully automated — no manual interaction required

## Usage

1. **Fork** this repository
2. Go to the **Actions** tab and enable workflows
3. Pick the workflow for the product you want (for example **"Build Windows 11 ISO"**) → **"Run workflow"**
4. Select your parameters:

| Parameter | Options | Default | Notes |
|-----------|---------|---------|-------|
| Channel | Retail, ReleasePreview, Beta, Experimental | Retail | Windows 11 only, see the table above |
| Milestone | 27H2, 26H2, 26H1, 25H2, 24H2 | 25H2 | Windows 11 only, see the table above |
| Architecture | amd64, arm64 (Windows 10 also x86) | amd64 | Windows Server is amd64 only |
| Language | Free text | en-us | UUP dump language codes, e.g. `zh-cn`, `de-de`, `sr-latn-rs` |
| Edition | PROFESSIONAL, CORE, SERVERSTANDARD, etc. | PROFESSIONAL | Client editions for Win10/11; Server editions for Server (`SERVERSTANDARD` / `SERVERDATACENTER` = Desktop Experience, `*CORE` = Server Core) |
| Drivers URL | URL to a zip file | *(empty)* | Optional, see [Driver Integration](#driver-integration) |

5. Wait for the workflow to complete (~1-3 hours)
6. Download the split 7z files from the **Releases** page

## Extracting the ISO

Download all `.7z.xxx` files to the same folder, then extract:

```
7z x <filename>.7z.001
```

This produces the full bootable ISO file.

## Driver Integration

You can integrate hardware drivers into the ISO by providing a URL to a zip file when triggering the workflow. The zip is downloaded at build time and is **not** stored in the repository, so forked repos stay clean.

### Preparing a Driver Package

1. Download the template zip from [`drivers-template.zip`](drivers-template.zip) included in this repository
2. Place your driver files into the appropriate subfolder:

| Folder | Injected into | Use case |
|--------|--------------|----------|
| `OS/` | `install.wim` only | Most hardware drivers (GPU, audio, chipset, etc.) |
| `WinPE/` | `boot.wim` / `winre.wim` only | Drivers needed during installation (storage controllers, NIC) |
| `ALL/` | All images | Drivers needed everywhere |

3. Each driver must be a complete INF driver package (`.inf` + `.sys` + `.cat` and any other referenced files). Only signed drivers are accepted.
4. Subdirectory nesting is fine — DISM scans recursively.

Example structure inside the zip:

```
OS/
  gpu-driver/
    nvidia.inf
    nvidia.sys
    nvidia.cat
WinPE/
  nvme-controller/
    stornvme.inf
    stornvme.sys
    stornvme.cat
```

### Exporting Drivers from an Existing System

[DriverStoreExplorer (RAPR)](https://github.com/lostindark/DriverStoreExplorer) is a handy open-source tool for browsing and exporting drivers from the Windows Driver Store. You can use it to select and export specific drivers, then organize the exported folders into the `OS/` or `WinPE/` structure described above.

### Using the Driver Package

1. Upload your zip file to any publicly accessible URL
2. When triggering the workflow, paste the URL into the **Drivers URL** field
3. The workflow will download, extract, and integrate the drivers automatically

[temp.sh](https://temp.sh) is a convenient no-signup temporary file hosting service (4 GB limit, files expire after 3 days). Upload with one command:

```bash
curl -F "file=@drivers.zip" https://temp.sh/upload
```

The returned URL can be pasted directly into the Drivers URL field. GitHub Release assets, cloud storage direct links, and other file hosting services also work.

If the field is left empty, no drivers are integrated — same as the default behavior.

## How It Works

1. **Query** — Calls the UUP dump API to find the latest matching build and get download URLs
   - Windows 11 uses `fetchupd.php` (a live Windows Update query) with the ring / target-release parameters of the current Insider channel structure, and falls back to the UUP dump build database if Windows Update does not answer
   - Windows 10 and Windows Server use the UUP dump build database (`listid.php`)
2. **Download** — Uses aria2c with multi-connection downloads to fetch UUP files
3. **Convert** — Uses [abbodi1406's uup-converter-wimlib](https://github.com/abbodi1406/BatUtil) to:
   - Extract ESD files to WIM format
   - Mount images and apply updates with DISM
   - Run component cleanup with `/ResetBase`
   - Enable .NET Framework 3.5
   - Create bootable ISO with cdimage
4. **Catalog updates** (Server / LTSC only) — Downloads the newest cumulative update from the Microsoft Update Catalog and applies it with DISM. For Windows Server the step is skipped automatically when the UUP dump base image is already at that level
5. **Split & Upload** — Splits the ISO into 1.9 GB 7z volumes and uploads to GitHub Releases

## Runner

Uses `windows-2022` runners which provide ~240 GB total disk space across C: and D: drives. The build process uses the D: drive for all working files.

## Credits

- [UUP dump](https://uupdump.net/) — API for finding and downloading UUP files
- [abbodi1406/BatUtil](https://github.com/abbodi1406/BatUtil) — UUP to ISO converter

## License

See [LICENSE](LICENSE).
