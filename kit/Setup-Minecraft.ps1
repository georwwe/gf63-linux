#Requires -Version 5.1
# Заставляет Minecraft (Java и Bedrock) работать на видеокарте NVIDIA GTX 1650,
# а не на встроенной Intel. Запускать ПОСЛЕ установки Minecraft и первого запуска игры.
# Права администратора не нужны: настройка хранится в профиле пользователя.

$ErrorActionPreference = 'Stop'
$gpuKey = 'HKCU:\SOFTWARE\Microsoft\DirectX\UserGpuPreferences'
if (-not (Test-Path $gpuKey)) { New-Item $gpuKey -Force | Out-Null }

$roots = @(
    "$env:APPDATA\.minecraft\runtime",
    "$env:LOCALAPPDATA\Packages\Microsoft.4297127D64EC6_8wekyb3d8bbwe\LocalCache\Local\runtime",
    "${env:ProgramFiles(x86)}\Minecraft Launcher\runtime",
    "$env:APPDATA\.tlauncher",
    "$env:APPDATA\PrismLauncher\java",
    "$env:APPDATA\ModrinthApp\meta\java_versions",
    "$env:ProgramFiles\Java",
    "$env:ProgramFiles\Eclipse Adoptium",
    "$env:ProgramFiles\Microsoft",
    "$env:ProgramFiles\Zulu"
) | Where-Object { $_ -and (Test-Path $_) }

$targets = @()
foreach ($root in $roots) {
    $targets += Get-ChildItem $root -Recurse -Include javaw.exe, java.exe -File -ErrorAction SilentlyContinue |
        ForEach-Object { $_.FullName }
}

# Minecraft Bedrock (версия из Microsoft Store)
$bedrock = Get-AppxPackage -Name 'Microsoft.MinecraftUWP' -ErrorAction SilentlyContinue
if ($bedrock) {
    $exe = Join-Path $bedrock.InstallLocation 'Minecraft.Windows.exe'
    if (Test-Path $exe) { $targets += $exe }
}

$targets = @($targets | Sort-Object -Unique)
if ($targets.Count -eq 0) {
    Write-Warning 'Minecraft и Java не найдены. Установите игру, запустите её один раз и повторите.'
    exit 1
}

foreach ($path in $targets) {
    # GpuPreference=2 - "Высокая производительность" (дискретная видеокарта)
    New-ItemProperty -Path $gpuKey -Name $path -Value 'GpuPreference=2;' -PropertyType String -Force | Out-Null
    Write-Host "  NVIDIA -> $path"
}

Write-Host ''
Write-Host "Готово: настроено файлов - $($targets.Count)." -ForegroundColor Green
Write-Host ''
Write-Host 'Проверка: в игре нажмите F3 - справа должно быть "GeForce GTX 1650", а не "Intel UHD".'
Write-Host ''
Write-Host 'Чтобы получить максимум FPS в Java-версии:'
Write-Host '  1. Поставьте Iris (irisshaders.dev) - установщик сам добавит Sodium. Это замена OptiFine,'
Write-Host '     без шейдеров даёт в 2-4 раза больше FPS, с шейдерами - заметно больше, чем OptiFine.'
Write-Host '  2. Добавьте моды Lithium, FerriteCore, ImmediatelyFast, EntityCulling (modrinth.com).'
Write-Host '  3. В лаунчере: Установки - Редактировать - Ещё - Аргументы JVM, замените -Xmx2G на -Xmx4G.'
Write-Host '     Больше 4 ГБ при 8 ГБ памяти ставить не надо - станет хуже.'
Write-Host '  4. В игре: дальность прорисовки 8-12 чанков, с шейдерами - профиль Low или Medium.'
Write-Host '  5. Играйте от сети и включайте Cooler Boost (кнопка с вентилятором на клавиатуре).'
