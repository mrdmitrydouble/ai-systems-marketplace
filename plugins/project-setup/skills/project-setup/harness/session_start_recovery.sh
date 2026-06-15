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
  date -u +"%Y-%m-%dT%H:%M:%SZ" > ".claude/live_sessions/${SID}.marker"
fi
# чистка протухших маркеров (>2 ч — сессия умерла без SessionEnd). Свой маркер только что записан
# (возраст 0) и переживёт чистку; долгая live-сессия освежает его через memory_write_guard.
find .claude/live_sessions -name "*.marker" -mmin +120 -delete 2>/dev/null

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
# Нечего сообщать — выходим молча
[ ! -f "$MARKER" ] && [ -z "$LOCK_MSG" ] && exit 0

# Дополнительный контекст — последние коммиты (только для чтения в Python через env)
RECENT_COMMITS=$(git log --oneline -5 2>/dev/null | tr '\n' '|')

# Закавыченный heredoc: никакой подстановки шелла в Python-код (аудит 10.06 п.9).
# Маркер Python читает сам из файла, остальное — через env.
export RC_LOCK_MSG="$LOCK_MSG" RC_COMMITS="$RECENT_COMMITS"
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

if parts:
    out = {"hookSpecificOutput": {"hookEventName": "SessionStart",
                                  "additionalContext": "\n\n".join(parts)}}
    print(json.dumps(out, ensure_ascii=False))
PYEOF

exit 0
