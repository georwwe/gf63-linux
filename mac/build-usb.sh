#!/bin/bash
# Сборка установочной флешки Windows 10 Enterprise LTSC 2021 для MSI GF63 Thin 9SCXR на macOS.
#
#   bash build-usb.sh [путь-к-ISO] [diskN] [папка-с-драйверами]
#
# Все параметры необязательны - скрипт спросит недостающее.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
KIT="$ROOT/kit"

step() { printf '\n=== %s\n' "$1"; }
fail() { printf '\nОШИБКА: %s\n' "$1" >&2; exit 1; }
# Путь, перетащенный в Терминал: убираем кавычки и экранирование пробелов
clean_path() { local p="$1"; p="${p%\'}"; p="${p#\'}"; p="${p//\\ / }"; p="${p%/}"; printf '%s' "$p"; }

[ "$(uname)" = "Darwin" ] || fail "Этот скрипт работает только на macOS."
[ -f "$KIT/Optimize-Windows.ps1" ] || fail "Не найдена папка kit рядом со скриптом. Распакуйте архив целиком."

if ! command -v wimlib-imagex >/dev/null 2>&1; then
    cat <<'MSG'

Не установлена программа wimlib (нужна для работы с образом Windows).
Установите её и запустите скрипт снова:

  1. Если нет Homebrew, поставьте его с https://brew.sh
  2. Выполните в Терминале:   brew install wimlib

MSG
    exit 1
fi

ISO="${1:-}"
DISK="${2:-}"
DRIVERS="${3:-}"

# ---------- ISO ----------
if [ -z "$ISO" ]; then
    printf '\nПеретащите сюда ISO-файл Windows 10 Enterprise LTSC 2021 и нажмите Enter:\n> '
    read -r ISO
fi
ISO="$(clean_path "$ISO")"
[ -f "$ISO" ] || fail "ISO-файл не найден: $ISO"

# ---------- Драйверы (необязательно) ----------
if [ -z "$DRIVERS" ] && [ -d "$ROOT/drivers" ]; then DRIVERS="$ROOT/drivers"; fi
if [ -z "$DRIVERS" ] && [ -t 0 ]; then
    printf '\nПеретащите сюда папку с распакованными драйверами с сайта MSI\n(или просто нажмите Enter, чтобы собрать без драйверов):\n> '
    read -r DRIVERS
fi
DRIVERS="$(clean_path "$DRIVERS")"
if [ -n "$DRIVERS" ]; then
    [ -d "$DRIVERS" ] || fail "Папка с драйверами не найдена: $DRIVERS"
    INF_COUNT="$(find "$DRIVERS" -iname '*.inf' | wc -l | tr -d ' ')"
    [ "$INF_COUNT" -gt 0 ] || fail "В папке $DRIVERS нет файлов .inf. Архивы драйверов нужно распаковать."
    echo "Драйверы: $DRIVERS (файлов .inf: $INF_COUNT)"
else
    echo "Сборка без драйверов: Windows поставит их сама через Центр обновления после подключения к интернету."
fi

# ---------- Флешка ----------
if [ -z "$DISK" ]; then
    echo
    echo "Внешние диски:"
    diskutil list external physical
    printf 'Введите имя флешки (например disk4):\n> '
    read -r DISK
fi
DISK="${DISK#/dev/}"
case "$DISK" in disk[0-9]|disk[0-9][0-9]) ;; *) fail "Нужно имя целого диска вида disk4 (без s1 в конце)." ;; esac
INFO="$(diskutil info "$DISK" 2>/dev/null)" || fail "Диск $DISK не найден."
if [ "${GF63_ALLOW_ANY_DISK:-}" != "1" ]; then
    echo "$INFO" | grep -Eq 'Device Location: +External' || fail "$DISK не является внешним диском. Для безопасности запись разрешена только на внешние диски."
    echo "$INFO" | grep -Eq 'Virtual: +No|Removable Media: +Removable' || fail "$DISK не похож на флешку."
fi
BYTES="$(echo "$INFO" | sed -n 's/.*Disk Size:.*(\([0-9]*\) Bytes).*/\1/p' | head -1)"
[ -n "$BYTES" ] || fail "Не удалось определить размер диска $DISK."
[ "$BYTES" -ge 7000000000 ] || fail "Флешка слишком маленькая, нужно минимум 8 ГБ."
[ "$BYTES" -le 300000000000 ] || fail "Диск больше 300 ГБ - это не похоже на флешку. Остановлено для безопасности."
NAME="$(echo "$INFO" | sed -n 's/.*Device \/ Media Name: *//p' | head -1)"

echo
echo "ВНИМАНИЕ: ВСЕ ДАННЫЕ на $DISK ($NAME, $((BYTES / 1000000000)) ГБ) будут УДАЛЕНЫ."
if [ "${GF63_NO_PROMPT:-}" != "1" ]; then
    printf 'Чтобы продолжить, введите YES: '
    read -r ANSWER
    [ "$ANSWER" = "YES" ] || fail "Отменено."
fi

# ---------- Рабочая папка ----------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/gf63.XXXXXX")"
MNT=""
cleanup() {
    [ -n "$MNT" ] && hdiutil detach "$MNT" -quiet 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT
FREE_KB="$(df -k "$WORK" | awk 'NR==2 {print $4}')"
[ "$FREE_KB" -ge 8000000 ] || fail "На диске Mac меньше 8 ГБ свободного места."

step "Подключаю ISO"
MNT="$WORK/iso"
mkdir "$MNT"
hdiutil attach "$ISO" -readonly -nobrowse -mountpoint "$MNT" >/dev/null
[ -f "$MNT/sources/install.wim" ] || fail "В образе нет sources/install.wim. Нужен оригинальный ISO LTSC 2021."

step "Копирую образ системы во временную папку"
cp "$MNT/sources/install.wim" "$WORK/install.wim"
chmod u+w "$WORK/install.wim"

# ---------- Выбор редакции (без "N") ----------
COUNT="$(wimlib-imagex info "$WORK/install.wim" | sed -n 's/^Image Count: *//p')"
INDEX=""
i=1
while [ "$i" -le "$COUNT" ]; do
    IMG_NAME="$(wimlib-imagex info "$WORK/install.wim" "$i" | sed -n 's/^Name: *//p' | head -1)"
    echo "  $i: $IMG_NAME"
    case " $IMG_NAME " in *" N "*) ;; *) [ -z "$INDEX" ] && INDEX="$i" ;; esac
    i=$((i + 1))
done
[ -n "$INDEX" ] || INDEX=1
echo "Выбрана редакция номер $INDEX"

# ---------- Набор оптимизации и драйверы ----------
step "Добавляю в образ набор оптимизации и драйверы"
STAGE="$WORK/GF63"
cp -R "$KIT" "$STAGE"
cp "$HERE/SetupComplete.cmd" "$WORK/SetupComplete.cmd"
# Лишние компоненты Windows удалит сама Windows при первом запуске оптимизации
: > "$STAGE/slim-pending"
# Командные файлы Windows должны иметь окончания строк CRLF
for f in "$STAGE"/*.cmd "$WORK/SetupComplete.cmd"; do perl -pi -e 's/\r?\n/\r\n/' "$f"; done
if [ -n "$DRIVERS" ]; then cp -R "$DRIVERS" "$STAGE/drivers"; fi
find "$STAGE" -name '.DS_Store' -delete

cat > "$WORK/update.txt" <<CMDS
add "$STAGE" /GF63
add "$WORK/SetupComplete.cmd" /Windows/Setup/Scripts/SetupComplete.cmd
CMDS
wimlib-imagex update "$WORK/install.wim" "$INDEX" < "$WORK/update.txt"

# ---------- Флешка ----------
step "Форматирую флешку $DISK"
diskutil eraseDisk MS-DOS GF63WIN MBR "/dev/$DISK"
USB="/Volumes/GF63WIN"
[ -d "$USB" ] || fail "Флешка не подключилась после форматирования."

step "Записываю файлы установщика (5-15 минут)"
rsync -r --exclude 'sources/install.wim' "$MNT/" "$USB/"

step "Записываю образ системы (10-30 минут)"
# FAT32 не хранит файлы больше 4 ГБ, поэтому образ делится на части; установщик собирает их сам
wimlib-imagex split "$WORK/install.wim" "$USB/sources/install.swm" 3800

step "Проверяю флешку"
[ -f "$USB/efi/boot/bootx64.efi" ] || fail "На флешке нет загрузчика UEFI."
[ -f "$USB/sources/boot.wim" ] || fail "На флешке нет boot.wim."
wimlib-imagex dir "$USB/sources/install.swm" "$INDEX" --ref="$USB/sources/install*.swm" --path=/GF63 \
    | grep -q 'Optimize-Windows.ps1' || fail "Набор оптимизации не попал в образ."
dot_clean -m "$USB" 2>/dev/null || true
sync
diskutil eject "/dev/$DISK" >/dev/null 2>&1 || true

cat <<'DONE'

ГОТОВО. Флешка записана, её можно вынимать.

Дальше на ноутбуке MSI:
  1. Сохраните важные файлы с него - установка сотрёт системный раздел.
  2. Вставьте флешку, включите ноутбук и сразу нажимайте F11. Выберите флешку.
  3. Установите Windows как обычно.
  4. При первом входе нажмите "Да" на запрос - оптимизация применится сама.
  5. Подключите интернет: Windows докачает недостающие драйверы.
DONE
