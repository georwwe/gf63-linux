#Requires -Version 5.1
# Проверка системы после установки: показывает, всё ли в порядке с драйверами,
# памятью, видеокартой и настройками. Ничего не изменяет.

$ErrorActionPreference = 'Continue'
$problems = 0

function Section($text) { Write-Host ''; Write-Host "=== $text" -ForegroundColor Cyan }
function Ok($text)      { Write-Host "  [OK] $text" -ForegroundColor Green }
function Bad($text)     { Write-Host "  [!!] $text" -ForegroundColor Yellow; $script:problems++ }
function Info($text)    { Write-Host "       $text" }

Section 'Система'
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
Info "$($cs.Manufacturer) $($cs.Model)"
Info "$($os.Caption), сборка $($os.BuildNumber)"
Info ((Get-CimInstance Win32_Processor | Select-Object -First 1).Name)

Section 'Драйверы'
$broken = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 })
if ($broken.Count -eq 0) {
    Ok 'Все устройства работают, устройств без драйвера нет.'
} else {
    Bad "Устройств с проблемой: $($broken.Count)"
    foreach ($device in $broken) {
        $name = if ($device.Name) { $device.Name } else { $device.DeviceID }
        Info "- $name (код $($device.ConfigManagerErrorCode))"
    }
    Info 'Решение: Параметры - Обновление и безопасность - Центр обновления - Проверить наличие обновлений.'
}

Section 'Видеокарты'
$gpus = @(Get-CimInstance Win32_VideoController)
foreach ($gpu in $gpus) {
    $date = if ($gpu.DriverDate) { $gpu.DriverDate.ToString('yyyy-MM-dd') } else { '?' }
    Info "$($gpu.Name) - драйвер $($gpu.DriverVersion) от $date"
}
if ($gpus | Where-Object Name -match 'NVIDIA') { Ok 'Видеокарта NVIDIA определена.' }
else { Bad 'Видеокарта NVIDIA не найдена - установите драйвер с nvidia.com.' }
if ($gpus | Where-Object Name -match 'Basic Display|Базовый') { Bad 'Одна из видеокарт работает на базовом драйвере Microsoft.' }

Section 'Память'
$usedMb  = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1KB)
$totalMb = [math]::Round($os.TotalVisibleMemorySize / 1KB)
Info "Занято $usedMb МБ из $totalMb МБ"
$sticks = @(Get-CimInstance Win32_PhysicalMemory)
foreach ($stick in $sticks) {
    Info ("- {0}: {1:N0} ГБ, {2} МГц" -f $stick.DeviceLocator, ($stick.Capacity / 1GB), $stick.Speed)
}
if ($sticks.Count -ge 2) { Ok 'Две планки памяти - двухканальный режим.' }
else { Bad 'Одна планка памяти (одноканальный режим). Вторая планка 8 ГБ DDR4 SO-DIMM даст +20-40% FPS.' }

Section 'Питание'
$schemeLine = (powercfg /getactivescheme) -join ' '
Info $schemeLine
if ($schemeLine -match 'GF63 Max Performance|8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c') { Ok 'Схема максимальной производительности активна.' }
else { Bad 'Активна не игровая схема питания. Запустите C:\GF63\Optimize.cmd.' }
$battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
if ($battery) {
    if ($battery.BatteryStatus -eq 2) { Ok 'Ноутбук работает от сети.' }
    else { Bad 'Ноутбук работает от батареи - видеокарта и процессор режут мощность. Для игр подключите зарядку.' }
}

Section 'Игровые настройки'
function Get-Value($path, $name) { (Get-ItemProperty $path -Name $name -ErrorAction SilentlyContinue).$name }
if ((Get-Value 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled') -eq 0) { Ok 'Запись Xbox DVR выключена.' } else { Bad 'Xbox DVR включён.' }
if ((Get-Value 'HKCU:\SOFTWARE\Microsoft\GameBar' 'AutoGameModeEnabled') -eq 1) { Ok 'Игровой режим включён.' } else { Bad 'Игровой режим выключен.' }
if ((Get-Value 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode') -eq 2) { Ok 'Аппаратный планировщик GPU включён.' } else { Bad 'Аппаратный планировщик GPU выключен.' }
$gpuPrefs = Get-Item 'HKCU:\SOFTWARE\Microsoft\DirectX\UserGpuPreferences' -ErrorAction SilentlyContinue
$javaPrefs = @()
if ($gpuPrefs) { $javaPrefs = @($gpuPrefs.GetValueNames() | Where-Object { $_ -match 'javaw?\.exe|Minecraft' }) }
if ($javaPrefs.Count -gt 0) { Ok "Minecraft привязан к NVIDIA (файлов: $($javaPrefs.Count))." }
else { Info 'Minecraft ещё не привязан к NVIDIA - после установки игры запустите C:\GF63\Setup-Minecraft.cmd.' }

Section 'Что занимает память (первые 10)'
Get-Process | Group-Object ProcessName | ForEach-Object {
    [pscustomobject]@{ Name = $_.Name; Mb = [math]::Round(($_.Group | Measure-Object WorkingSet64 -Sum).Sum / 1MB) }
} | Sort-Object Mb -Descending | Select-Object -First 10 | ForEach-Object { Info ('{0,6} МБ  {1}' -f $_.Mb, $_.Name) }

Write-Host ''
if ($problems -eq 0) { Write-Host 'ИТОГ: проблем не найдено.' -ForegroundColor Green }
else { Write-Host "ИТОГ: найдено замечаний - $problems (см. строки с [!!] выше)." -ForegroundColor Yellow }
exit 0
