#!/bin/bash
# stop_guard.sh — Stop hook: блокирует декларацию завершения без wrap-up
# Срабатывает если в последнем ответе Claude есть ключевые слова закрытия,
# но PROGRESS.md не обновлялся недавно.
#
# Фильтры ложных срабатываний:
# 1. Пропуск если stop_hook_active (защита от рекурсии)
# 2. Пропуск если есть свежий .session_closed.flag (< 5 мин)
# 3. Пропуск если PROGRESS.md обновлялся < 10 мин назад
# 4. Пропуск если в сессии не было значимой активности (нет uncommitted и commits за последний час)
# 5. Пропуск если пользователь явно сказал «без wrap-up» / «не закрывай»

set -u

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$PROJECT_DIR" || exit 0

HOOK_INPUT=$(cat)
NOW=$(date +%s)

# Защита от рекурсии
STOP_ACTIVE=$(echo "$HOOK_INPUT" | python3 -c "import sys,json
try: d=json.load(sys.stdin); print('1' if d.get('stop_hook_active') else '0')
except: print('0')" 2>/dev/null)
[ "$STOP_ACTIVE" = "1" ] && exit 0

# Флаг корректного закрытия через /end — пропускаем и чистим
FLAG=".claude/.session_closed.flag"
if [ -f "$FLAG" ]; then
  FLAG_MTIME=$(stat -f %m "$FLAG" 2>/dev/null || stat -c %Y "$FLAG" 2>/dev/null || echo 0)
  if [ $((NOW - FLAG_MTIME)) -lt 300 ]; then
    rm -f "$FLAG"
    exit 0
  fi
fi

TRANSCRIPT=$(echo "$HOOK_INPUT" | python3 -c "import sys,json
try: d=json.load(sys.stdin); print(d.get('transcript_path',''))
except: print('')" 2>/dev/null)

[ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ] && exit 0

# Защищённый парсер transcript — путь через env var, не через heredoc interpolation
# (defense in depth от инъекции через контролируемый системой путь)
PARSE_TRANSCRIPT='
import json, os
path = os.environ.get("HOOK_TRANSCRIPT", "")
role = os.environ.get("HOOK_ROLE", "assistant")
try:
    with open(path, encoding="utf-8") as f:
        lines = f.readlines()
    for line in reversed(lines):
        try:
            e = json.loads(line)
            if e.get("type") == role:
                msg = e.get("message", {})
                c = msg.get("content", "")
                if isinstance(c, str):
                    print(c.lower())
                elif isinstance(c, list):
                    parts = [p.get("text","") for p in c if isinstance(p, dict) and p.get("type")=="text"]
                    print(" ".join(parts).lower())
                break
        except Exception:
            continue
except Exception:
    pass
'

LAST_ASSISTANT=$(HOOK_TRANSCRIPT="$TRANSCRIPT" HOOK_ROLE="assistant" python3 -c "$PARSE_TRANSCRIPT")
LAST_USER=$(HOOK_TRANSCRIPT="$TRANSCRIPT" HOOK_ROLE="user" python3 -c "$PARSE_TRANSCRIPT")

# Escape hatch
if echo "$LAST_USER" | grep -qiE "без wrap-up|не закрывай|без закрытия|skip wrap|без хендофф|без handoff"; then
  exit 0
fi

# Ключевые слова декларации завершения
CLOSURE_RE="сессия завершена|сессия закрыта|сессия свёрнута|handoff готов|хэндофф готов|хендофф готов|закрываю сессию|до следующей сессии|session closed|wrap[- ]?up готов"

if ! echo "$LAST_ASSISTANT" | grep -qiE "$CLOSURE_RE"; then
  exit 0
fi

# Была ли сессия «рабочей»?
# Сигнал: либо есть uncommitted, либо был коммит за последний час
WORK_SIGNAL=0
UNCOMMITTED=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
[ "$UNCOMMITTED" -gt "0" ] && WORK_SIGNAL=1
if [ "$WORK_SIGNAL" -eq "0" ]; then
  LAST_COMMIT_TIME=$(git log -1 --format=%ct 2>/dev/null || echo 0)
  [ $((NOW - LAST_COMMIT_TIME)) -lt 3600 ] && WORK_SIGNAL=1
fi
[ "$WORK_SIGNAL" -eq "0" ] && exit 0

# PROGRESS свежий? Берём НОВЕЙШИЙ PROGRESS*.md — портируемо: solo=PROGRESS.md,
# team=PROGRESS_<member>.md (у подопечных общего PROGRESS.md нет).
PROGRESS=$(ls -t Система/память/PROGRESS*.md 2>/dev/null | head -1)
if [ -n "$PROGRESS" ] && [ -f "$PROGRESS" ]; then
  PROGRESS_MTIME=$(stat -f %m "$PROGRESS" 2>/dev/null || stat -c %Y "$PROGRESS" 2>/dev/null || echo 0)
  if [ $((NOW - PROGRESS_MTIME)) -lt 600 ]; then
    exit 0
  fi
fi

# БЛОКИРУЕМ. exit 2 → модели передаётся ТОЛЬКО stderr (stdout игнорируется), потому пишем в stderr.
cat >&2 <<'BLOCK'
🛑 HARNESS: декларация завершения без wrap-up

Ты сказал что сессия завершена, но PROGRESS.md не обновлялся за последние 10 минут.
Это паттерн P-001 (ОКО) — «handoff готов без чеклиста».

Сделай правильно:
1. /end           — запустит валидацию чеклиста
2. ИЛИ обнови вручную: PROGRESS.md, SYSTEM_LOG.md, HANDOFF.md
3. Проверь: bash Система/scripts/close_session_check.sh
4. При PASS: git commit + push + touch .claude/.session_closed.flag
5. Только потом объявляй закрытие

Escape hatch: если это был ложный триггер (не было реального wrap-up),
напиши пользователю что сессия продолжается, и он ответит «без wrap-up».
BLOCK

exit 2
