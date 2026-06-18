#!/usr/bin/env bash
# check-spore-ascii.sh — релиз-проверка споры.
# Загрузчик скиллов/плагинов отвергает не-ASCII символы в ИМЕНАХ файлов
# («Zip file contains path with invalid characters»). Этот линт ловит их
# до сборки/публикации. Содержимое файлов может быть на любом языке —
# проверяются только базовые имена файлов и папок.
#
# Запуск из корня репо: bash scripts/check-spore-ascii.sh
# Код возврата: 0 — чисто; 1 — найдены не-ASCII имена; 2 — ошибка окружения.
#
# Примечание: используем `LC_ALL=C grep '[^ -~]'` (печатаемый ASCII = 0x20..0x7E),
# а НЕ `grep -P` — флаг -P отсутствует в BSD grep (macOS) и даёт ложный «зелёный».

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2

non_ascii_basename() { printf '%s' "$1" | LC_ALL=C grep -q '[^ -~]'; }

bad=0
while IFS= read -r p; do
  if non_ascii_basename "$(basename "$p")"; then
    [ "$bad" -eq 0 ] && echo "❌ Не-ASCII имена файлов/папок в plugins/ — загрузчик их отвергнет:"
    echo "   $p"
    bad=1
  fi
done < <(find plugins -print 2>/dev/null)

if [ "$bad" -ne 0 ]; then
  echo "→ Переименуй в ASCII (транслит/англ.) перед публикацией споры."
  exit 1
fi

echo "✓ Все имена файлов в plugins/ — чисто ASCII. Спору можно паковать/публиковать."
exit 0
