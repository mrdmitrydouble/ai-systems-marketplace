#!/bin/bash
# quick_health.sh — Детерминированные метрики системы
# Выдаёт ЧИСЛА, не оценки. Агент получает факты, не галлюцинации.
# Запускается: агентом при старте сессии, scheduled task, или вручную.

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MEM="$PROJECT_ROOT/System/memory"

echo "=== HEALTH CHECK | $(date '+%Y-%m-%d %H:%M') ==="
echo ""

# --- МЕТРИКИ РАЗМЕРОВ (P-компонент: текущее отклонение) ---
echo "[РАЗМЕРЫ ФАЙЛОВ]"

OVER_LIMIT=0
TOTAL_OVERSHOOT=0

check_size() {
    local NAME="$1"
    local FILE="$2"
    local LIMIT="$3"
    if [ -f "$FILE" ]; then
        LINES=$(wc -l < "$FILE" | tr -d ' ')
        DELTA=$((LINES - LIMIT))
        if [ "$DELTA" -gt 0 ]; then
            echo "  $NAME: $LINES строк (лимит $LIMIT, ПРЕВЫШЕНИЕ +$DELTA)"
            OVER_LIMIT=$((OVER_LIMIT + 1))
            TOTAL_OVERSHOOT=$((TOTAL_OVERSHOOT + DELTA))
        else
            echo "  $NAME: $LINES строк (лимит $LIMIT, ок)"
        fi
    else
        echo "  $NAME: НЕ НАЙДЕН"
        OVER_LIMIT=$((OVER_LIMIT + 1))
    fi
}

check_size "CLAUDE.md" "$PROJECT_ROOT/CLAUDE.md" 80
check_size "RULES.md" "$MEM/RULES.md" 250
# Лимиты — по «Канону лимитов» (STRUCTURES.md). Подстрой, если канон менялся.
check_size "CONTEXT.md" "$MEM/CONTEXT.md" 250
check_size "PROGRESS.md" "$MEM/PROGRESS.md" 200
check_size "SYSTEM_LOG.md" "$MEM/SYSTEM_LOG.md" 200
check_size "CHANGELOG.md" "$MEM/CHANGELOG.md" 200
check_size "TRACKER.md" "$MEM/TRACKER.md" 500

echo ""

# --- ОБЯЗАТЕЛЬНЫЕ ФАЙЛЫ ---
echo "[ОБЯЗАТЕЛЬНЫЕ ФАЙЛЫ]"
MISSING=0
for F in CLAUDE.md; do
    if [ ! -f "$PROJECT_ROOT/$F" ]; then
        echo "  ОТСУТСТВУЕТ: $F"
        MISSING=$((MISSING + 1))
    fi
done
for F in RULES.md CONTEXT.md TRACKER.md PROGRESS.md HANDOFF.md VERSION.md SYSTEM_LOG.md ARCH_PRINCIPLES.md STARTUP.md CHANGELOG.md FILE_INDEX.md; do
    if [ ! -f "$MEM/$F" ]; then
        echo "  ОТСУТСТВУЕТ: $F"
        MISSING=$((MISSING + 1))
    fi
done
if [ $MISSING -eq 0 ]; then
    echo "  Все 12 файлов на месте"
fi

echo ""

# --- СТРУКТУРА ПАПОК ---
echo "[СТРУКТУРА]"
MISSING_DIRS=0
for D in "$PROJECT_ROOT/Project" "$PROJECT_ROOT/Project/Sources" "$PROJECT_ROOT/Project/Documents" "$PROJECT_ROOT/System" "$PROJECT_ROOT/System/memory" "$PROJECT_ROOT/System/working" "$PROJECT_ROOT/System/archive"; do
    if [ ! -d "$D" ]; then
        echo "  ОТСУТСТВУЕТ: $D"
        MISSING_DIRS=$((MISSING_DIRS + 1))
    fi
done
if [ $MISSING_DIRS -eq 0 ]; then
    echo "  Все 7 папок на месте"
fi

echo ""

# --- GIT ---
echo "[GIT]"
if [ -d "$PROJECT_ROOT/.git" ]; then
    UNCOMMITTED=$(cd "$PROJECT_ROOT" && git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    UNPUSHED=$(cd "$PROJECT_ROOT" && git log --oneline @{upstream}..HEAD 2>/dev/null | wc -l | tr -d ' ')
    echo "  Незакоммиченных изменений: $UNCOMMITTED"
    echo "  Незапушенных коммитов: $UNPUSHED"
else
    echo "  Git НЕ инициализирован"
    UNCOMMITTED=0
    UNPUSHED=0
fi

echo ""

# --- HANDOFF СВЕЖЕСТЬ ---
echo "[HANDOFF]"
if [ -f "$MEM/HANDOFF.md" ]; then
    HANDOFF_DATE=$(grep -m1 'Обновлено:' "$MEM/HANDOFF.md" 2>/dev/null | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')
    if [ -n "$HANDOFF_DATE" ]; then
        DAYS_OLD=$(( ($(date +%s) - $(date -j -f "%Y-%m-%d" "$HANDOFF_DATE" +%s 2>/dev/null || echo $(date +%s))) / 86400 ))
        echo "  Последнее обновление: $HANDOFF_DATE ($DAYS_OLD дней назад)"
    else
        echo "  Дата обновления не найдена"
    fi
else
    echo "  HANDOFF.md не найден"
fi

echo ""

# --- HARNESS-СЛОИ (аудит 10.06: пп. 7, 8) ---
echo "[HARNESS]"
HARNESS_WARN=0
LOCKFILE="$PROJECT_ROOT/.git/index.lock"
if [ -f "$LOCKFILE" ]; then
    LOCK_MTIME=$(stat -f %m "$LOCKFILE" 2>/dev/null || stat -c %Y "$LOCKFILE" 2>/dev/null || echo 0)
    LOCK_AGE=$(( $(date +%s) - LOCK_MTIME ))
    if [ "$LOCK_AGE" -gt 1800 ]; then
        echo "  ⚠️ STALE .git/index.lock (возраст $((LOCK_AGE/60)) мин) — git заблокирован, убрать: rm .git/index.lock"
        HARNESS_WARN=$((HARNESS_WARN + 1))
    else
        echo "  .git/index.lock есть, но свежий ($((LOCK_AGE/60)) мин) — возможно активная git-операция"
    fi
else
    echo "  index.lock: нет ✅"
fi
CHMOD_BAD=0
for F in "$PROJECT_ROOT/CLAUDE.md" "$MEM/RULES.md" "$MEM/ARCH_PRINCIPLES.md"; do
    if [ -f "$F" ]; then
        PERMS=$(stat -f %Lp "$F" 2>/dev/null || stat -c %a "$F" 2>/dev/null || echo "?")
        [ "$PERMS" != "444" ] && CHMOD_BAD=$((CHMOD_BAD + 1))
    fi
done
if [ "$CHMOD_BAD" -gt 0 ]; then
    echo "  ⚠️ chmod 444 слетел на $CHMOD_BAD body-файлах (слой 1 harness неактивен; вероятно синк)"
    HARNESS_WARN=$((HARNESS_WARN + 1))
else
    echo "  chmod 444 body-файлов: ок ✅"
fi
# неслитые инбоксы параллельных сессий (страж v3; слияние = шаг слияния инбоксов в STARTUP)
if [ ! -d "$MEM/inbox_sessions" ]; then
    echo "  inbox_sessions: папка отсутствует (harness параллельности не установлен)"
else
    INBOX_N=$(find "$MEM/inbox_sessions" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [ "$INBOX_N" -gt 0 ]; then
        echo "  ⚠️ inbox_sessions: $INBOX_N неслитых дельт параллельных сессий — выполни слияние инбоксов (STARTUP)"
        HARNESS_WARN=$((HARNESS_WARN + 1))
    else
        echo "  inbox_sessions: пусто ✅"
    fi
fi
# dead-path детектор (класс LOOV-C3): scheduled-задачи с cwd на мёртвый путь — планировщик молча скипает, автономия мертва
DEAD_CWD=$(python3 - 2>/dev/null <<'PYEOF'
import json, glob, os
hits=glob.glob(os.path.expanduser("~/Library/Application Support/Claude/*/*/*/scheduled-tasks.json"))
dead=set()
for f in hits:
    try: d=json.load(open(f,encoding="utf-8"))
    except Exception: continue
    tasks=d.get("scheduledTasks")
    if isinstance(tasks,dict): tasks=list(tasks.values())
    for t in (tasks or []):
        if isinstance(t,dict):
            if t.get("enabled", True) is False: continue  # отключённые задачи планировщик не запускает
            cwd=t.get("cwd","")
            # ключ идентификатора в конфиге — "id" (не "taskId"); fallback на случай смены схемы
            if cwd and not os.path.isdir(cwd): dead.add(t.get("id") or t.get("taskId") or "?")
print(len(dead))
for x in sorted(dead): print(x)
PYEOF
)
DEAD_N=$(echo "$DEAD_CWD" | head -1)
if ! echo "$DEAD_N" | grep -qE '^[0-9]+$'; then
    echo "  cwd-биндинги scheduled-задач: не проверено (нет python3/конфига)"
elif [ "$DEAD_N" -gt 0 ]; then
    echo "  ⚠️ scheduled-задачи с МЁРТВЫМ cwd: $DEAD_N ($(echo "$DEAD_CWD" | tail -n +2 | tr '\n' ',' | sed 's/,$//')) — планировщик молча скипает, автономия мертва (класс LOOV-C3 → мигрируй cwd)"
    HARNESS_WARN=$((HARNESS_WARN + 1))
else
    echo "  cwd-биндинги scheduled-задач: все живы ✅"
fi

echo ""

# --- СВОДКА PID ---
echo "=== PID-МЕТРИКИ ==="
echo "  P (текущие ошибки):"
echo "    Файлов за лимитом: $OVER_LIMIT"
echo "    Суммарное превышение строк: $TOTAL_OVERSHOOT"
echo "    Отсутствующих файлов: $MISSING"
echo "    Отсутствующих папок: $MISSING_DIRS"
echo "    Незакоммиченных изменений: $UNCOMMITTED"
echo "  HARNESS-предупреждений: $HARNESS_WARN (lock/chmod; в P-error НЕ входят осознанно — chmod слетает от синка, не красим статус)"
echo ""
TOTAL_ERRORS=$((OVER_LIMIT + MISSING + MISSING_DIRS))
echo "  Общий P-error: $TOTAL_ERRORS"
echo ""

# --- ИТОГ ---
if [ $TOTAL_ERRORS -eq 0 ]; then
    echo "СТАТУС: ЗЕЛЁНЫЙ"
elif [ $TOTAL_ERRORS -le 3 ]; then
    echo "СТАТУС: ЖЁЛТЫЙ ($TOTAL_ERRORS проблем)"
else
    echo "СТАТУС: КРАСНЫЙ ($TOTAL_ERRORS проблем)"
fi
