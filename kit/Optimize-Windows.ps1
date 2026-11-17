#Requires -Version 5.1
# Оптимизация Windows 10 Enterprise LTSC 2021 под игры на MSI GF63 Thin 9SCXR.
# Все изменения записываются в backup.json и отменяются запуском Undo.cmd.
#
#   Optimize.cmd          - обычный режим (безопасный)
#   Optimize-Extreme.cmd  - дополнительно отключает печать, отпечатки, сканеры, смарт-карты
#   Undo.cmd              - вернуть всё как было
param(
    [switch]$Extreme,
    [switch]$Undo,
    [switch]$NoRestorePoint
)

$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Extreme)        { $argList += '-Extreme' }
    if ($Undo)           { $argList += '-Undo' }
    if ($NoRestorePoint) { $argList += '-NoRestorePoint' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    exit
}

$BackupFile = Join-Path $PSScriptRoot 'backup.json'
$LogFile    = Join-Path $PSScriptRoot 'optimize.log'
Start-Transcript -Path $LogFile -Append | Out-Null

function Step($text) { Write-Host ''; Write-Host "=== $text" -ForegroundColor Cyan }

function Get-UsedRamMb {
    $os = Get-CimInstance Win32_OperatingSystem
    [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1KB)
}

# ---------- Резервная копия исходных значений ----------
$Backup = [ordered]@{}
if (Test-Path $BackupFile) {
    $loaded = Get-Content $BackupFile -Raw | ConvertFrom-Json
    foreach ($p in $loaded.PSObject.Properties) { $Backup[$p.Name] = $p.Value }
}
function Save-Backup { $Backup | ConvertTo-Json -Depth 5 | Set-Content $BackupFile -Encoding UTF8 }

# Исходное значение запоминается только при первом изменении,
# поэтому повторный запуск скрипта не затирает резервную копию.
function Set-Reg {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    $id = "reg|$Path|$Name"
    if (-not $Backup.Contains($id)) {
        $existed = $false; $old = $null; $oldType = $null
        if (Test-Path $Path) {
            $key = Get-Item $Path
            if ($key.GetValueNames() -contains $Name) {
                $existed = $true
                $old     = $key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
                $oldType = $key.GetValueKind($Name).ToString()
            }
        }
        $Backup[$id] = @{ Kind = 'reg'; Path = $Path; Name = $Name; Existed = $existed; Value = $old; Type = $oldType }
    }
    if (-not (Test-Path $Path)) { New-Item $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Set-Svc {
    param([string]$Name, [string]$Start = 'Disabled')
    $svc = Get-Service $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return }
    $id = "svc|$Name"
    if (-not $Backup.Contains($id)) {
        $Backup[$id] = @{ Kind = 'svc'; Name = $Name; Start = $svc.StartType.ToString() }
    }
    try {
        Set-Service $Name -StartupType $Start
        if ($Start -eq 'Disabled') { Stop-Service $Name -Force -ErrorAction SilentlyContinue }
        Write-Host "  служба $Name -> $Start"
    } catch {
        Write-Warning "  службу $Name изменить не удалось: $($_.Exception.Message)"
    }
}

function Disable-Task {
    param([string]$TaskPath, [string]$TaskName)
    $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) { return }
    $id = "task|$TaskPath|$TaskName"
    if (-not $Backup.Contains($id)) {
        $Backup[$id] = @{ Kind = 'task'; TaskPath = $TaskPath; TaskName = $TaskName; Enabled = ($task.State -ne 'Disabled') }
    }
    try {
        Disable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName | Out-Null
        Write-Host "  задача $TaskName отключена"
    } catch {
        Write-Warning "  задачу $TaskName отключить не удалось: $($_.Exception.Message)"
    }
}

function Get-ActivePowerScheme {
    if ((powercfg /getactivescheme) -match '([0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})') { $Matches[1] }
}

# =====================================================================
#  ОТМЕНА
# =====================================================================
if ($Undo) {
    if ($Backup.Count -eq 0) {
        Write-Host 'Резервной копии нет - отменять нечего.'
        Stop-Transcript | Out-Null
        Read-Host 'Нажмите Enter для выхода'
        exit
    }
    Step 'Возвращаю исходные настройки'
    foreach ($entry in $Backup.Values) {
        try {
            switch ($entry.Kind) {
                'reg' {
                    if ($entry.Existed) {
                        $value = $entry.Value
                        if ($entry.Type -eq 'Binary')      { $value = [byte[]]$value }
                        if ($entry.Type -eq 'MultiString') { $value = [string[]]$value }
                        if ($entry.Type -eq 'DWord')       { $value = [int]$value }
                        if (-not (Test-Path $entry.Path)) { New-Item $entry.Path -Force | Out-Null }
                        New-ItemProperty -Path $entry.Path -Name $entry.Name -Value $value -PropertyType $entry.Type -Force | Out-Null
                    } elseif (Test-Path $entry.Path) {
                        Remove-ItemProperty -Path $entry.Path -Name $entry.Name -ErrorAction SilentlyContinue
                    }
                }
                'svc'  { Set-Service $entry.Name -StartupType $entry.Start }
                'task' { if ($entry.Enabled) { Enable-ScheduledTask -TaskPath $entry.TaskPath -TaskName $entry.TaskName | Out-Null } }
                'power' {
                    powercfg /setactive $entry.Scheme | Out-Null
                    if ($entry.Hibernate) { powercfg /hibernate on | Out-Null }
                }
            }
        } catch {
            Write-Warning "Не удалось вернуть $($entry.Kind) $($entry.Name): $($_.Exception.Message)"
        }
    }
    Remove-Item $BackupFile -Force
    Write-Host ''
    Write-Host 'Готово. Перезагрузите компьютер.' -ForegroundColor Green
    Stop-Transcript | Out-Null
    Read-Host 'Нажмите Enter для выхода'
    exit
}

# =====================================================================
#  ОПТИМИЗАЦИЯ
# =====================================================================
$mode = if ($Extreme) { 'ЭКСТРЕМАЛЬНЫЙ' } else { 'обычный' }
Write-Host "Оптимизация Windows под игры - MSI GF63 Thin 9SCXR (режим: $mode)" -ForegroundColor Green
$ramBefore = Get-UsedRamMb
Write-Host "Занято памяти сейчас: $ramBefore МБ"

if (-not $NoRestorePoint) {
    Step 'Создаю точку восстановления'
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\"
        Checkpoint-Computer -Description 'GF63 Optimize' -RestorePointType MODIFY_SETTINGS
    } catch {
        Write-Warning "Точку восстановления создать не удалось: $($_.Exception.Message). Отмена через Undo.cmd всё равно работает."
    }
}

# ---------- Электропитание ----------
Step 'Электропитание: максимальная производительность'
if (-not $Backup.Contains('power')) {
    $hibernateOn = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction SilentlyContinue).HibernateEnabled -eq 1
    $Backup['power'] = @{ Kind = 'power'; Name = 'scheme'; Scheme = (Get-ActivePowerScheme); Hibernate = $hibernateOn }
}
$ultimate = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$high     = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$scheme   = $null
$existing = powercfg /list | Select-String 'GF63 Max Performance'
if ($existing -and "$existing" -match '([0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})') {
    $scheme = $Matches[1]
} else {
    $dup = powercfg /duplicatescheme $ultimate
    if ("$dup" -match '([0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})') {
        $scheme = $Matches[1]
        powercfg /changename $scheme 'GF63 Max Performance' | Out-Null
    }
}
if (-not $scheme) { $scheme = $high }
powercfg /setactive $scheme | Out-Null
# От сети экран и сон не мешают игре; от батареи остаются обычные значения
powercfg /change monitor-timeout-ac 15 | Out-Null
powercfg /change standby-timeout-ac 0  | Out-Null
# Гибернация и быстрый запуск: освобождает несколько ГБ на SSD и убирает баги после "выключения"
powercfg /hibernate off | Out-Null
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1
Write-Host "  активная схема: $scheme"

# ---------- Игры и видеокарта ----------
Step 'Игровые настройки'
Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
Set-Reg 'HKCU:\SOFTWARE\Microsoft\GameBar' 'AutoGameModeEnabled' 1
Set-Reg 'HKCU:\SOFTWARE\Microsoft\GameBar' 'AllowAutoGameMode' 1
# Аппаратный планировщик GPU (GTX 1650 поддерживает)
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2
# Приоритет игр в планировщике мультимедиа
$mm = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
Set-Reg $mm 'SystemResponsiveness' 10
Set-Reg $mm 'NetworkThrottlingIndex' ([int]-1)   # 0xFFFFFFFF = без ограничения
Set-Reg "$mm\Tasks\Games" 'GPU Priority' 8
Set-Reg "$mm\Tasks\Games" 'Priority' 6
Set-Reg "$mm\Tasks\Games" 'Scheduling Category' 'High' 'String'
Set-Reg "$mm\Tasks\Games" 'SFIO Priority' 'High' 'String'

# ---------- Телеметрия и фон ----------
Step 'Телеметрия и фоновая активность'
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 0
Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0
Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search' 'CortanaConsent' 0
Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1
Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' 0
Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 0
Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SoftLandingEnabled' 0
# Edge не должен висеть в памяти после закрытия
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled' 0
# Обновления ставятся, но не перезагружают компьютер посреди игры
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoRebootWithLoggedOnUsers' 1

# ---------- Службы ----------
Step 'Службы'
$services = @(
    'DiagTrack',                                 # телеметрия
    'dmwappushservice',                          # телеметрия
    'diagnosticshub.standardcollector.service',  # сбор диагностики
    'WerSvc',                                    # отчёты об ошибках
    'PcaSvc',                                    # помощник по совместимости
    'SysMain',                                   # Superfetch: на SSD не нужен, ест память
    'WSearch',                                   # индексация файлов
    'MapsBroker',                                # карты
    'lfsvc',                                     # геолокация
    'RetailDemo',                                # демо-режим магазина
    'RemoteRegistry',                            # удалённый реестр
    'Fax',                                       # факс
    'WMPNetworkSvc',                             # общий доступ Windows Media
    'TrkWks'                                     # отслеживание ярлыков в сети
)
if ($Extreme) {
    $services += @(
        'Spooler',      # печать
        'WbioSrvc',     # отпечатки пальцев
        'StiSvc',       # сканеры и камеры (WIA)
        'SCardSvr',     # смарт-карты
        'WalletService',
        'SEMgrSvc'      # NFC-платежи
    )
}
foreach ($name in $services) { Set-Svc $name 'Disabled' }
# Службы Xbox и Store не трогаются: они нужны для Minecraft Bedrock.

# ---------- Задачи планировщика ----------
Step 'Задачи планировщика'
Disable-Task '\Microsoft\Windows\Application Experience\' 'Microsoft Compatibility Appraiser'
Disable-Task '\Microsoft\Windows\Application Experience\' 'ProgramDataUpdater'
Disable-Task '\Microsoft\Windows\Autochk\' 'Proxy'
Disable-Task '\Microsoft\Windows\Customer Experience Improvement Program\' 'Consolidator'
Disable-Task '\Microsoft\Windows\Customer Experience Improvement Program\' 'UsbCeip'
Disable-Task '\Microsoft\Windows\DiskDiagnostic\' 'Microsoft-Windows-DiskDiagnosticDataCollector'
Disable-Task '\Microsoft\Windows\Feedback\Siuf\' 'DmClient'
Disable-Task '\Microsoft\Windows\Feedback\Siuf\' 'DmClientOnScenarioDownload'
Disable-Task '\Microsoft\Windows\Windows Error Reporting\' 'QueueReporting'
Disable-Task '\Microsoft\Windows\Maps\' 'MapsUpdateTask'
Disable-Task '\Microsoft\Windows\Maps\' 'MapsToastTask'

# ---------- Интерфейс ----------
Step 'Интерфейс: без анимаций и прозрачности'
Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 3
# Всё выключено, кроме сглаживания шрифтов, эскизов и содержимого окна при перетаскивании
Set-Reg 'HKCU:\Control Panel\Desktop' 'UserPreferencesMask' ([byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00)) 'Binary'
Set-Reg 'HKCU:\Control Panel\Desktop' 'FontSmoothing' '2' 'String'
Set-Reg 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '0' 'String'
Set-Reg 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String'
Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 0
Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ListviewAlphaSelect' 0
Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\DWM' 'EnableAeroPeek' 0
Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0
Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec' 0

Save-Backup

# ---------- Итог ----------
Write-Host ''
Write-Host 'ГОТОВО.' -ForegroundColor Green
Write-Host "Памяти занято до оптимизации: $ramBefore МБ. Точная цифра 'после' будет видна после перезагрузки"
Write-Host '(Диспетчер задач - Производительность - Память).'
Write-Host ''
Write-Host 'Что сделать после перезагрузки:'
Write-Host '  1. Обновить драйвер видеокарты с nvidia.com (GeForce GTX 1650, Windows 10 64-bit).'
Write-Host '  2. Для Minecraft Bedrock: запустить C:\GF63\Install-Store.cmd.'
Write-Host '  3. После установки Minecraft: запустить C:\GF63\Setup-Minecraft.cmd.'
Write-Host '  Вернуть всё как было: C:\GF63\Undo.cmd'
Write-Host ''
Stop-Transcript | Out-Null

if ((Read-Host 'Перезагрузить компьютер сейчас? (y/n)') -eq 'y') { Restart-Computer -Force }
