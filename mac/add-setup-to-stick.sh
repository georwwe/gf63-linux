#!/bin/bash
# Кладёт на флешку всё для автоматической установки игр на ноутбуке:
# набор скриптов, файл START.cmd и установщик драйвера NVIDIA из "Загрузок" (если он там есть).
# Подходит любая внешняя флешка. Если она уже читается в Windows (FAT32/exFAT), её
# содержимое не трогается; иначе скрипт спросит разрешение и отформатирует её в exFAT.
#
#   bash add-setup-to-stick.sh [путь-к-флешке]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
fail() { printf '\nОШИБКА: %s\n' "$1" >&2; exit 1; }

STICK="${1:-${GF63_STICK:-}}"

mount_point() { diskutil info "$1" 2>/dev/null | sed -n 's/^ *Mount Point: *//p'; }
fs_kind()     { diskutil info "$1" 2>/dev/null | sed -n 's/^ *File System Personality: *//p'; }

if [ -z "$STICK" ]; then
    # 1. Флешка с установщиком Windows, если она есть
    for v in /Volumes/*; do
        if [ -f "$v/sources/boot.wim" ]; then STICK="$v"; break; fi
    done
fi

if [ -z "$STICK" ]; then
    # 2. Любая внешняя флешка
    DISKS="$(diskutil list external physical | sed -n 's|^/dev/\(disk[0-9]*\) .*|\1|p')"
    COUNT="$(printf '%s\n' "$DISKS" | grep -c . || true)"
    [ "$COUNT" -gt 0 ] || fail "Внешняя флешка не найдена. Вставьте флешку в Mac и запустите снова."
    if [ "$COUNT" -gt 1 ]; then
        echo
        echo "Найдено несколько внешних дисков:"
        diskutil list external physical
        printf 'Введите имя нужной флешки (например disk4):\n> '
        read -r DISK
        DISK="${DISK#/dev/}"
        printf '%s\n' "$DISKS" | grep -qx "$DISK" || fail "$DISK нет среди внешних дисков."
    else
        DISK="$DISKS"
    fi
    INFO="$(diskutil info "$DISK")"
    BYTES="$(echo "$INFO" | sed -n 's/.*Disk Size:.*(\([0-9]*\) Bytes).*/\1/p' | head -1)"
    NAME="$(echo "$INFO" | sed -n 's/.*Device \/ Media Name: *//p' | head -1)"
    [ -n "$BYTES" ] && [ "$BYTES" -le 300000000000 ] || fail "$DISK больше 300 ГБ - это не похоже на флешку. Остановлено для безопасности."
    echo "Флешка: $DISK ($NAME, $((BYTES / 1000000000)) ГБ)"

    # Подходящий том: подключён и читается в Windows (FAT32 или exFAT)
    for part in $(diskutil list "$DISK" | sed -n "s/.* \(${DISK}s[0-9]*\)\$/\1/p"); do
        case "$(fs_kind "$part")" in
            MS-DOS*|ExFAT)
                [ -n "$(mount_point "$part")" ] || diskutil mount "$part" >/dev/null 2>&1 || true
                STICK="$(mount_point "$part")"
                [ -n "$STICK" ] && break ;;
        esac
    done

    if [ -z "$STICK" ]; then
        # Флешка пустая или в формате, который Windows не читает - форматируем в exFAT
        echo
        echo "Флешку нужно отформатировать, чтобы её увидела Windows."
        echo "ВНИМАНИЕ: ВСЕ ДАННЫЕ на $DISK ($NAME, $((BYTES / 1000000000)) ГБ) будут УДАЛЕНЫ."
        if [ "${GF63_NO_PROMPT:-}" != "1" ]; then
            printf 'Чтобы продолжить, введите YES: '
            read -r ANSWER
            [ "$ANSWER" = "YES" ] || fail "Отменено."
        fi
        diskutil eraseDisk ExFAT GF63 MBR "/dev/$DISK"
        [ -n "$(mount_point "${DISK}s1")" ] || diskutil mount "${DISK}s1" >/dev/null 2>&1 || true
        STICK="$(mount_point "${DISK}s1")"
        [ -n "$STICK" ] || fail "Флешка не подключилась после форматирования. Выньте её, вставьте снова и запустите ещё раз."
    fi
fi
[ -d "$STICK" ] || fail "Папка флешки не найдена: $STICK"
[ -w "$STICK" ] || fail "На флешку $STICK нельзя записать."
[ -f "$ROOT/kit/Install-All.ps1" ] || fail "Не найдена папка kit рядом со скриптом."

echo "Флешка: $STICK"
DEST="$STICK/GF63-SETUP"
rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$ROOT/kit/." "$DEST/"
cp "$HERE/START.cmd" "$STICK/START.cmd"
# Командные файлы Windows должны иметь окончания строк CRLF
for f in "$DEST"/*.cmd "$STICK/START.cmd"; do perl -pi -e 's/\r?\n/\r\n/' "$f"; done
echo "  набор скопирован в GF63-SETUP, START.cmd лежит в корне флешки"

# Установщик драйвера NVIDIA: берём самый новый из "Загрузок"
DRIVER="$(ls -t "${GF63_DOWNLOADS:-$HOME/Downloads}"/*-win10-win11-64bit-*.exe 2>/dev/null | head -1 || true)"
if [ -n "$DRIVER" ]; then
    NAME="$(basename "$DRIVER")"
    if [ -f "$STICK/$NAME" ] && [ "$(stat -f %z "$STICK/$NAME")" = "$(stat -f %z "$DRIVER")" ]; then
        echo "  драйвер NVIDIA уже на флешке: $NAME"
    else
        echo "  копирую драйвер NVIDIA: $NAME (около 1 ГБ, пара минут)..."
        cp "$DRIVER" "$STICK/$NAME"
    fi
else
    echo "  драйвер NVIDIA в Загрузках не найден - на ноутбуке его придётся поставить вручную с nvidia.com"
fi

find "$STICK/GF63-SETUP" -name '.DS_Store' -delete 2>/dev/null || true
dot_clean -m "$STICK" 2>/dev/null || true
sync
DISK="$(diskutil info "$STICK" 2>/dev/null | sed -n 's/^ *Part of Whole: *//p')"
if [ -n "$DISK" ] && [ "${GF63_NO_EJECT:-}" != "1" ]; then diskutil eject "/dev/$DISK" >/dev/null 2>&1 || true; fi

cat <<'DONE'

ГОТОВО. Флешку можно вынимать.

На ноутбуке MSI:
  1. Вставьте флешку.
  2. Откройте её в Проводнике (This PC) и дважды щёлкните START (или START.cmd).
  3. Нажмите "Да" на запрос и ждите - всё поставится само.
DONE
