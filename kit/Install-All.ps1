#Requires -Version 5.1
# Ставит всё для игры одним запуском: драйвер NVIDIA (если его установщик лежит рядом),
# лаунчер Minecraft, лаунчер Horizon, шейдерпаки и фоновую донастройку Horizon.
# Запускается с флешки (START.cmd) или из C:\GF63 (Install-All.cmd).
param(
    [switch]$SkipNvidia,
    [switch]$NoPrompt
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($SkipNvidia) { $argList += '-SkipNvidia' }
    if ($NoPrompt)   { $argList += '-NoPrompt' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    exit
}

$Target = 'C:\GF63'
New-Item $Target -ItemType Directory -Force | Out-Null
Start-Transcript -Path (Join-Path $Target 'install-all.log') -Append | Out-Null
$headers = @{ 'User-Agent' = 'gf63-kit/1.0 (installer)' }
$todo = @()

function Step($text) { Write-Host ''; Write-Host "=== $text" -ForegroundColor Cyan }
function Ok($text)   { Write-Host "  [OK] $text" -ForegroundColor Green }
function Bad($text)  { Write-Host "  [!!] $text" -ForegroundColor Yellow }

# ---------- 1. Набор в C:\GF63 ----------
Step 'Обновляю набор в C:\GF63'
if ((Resolve-Path $PSScriptRoot).Path.TrimEnd('\') -ne $Target) {
    Copy-Item (Join-Path $PSScriptRoot '*') $Target -Recurse -Force
    Ok 'файлы скопированы'
} else {
    Ok 'запущено из C:\GF63'
}

# ---------- 2. Драйвер NVIDIA ----------
Step 'Драйвер NVIDIA'
$searchDirs = @($PSScriptRoot, (Split-Path $PSScriptRoot -Parent), $Target) | Sort-Object -Unique
$nvidiaExe = if ($SkipNvidia) { $null } else {
    $searchDirs | ForEach-Object { Get-ChildItem $_ -Filter '*-win10-win11-64bit-*.exe' -File -ErrorAction SilentlyContinue } |
        Sort-Object Name -Descending | Select-Object -First 1
}
if ($SkipNvidia) {
    Write-Host '  пропущено'
} elseif (-not $nvidiaExe) {
    Bad 'установщик драйвера рядом не найден - поставьте драйвер с nvidia.com вручную'
    $todo += 'Поставить драйвер NVIDIA с nvidia.com (GeForce GTX 1650, Windows 10 64-bit).'
} else {
    # Имя файла начинается с версии (621.24-...); у установленного драйвера она в последних пяти цифрах (..16.2124)
    $wanted = ($nvidiaExe.Name -split '-')[0]
    $gpu = Get-CimInstance Win32_VideoController | Where-Object Name -match 'NVIDIA' | Select-Object -First 1
    $current = ''
    if ($gpu -and $gpu.DriverVersion) {
        $digits = ($gpu.DriverVersion -replace '\.', '')
        if ($digits.Length -ge 5) { $tail = $digits.Substring($digits.Length - 5); $current = $tail.Substring(0, 3) + '.' + $tail.Substring(3) }
    }
    if ($current -eq $wanted) {
        Ok "версия $wanted уже установлена"
    } else {
        Write-Host "  ставлю $wanted (сейчас: $(if ($current) { $current } else { 'нет' })), экран может мигать, 5-10 минут..."
        $p = Start-Process $nvidiaExe.FullName -ArgumentList '-s', '-noreboot', '-clean' -Wait -PassThru
        if ($p.ExitCode -in 0, 1) { Ok "драйвер $wanted установлен" }
        else {
            Bad "установщик завершился с кодом $($p.ExitCode) - запустите его вручную: $($nvidiaExe.FullName)"
            $todo += "Запустить вручную $($nvidiaExe.Name)."
        }
    }
}

# ---------- 3. Лаунчер Minecraft ----------
Step 'Лаунчер Minecraft'
$mcExe = Join-Path ${env:ProgramFiles(x86)} 'Minecraft Launcher\MinecraftLauncher.exe'
if (Test-Path $mcExe) {
    Ok 'уже установлен'
} else {
    try {
        # Версия-MSI работает без Microsoft Store, которого нет в LTSC
        $msi = Join-Path $env:TEMP 'MinecraftInstaller.msi'
        Invoke-WebRequest 'https://launcher.mojang.com/download/MinecraftInstaller.msi' -OutFile $msi -UseBasicParsing
        $sig = Get-AuthenticodeSignature $msi
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Mojang|Microsoft') {
            throw "подпись установщика не подтверждена ($($sig.Status))"
        }
        $p = Start-Process msiexec.exe -ArgumentList '/i', "`"$msi`"", '/qn', '/norestart' -Wait -PassThru
        if ($p.ExitCode -notin 0, 3010) { throw "msiexec вернул код $($p.ExitCode)" }
        Ok 'установлен'
    } catch {
        Bad "не удалось: $($_.Exception.Message)"
        $todo += 'Скачать и установить лаунчер Minecraft с minecraft.net/download.'
    }
}

# ---------- 4. Лаунчер Horizon ----------
Step 'Лаунчер Horizon'
$hzExe = Join-Path $env:LOCALAPPDATA 'Programs\Horizon Launcher\horizon-launcher.exe'
if (Test-Path $hzExe) {
    Ok 'уже установлен'
} else {
    try {
        $releases = Invoke-RestMethod 'https://api.github.com/repos/horizon-rust/horizon/releases?per_page=40' -Headers $headers
        $asset = $releases | ForEach-Object { $_.assets } | Where-Object name -eq 'horizon-launcher-setup.exe' | Select-Object -First 1
        if (-not $asset) { throw 'в выпусках проекта нет файла horizon-launcher-setup.exe' }
        $setupExe = Join-Path $env:TEMP 'horizon-launcher-setup.exe'
        Invoke-WebRequest $asset.browser_download_url -OutFile $setupExe -Headers $headers -UseBasicParsing
        if ((Get-Item $setupExe).Length -ne $asset.size) { throw 'файл скачался не полностью' }
        $p = Start-Process $setupExe -ArgumentList 'setup', '--quiet', '--desktop-shortcut' -Wait -PassThru
        if (-not (Test-Path $hzExe)) { throw "установщик завершился с кодом $($p.ExitCode), лаунчер не появился" }
        Ok 'установлен, ярлык на рабочем столе'
    } catch {
        Bad "не удалось: $($_.Exception.Message)"
        $todo += 'Скачать и установить лаунчер Horizon с playhorizon.dev/download.'
    }
}

# ---------- 5. Шейдерпаки ----------
Step 'Шейдерпаки'
$cache = Join-Path $Target 'shaderpacks'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Target 'Setup-Horizon.ps1') -DownloadOnly -PackCache $cache | Out-Host

# ---------- 6. Minecraft Java на NVIDIA ----------
Step 'Видеокарта для Minecraft Java'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Target 'Setup-Minecraft.ps1') *> $null
Write-Host '  привязка к NVIDIA применится автоматически после первого запуска игры'

# ---------- 7. Фоновая донастройка Horizon ----------
Step 'Донастройка Horizon'
$watch = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Target\Horizon-Watch.ps1`""
New-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'GF63Horizon' -Value $watch -PropertyType String -Force | Out-Null
if (-not $NoPrompt) {
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$Target\Horizon-Watch.ps1`""
}
Ok 'шейдеры и настройки встанут сами после первого запуска Horizon'

# ---------- Итог ----------
Write-Host ''
Write-Host 'УСТАНОВКА ЗАВЕРШЕНА.' -ForegroundColor Green
Write-Host ''
Write-Host 'Осталось то, что может сделать только владелец аккаунта:'
Write-Host '  1. Откройте Minecraft Launcher, войдите в свой аккаунт Microsoft (с купленной Java Edition),'
Write-Host '     выберите версию 26.3, нажмите Play, дождитесь главного меню и закройте игру.'
Write-Host '  2. Откройте Horizon Launcher (ярлык на рабочем столе), нажмите Play, дождитесь главного меню и закройте игру.'
Write-Host '  3. Через полминуты появится окно "Horizon настроен". После этого просто играйте.'
if ($todo.Count) {
    Write-Host ''
    Write-Host 'Не получилось автоматически, сделайте вручную:' -ForegroundColor Yellow
    $todo | ForEach-Object { Write-Host "  - $_" }
}
Write-Host ''
Stop-Transcript | Out-Null
if (-not $NoPrompt) { Read-Host 'Нажмите Enter для выхода' }
exit 0
