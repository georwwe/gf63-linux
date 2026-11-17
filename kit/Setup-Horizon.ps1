#Requires -Version 5.1
# Настройка Horizon (Minecraft Java 26.3, переписанный на Rust) под MSI GF63 Thin 9SCXR:
# привязывает игру к видеокарте NVIDIA и скачивает шейдерпаки в папку игры.
# Запускать ПОСЛЕ того, как Horizon установлен и хотя бы раз запущен до главного меню.
# Права администратора не нужны.
param(
    [string]$GameDir,   # папка игры (где лежит options.txt); по умолчанию ищется автоматически
    [switch]$NoPrompt
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

function Step($text) { Write-Host ''; Write-Host "=== $text" -ForegroundColor Cyan }

# Шейдерпаки с Modrinth. Скачиваются с официальных страниц авторов, в набор не входят.
$packs = @(
    @{ Slug = 'makeup-ultra-fast-shaders'; Name = 'MakeUp - Ultra Fast';      Note = 'самый лёгкий, для максимума FPS' },
    @{ Slug = 'mellow';                    Name = 'Mellow';                   Note = 'лёгкий, мягкая картинка' },
    @{ Slug = 'complementary-reimagined';  Name = 'Complementary Reimagined'; Note = 'красивый; ставьте профиль Low или Potato' },
    @{ Slug = 'complementary-unbound';     Name = 'Complementary Unbound';    Note = 'самый тяжёлый; только профиль Potato/Low' }
)

# ---------- Лаунчер ----------
Step 'Ищу Horizon'
$launcher = Join-Path $env:LOCALAPPDATA 'Programs\Horizon Launcher\horizon-launcher.exe'
if (-not $GameDir -and -not (Test-Path $launcher)) {
    Write-Warning 'Лаунчер Horizon не установлен.'
    Write-Host '  1. Установите и один раз запустите обычный Minecraft: Java Edition версии 26.3 (нужна лицензия).'
    Write-Host '  2. Скачайте лаунчер Horizon с https://playhorizon.dev/download и установите его.'
    Write-Host '  3. Запустите игру через лаунчер до главного меню, закройте её.'
    Write-Host '  4. Запустите этот файл ещё раз.'
    if (-not $NoPrompt) { Start-Process 'https://playhorizon.dev/download' }
    exit 1
}

# ---------- Папка игры ----------
if (-not $GameDir) {
    # Папка игры - та, где Horizon хранит свои настройки графики рядом с options.txt
    $roots = @($env:APPDATA, $env:LOCALAPPDATA, (Join-Path $env:USERPROFILE 'Documents')) | Where-Object { $_ -and (Test-Path $_) }
    $found = foreach ($root in $roots) {
        Get-ChildItem $root -Recurse -Depth 5 -Filter 'horizon-graphics.txt' -File -ErrorAction SilentlyContinue
    }
    $best = $found | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($best) { $GameDir = $best.DirectoryName }
}
if (-not $GameDir -or -not (Test-Path $GameDir)) {
    Write-Warning 'Папка игры не найдена. Запустите Horizon до главного меню хотя бы один раз.'
    Write-Host 'Если уже запускали: в игре откройте Options - Video Settings - Shaders - Shader Packs - Open Pack Folder,'
    Write-Host 'скопируйте путь из адресной строки без "\shaderpacks" в конце и запустите:'
    Write-Host '  powershell -ExecutionPolicy Bypass -File C:\GF63\Setup-Horizon.ps1 -GameDir "путь"'
    exit 1
}
Write-Host "Папка игры: $GameDir"
$shaderDir = Join-Path $GameDir 'shaderpacks'
New-Item $shaderDir -ItemType Directory -Force | Out-Null

# ---------- Видеокарта ----------
Step 'Привязываю Horizon к видеокарте NVIDIA'
$gpuKey = 'HKCU:\SOFTWARE\Microsoft\DirectX\UserGpuPreferences'
if (-not (Test-Path $gpuKey)) { New-Item $gpuKey -Force | Out-Null }
$exeRoots = @((Join-Path $env:LOCALAPPDATA 'Programs\Horizon Launcher'), (Join-Path $env:APPDATA 'horizon-launcher'), $GameDir) |
    Where-Object { Test-Path $_ }
$exes = @(foreach ($root in $exeRoots) {
    Get-ChildItem $root -Recurse -Depth 6 -Include 'horizon-client*.exe', 'horizon-launcher.exe' -File -ErrorAction SilentlyContinue
}) | ForEach-Object FullName | Sort-Object -Unique
foreach ($exe in $exes) {
    New-ItemProperty -Path $gpuKey -Name $exe -Value 'GpuPreference=2;' -PropertyType String -Force | Out-Null
    Write-Host "  NVIDIA -> $exe"
}
if (-not $exes) { Write-Warning '  Файлы игры не найдены - запустите этот скрипт ещё раз после первого запуска Horizon.' }

# ---------- Шейдерпаки ----------
Step 'Скачиваю шейдерпаки'
$headers = @{ 'User-Agent' = 'gf63-kit/1.0 (shader pack installer)' }
$installed = @()
foreach ($pack in $packs) {
    try {
        $versions = Invoke-RestMethod -Uri "https://api.modrinth.com/v2/project/$($pack.Slug)/version" -Headers $headers
        $latest = @($versions) | Sort-Object { [datetime]$_.date_published } -Descending | Select-Object -First 1
        if (-not $latest) { throw 'нет опубликованных версий' }
        $file = @($latest.files | Where-Object primary) + @($latest.files) | Select-Object -First 1
        $target = Join-Path $shaderDir $file.filename
        $have = (Test-Path $target) -and ((Get-FileHash $target -Algorithm SHA512).Hash -eq $file.hashes.sha512)
        if (-not $have) {
            Invoke-WebRequest -Uri $file.url -OutFile $target -Headers $headers -UseBasicParsing
            $hash = (Get-FileHash $target -Algorithm SHA512).Hash
            if ($hash -ne $file.hashes.sha512) {
                Remove-Item $target -Force
                throw 'контрольная сумма файла не совпала'
            }
        }
        Write-Host ("  [OK] {0} {1} - {2}" -f $pack.Name, $latest.version_number, $pack.Note) -ForegroundColor Green
        $installed += $pack.Name
    } catch {
        Write-Warning "  $($pack.Name): скачать не удалось ($($_.Exception.Message))"
    }
}

# ---------- Итог ----------
Write-Host ''
Write-Host "Готово: шейдерпаков установлено - $($installed.Count) из $($packs.Count)." -ForegroundColor Green
Write-Host "Папка: $shaderDir"
Write-Host ''
Write-Host 'Что настроить в игре (Options - Video Settings):'
Write-Host '  1. General - Preset: Performance. С тяжёлым шейдером - Full Performance.'
Write-Host '  2. Shaders - Shader Packs: выберите пак. Начните с MakeUp - Ultra Fast или Mellow.'
Write-Host '     У Complementary откройте его настройки и поставьте профиль Low или Potato.'
Write-Host '  3. Quality - Dynamic Resolution: On, Target FPS: 60. Игра сама снизит разрешение, когда FPS проседает.'
Write-Host '  4. Quality - Anti-aliasing: TAA, Upscaling: Quality. Это главный прирост FPS с шейдерами.'
Write-Host '  5. Advanced - Performance overlay: On, чтобы видеть FPS.'
Write-Host ''
Write-Host 'Шейдеров "от GeForce" для этой игры нет: RTX-режим существует только в Minecraft Bedrock'
Write-Host 'и требует видеокарту RTX, а у этого ноутбука GTX 1650.'
exit 0
