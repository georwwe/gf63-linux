#Requires -Version 5.1
# Шаг 2. Берёт официальный ISO Windows 10 Enterprise LTSC 2021, встраивает в него
# драйверы из папки drivers и набор оптимизации из папки kit, затем записывает
# установочную флешку. Сам ISO-файл не изменяется.
param(
    [string]$IsoPath,
    [string]$UsbDrive,
    [string]$DriversPath,
    [string]$WorkDir,
    [int]$Index = 0,
    [switch]$NoSlim,       # не удалять лишние компоненты из образа
    [switch]$NoPrompt,     # без подтверждения (для автоматических тестов)
    [switch]$AllowNonUsb   # разрешить запись не на USB (только для автоматических тестов)
)

$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$PSCommandPath`"")
    exit
}

$root = Split-Path -Parent $PSScriptRoot
$kit  = Join-Path $root 'kit'
if (-not $DriversPath) { $DriversPath = Join-Path $root 'drivers' }
if (-not $WorkDir)     { $WorkDir     = Join-Path $root 'work' }
$media = Join-Path $WorkDir 'media'
$mount = Join-Path $WorkDir 'mount'

function Step($text) { Write-Host ''; Write-Host "=== $text" -ForegroundColor Cyan }

# ---------- Проверки ----------
if (-not (Test-Path (Join-Path $DriversPath '*'))) {
    throw "Папка с драйверами пуста или не найдена: $DriversPath. Сначала запустите 1-Export-Drivers.cmd."
}

if (-not $IsoPath) {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title  = 'Выберите ISO Windows 10 Enterprise LTSC 2021'
    $dialog.Filter = 'ISO (*.iso)|*.iso'
    if ($dialog.ShowDialog() -ne 'OK') { throw 'ISO-файл не выбран.' }
    $IsoPath = $dialog.FileName
}
if (-not (Test-Path $IsoPath)) { throw "ISO не найден: $IsoPath" }

New-Item $WorkDir -ItemType Directory -Force | Out-Null
$workVolume = Get-Volume -DriveLetter ((Resolve-Path $WorkDir).Path.Substring(0, 1))
if ($workVolume.SizeRemaining -lt 20GB) {
    throw "На диске $($workVolume.DriveLetter): меньше 20 ГБ свободного места. Освободите место и запустите снова."
}

# ---------- Выбор флешки (до долгой работы, чтобы потом не ждать) ----------
function Get-UsbVolume($letter) {
    $part = Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue
    if (-not $part) { return $null }
    $disk = Get-Disk -Number $part.DiskNumber
    if ($disk.BusType -ne 'USB' -and -not $AllowNonUsb) { return $null }
    [pscustomobject]@{ Letter = $letter; Disk = $disk; Volume = (Get-Volume -DriveLetter $letter) }
}

if (-not $UsbDrive) {
    $candidates = Get-Disk | Where-Object BusType -eq 'USB' | Get-Partition |
        Where-Object DriveLetter | ForEach-Object { Get-UsbVolume $_.DriveLetter }
    if (-not $candidates) { throw 'USB-флешка не найдена. Вставьте флешку от 8 ГБ и запустите снова.' }
    Write-Host ''
    Write-Host 'Найденные USB-накопители:'
    foreach ($c in $candidates) {
        '  {0}:  {1}  {2:N0} ГБ  метка "{3}"' -f $c.Letter, $c.Disk.FriendlyName,
            ($c.Disk.Size / 1GB), $c.Volume.FileSystemLabel | Write-Host
    }
    $UsbDrive = Read-Host 'Введите букву флешки (например E)'
}
$UsbDrive = $UsbDrive.Trim().TrimEnd(':').ToUpper()
$usb = Get-UsbVolume $UsbDrive
if (-not $usb) { throw "Диск ${UsbDrive}: не является USB-накопителем. Для безопасности запись разрешена только на USB." }
if ($usb.Disk.Size -lt 7GB) { throw 'Флешка слишком маленькая, нужно минимум 8 ГБ.' }

Write-Host ''
Write-Warning ("ВСЕ ДАННЫЕ на флешке {0}: ({1}, {2:N0} ГБ) будут УДАЛЕНЫ." -f $UsbDrive, $usb.Disk.FriendlyName, ($usb.Disk.Size / 1GB))
if (-not $NoPrompt -and (Read-Host 'Чтобы продолжить, введите YES') -cne 'YES') { throw 'Отменено.' }

# ---------- Распаковка ISO ----------
Step 'Распаковываю ISO'
foreach ($dir in $media, $mount) {
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    New-Item $dir -ItemType Directory -Force | Out-Null
}
$image = Mount-DiskImage -ImagePath $IsoPath -PassThru
try {
    $isoLetter = ($image | Get-Volume).DriveLetter
    robocopy "${isoLetter}:\" $media /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Не удалось скопировать содержимое ISO (robocopy $LASTEXITCODE)." }
} finally {
    Dismount-DiskImage -ImagePath $IsoPath | Out-Null
}
attrib -R "$media\*" /S /D | Out-Null

$wim = Join-Path $media 'sources\install.wim'
if (-not (Test-Path $wim)) {
    throw 'В образе нет sources\install.wim. Нужен оригинальный ISO Windows 10 Enterprise LTSC 2021 (не ESD-сборка).'
}

# ---------- Выбор редакции ----------
$images = @(Get-WindowsImage -ImagePath $wim)
if ($Index -eq 0) {
    if ($images.Count -eq 1) {
        $Index = $images[0].ImageIndex
    } else {
        Write-Host 'В образе несколько редакций:'
        $images | ForEach-Object { '  {0}: {1}' -f $_.ImageIndex, $_.ImageName | Write-Host }
        $Index = [int](Read-Host 'Введите номер нужной редакции')
    }
}
$chosen = $images | Where-Object ImageIndex -eq $Index
if (-not $chosen) { throw "Редакции с номером $Index в образе нет." }
Write-Host "Редакция: $($chosen.ImageName)"
if ($chosen.ImageName -notmatch 'LTSC') {
    Write-Warning 'Это не LTSC-редакция. Набор рассчитан на Windows 10 Enterprise LTSC 2021, на других возможны отличия.'
}
$detail = Get-WindowsImage -ImagePath $wim -Index $Index
Write-Host "Версия: $($detail.Version), архитектура: $($detail.Architecture)"
if ("$($detail.Version)" -notmatch '^10\.0\.19044') {
    Write-Warning 'Это не сборка 19044 (LTSC 2021). Скрипт продолжит работу, но рассчитан на LTSC 2021.'
}

# ---------- Встраивание драйверов и набора ----------
Step 'Встраиваю драйверы в install.wim (10-20 минут)'
Mount-WindowsImage -ImagePath $wim -Index $Index -Path $mount | Out-Null
$saved = $false
try {
    try {
        $added = Add-WindowsDriver -Path $mount -Driver $DriversPath -Recurse
        Write-Host "Добавлено драйверов: $(@($added).Count)"
    } catch {
        Write-Warning "Часть драйверов не добавилась: $($_.Exception.Message)"
        Write-Warning 'Продолжаю: остальные драйверы добавлены, недостающие Windows поставит через Центр обновления.'
    }

    if (-not $NoSlim) {
        Step 'Убираю из образа ненужные компоненты'
        # Только то, что не нужно для игр. Медиа-кодеки, .NET, DirectX, Store-службы не трогаются.
        $features = @(
            'Internet-Explorer-Optional-amd64',   # Internet Explorer 11
            'WorkFolders-Client',                 # рабочие папки (корпоративная функция)
            'Printing-XPSServices-Features',      # печать в XPS
            'SMB1Protocol',                       # устаревший небезопасный сетевой протокол
            'MicrosoftWindowsPowerShellV2Root',   # старый PowerShell 2.0
            'FaxServicesClientPackage'            # факсы
        )
        $present = @(Get-WindowsOptionalFeature -Path $mount | Where-Object State -eq 'Enabled' | ForEach-Object FeatureName)
        foreach ($feature in $features) {
            if ($present -notcontains $feature) { continue }
            try {
                Disable-WindowsOptionalFeature -Path $mount -FeatureName $feature | Out-Null
                Write-Host "  отключено: $feature"
            } catch { Write-Warning "  не удалось отключить ${feature}: $($_.Exception.Message)" }
        }
        $capPattern = '^(App\.StepsRecorder|App\.Support\.QuickAssist|Browser\.InternetExplorer|Hello\.Face|MathRecognizer|Print\.Fax\.Scan)'
        $caps = @(Get-WindowsCapability -Path $mount | Where-Object { $_.State -eq 'Installed' -and $_.Name -match $capPattern })
        foreach ($cap in $caps) {
            try {
                Remove-WindowsCapability -Path $mount -Name $cap.Name | Out-Null
                Write-Host "  удалено: $($cap.Name)"
            } catch { Write-Warning "  не удалось удалить $($cap.Name): $($_.Exception.Message)" }
        }
    }

    Step 'Копирую набор оптимизации в C:\GF63'
    $kitTarget = Join-Path $mount 'GF63'
    New-Item $kitTarget -ItemType Directory -Force | Out-Null
    Copy-Item (Join-Path $kit '*') $kitTarget -Recurse -Force

    # Автозапуск оптимизации при первом входе в систему
    $hive = Join-Path $mount 'Windows\System32\config\SOFTWARE'
    reg.exe load 'HKLM\GF63SOFT' $hive | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Не удалось загрузить реестр образа.' }
    try {
        reg.exe add 'HKLM\GF63SOFT\Microsoft\Windows\CurrentVersion\RunOnce' /v GF63Optimize /t REG_SZ /d 'C:\GF63\Optimize.cmd' /f | Out-Null
    } finally {
        [gc]::Collect()
        reg.exe unload 'HKLM\GF63SOFT' | Out-Null
    }

    Step 'Проверяю образ перед сохранением'
    if (-not (Test-Path (Join-Path $kitTarget 'Optimize-Windows.ps1'))) { throw 'Набор оптимизации не попал в образ.' }
    $inImage = @(Get-WindowsDriver -Path $mount)
    Write-Host "  сторонних драйверов в образе: $($inImage.Count)"
    $inImage | Group-Object ClassName | Sort-Object Count -Descending |
        ForEach-Object { '    {0,-22} {1}' -f $_.Name, $_.Count } | Write-Host
    if ($inImage.Count -eq 0) { throw 'В образ не добавлен ни один драйвер.' }
    foreach ($class in 'Display', 'Net', 'MEDIA') {
        if (-not ($inImage | Where-Object ClassName -eq $class)) {
            Write-Warning "  в образе нет драйверов класса $class - после установки это устройство может не работать до обновления Windows."
        }
    }

    Step 'Сохраняю install.wim'
    Dismount-WindowsImage -Path $mount -Save | Out-Null
    $saved = $true
} finally {
    if (-not $saved) {
        Write-Warning 'Произошла ошибка - отменяю изменения образа.'
        Dismount-WindowsImage -Path $mount -Discard -ErrorAction SilentlyContinue | Out-Null
    }
}

# ---------- Драйверы дисков в установщик (чтобы он видел SSD) ----------
$storageInfs = @(Get-ChildItem $DriversPath -Recurse -Filter *.inf |
    Where-Object { Select-String -Path $_.FullName -Pattern '^\s*Class\s*=\s*(SCSIAdapter|HDC)\b' -Quiet })
if ($storageInfs.Count -gt 0) {
    Step "Добавляю драйверы дисков в установщик ($($storageInfs.Count) шт.)"
    $bootWim = Join-Path $media 'sources\boot.wim'
    try {
        Mount-WindowsImage -ImagePath $bootWim -Index 2 -Path $mount | Out-Null
        foreach ($inf in $storageInfs) {
            try { Add-WindowsDriver -Path $mount -Driver $inf.FullName | Out-Null }
            catch { Write-Warning "Пропущен $($inf.Name): $($_.Exception.Message)" }
        }
        Dismount-WindowsImage -Path $mount -Save | Out-Null
    } catch {
        Write-Warning "Не удалось обновить boot.wim: $($_.Exception.Message). Это не критично."
        Dismount-WindowsImage -Path $mount -Discard -ErrorAction SilentlyContinue | Out-Null
    }
}

# ---------- Подготовка флешки ----------
Step "Форматирую флешку ${UsbDrive}:"
$diskNumber = $usb.Disk.Number
try {
    Clear-Disk -Number $diskNumber -RemoveData -RemoveOEM -Confirm:$false
    Initialize-Disk -Number $diskNumber -PartitionStyle MBR -ErrorAction SilentlyContinue
    # FAT32 нужен для загрузки UEFI; Windows форматирует в FAT32 разделы до 32 ГБ
    $partSize = [math]::Min((Get-Disk -Number $diskNumber).LargestFreeExtent, 30GB)
    $part = New-Partition -DiskNumber $diskNumber -Size $partSize -IsActive -DriveLetter $UsbDrive
    Format-Volume -Partition $part -FileSystem FAT32 -NewFileSystemLabel 'GF63WIN' -Confirm:$false | Out-Null
} catch {
    throw "Не удалось отформатировать флешку: $($_.Exception.Message). Отформатируйте её вручную в FAT32 (Проводник - правый клик - Форматировать) и запустите скрипт снова."
}

# ---------- Запись ----------
Step 'Записываю файлы на флешку (10-30 минут)'
robocopy $media "${UsbDrive}:\" /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP /XF install.wim | Out-Null
if ($LASTEXITCODE -ge 8) { throw "Ошибка копирования на флешку (robocopy $LASTEXITCODE)." }

$usbSources = "${UsbDrive}:\sources"
if ((Get-Item $wim).Length -gt 3800MB) {
    # FAT32 не хранит файлы больше 4 ГБ, поэтому образ делится на части;
    # установщик Windows собирает install.swm сам
    Split-WindowsImage -ImagePath $wim -SplitImagePath (Join-Path $usbSources 'install.swm') -FileSize 3800 -CheckIntegrity | Out-Null
} else {
    Copy-Item $wim $usbSources
}

Step 'Убираю временные файлы'
Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host 'ГОТОВО. Установочная флешка записана.' -ForegroundColor Green
Write-Host ''
Write-Host 'Дальше:'
Write-Host '  1. Сохраните свои важные файлы на другой диск - установка сотрёт системный раздел.'
Write-Host '  2. Перезагрузите ноутбук и сразу нажимайте F11 - откроется меню загрузки. Выберите флешку.'
Write-Host '  3. Установите Windows как обычно. Драйверы поставятся сами.'
Write-Host '  4. При первом входе оптимизация запустится автоматически (нажмите "Да" на запрос).'
