#Requires -Version 5.1
# Настройка Horizon (Minecraft Java 26.3, переписанный на Rust) под MSI GF63 Thin 9SCXR:
# привязывает игру к видеокарте NVIDIA, кладёт шейдерпаки в папку игры и включает
# настройки для высокого FPS. Права администратора не нужны.
#
#   Setup-Horizon.cmd                 - всё сразу (Horizon должен быть запущен хотя бы раз)
#   -DownloadOnly -PackCache <папка>  - только скачать шейдерпаки в папку
#   -Quiet                            - без подсказок; код 2, если папка игры ещё не появилась
param(
    [string]$GameDir,      # папка игры (где лежит options.txt); по умолчанию ищется автоматически
    [string]$PackCache,    # папка с уже скачанными шейдерпаками
    [switch]$DownloadOnly,
    [switch]$Quiet,
    [switch]$NoPrompt
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

function Step($text) { if (-not $Quiet) { Write-Host ''; Write-Host "=== $text" -ForegroundColor Cyan } }
function Say($text, $color = 'Gray') { if (-not $Quiet) { Write-Host $text -ForegroundColor $color } }

# Шейдерпаки с Modrinth. Скачиваются с официальных страниц авторов, в набор не входят.
$packs = @(
    @{ Slug = 'complementary-reimagined';  Name = 'Complementary Reimagined'; Note = 'красивый; включается по умолчанию' },
    @{ Slug = 'mellow';                    Name = 'Mellow';                   Note = 'лёгкий, мягкая картинка' },
    @{ Slug = 'makeup-ultra-fast-shaders'; Name = 'MakeUp - Ultra Fast';      Note = 'самый лёгкий, для максимума FPS' },
    @{ Slug = 'complementary-unbound';     Name = 'Complementary Unbound';    Note = 'самый тяжёлый' }
)
$defaultPack = 'Complementary\s*Reimagined'

function Get-Packs([string]$dir) {
    New-Item $dir -ItemType Directory -Force | Out-Null
    $headers = @{ 'User-Agent' = 'gf63-kit/1.0 (shader pack installer)' }
    $count = 0
    foreach ($pack in $packs) {
        try {
            $versions = Invoke-RestMethod -Uri "https://api.modrinth.com/v2/project/$($pack.Slug)/version" -Headers $headers
            $latest = @($versions) | Sort-Object { [datetime]$_.date_published } -Descending | Select-Object -First 1
            if (-not $latest) { throw 'нет опубликованных версий' }
            $file = @($latest.files | Where-Object primary) + @($latest.files) | Select-Object -First 1
            $target = Join-Path $dir $file.filename
            $have = (Test-Path $target) -and ((Get-FileHash $target -Algorithm SHA512).Hash -eq $file.hashes.sha512)
            if (-not $have) {
                Invoke-WebRequest -Uri $file.url -OutFile $target -Headers $headers -UseBasicParsing
                if ((Get-FileHash $target -Algorithm SHA512).Hash -ne $file.hashes.sha512) {
                    Remove-Item $target -Force
                    throw 'контрольная сумма файла не совпала'
                }
            }
            Say ("  [OK] {0} {1} - {2}" -f $pack.Name, $latest.version_number, $pack.Note) 'Green'
            $count++
        } catch {
            Write-Warning "  $($pack.Name): скачать не удалось ($($_.Exception.Message))"
        }
    }
    return $count
}

# ---------- Режим "только скачать" ----------
if ($DownloadOnly) {
    if (-not $PackCache) { throw 'Для -DownloadOnly укажите -PackCache.' }
    Step 'Скачиваю шейдерпаки'
    $n = Get-Packs $PackCache
    Say "Скачано: $n из $($packs.Count) в $PackCache"
    exit 0
}

# ---------- Папка игры ----------
Step 'Ищу Horizon'
if (-not $GameDir) {
    # Папка игры - та, где Horizon хранит свои настройки графики рядом с options.txt
    $roots = @($env:APPDATA, $env:LOCALAPPDATA, (Join-Path $env:USERPROFILE 'Documents')) | Where-Object { $_ -and (Test-Path $_) }
    $found = foreach ($root in $roots) {
        Get-ChildItem $root -Recurse -Depth 5 -Filter 'horizon-graphics.txt' -File -ErrorAction SilentlyContinue
    }
    if (-not $found) {
        # Файл настроек графики ещё не создан - берём папку с options.txt внутри каталога Horizon
        $found = foreach ($root in $roots) {
            Get-ChildItem $root -Recurse -Depth 5 -Filter 'options.txt' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match 'horizon' }
        }
    }
    $best = $found | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($best) { $GameDir = $best.DirectoryName }
}
if (-not $GameDir -or -not (Test-Path $GameDir)) {
    if ($Quiet) { exit 2 }
    $launcher = Join-Path $env:LOCALAPPDATA 'Programs\Horizon Launcher\horizon-launcher.exe'
    if (-not (Test-Path $launcher)) {
        Write-Warning 'Лаунчер Horizon не установлен. Запустите C:\GF63\Install-All.cmd - он поставит всё сам.'
    } else {
        Write-Warning 'Папка игры не найдена. Запустите Horizon до главного меню хотя бы один раз, закройте и повторите.'
    }
    exit 1
}
Say "Папка игры: $GameDir"
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
    Say "  NVIDIA -> $exe"
}

# ---------- Шейдерпаки ----------
Step 'Устанавливаю шейдерпаки'
if ($PackCache -and (Test-Path (Join-Path $PackCache '*'))) {
    Copy-Item (Join-Path $PackCache '*') $shaderDir -Force
    Say "  скопировано из $PackCache"
} else {
    [void](Get-Packs $shaderDir)
}
$installed = @(Get-ChildItem $shaderDir -File)

# ---------- Настройки графики ----------
# horizon-graphics.txt - строки "ключ:значение". Меняются только перечисленные ключи, остальное сохраняется.
# Игра перезаписывает файл при выходе, поэтому менять его можно только когда она закрыта.
Step 'Включаю настройки для высокого FPS'
if (Get-Process -Name 'horizon-client*' -ErrorAction SilentlyContinue) {
    if ($Quiet) { exit 2 }
    Write-Warning 'Horizon сейчас запущен. Закройте игру и запустите этот файл снова, чтобы применить настройки.'
} else {
    $settingsFile = Join-Path $GameDir 'horizon-graphics.txt'
    $picked = $installed | Where-Object Name -match $defaultPack | Select-Object -First 1
    $wanted = [ordered]@{
        dynamicResolution = 'true'   # игра сама снижает разрешение, когда FPS проседает
        targetFps         = '60'
        taa               = 'true'
        overlay           = 'fps'    # счётчик FPS на экране
    }
    if ($picked) { $wanted['pickedShaderPack'] = $picked.Name }
    $lines = @()
    if (Test-Path $settingsFile) {
        Copy-Item $settingsFile "$settingsFile.gf63-backup" -Force
        $lines = @(Get-Content $settingsFile | Where-Object { $key = ($_ -split ':', 2)[0]; -not $wanted.Contains($key) })
    }
    foreach ($key in $wanted.Keys) { $lines += "${key}:$($wanted[$key])" }
    # Без BOM: игра читает файл как обычный UTF-8
    [IO.File]::WriteAllLines($settingsFile, [string[]]$lines, (New-Object Text.UTF8Encoding($false)))
    foreach ($key in $wanted.Keys) { Say "  $key = $($wanted[$key])" }
}

# ---------- Итог ----------
if (-not $Quiet) {
    Write-Host ''
    Write-Host "Готово: шейдерпаков в игре - $($installed.Count)." -ForegroundColor Green
    Write-Host 'Сменить шейдер: Options - Video Settings - Shaders - Shader Packs.'
    Write-Host 'Если FPS мало: там же откройте настройки Complementary и выберите профиль Low или Potato,'
    Write-Host 'или переключитесь на Mellow / MakeUp - Ultra Fast. На General поставьте Preset: Performance.'
}
exit 0
