#Requires -Version 5.1
# Шаг 1. Выгружает все установленные драйверы этого ноутбука в папку drivers.
# Запускать на самом MSI GF63 Thin 9SCXR, пока на нём стоит рабочая Windows.
param([switch]$Force)

$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$PSCommandPath`"")
    exit
}

$root = Split-Path -Parent $PSScriptRoot
$dest = Join-Path $root 'drivers'

$cs  = Get-CimInstance Win32_ComputerSystem
$cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
$gpu = (Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name }) -join ', '
$ramGb = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)

Write-Host ''
Write-Host "Компьютер : $($cs.Manufacturer) $($cs.Model)"
Write-Host "Процессор : $cpu"
Write-Host "Видеокарты: $gpu"
Write-Host "Память    : $ramGb ГБ"
Write-Host ''

if ($cs.Model -notmatch 'GF63' -and -not $Force) {
    Write-Warning 'Это не похоже на MSI GF63. Драйверы нужно выгружать именно с того ноутбука, на который будет ставиться Windows.'
    $answer = Read-Host 'Всё равно продолжить? (y/n)'
    if ($answer -ne 'y') { exit 1 }
}

if (Test-Path $dest) {
    Write-Host "Папка $dest уже есть - очищаю её."
    Remove-Item $dest -Recurse -Force
}
New-Item $dest -ItemType Directory -Force | Out-Null

Write-Host 'Выгружаю драйверы, это займёт 2-10 минут...'
$exported = Export-WindowsDriver -Online -Destination $dest

@(
    "Model: $($cs.Manufacturer) $($cs.Model)"
    "CPU:   $cpu"
    "GPU:   $gpu"
    "RAM:   $ramGb GB"
    "OS:    $((Get-CimInstance Win32_OperatingSystem).Caption) $([Environment]::OSVersion.Version)"
    "Date:  $(Get-Date -Format s)"
) | Set-Content (Join-Path $dest 'system-info.txt') -Encoding UTF8

$sizeGb = [math]::Round(((Get-ChildItem $dest -Recurse -File | Measure-Object Length -Sum).Sum) / 1GB, 2)

Write-Host ''
Write-Host "Готово: выгружено драйверов - $($exported.Count), размер - $sizeGb ГБ." -ForegroundColor Green
Write-Host "Папка: $dest"
Write-Host ''
Write-Host 'По классам устройств:'
$exported | Group-Object ClassName | Sort-Object Count -Descending |
    ForEach-Object { '  {0,-22} {1}' -f $_.Name, $_.Count } | Write-Host
Write-Host ''
Write-Host 'Следующий шаг: запустите 2-Build-USB.cmd'
