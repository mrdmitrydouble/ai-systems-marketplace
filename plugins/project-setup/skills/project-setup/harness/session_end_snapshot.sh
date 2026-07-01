#!/bin/bash
# session_end_snapshot.sh — SessionEnd hook (v3: marker-only + durable stash-ref)
# Срабатывает при закрытии сессии (включая закрытие окна без /end).
#
# ДИЗАЙН (research 2026-06-16; прецеденты JetBrains Local History / VS Code Hot Exit / Emacs auto-save):
#   авто-safety-net НЕ мутирует общий git (ни ветки, ни коммиты, ни stash-list). Прошлая версия
#   делала WIP-коммит в текущую ветку (main) → в мете накопилось 24+ мусорных WIP-коммита и был
#   цикл-инцидент (коммит 2b1132a). Теперь:
#     1) git stash create — durable снапшот рабочего дерева в БД объектов git БЕЗ смены HEAD/ветки/
#        индекса и БЕЗ записи в stash-list; якорим refs/wip-snapshot/<sid> (чтобы не выгреб GC).
#        Хэш кладём в маркер (snapshot_ref) — откат на случай git clean/checkout или долгого recovery.
#     2) маркер .session_incomplete.json пишется АТОМАРНО (temp + os.replace) и СТРОГО ПОСЛЕДНИМ —
#        он единственное свидетельство незавершённости; полузаписанный маркер ломает recovery.
#   Данные остаются в рабочем дереве (как у IDE-autosave); main не трогается → team-безопасно.
#
# Если сессия корректно закрыта через /end (свежий .session_closed.flag) — пропускаем.

set -u

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$PROJECT_DIR" || exit 0

HOOK_INPUT=$(cat 2>/dev/null || echo "{}")
NOW=$(date +%s)

# Снять heartbeat-маркер этой сессии (координация параллельных сессий)
SID=$(echo "$HOOK_INPUT" | python3 -c "import sys,json
try: print(json.load(sys.stdin).get('session_id',''))
except: print('')" 2>/dev/null)
[ -n "$SID" ] && rm -f ".claude/live_sessions/${SID}.marker" 2>/dev/null

REASON=$(echo "$HOOK_INPUT" | python3 -c "import sys,json
try: d=json.load(sys.stdin); print(d.get('reason','unknown'))
except: print('unknown')" 2>/dev/null)

# Корректное закрытие через /end — пропускаем и чистим флаг
FLAG=".claude/.session_closed.flag"
if [ -f "$FLAG" ]; then
  FLAG_MTIME=$(stat -f %m "$FLAG" 2>/dev/null || stat -c %Y "$FLAG" 2>/dev/null || echo 0)
  if [ $((NOW - FLAG_MTIME)) -lt 600 ]; then
    rm -f "$FLAG"
    exit 0
  fi
fi

# Не git-репо? Пропускаем
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

# Чистое дерево → сессия ничего не меняла → не пишем маркер (фикс цикла marker-only WIP)
UNCOMMITTED=$(git status --porcelain 2>/dev/null)
[ -z "$UNCOMMITTED" ] && exit 0
# Чистая телеметрия (as-metrics.jsonl) — не «работа»: не плодим incomplete-маркер/снапшот.
# Это убирает накопление осиротевших wip-снапшотов от scheduled-прогонов (v4, 29.06).
SIGNIFICANT=$(printf '%s\n' "$UNCOMMITTED" | grep -v 'as-metrics\.jsonl' | sed '/^[[:space:]]*$/d')
[ -z "$SIGNIFICANT" ] && exit 0

mkdir -p .claude
TIMESTAMP_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Список изменённых файлов — из фактического status (ДО любых git-операций)
CHANGED_FILES=$(printf '%s\n' "$UNCOMMITTED" | awk '{print $NF}' | head -20 | tr '\n' ',' | sed 's/,$//')

# --- Durable снапшот БЕЗ мутации main ---
# git stash create кладёт коммит-объект рабочего дерева+индекса в БД объектов git, НЕ трогая
# HEAD/ветку/индекс/рабочее дерево и НЕ создавая запись в stash-list. Untracked-файлы он не
# включает — они и так остаются в рабочем дереве (marker-only сохраняет их). Якорим ref'ом от GC.
SNAPSHOT_REF=$(git stash create "session-snapshot $TIMESTAMP_ISO" 2>/dev/null || echo "")
if [ -n "$SNAPSHOT_REF" ] && [ -n "$SID" ]; then
  git update-ref "refs/wip-snapshot/$SID" "$SNAPSHOT_REF" 2>/dev/null || true
fi
LAST_COMMIT=$(git log -1 --format=%H 2>/dev/null)

# --- Маркер: пишем АТОМАРНО (temp + os.replace) и ПОСЛЕДНИМ ---
MARKER=".claude/.session_incomplete.json"
export SNAP_TS="$TIMESTAMP_ISO" SNAP_REASON="$REASON" SNAP_COMMIT="$LAST_COMMIT" \
       SNAP_FILES="$CHANGED_FILES" SNAP_REF="$SNAPSHOT_REF" SNAP_MARKER="$MARKER"
python3 <<'PYEOF'
import json, os, tempfile
marker = os.environ.get("SNAP_MARKER", ".claude/.session_incomplete.json")
ref = os.environ.get("SNAP_REF", "")
data = {
    "timestamp": os.environ.get("SNAP_TS", ""),
    "reason": os.environ.get("SNAP_REASON", "unknown"),
    "status": "marker_only+snapshot_ref" if ref else "marker_only",
    "last_commit": os.environ.get("SNAP_COMMIT", ""),
    "snapshot_ref": ref,                       # git stash create хэш; якорь refs/wip-snapshot/<sid>
    "changed_files": [f for f in os.environ.get("SNAP_FILES", "").split(",") if f],
    "note": ("Сессия не закрыта через /end. Данные — в рабочем дереве (git status/diff). "
             "Если дерево вычищено — восстановить снапшот: git stash apply <snapshot_ref>. "
             "STARTUP/recovery: восстанови wrap-up по git log+diff и закрой через /end."),
}
d = os.path.dirname(marker) or "."
os.makedirs(d, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=d, prefix=".sess_marker_", suffix=".tmp")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.flush(); os.fsync(f.fileno())
    os.replace(tmp, marker)                    # атомарная замена
except Exception:
    try: os.unlink(tmp)
    except Exception: pass
PYEOF

exit 0
