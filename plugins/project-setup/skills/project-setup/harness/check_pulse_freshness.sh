#!/bin/bash
# check_pulse_freshness.sh — детектор класса «прогон без следа».
#
# ЗАЧЕМ: задача планировщика может «отработать» (отметка о запуске обновилась), но НЕ
# доставить результат — и тогда успех неотличим от тихого сбоя. Этот детектор НЕЗАВИСИМ
# от самоотчёта задачи: источник истины — реальный коммит-ДОСТАВКА в репозитории.
# Самоотчёт при тихом сбое ненадёжен по определению — это и есть ловимый класс.
#
# КАК: для каждой периодической задачи берём дату последнего коммита-доставки
# (по ЯКОРНОМУ grep ^шаблон — чтобы не поймать коммиты, лишь УПОМИНАЮЩИЕ фразу)
# и сравниваем возраст с окном MAX_AGE. Старше окна или ни разу — протухло.
#
# РЕЕСТР — не в коде. Он в System/memory/pulse_registry.txt, по строке на задачу:
#   метка | путь к репозиторию | ^якорный-шаблон-коммита
# Строки с # — комментарии. Пример лежит в pulse_registry.example.txt.
#
# ВАЖНО: если реестр не настроен, скрипт НЕ говорит «всё свежо». Он говорит «не
# проверено» и выходит с кодом 2. Зелёный отчёт при нулевой проверке — ровно тот
# самый класс ошибки, который этот детектор и создан ловить.
#
# ФЛАГ --ledger: дополнительно перезаписать снимок в System/memory/scheduled_runs.md.
# EXIT: 0 = все свежие; 1 = есть протухшие; 2 = детектор не смог отработать.

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REGISTRY="$PROJECT_ROOT/System/memory/pulse_registry.txt"
LEDGER="$PROJECT_ROOT/System/memory/scheduled_runs.md"
MAX_AGE=9   # 7-дневный цикл + 2 дня на вытеснение слота и ночной catch-up

WRITE_LEDGER=0
[ "${1:-}" = "--ledger" ] && WRITE_LEDGER=1

if [ ! -f "$REGISTRY" ]; then
    echo "  ❓ реестр пульса не настроен ($REGISTRY отсутствует)"
    echo "ИТОГ: НЕ ПРОВЕРЕНО — заполни реестр из pulse_registry.example.txt"
    exit 2
fi

REG=()
while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    REG+=("$line")
done < "$REGISTRY"

if [ "${#REG[@]}" -eq 0 ]; then
    echo "  ❓ реестр пульса пуст ($REGISTRY без записей)"
    echo "ИТОГ: НЕ ПРОВЕРЕНО — ни одной задачи не заявлено к контролю"
    exit 2
fi

NOW=$(date +%s)
STALE=0
OUT=""
for entry in "${REG[@]}"; do
    IFS='|' read -r label path pat <<< "$entry"
    # обрезаем пробелы по краям — реестр пишет человек
    label="$(echo "$label" | sed 's/^ *//;s/ *$//')"
    path="$(echo "$path"  | sed 's/^ *//;s/ *$//')"
    pat="$(echo "$pat"    | sed 's/^ *//;s/ *$//')"
    # относительный путь считаем от корня проекта
    case "$path" in /*) ;; *) path="$PROJECT_ROOT/$path" ;; esac

    if ! git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        OUT+="  ❓ $label — репозиторий недоступен ($path)\n"
        continue
    fi
    d=$(git -C "$path" log -1 --grep="$pat" --format=%cd --date=short 2>/dev/null)
    if [ -z "$d" ]; then
        OUT+="  🔴 $label — НИ РАЗУ не доставлялся\n"
        STALE=$((STALE + 1))
        continue
    fi
    # BSD date (macOS) и GNU date (Linux) — разные ключи, поэтому две попытки
    ts=$(date -j -f "%Y-%m-%d" "$d" +%s 2>/dev/null || date -d "$d" +%s 2>/dev/null || echo 0)
    age=$(( (NOW - ts) / 86400 ))
    if [ "$age" -gt "$MAX_AGE" ]; then
        OUT+="  🔴 $label — последняя доставка $d ($age дн назад, >$MAX_AGE) — ПРОПУЩЕН ЦИКЛ\n"
        STALE=$((STALE + 1))
    else
        OUT+="  ✅ $label — последняя доставка $d ($age дн назад)\n"
    fi
done

printf "%b" "$OUT"
if [ "$STALE" -gt 0 ]; then
    echo "ИТОГ: $STALE деливераблов протухло/не доставлено"
else
    echo "ИТОГ: все деливераблы свежие"
fi

if [ "$WRITE_LEDGER" = "1" ]; then
    {
        echo "# scheduled_runs.md — LEDGER доставки периодических деливераблов"
        echo "> Детектор класса «прогон без следа». Git-производный, НЕЗАВИСИМ от самоотчёта задачи."
        echo "> Источник истины — реальный коммит-доставка (якорный grep)."
        echo "> Перезаписывается \`check_pulse_freshness.sh --ledger\`. Окно свежести: $MAX_AGE дн."
        echo ""
        echo "## Снимок свежести — обновлён $(date '+%Y-%m-%d %H:%M')"
        echo ""
        printf "%b" "$OUT"
        echo ""
        if [ "$STALE" -gt 0 ]; then
            echo "**СТАТУС: 🔴 $STALE протухло — результат не доходит до владельца.**"
        else
            echo "**СТАТУС: ✅ все деливераблы свежие.**"
        fi
    } > "$LEDGER"
fi

[ "$STALE" -gt 0 ] && exit 1 || exit 0
