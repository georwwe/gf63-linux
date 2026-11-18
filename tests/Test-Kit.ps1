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
    @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'StartupBoostEnabled', '0'),
    @('HKCU:\Control Panel\Mouse', 'MouseSpeed', '0'),
    @('HKCU:\System\GameConfigStore', 'GameDVR_FSEBehaviorMode', '2'),
    @('HKCU:\SOFTWARE\Microsoft\DirectX\UserGpuPreferences', 'DirectXUserGlobalSettings', 'SwapEffectUpgradeEnable=1;')
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
# Informational: what the game power scheme holds now (a VM may not offer every setting)
$activeScheme = ((powercfg /getactivescheme) -join ' ') -replace '.*GUID: ([0-9a-f-]{36}).*', '$1'
foreach ($q in @(@('SUB_PROCESSOR', 'PROCTHROTTLEMIN'), @('SUB_PROCESSOR', 'CPMINCORES'), @('SUB_PROCESSOR', 'SYSCOOLPOL'), @('SUB_PCIEXPRESS', 'ASPM'), @('2a737441-1930-4402-8d77-b2bebba308a3', '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'))) {
    $out = (powercfg /query $activeScheme $q[0] $q[1] 2>&1) -join ' '
    $ac = if ($out -match 'Current AC Power Setting Index: (0x[0-9a-f]+)') { $Matches[1] } else { 'n/a' }
    Write-Host ("  power {0}/{1}: AC={2}" -f $q[0], $q[1], $ac)
}

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

# --- 5a. Install-All: real installs of the Minecraft and Horizon launchers --
# (the NVIDIA step is skipped: the runner has no NVIDIA GPU)
$stage = Join-Path $env:RUNNER_TEMP 'stick\GF63-SETUP'
New-Item $stage -ItemType Directory -Force | Out-Null
Copy-Item (Join-Path $kit '*') $stage -Recurse -Force
$code = Run (Join-Path $stage 'Install-All.ps1') @('-SkipNvidia', '-NoPrompt')
Check 'Install-All exit code' ($code -eq 0) "code=$code"
Check 'Kit copied to C:\GF63' (Test-Path 'C:\GF63\Horizon-Watch.ps1')
Check 'Minecraft launcher installed' (Test-Path (Join-Path ${env:ProgramFiles(x86)} 'Minecraft Launcher\MinecraftLauncher.exe'))
Check 'Horizon launcher installed' (Test-Path (Join-Path $env:LOCALAPPDATA 'Programs\Horizon Launcher\horizon-launcher.exe'))
$zips = @(Get-ChildItem 'C:\GF63\shaderpacks' -File -ErrorAction SilentlyContinue)
$zips | ForEach-Object { Write-Host ("  {0}  {1:N0} KB" -f $_.Name, ($_.Length / 1KB)) }
Check 'All four shader packs downloaded' ($zips.Count -eq 4) "count=$($zips.Count)"
$runKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
Check 'Watcher registered for logon' ((Read-Reg $runKey 'GF63Horizon') -match 'Horizon-Watch')

# --- 5a2. Watcher: nothing to do before the game has run, then configures it --
$code = Run 'C:\GF63\Horizon-Watch.ps1' @('-Once')
Check 'Watcher waits while there is no game folder' ($code -eq 2) "code=$code"
$game = Join-Path $env:APPDATA 'horizon-ci\game'
New-Item $game -ItemType Directory -Force | Out-Null
Set-Content (Join-Path $game 'options.txt') 'renderDistance:12'
[IO.File]::WriteAllLines((Join-Path $game 'horizon-graphics.txt'), [string[]]@('preset:balanced', 'taa:false', 'caveCulling:true'))
$code = Run 'C:\GF63\Horizon-Watch.ps1' @('-Once')
Check 'Watcher configures the game' ($code -eq 0) "code=$code"
Check 'Packs copied into the game' (@(Get-ChildItem (Join-Path $game 'shaderpacks') -File).Count -eq 4)
$gfx = Get-Content (Join-Path $game 'horizon-graphics.txt')
$gfx | ForEach-Object { Write-Host "  $_" }
Check 'Existing settings kept' ($gfx -contains 'preset:balanced' -and $gfx -contains 'caveCulling:true')
Check 'TAA replaced, not duplicated' (@($gfx | Where-Object { $_ -like 'taa:*' }).Count -eq 1 -and $gfx -contains 'taa:true')
Check 'Dynamic resolution on' ($gfx -contains 'dynamicResolution:true' -and $gfx -contains 'targetFps:60')
Check 'Shader pack picked' ([bool]($gfx | Where-Object { $_ -match '^pickedShaderPack:.*Complementary' }))
$bytes = [IO.File]::ReadAllBytes((Join-Path $game 'horizon-graphics.txt'))
Check 'Settings file has no BOM' ($bytes[0] -ne 0xEF)
Check 'Watcher removed itself' ((Read-Reg $runKey 'GF63Horizon') -eq '<none>')

# --- 5a3. Add-Game: any game exe is pinned to the discrete GPU ---------------
$gameDir = Join-Path $env:RUNNER_TEMP 'fakegame'
New-Item $gameDir -ItemType Directory -Force | Out-Null
Set-Content (Join-Path $gameDir 'game.exe') 'x'
Set-Content (Join-Path $gameDir 'unins000.exe') 'x'
$code = Run (Join-Path $kit 'Add-Game.ps1') @($gameDir)
Check 'Add-Game exit code' ($code -eq 0) "code=$code"
Check 'Game pinned to NVIDIA' ((Read-Reg 'HKCU:\SOFTWARE\Microsoft\DirectX\UserGpuPreferences' (Join-Path $gameDir 'game.exe')) -eq 'GpuPreference=2;')
Check 'Uninstaller skipped' ((Read-Reg 'HKCU:\SOFTWARE\Microsoft\DirectX\UserGpuPreferences' (Join-Path $gameDir 'unins000.exe')) -eq '<none>')

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
