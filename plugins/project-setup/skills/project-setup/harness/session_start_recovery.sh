#!/bin/bash
# session_start_recovery.sh — SessionStart hook
# 1) Авто-убирает stale .git/index.lock (>30 мин, нет git-процессов) — аудит 10.06 п.7, паттерн N=3.
# 2) Если есть маркер .session_incomplete.json — через JSON-output добавляет
#    системное сообщение что прошлая сессия прервана и нужен recovery.
# Это harness-слой над шагом обработки прерванной сессии в STARTUP (который живёт в промпте — ненадёжно).

set -u

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$PROJECT_DIR" || exit 0

# --- Heartbeat-реестр живых сессий (Фаза C: координация, VSM S2) ---
HOOK_STDIN=$(cat 2>/dev/null || echo '{}')
SID=$(printf '%s' "$HOOK_STDIN" | python3 -c "import sys,json
try: print(json.load(sys.stdin).get('session_id',''))
except: print('')" 2>/dev/null)
mkdir -p .claude/live_sessions
if [ -n "$SID" ]; then
  # v4 (29.06): живость по ПРОЦЕССУ, не по таймеру. строка1=ISO-время, строка2=root-PID claude.
  # PID нужен, чтобы любая сессия могла точно отличить живой процесс от крэш-маркера.
  { date -u +"%Y-%m-%dT%H:%M:%SZ"; python3 System/scripts/session_liveness.py self 2>/dev/null; } \
    > ".claude/live_sessions/${SID}.marker"
fi
# Подмести маркеры МЁРТВЫХ процессов — по факту процесса (kill-уровень точность, не таймер 2ч).
# Свой маркер только что записан с живым PID → переживёт. Pidless-маркеры старого формата: фолбэк >8ч.
python3 System/scripts/session_liveness.py sweep "$PROJECT_DIR" >/dev/null 2>&1

# --- Автоочистка stale index.lock ---
LOCK_MSG=""
LOCK=".git/index.lock"
if [ -f "$LOCK" ]; then
  LOCK_MTIME=$(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK" 2>/dev/null || echo 0)
  LOCK_AGE=$(( $(date +%s) - LOCK_MTIME ))
  if [ "$LOCK_AGE" -gt 1800 ] && ! pgrep -x git >/dev/null 2>&1; then
    if rm -f "$LOCK" 2>/dev/null; then
      LOCK_MSG="🔧 Хук авто-убрал stale .git/index.lock (возраст $((LOCK_AGE/60)) мин, активных git-процессов не было). Git разблокирован."
    else
      LOCK_MSG="⚠️ Найден stale .git/index.lock (возраст $((LOCK_AGE/60)) мин), убрать не удалось (нет прав — VM?). Убери вручную: rm .git/index.lock"
    fi
  fi
fi

MARKER=".claude/.session_incomplete.json"
# Несмёрженные инбоксы параллельных сессий (Пакет C: гарантия слияния, не «надежда на промпт»)
INBOX_CNT=$(find "System/memory/inbox_sessions" -maxdepth 1 -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
INBOX_LIST=$(find "System/memory/inbox_sessions" -maxdepth 1 -name "*.md" -exec basename {} \; 2>/dev/null | tr '\n' ',' | sed 's/,$//')
# Нечего сообщать — выходим молча
[ ! -f "$MARKER" ] && [ -z "$LOCK_MSG" ] && [ "${INBOX_CNT:-0}" -eq "0" ] && exit 0

# Дополнительный контекст — последние коммиты (только для чтения в Python через env)
RECENT_COMMITS=$(git log --oneline -5 2>/dev/null | tr '\n' '|')

# Закавыченный heredoc: никакой подстановки шелла в Python-код (аудит 10.06 п.9).
# Маркер Python читает сам из файла, остальное — через env.
export RC_LOCK_MSG="$LOCK_MSG" RC_COMMITS="$RECENT_COMMITS" RC_INBOX_CNT="$INBOX_CNT" RC_INBOX_LIST="$INBOX_LIST"
python3 <<'PYEOF'
import json, os

parts = []
lock_msg = os.environ.get("RC_LOCK_MSG", "")
if lock_msg:
    parts.append(lock_msg)

mpath = ".claude/.session_incomplete.json"
if os.path.exists(mpath):
    try:
        with open(mpath, encoding="utf-8") as f:
            marker = json.load(f)
    except Exception:
        marker = {}
    parts.append(
        "⚠️ RECOVERY MODE: прошлая сессия не закрыта через /end.\n\n"
        f"Маркер .claude/.session_incomplete.json: timestamp={marker.get('timestamp','?')} "
        f"reason={marker.get('reason','?')} status={marker.get('status','?')}.\n\n"
        "ОБЯЗАТЕЛЬНО выполни шаг обработки прерванной сессии в STARTUP:\n"
        "1. Прочитай маркер целиком (cat .claude/.session_incomplete.json)\n"
        "2. Посмотри git log -5 --stat чтобы понять что было сделано\n"
        "3. Спроси пользователя: «Прошлая сессия закрыта некорректно. Восстановить wrap-up по факту git log?»\n"
        "4. Если да → обнови PROGRESS/SYSTEM_LOG/HANDOFF постфактум → запусти /end (он удалит маркер)\n"
        "5. Если «пропустить» → rm .claude/.session_incomplete.json, продолжай новую сессию\n\n"
        f"Последние коммиты: {os.environ.get('RC_COMMITS', '?')}\n\n"
        "Не игнорируй это сообщение. Это harness для паттерна P-001."
    )

inbox_cnt = os.environ.get("RC_INBOX_CNT", "0")
if inbox_cnt and inbox_cnt != "0":
    inbox_list = os.environ.get("RC_INBOX_LIST", "")
    parts.append(
        f"📥 СЛЕЙ ИНБОКСЫ ПЕРЕД РАБОТОЙ: в System/memory/inbox_sessions/ есть {inbox_cnt} несмёрженных "
        f"дельт параллельных сессий ({inbox_list}). ОБЯЗАТЕЛЬНО выполни шаг 0.6 STARTUP (слияние инбоксов) "
        "ДО любой другой работы: прочитай каждый файл, влей содержимое по заголовкам «## для X» в целевой "
        "файл памяти, удали файл-инбокс. Это harness-гейт (Пакет C) — данные параллельных сессий не должны "
        "зависнуть несмёрженными (был недельный завал в подопечных)."
    )

if parts:
    out = {"hookSpecificOutput": {"hookEventName": "SessionStart",
                                  "additionalContext": "\n\n".join(parts)}}
    print(json.dumps(out, ensure_ascii=False))
PYEOF

exit 0
