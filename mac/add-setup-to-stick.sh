#!/bin/bash
# Кладёт на уже записанную флешку GF63WIN всё для автоматической установки игр:
# набор скриптов, файл START.cmd и установщик драйвера NVIDIA из "Загрузок" (если он там есть).
# Флешка не форматируется, установщик Windows на ней остаётся.
#
#   bash add-setup-to-stick.sh [путь-к-флешке]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
fail() { printf '\nОШИБКА: %s\n' "$1" >&2; exit 1; }

STICK="${1:-${GF63_STICK:-}}"
if [ -z "$STICK" ]; then
    # Флешка может называться не GF63WIN (например "GF63WIN 1") - ищем том с установщиком Windows
    for v in /Volumes/*; do
        if [ -f "$v/sources/boot.wim" ]; then STICK="$v"; break; fi
    done
fi
if [ -z "$STICK" ] || [ ! -d "$STICK" ]; then
    echo
    echo "Подключённые диски:"
    ls /Volumes
    fail "Флешка с установщиком Windows не найдена. Вставьте её в Mac и запустите снова. Если она в списке выше под другим именем, добавьте в конец команды путь в кавычках, например: \"/Volumes/USB\""
fi
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
  2. Откройте её в Проводнике и дважды щёлкните START (или START.cmd).
  3. Нажмите "Да" на запрос и ждите - всё поставится само.
DONE
