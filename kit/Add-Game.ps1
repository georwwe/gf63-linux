#Requires -Version 5.1
# Заставляет любую игру работать на видеокарте NVIDIA, а не на встроенной Intel.
# Перетащите .exe игры (или папку с игрой) на Add-Game.cmd, либо запустите без аргументов.
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Path)

$ErrorActionPreference = 'Stop'
$gpuKey = 'HKCU:\SOFTWARE\Microsoft\DirectX\UserGpuPreferences'
if (-not (Test-Path $gpuKey)) { New-Item $gpuKey -Force | Out-Null }

if (-not $Path -or $Path.Count -eq 0) {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = 'Выберите .exe игры'
    $dialog.Filter = 'Программы (*.exe)|*.exe'
    $dialog.Multiselect = $true
    if ($dialog.ShowDialog() -ne 'OK') { exit 1 }
    $Path = $dialog.FileNames
}

$targets = @()
foreach ($item in $Path) {
    if (-not (Test-Path -LiteralPath $item)) { Write-Warning "Не найдено: $item"; continue }
    if ((Get-Item -LiteralPath $item).PSIsContainer) {
        # Папка игры: все .exe до трёх уровней вглубь, кроме установщиков и средств удаления
        $targets += Get-ChildItem -LiteralPath $item -Recurse -Depth 3 -Filter '*.exe' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '^(unins|setup|install|crashpad|crashhandler|vc_redist|dxsetup|uninstall)' } |
            ForEach-Object FullName
    } elseif ($item -like '*.exe') {
        $targets += (Resolve-Path -LiteralPath $item).Path
    }
}

$targets = @($targets | Sort-Object -Unique)
if ($targets.Count -eq 0) { Write-Warning 'Подходящих .exe не найдено.'; exit 1 }

foreach ($exe in $targets) {
    # GpuPreference=2 - "Высокая производительность" (дискретная видеокарта)
    New-ItemProperty -Path $gpuKey -Name $exe -Value 'GpuPreference=2;' -PropertyType String -Force | Out-Null
    Write-Host "  NVIDIA -> $exe"
}
Write-Host ''
Write-Host "Готово: игр и файлов привязано к NVIDIA - $($targets.Count)." -ForegroundColor Green
exit 0
