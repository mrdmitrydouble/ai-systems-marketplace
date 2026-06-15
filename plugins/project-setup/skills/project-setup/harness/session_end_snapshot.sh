#!/bin/bash
# session_end_snapshot.sh — SessionEnd hook
# Срабатывает при закрытии сессии (включая закрытие окна без /end).
# Если есть незакоммиченные изменения → WIP-коммит.
# Записывает маркер .session_incomplete.json для следующей сессии (STARTUP подхватит).
#
# Если сессия была корректно закрыта через /end (свежий .session_closed.flag) — пропускаем.

set -u

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$PROJECT_DIR" || exit 0

HOOK_INPUT=$(cat 2>/dev/null || echo "{}")
NOW=$(date +%s)

# Снять heartbeat-маркер этой сессии (Фаза C: координация сессий)
SID=$(echo "$HOOK_INPUT" | python3 -c "import sys,json
try: print(json.load(sys.stdin).get('session_id',''))
except: print('')" 2>/dev/null)
[ -n "$SID" ] && rm -f ".claude/live_sessions/${SID}.marker" 2>/dev/null

REASON=$(echo "$HOOK_INPUT" | python3 -c "import sys,json
try: d=json.load(sys.stdin); print(d.get('reason','unknown'))
except: print('unknown')" 2>/dev/null)

# Если корректное закрытие через /end — пропускаем
FLAG=".claude/.session_closed.flag"
if [ -f "$FLAG" ]; then
  FLAG_MTIME=$(stat -f %m "$FLAG" 2>/dev/null || stat -c %Y "$FLAG" 2>/dev/null || echo 0)
  if [ $((NOW - FLAG_MTIME)) -lt 600 ]; then
    rm -f "$FLAG"
    exit 0
  fi
fi

# Не мета-репо? Пропускаем
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

# Есть ли что сохранять? Чистое дерево → сессия ничего не меняла →
# НЕ пишем маркер и НЕ коммитим (фикс цикла marker-only WIP, аудит 10.06 п.5)
UNCOMMITTED=$(git status --porcelain 2>/dev/null)
[ -z "$UNCOMMITTED" ] && exit 0

mkdir -p .claude
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
TIMESTAMP_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Список изменённых файлов — ДО коммита, из фактического status (точно в обоих исходах)
CHANGED_FILES=$(printf '%s\n' "$UNCOMMITTED" | awk '{print $NF}' | head -20 | tr '\n' ',' | sed 's/,$//')

# WIP-коммит в main (solo mode мета-проекта). Честный статус при провале (аудит 10.06 п.6)
git add -A 2>/dev/null
if git commit -m "WIP: прерванная сессия $TIMESTAMP (reason: $REASON)

Автоматический коммит от SessionEnd hook.
Следующая сессия должна восстановить wrap-up:
- PROGRESS.md (запись о сессии)
- SYSTEM_LOG.md (наблюдения)
- HANDOFF.md (контекст)
- /end для финализации" >/dev/null 2>&1; then
  SNAPSHOT_STATUS="wip_committed"
else
  SNAPSHOT_STATUS="wip_commit_FAILED_changes_only_on_disk"
fi
LAST_COMMIT=$(git log -1 --format=%H 2>/dev/null)

# Маркер для следующей сессии (env + закавыченный heredoc — без подстановки в код, аудит 10.06 п.9)
MARKER=".claude/.session_incomplete.json"
export SNAP_TS="$TIMESTAMP_ISO" SNAP_REASON="$REASON" SNAP_STATUS="$SNAPSHOT_STATUS" \
       SNAP_COMMIT="$LAST_COMMIT" SNAP_FILES="$CHANGED_FILES"
python3 <<'PYEOF' > "$MARKER"
import json, os
data = {
    "timestamp": os.environ.get("SNAP_TS", ""),
    "reason": os.environ.get("SNAP_REASON", "unknown"),
    "status": os.environ.get("SNAP_STATUS", ""),
    "last_commit": os.environ.get("SNAP_COMMIT", ""),
    "changed_files": [f for f in os.environ.get("SNAP_FILES", "").split(",") if f],
    "note": "Сессия не закрыта через /end. STARTUP должен восстановить wrap-up из git log + diff."
}
print(json.dumps(data, ensure_ascii=False, indent=2))
PYEOF

exit 0
