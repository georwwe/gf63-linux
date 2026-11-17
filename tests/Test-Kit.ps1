# Runs the kit on a real Windows machine (GitHub Actions runner) and verifies the results.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$failed = 0
function Check($name, [bool]$ok, $detail = '') {
    if ($ok) { Write-Host "PASS  $name" } else { Write-Host "FAIL  $name $detail"; $script:failed++ }
}
function Run($file, [string[]]$scriptArgs) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $file @scriptArgs | Out-Host
    return $LASTEXITCODE
}
function Read-Reg($path, $name) {
    if (-not (Test-Path $path)) { return '<none>' }
    $key = Get-Item $path
    if ($key.GetValueNames() -notcontains $name) { return '<none>' }
    $value = $key.GetValue($name)
    if ($value -is [byte[]]) { return ($value -join ',') }
    return "$value"
}

Write-Host "OS: $((Get-CimInstance Win32_OperatingSystem).Caption), PowerShell $($PSVersionTable.PSVersion)"

# --- 1. Encoding and syntax -------------------------------------------------
foreach ($file in Get-ChildItem $root -Recurse -Filter *.ps1 | Where-Object FullName -notmatch '\\tests\\') {
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    Check "BOM    $($file.Name)" ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    Check "Parse  $($file.Name)" ($errors.Count -eq 0) (($errors | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ')
}
foreach ($file in Get-ChildItem $root -Recurse -Filter *.cmd) {
    $text = [IO.File]::ReadAllText($file.FullName)
    Check "CRLF   $($file.Name)" ($text -match "`r`n" -and $text -notmatch "[^`r]`n")
}

# --- 2. Optimize ------------------------------------------------------------
$kit = Join-Path $root 'kit'
$watch = @(
    @('HKCU:\System\GameConfigStore', 'GameDVR_Enabled', '0'),
    @('HKCU:\SOFTWARE\Microsoft\GameBar', 'AutoGameModeEnabled', '1'),
    @('HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers', 'HwSchMode', '2'),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection', 'AllowTelemetry', '0'),
    @('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile', 'NetworkThrottlingIndex', '-1'),
    @('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games', 'Scheduling Category', 'High'),
    @('HKCU:\Control Panel\Desktop', 'UserPreferencesMask', '144,18,3,128,16,0,0,0'),
    @('HKCU:\Control Panel\Desktop', 'MenuShowDelay', '0'),
    @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'StartupBoostEnabled', '0')
)
$svcNames = 'DiagTrack', 'SysMain', 'WSearch', 'MapsBroker', 'WerSvc'
$before = @{}
foreach ($w in $watch) { $before["$($w[0])|$($w[1])"] = Read-Reg $w[0] $w[1] }
$svcBefore = @{}
foreach ($n in $svcNames) { $s = Get-Service $n -ErrorAction SilentlyContinue; if ($s) { $svcBefore[$n] = "$($s.StartType)" } }
Write-Host "Services present: $($svcBefore.Keys -join ', ')"

Set-Content (Join-Path $kit 'slim-pending') ''   # exercise the online component removal as well
$code = Run (Join-Path $kit 'Optimize-Windows.ps1') @('-NoPrompt', '-NoRestorePoint')
Check 'Online slimming finished' (-not (Test-Path (Join-Path $kit 'slim-pending')))
Check 'Optimize exit code' ($code -eq 0) "code=$code"
foreach ($w in $watch) {
    $actual = Read-Reg $w[0] $w[1]
    Check "Set    $($w[1])" ($actual -eq $w[2]) "expected=$($w[2]) actual=$actual"
}
foreach ($n in $svcBefore.Keys) {
    Check "Svc    $n disabled" ("$((Get-Service $n).StartType)" -eq 'Disabled')
}
$backupFile = Join-Path $kit 'backup.json'
Check 'backup.json created' (Test-Path $backupFile)
$backupText = Get-Content $backupFile -Raw
Check 'Power scheme active' (((powercfg /getactivescheme) -join ' ') -match 'GF63 Max Performance|8c5e7fda')

# --- 3. Second run must not overwrite the backup ---------------------------
$code = Run (Join-Path $kit 'Optimize-Windows.ps1') @('-NoPrompt', '-NoRestorePoint', '-Extreme')
Check 'Second run exit code' ($code -eq 0) "code=$code"
$backup2 = Get-Content $backupFile -Raw | ConvertFrom-Json
$first = $backupText | ConvertFrom-Json
$kept = $true
foreach ($p in $first.PSObject.Properties) {
    if (($p.Value | ConvertTo-Json -Compress -Depth 5) -ne ($backup2.($p.Name) | ConvertTo-Json -Compress -Depth 5)) { $kept = $false; Write-Host "changed: $($p.Name)" }
}
Check 'Backup keeps original values' $kept

# --- 4. Check-System --------------------------------------------------------
$code = Run (Join-Path $kit 'Check-System.ps1') @()
Check 'Check-System exit code' ($code -eq 0) "code=$code"

# --- 5. Minecraft GPU preference -------------------------------------------
$fakeJava = Join-Path $env:APPDATA '.minecraft\runtime\test\bin\javaw.exe'
New-Item (Split-Path $fakeJava) -ItemType Directory -Force | Out-Null
Set-Content $fakeJava 'x'
$code = Run (Join-Path $kit 'Setup-Minecraft.ps1') @()
Check 'Setup-Minecraft exit code' ($code -eq 0) "code=$code"
Check 'GPU preference written' ((Read-Reg 'HKCU:\SOFTWARE\Microsoft\DirectX\UserGpuPreferences' $fakeJava) -eq 'GpuPreference=2;')

# --- 5b. SetupComplete (first-boot script used by the macOS build) -----------
New-Item 'C:\GF63' -ItemType Directory -Force | Out-Null
& cmd.exe /c (Join-Path $root 'mac\SetupComplete.cmd')
Check 'SetupComplete exit code' ($LASTEXITCODE -eq 0) "code=$LASTEXITCODE"
$runOnce = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
Check 'SetupComplete registers autorun' ((Read-Reg $runOnce 'GF63Optimize') -eq 'C:\GF63\Optimize.cmd') (Read-Reg $runOnce 'GF63Optimize')
Remove-ItemProperty $runOnce -Name 'GF63Optimize' -ErrorAction SilentlyContinue

# --- 6. Undo ----------------------------------------------------------------
$code = Run (Join-Path $kit 'Optimize-Windows.ps1') @('-Undo', '-NoPrompt')
Check 'Undo exit code' ($code -eq 0) "code=$code"
foreach ($w in $watch) {
    $actual = Read-Reg $w[0] $w[1]
    $expected = $before["$($w[0])|$($w[1])"]
    Check "Undo   $($w[1])" ($actual -eq $expected) "expected=$expected actual=$actual"
}
foreach ($n in $svcBefore.Keys) {
    Check "Undo   svc $n" ("$((Get-Service $n).StartType)" -eq $svcBefore[$n]) "expected=$($svcBefore[$n]) actual=$((Get-Service $n).StartType)"
}
Check 'backup.json removed' (-not (Test-Path $backupFile))

Write-Host ''
if ($failed -gt 0) { Write-Host "$failed check(s) FAILED"; exit 1 }
Write-Host 'All checks passed'
