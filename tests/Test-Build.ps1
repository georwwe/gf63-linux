# End-to-end test of Export-Drivers + Build-USB on a GitHub Actions runner:
# official LTSC 2021 evaluation ISO in, bootable FAT32 volume (a virtual disk) out.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tmp  = Join-Path $env:RUNNER_TEMP 'gf63'
New-Item $tmp -ItemType Directory -Force | Out-Null
function Check($name, [bool]$ok, $detail = '') {
    if ($ok) { Write-Host "PASS  $name" } else { Write-Host "FAIL  $name $detail"; $script:failed++ }
}
$failed = 0

Get-Volume | Where-Object DriveLetter | Format-Table DriveLetter, FileSystemLabel, @{n='FreeGB';e={[math]::Round($_.SizeRemaining/1GB)}} | Out-Host

# --- ISO from the Microsoft Evaluation Center --------------------------------
$iso = Join-Path $tmp 'ltsc2021.iso'
$url = 'https://go.microsoft.com/fwlink/p/?LinkID=2195404&clcid=0x409&culture=en-us&country=US'
Write-Host 'Downloading ISO...'
& curl.exe -L --fail --retry 3 -sS -o $iso $url
if ($LASTEXITCODE -ne 0) { throw "ISO download failed ($LASTEXITCODE)" }
$isoGb = [math]::Round((Get-Item $iso).Length / 1GB, 2)
Write-Host "ISO size: $isoGb GB"
if ($isoGb -lt 3) { throw 'Downloaded file is too small to be a Windows ISO.' }

# --- Drivers -----------------------------------------------------------------
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\Export-Drivers.ps1') -Force | Out-Host
Check 'Export-Drivers exit code' ($LASTEXITCODE -eq 0)
$infs = @(Get-ChildItem (Join-Path $root 'drivers') -Recurse -Filter *.inf -ErrorAction SilentlyContinue)
Write-Host "Exported INF files: $($infs.Count)"
if ($infs.Count -eq 0) { throw 'The runner has no third-party drivers to export; the build cannot be exercised.' }

# --- Virtual disk that stands in for the USB stick ---------------------------
$vhd = Join-Path $tmp 'usb.vhd'
@"
create vdisk file="$vhd" maximum=12000 type=expandable
select vdisk file="$vhd"
attach vdisk
create partition primary
format fs=ntfs quick label=OLD
assign letter=U
"@ | Set-Content (Join-Path $tmp 'dp.txt') -Encoding ASCII
& diskpart.exe /s (Join-Path $tmp 'dp.txt') | Out-Host
if (-not (Test-Path 'U:\')) { throw 'Virtual disk was not created.' }

# --- Build -------------------------------------------------------------------
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\Build-USB.ps1') `
    -IsoPath $iso -UsbDrive U -WorkDir (Join-Path $tmp 'work') -NoPrompt -AllowNonUsb | Out-Host
Check 'Build-USB exit code' ($LASTEXITCODE -eq 0) "code=$LASTEXITCODE"

# --- Verify the result -------------------------------------------------------
$vol = Get-Volume -DriveLetter U
Check 'Volume is FAT32' ($vol.FileSystem -eq 'FAT32') $vol.FileSystem
Check 'UEFI loader present' (Test-Path 'U:\efi\boot\bootx64.efi')
Check 'boot.wim present' (Test-Path 'U:\sources\boot.wim')
Check 'setup.exe present' (Test-Path 'U:\setup.exe')
$image = @(Get-ChildItem 'U:\sources' -Filter 'install*.swm') + @(Get-ChildItem 'U:\sources' -Filter 'install.wim')
Check 'install image present' ($image.Count -gt 0)
$image | ForEach-Object { Write-Host ("  {0}  {1:N0} MB" -f $_.Name, ($_.Length / 1MB)) }
Check 'No file over 4 GB' (-not (Get-ChildItem U:\ -Recurse -File | Where-Object Length -ge 4GB))

# Expand the written image and look inside it
$first = $image | Sort-Object Name | Select-Object -First 1
$apply = Join-Path $tmp 'apply'
New-Item $apply -ItemType Directory -Force | Out-Null
if ($first.Extension -eq '.swm') {
    Expand-WindowsImage -ImagePath $first.FullName -SplitImageFilePattern 'U:\sources\install*.swm' -Index 1 -ApplyPath $apply | Out-Null
} else {
    Expand-WindowsImage -ImagePath $first.FullName -Index 1 -ApplyPath $apply | Out-Null
}
Check 'Kit is inside the image' (Test-Path (Join-Path $apply 'GF63\Optimize-Windows.ps1'))
$drivers = @(Get-WindowsDriver -Path $apply)
Check 'Drivers are inside the image' ($drivers.Count -gt 0) "count=$($drivers.Count)"
& reg.exe load 'HKLM\GF63TEST' (Join-Path $apply 'Windows\System32\config\SOFTWARE') | Out-Null
$runOnce = (& reg.exe query 'HKLM\GF63TEST\Microsoft\Windows\CurrentVersion\RunOnce' /v GF63Optimize) -join ' '
& reg.exe unload 'HKLM\GF63TEST' | Out-Null
Check 'First-logon autorun registered' ($runOnce -match 'Optimize\.cmd')
$ie = Get-WindowsOptionalFeature -Path $apply -FeatureName 'Internet-Explorer-Optional-amd64'
Check 'Internet Explorer disabled in image' ($ie.State -ne 'Enabled') "$($ie.State)"

Write-Host ''
if ($failed -gt 0) { Write-Host "$failed check(s) FAILED"; exit 1 }
Write-Host 'All checks passed'
