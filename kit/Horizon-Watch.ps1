#Requires -Version 5.1
# Ждёт в фоне, пока Horizon будет запущен в первый раз и закрыт, затем сам ставит в него
# шейдерпаки и настройки (Setup-Horizon.ps1) и убирает себя из автозапуска.
# Запускается из Install-All.ps1 и при каждом входе в систему, пока не выполнит работу.
param(
    [switch]$Once,           # одна попытка без ожидания (для автоматических тестов)
    [int]$MaxHours = 12
)

$ErrorActionPreference = 'Continue'
$here   = $PSScriptRoot
$setup  = Join-Path $here 'Setup-Horizon.ps1'
$cache  = Join-Path $here 'shaderpacks'
$runKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$log    = Join-Path $here 'horizon-watch.log'
$deadline = (Get-Date).AddHours($MaxHours)

while ($true) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup -Quiet -PackCache $cache *>> $log
    if ($LASTEXITCODE -eq 0) {
        Remove-ItemProperty -Path $runKey -Name 'GF63Horizon' -ErrorAction SilentlyContinue
        # К этому моменту обычный Minecraft Java уже установлен - привязываем к NVIDIA и его
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'Setup-Minecraft.ps1') *>> $log
        "$(Get-Date -Format s) Horizon configured" | Add-Content $log
        if (-not $Once) {
            Add-Type -AssemblyName System.Windows.Forms
            [void][System.Windows.Forms.MessageBox]::Show(
                "Horizon настроен: видеокарта NVIDIA, шейдеры и счётчик FPS включены.`nЗапускайте игру.",
                'GF63')
        }
        exit 0
    }
    if ($Once -or (Get-Date) -gt $deadline) { exit 2 }
    Start-Sleep -Seconds 20
}
