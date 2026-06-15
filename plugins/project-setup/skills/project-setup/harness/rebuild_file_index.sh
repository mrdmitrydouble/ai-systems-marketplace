#!/bin/bash
# rebuild_file_index.sh — Автоинвентарь файлов проекта (аудит 10.06 п.13: FILE_INDEX был заморожен 72 дня)
# Перегенерирует секцию между маркерами AUTO-INDEX в FILE_INDEX.md, ручную часть не трогает.
# Запуск: вручную, из /end, или scheduled-задачей.

set -u
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INDEX="$PROJECT_ROOT/Система/память/FILE_INDEX.md"
[ -f "$INDEX" ] || { echo "FILE_INDEX.md не найден"; exit 1; }

TMP=$(mktemp)
{
echo "<!-- AUTO-INDEX:START (генерируется rebuild_file_index.sh — НЕ редактировать руками) -->"
echo "## Автоинвентарь (обновлён: $(date '+%Y-%m-%d %H:%M'))"
echo ""
for DIR in "Проект/Документы/Финальные" "Проект/Документы/Черновики" "Система/память" "Система/рабочие" "Система/scripts" ".claude/hooks" ".claude/commands"; do
    FULL="$PROJECT_ROOT/$DIR"
    [ -d "$FULL" ] || continue
    COUNT=$(find "$FULL" -maxdepth 1 -type f -not -name ".*" | wc -l | tr -d ' ')
    echo "### $DIR/ ($COUNT файлов)"
    # файлы с датой изменения, сортировка по имени; stat портируемый (macOS -f / Linux -c)
    find "$FULL" -maxdepth 1 -type f -not -name ".*" | sort | while IFS= read -r FILE; do
        MTIME=$(stat -f "%Sm" -t "%Y-%m-%d" "$FILE" 2>/dev/null || stat -c "%y" "$FILE" 2>/dev/null | cut -d' ' -f1)
        echo "- ${FILE##*/} | $MTIME"
    done
    # подпапки одной строкой
    SUBDIRS=$(find "$FULL" -maxdepth 1 -type d -not -path "$FULL" -not -name ".*" 2>/dev/null | sed "s|$FULL/||" | sort | tr '\n' ' ')
    [ -n "$SUBDIRS" ] && echo "- 📁 подпапки: $SUBDIRS"
    echo ""
done
ISO_COUNT=$(find "$PROJECT_ROOT/Проект/Исходники" -type f 2>/dev/null | wc -l | tr -d ' ')
echo "### Проект/Исходники/ — FROZEN ZONE: $ISO_COUNT файлов (поимённо см. ручную секцию)"
echo "<!-- AUTO-INDEX:END -->"
} > "$TMP"

python3 - "$INDEX" "$TMP" <<'PYEOF'
import sys, re, datetime
index_path, block_path = sys.argv[1], sys.argv[2]
text = open(index_path, encoding="utf-8").read()
block = open(block_path, encoding="utf-8").read()
pat = re.compile(r"<!-- AUTO-INDEX:START.*?AUTO-INDEX:END -->", re.DOTALL)
if pat.search(text):
    text = pat.sub(lambda m: block.rstrip(), text)
else:
    text = text.rstrip() + "\n\n" + block
today = datetime.date.today().isoformat()
text = re.sub(r"(> Обновлено: )\d{4}-\d{2}-\d{2}", rf"\g<1>{today}", text, count=1)
open(index_path, "w", encoding="utf-8").write(text)
print("✅ FILE_INDEX.md: авто-секция перегенерирована, дата шапки обновлена")
PYEOF
rm -f "$TMP"
