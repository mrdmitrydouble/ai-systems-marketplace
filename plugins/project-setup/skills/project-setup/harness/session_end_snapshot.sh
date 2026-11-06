#!/bin/bash
# session_end_snapshot.sh — SessionEnd hook (v3: marker-only + durable stash-ref; v4.3: работа соседей — не своя)
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
# Снимок незакоммиченного на старте этой сессии (пишет SessionStart) — забираем ДО снятия маркера.
START_SNAP=""
if [ -n "$SID" ] && [ -f ".claude/live_sessions/${SID}.dirty" ]; then
  START_SNAP=$(mktemp 2>/dev/null || echo "/tmp/snap_start_$$")
  mv ".claude/live_sessions/${SID}.dirty" "$START_SNAP" 2>/dev/null || START_SNAP=""
  [ -n "$START_SNAP" ] && trap 'rm -f "$START_SNAP"' EXIT
fi
# Журнал сессии — по нему видно её последнее действие (v4.3): из ввода хука, иначе строка 4 маркера.
TRANSCRIPT=$(echo "$HOOK_INPUT" | python3 -c "import sys,json
try: print(json.load(sys.stdin).get('transcript_path',''))
except: print('')" 2>/dev/null)
[ -z "$TRANSCRIPT" ] && [ -n "$SID" ] && TRANSCRIPT=$(sed -n 4p ".claude/live_sessions/${SID}.marker" 2>/dev/null)
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
UNCOMMITTED=$(git -c core.quotepath=off status --porcelain 2>/dev/null)
[ -z "$UNCOMMITTED" ] && exit 0
# Не «работа» — не плодим incomplete-маркер/снапшот:
#   телеметрия as-metrics.jsonl (v4, 29.06: осиротевшие wip-снапшоты от scheduled-прогонов);
#   кэш Python __pycache__/ и *.pyc (v4.1, 02.11: ложный RECOVERY после КАЖДОГО scheduled-прогона);
#   служебные файлы самого harness (v4.1): live-маркер соседней живой сессии, отметки прогонов
#   stamp_run (System/state/) и сам маркер незавершённости — иначе однажды записанный маркер
#   переписывает себя каждым прогоном без /end.
SIGNIFICANT=$(printf '%s\n' "$UNCOMMITTED" | grep -v 'as-metrics\.jsonl' \
  | grep -v -E '__pycache__/|\.pyc"?$|System/state/|\.claude/(live_sessions/|\.session_incomplete\.json|\.session_closed\.flag|\.sess_marker_)' \
  | sed '/^[[:space:]]*$/d')
[ -z "$SIGNIFICANT" ] && exit 0

# Только работа ЭТОЙ сессии (v4.2, 8.1.2): сравниваем снимки незакоммиченного на старте и сейчас.
# Новое или изменённое = работа сессии (в т.ч. git mv, cp -p, chmod — без свежей даты файла). Давние
# черновики и давние удаления одинаковы в обоих снимках — не в счёт. Снимка нет (сессия открыта до
# обновления обвязки, SessionStart не отработал; 8.1.3) — работа = значимое, изменённое после старта
# процесса этой сессии. Не удалось ни то, ни другое — по-старому: любая значимая незакоммиченная правка.
NEW_WORK=""
if [ -n "$START_SNAP" ]; then
  NOW_SNAP=$(python3 System/scripts/session_liveness.py dirty "$PROJECT_DIR" 15 2>/dev/null) && {
    NEW_WORK=$(LC_ALL=C comm -13 <(LC_ALL=C sort "$START_SNAP") <(printf '%s\n' "$NOW_SNAP" | sed '/^$/d' | LC_ALL=C sort))
    [ -z "$NEW_WORK" ] && exit 0
  }
else
  SINCE=$(python3 System/scripts/session_liveness.py since "$PROJECT_DIR" 15 2>/dev/null) && {
    NEW_WORK="$SINCE"
    [ -z "$NEW_WORK" ] && exit 0
  }
fi
# v4.3 (8.1.5): сессия простаивала к концу (окно закрыли или отправили в архив через сутки после /end) —
# правки позже её последнего действия сделали соседние сессии, это не её работа. Работала до конца —
# всё по-прежнему её. Не удалось прочитать журнал — тоже по-прежнему.
if [ -n "$NEW_WORK" ] && [ -n "$TRANSCRIPT" ]; then
  OWN=$(printf '%s\n' "$NEW_WORK" | python3 System/scripts/session_liveness.py own "$TRANSCRIPT" 2>/dev/null) && {
    NEW_WORK="$OWN"
    [ -z "$NEW_WORK" ] && exit 0
  }
fi

mkdir -p .claude
TIMESTAMP_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Список изменённых файлов (ДО любых git-операций): работа этой сессии, если она известна, иначе всё
# значимое. Путь — целиком, по строке на файл (8.1.3: awk '{print $NF}' резал пути с пробелами,
# а склейка через запятую — имена с запятой).
if [ -n "$NEW_WORK" ]; then
  CHANGED_FILES=$(printf '%s\n' "$NEW_WORK" | cut -f2 | sed 's/ <- .*//' | head -20)
else
  CHANGED_FILES=$(printf '%s\n' "$SIGNIFICANT" | sed -E 's/^.{3}//; s/^.* -> //; s/^"(.*)"$/\1/' | head -20)
fi

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
       SNAP_FILES="$CHANGED_FILES" SNAP_REF="$SNAPSHOT_REF" SNAP_MARKER="$MARKER" SNAP_SID="$SID"
python3 <<'PYEOF'
import json, os, tempfile
marker = os.environ.get("SNAP_MARKER", ".claude/.session_incomplete.json")
ref = os.environ.get("SNAP_REF", "")
data = {
    "timestamp": os.environ.get("SNAP_TS", ""),
    "session_id": os.environ.get("SNAP_SID", ""),   # чей маркер: вернувшаяся сессия узнаёт свой (8.1.5)
    "reason": os.environ.get("SNAP_REASON", "unknown"),
    "status": "marker_only+snapshot_ref" if ref else "marker_only",
    "last_commit": os.environ.get("SNAP_COMMIT", ""),
    "snapshot_ref": ref,                       # git stash create хэш; якорь refs/wip-snapshot/<sid>
    "changed_files": [f for f in os.environ.get("SNAP_FILES", "").split("\n") if f],
    "note": ("Сессия не закрыта через /end. Данные — в рабочем дереве (git status/diff). "
             "Если дерево вычищено — восстановить снапшот: git stash apply <snapshot_ref>. "
             "STARTUP/recovery: восстанови wrap-up по git log+diff и закрой через /end."),
}
# Маркер уже есть (окна закрылись подряд — выход или обновление приложения) — его файлы не теряем: в нём
# может быть чужая работа. Чужой маркер → session_id пуст: вернувшееся окно не примет общий маркер за свой.
try:
    with open(marker, encoding="utf-8") as f:
        prev = json.load(f)
except Exception:
    prev = None
if isinstance(prev, dict):
    if prev.get("session_id") != data["session_id"]:
        data["session_id"] = ""
    data["changed_files"] = sorted(set(data["changed_files"]) | set(prev.get("changed_files") or []))
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
