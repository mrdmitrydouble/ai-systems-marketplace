#!/bin/bash
# close_session_check.sh — валидация готовности к закрытию сессии
# Использование: bash Система/scripts/close_session_check.sh
# Exit 0 = PASS (готово), Exit 1 = FAIL (блокеры)
# Часть harness по Правилу 13 «Harness > Memory LLM»

set -u

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$PROJECT_DIR" || { echo "❌ Не могу зайти в $PROJECT_DIR"; exit 1; }

MEMORY_DIR="Система/память"
WINDOW_MINUTES="${SESSION_WINDOW_MINUTES:-240}"
NOW=$(date +%s)
THRESHOLD=$((NOW - WINDOW_MINUTES * 60))
FAILS=0
WARNINGS=0

_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

_check_mtime_updated() {
  local file="$1"
  local label="$2"
  if [ ! -f "$file" ]; then
    echo "❌ $label: файл не найден ($file)"
    FAILS=$((FAILS+1))
    return
  fi
  local mtime=$(_mtime "$file")
  if [ "$mtime" -lt "$THRESHOLD" ]; then
    local hours=$(( (NOW - mtime) / 3600 ))
    echo "❌ $label: не обновлялся в этой сессии (последнее изменение $hours ч назад, окно $((WINDOW_MINUTES/60)) ч)"
    FAILS=$((FAILS+1))
  else
    local mins=$(( (NOW - mtime) / 60 ))
    echo "✅ $label: обновлён $mins мин назад"
  fi
}

echo "=== ЧЕКЛИСТ ЗАВЕРШЕНИЯ СЕССИИ ==="
echo "Окно сессии: $((WINDOW_MINUTES/60)) ч"
echo ""
# [team] память разделена по участникам — подставь суффикс: PROGRESS_$WHO.md и т.п.
WHO="${SESSION_MEMBER:-}"
SUF=""; [ -n "$WHO" ] && SUF="_$WHO"
echo "Блок 1 — Файлы памяти (Правило 9):"
_check_mtime_updated "$MEMORY_DIR/PROGRESS$SUF.md"   "PROGRESS.md  "
_check_mtime_updated "$MEMORY_DIR/SYSTEM_LOG$SUF.md" "SYSTEM_LOG.md"
_check_mtime_updated "$MEMORY_DIR/HANDOFF$SUF.md"    "HANDOFF.md   "

echo ""
echo "Блок 2 — Git:"
if git rev-parse --git-dir >/dev/null 2>&1; then
  UNCOMMITTED=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  if [ "$UNCOMMITTED" -eq "0" ]; then
    echo "✅ Git working tree clean"
  else
    echo "⚠️  $UNCOMMITTED незакоммиченных изменений (не блокер для /end — он закоммитит сам)"
    WARNINGS=$((WARNINGS+1))
  fi

  if git rev-parse --verify origin/main >/dev/null 2>&1; then
    UNPUSHED=$(git log origin/main..HEAD --oneline 2>/dev/null | wc -l | tr -d ' ')
    if [ "$UNPUSHED" -eq "0" ]; then
      echo "✅ Всё запушено на origin/main"
    else
      echo "⚠️  $UNPUSHED незапушенных коммитов (не блокер — /end запушит)"
      WARNINGS=$((WARNINGS+1))
    fi
  else
    echo "⚠️  origin/main не найден локально (git fetch пропущен?)"
    WARNINGS=$((WARNINGS+1))
  fi
else
  echo "⚠️  Не git-репозиторий"
  WARNINGS=$((WARNINGS+1))
fi

echo ""
echo "Блок 3 — Лимиты строк (ARCH_PRINCIPLES):"
_limit_for() { case "$1" in RULES.md|CONTEXT.md) echo 250;; *) echo 200;; esac; }
LIMIT_WARN=0
for f in RULES.md CONTEXT.md PROGRESS.md SYSTEM_LOG.md CHANGELOG.md; do
  if [ -f "$MEMORY_DIR/$f" ]; then
    lines=$(wc -l < "$MEMORY_DIR/$f" | tr -d ' ')
    lim=$(_limit_for "$f")
    if [ "$lines" -gt "$lim" ]; then
      echo "⚠️  $f: $lines строк (лимит $lim)"
      WARNINGS=$((WARNINGS+1)); LIMIT_WARN=$((LIMIT_WARN+1))
    fi
  fi
done
[ "$LIMIT_WARN" -eq "0" ] && echo "✅ Лимиты соблюдены"

echo ""
echo "Блок 4 — HANDOFF содержательный:"
HANDOFF_FILE="$MEMORY_DIR/HANDOFF$SUF.md"
if [ -f "$HANDOFF_FILE" ]; then
  HANDOFF_LINES=$(wc -l < "$HANDOFF_FILE" | tr -d ' ')
  if [ "$HANDOFF_LINES" -lt "10" ]; then
    echo "❌ HANDOFF.md слишком короткий ($HANDOFF_LINES строк) — маловероятно что это полноценный handoff"
    FAILS=$((FAILS+1))
  else
    echo "✅ HANDOFF.md содержателен ($HANDOFF_LINES строк)"
  fi
fi

echo ""
echo "=== ИТОГ ==="
if [ "$FAILS" -gt "0" ]; then
  echo "❌ FAIL: $FAILS блокеров, $WARNINGS предупреждений"
  echo ""
  echo "Не декларируй «сессия завершена» — сначала закрой блокеры."
  exit 1
else
  if [ "$WARNINGS" -gt "0" ]; then
    echo "✅ PASS с $WARNINGS предупреждениями (не блокеры)"
  else
    echo "✅ PASS — можно закрывать сессию"
  fi
  exit 0
fi
