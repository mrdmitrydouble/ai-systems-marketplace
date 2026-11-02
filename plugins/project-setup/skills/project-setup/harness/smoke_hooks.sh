#!/bin/bash
# smoke_hooks.sh — функциональный smoke-тест harness-хуков (DoD Правила 4: «red→green»).
# Прогоняет РЕАЛЬНЫЕ хуки из .claude/hooks/ на crafted-вводе в ИЗОЛИРОВАННОЙ /tmp-песочнице
# (CLAUDE_PROJECT_DIR=песочница), чтобы тест не засорял .claude/live_sessions/ и git живого
# проекта. exit≠0 при любом провале → пригоден для CI/scheduled.
#
# Покрытие:
#   memory_write_guard: frozen-блок (exit2) · чистая запись (exit0) · живой соперник→deny+inbox ·
#                       маркер без процесса→НЕ блокирует (контракт v4) · inbox-путь→exit0
#   stop_guard: декларация без свежего PROGRESS (exit2) · benign (exit0) · escape hatch (exit0) · свежий PROGRESS (exit0)
#   установка: System/scripts/session_liveness.py проекта на месте и импортируется (без него страж молча выключен)
#   ложный RECOVERY (8.1.1): страж не оставляет __pycache__ · снапшот не считает работой кэш Python,
#                       live-маркер соседней сессии, отметку прогона (System/state/) и сам старый
#                       маркер · но пишет маркер при настоящей
#                       незакоммиченной правке (позитивный контроль)
#   dead-path детектор (логика quick_health): 2 мёртвых cwd → count=2 + оба id ; disabled не считается
#
# Запуск: bash System/scripts/smoke_hooks.sh   (см. также quick_health.sh — детектор dead-path)

set -u
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOKS="$PROJECT_ROOT/.claude/hooks"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ❌ $1"; }

# Изолированная песочница
SBX=$(mktemp -d "/tmp/smoke_hooks.XXXXXX")
trap 'rm -rf "$SBX"' EXIT
mkdir -p "$SBX/System/memory/inbox_sessions" "$SBX/Project/Sources" "$SBX/.claude/live_sessions"
export CLAUDE_PROJECT_DIR="$SBX"

run_guard() { # stdin JSON → запускает memory_write_guard, печатает "EXIT=<code>" + stdout
  local input="$1"
  local out; out=$(printf '%s' "$input" | bash "$HOOKS/memory_write_guard.sh" 2>/dev/null)
  echo "EXIT=$?|$out"
}

echo "=== SMOKE: установка ==="
# Проверки стража ниже идут в песочнице со стабами — они не видят, лежит ли модуль живости в САМОМ
# проекте. А без него страж молча пропускает любую запись (fail-open). Поэтому — отдельная проверка.
if python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import session_liveness as L; sys.exit(0 if callable(getattr(L, "blocking_rivals", None)) else 1)' \
     "$PROJECT_ROOT/System/scripts" >/dev/null 2>&1; then
  ok "System/scripts/session_liveness.py на месте и импортируется"
else
  bad "нет рабочего System/scripts/session_liveness.py → страж параллельных сессий молча выключен"
fi

echo "=== SMOKE: memory_write_guard ==="

# 1) frozen zone → exit 2
R=$(printf '{"tool_input":{"file_path":"%s/Project/Sources/x.md"},"session_id":"sA"}' "$SBX" | bash "$HOOKS/memory_write_guard.sh" 2>/dev/null; echo "rc=$?")
echo "$R" | grep -q 'rc=2' && ok "frozen Sources → exit 2" || bad "frozen Sources: $R"

R=$(printf '{"tool_input":{"file_path":"/x/_backup/y.md"},"session_id":"sA"}' | bash "$HOOKS/memory_write_guard.sh" 2>/dev/null; echo "rc=$?")
echo "$R" | grep -q 'rc=2' && ok "frozen _backup → exit 2" || bad "frozen _backup: $R"

# 2) чистая запись в память без соперников → exit 0, без deny
rm -f "$SBX/.claude/live_sessions/"*.marker 2>/dev/null
OUT=$(printf '{"tool_input":{"file_path":"%s/System/memory/PROGRESS.md"},"session_id":"sA"}' "$SBX" | bash "$HOOKS/memory_write_guard.sh" 2>/dev/null); RC=$?
{ [ "$RC" = "0" ] && ! echo "$OUT" | grep -q '"deny"'; } && ok "чистая запись (нет соперников) → exit 0, без deny" || bad "чистая запись: rc=$RC out=$OUT"

# 3) чужая live-сессия → deny + инструкция в inbox (stdout JSON), exit 0
#
# ПОЧЕМУ ЧЕРЕЗ ПОДСТАВНОЙ МОДУЛЬ. В harness v4 соперник — это РЕАЛЬНЫЙ живой процесс
# claude с рабочей папкой этого проекта. Подделать его файлом-маркером нельзя (в этом
# и смысл v4: маркеры врали на долгих сессиях). Значит smoke-тест физически не может
# создать настоящего соперника — и старая версия этого теста, крафтившая маркер, была
# ВЕЧНО КРАСНОЙ, приучая читателя игнорировать красный цвет.
# Поэтому проверяем две РАЗНЫЕ вещи по отдельности:
#   3а — решение стража при живом сопернике (живость подменяем стабом);
#   3б — контракт v4: маркер без живого процесса НЕ блокирует (нет ложных блокировок).
STUB_DIR="$SBX/System/scripts"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/session_liveness.py" <<'STUB'
def blocking_rivals(d):  return ["99999"]
def describe(d, pids=None):  return "  • сессия-соперник PID 99999 (стаб теста)"
STUB
OUT=$(printf '{"tool_input":{"file_path":"%s/System/memory/PROGRESS.md"},"session_id":"sA"}' "$SBX" | bash "$HOOKS/memory_write_guard.sh" 2>/dev/null); RC=$?
{ [ "$RC" = "0" ] && echo "$OUT" | grep -q '"permissionDecision": "deny"' && echo "$OUT" | grep -q 'inbox_sessions'; } \
  && ok "живой соперник → deny + редирект в inbox" || bad "живой соперник: rc=$RC out=$OUT"
rm -f "$STUB_DIR/session_liveness.py" "$STUB_DIR"/__pycache__/session_liveness*.pyc 2>/dev/null

# 3б) маркер без живого процесса НЕ должен блокировать (контракт v4, анти-ложная-блокировка)
printf 'now' > "$SBX/.claude/live_sessions/ZZrival0000.marker"   # v3-стиль: время без PID
OUT=$(printf '{"tool_input":{"file_path":"%s/System/memory/PROGRESS.md"},"session_id":"sA"}' "$SBX" | bash "$HOOKS/memory_write_guard.sh" 2>/dev/null); RC=$?
{ [ "$RC" = "0" ] && ! echo "$OUT" | grep -q '"deny"'; } \
  && ok "маркер без живого процесса → НЕ блокирует (контракт v4)" || bad "ложная блокировка по маркеру: rc=$RC out=$OUT"
rm -f "$SBX/.claude/live_sessions/ZZrival0000.marker"

# 4) путь inbox_sessions → всегда exit 0 (даже при сопернике)
printf 'now' > "$SBX/.claude/live_sessions/ZZrival0000.marker"
OUT=$(printf '{"tool_input":{"file_path":"%s/System/memory/inbox_sessions/d.md"},"session_id":"sA"}' "$SBX" | bash "$HOOKS/memory_write_guard.sh" 2>/dev/null); RC=$?
{ [ "$RC" = "0" ] && ! echo "$OUT" | grep -q '"deny"'; } && ok "inbox-путь → exit 0 (личная зона)" || bad "inbox-путь: rc=$RC out=$OUT"
rm -f "$SBX/.claude/live_sessions/"*.marker

echo "=== SMOKE: stop_guard ==="
# Подготовка git-песочницы (work signal = untracked файл) + transcript
( cd "$SBX" && git init -q && git config user.email s@s && git config user.name s && git config commit.gpgsign false )
printf 'work' > "$SBX/uncommitted.txt"   # untracked → git status непустой → WORK_SIGNAL=1
TR="$SBX/transcript.jsonl"

# stale PROGRESS (mtime > 10 мин назад)
printf '# progress' > "$SBX/System/memory/PROGRESS.md"
touch -t 202601010000 "$SBX/System/memory/PROGRESS.md"

# B1) декларация завершения + work signal + stale PROGRESS → exit 2 (БЛОК)
printf '%s\n' '{"type":"assistant","message":{"content":"Готово. Сессия завершена, hand-off готов."}}' > "$TR"
printf '{"transcript_path":"%s","stop_hook_active":false}' "$TR" | bash "$HOOKS/stop_guard.sh" >/dev/null 2>&1
[ $? -eq 2 ] && ok "декларация без свежего PROGRESS → exit 2" || bad "декларация: ожидался exit 2"

# B2) benign (нет ключевых слов) → exit 0
printf '%s\n' '{"type":"assistant","message":{"content":"Продолжаю работу над задачей."}}' > "$TR"
printf '{"transcript_path":"%s","stop_hook_active":false}' "$TR" | bash "$HOOKS/stop_guard.sh" >/dev/null 2>&1
[ $? -eq 0 ] && ok "benign ответ → exit 0" || bad "benign: ожидался exit 0"

# B3) escape hatch (user: «без wrap-up») → exit 0 даже при декларации
printf '%s\n' '{"type":"assistant","message":{"content":"Сессия завершена."}}' > "$TR"
printf '%s\n' '{"type":"user","message":{"content":"закончим без wrap-up"}}' >> "$TR"
printf '{"transcript_path":"%s","stop_hook_active":false}' "$TR" | bash "$HOOKS/stop_guard.sh" >/dev/null 2>&1
[ $? -eq 0 ] && ok "escape hatch «без wrap-up» → exit 0" || bad "escape hatch: ожидался exit 0"

# B4) свежий PROGRESS → exit 0 (wrap-up уже сделан)
printf '%s\n' '{"type":"assistant","message":{"content":"Сессия завершена."}}' > "$TR"
touch "$SBX/System/memory/PROGRESS.md"   # свежий mtime
printf '{"transcript_path":"%s","stop_hook_active":false}' "$TR" | bash "$HOOKS/stop_guard.sh" >/dev/null 2>&1
[ $? -eq 0 ] && ok "свежий PROGRESS → exit 0" || bad "свежий PROGRESS: ожидался exit 0"

# B5) рекурсия (stop_hook_active=true) → exit 0
printf '%s\n' '{"type":"assistant","message":{"content":"Сессия завершена."}}' > "$TR"
touch -t 202601010000 "$SBX/System/memory/PROGRESS.md"
printf '{"transcript_path":"%s","stop_hook_active":true}' "$TR" | bash "$HOOKS/stop_guard.sh" >/dev/null 2>&1
[ $? -eq 0 ] && ok "stop_hook_active=true → exit 0 (анти-рекурсия)" || bad "рекурсия: ожидался exit 0"

echo "=== SMOKE: ложный RECOVERY (кэш и служебные файлы ≠ работа сессии) ==="
# Класс бага (8.1.1): страж импортировал session_liveness → Python клал System/scripts/__pycache__/ →
# дерево навсегда «грязное» → каждый прогон без /end (scheduled!) писал маркер «сессия не закрыта».
# R1) страж импортирует модуль живости и НЕ оставляет байткод. env -u: проверка честная и там,
#     где PYTHONDONTWRITEBYTECODE уже выставлен (иначе тест прошёл бы вхолостую).
rm -rf "$STUB_DIR/__pycache__" "$STUB_DIR/imported.flag"
cat > "$STUB_DIR/session_liveness.py" <<'STUB'
import os
open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "imported.flag"), "w").close()
def blocking_rivals(d):  return []
def describe(d, pids=None):  return ""
STUB
printf '{"tool_input":{"file_path":"%s/System/memory/PROGRESS.md"},"session_id":"sA"}' "$SBX" \
  | env -u PYTHONDONTWRITEBYTECODE bash "$HOOKS/memory_write_guard.sh" >/dev/null 2>&1
if [ ! -f "$STUB_DIR/imported.flag" ]; then
  bad "страж не импортировал модуль живости — проверка байткода невалидна"
elif [ -d "$STUB_DIR/__pycache__" ]; then
  bad "страж оставил $STUB_DIR/__pycache__ → вечный ложный RECOVERY"
else
  ok "страж импортирует модуль живости без __pycache__"
fi
rm -rf "$STUB_DIR/session_liveness.py" "$STUB_DIR/imported.flag" "$STUB_DIR/__pycache__"

# R2) снапшот: «грязь» = только кэш Python → маркер НЕ пишется.
#     System/scripts/ и .claude/ отслеживаются git (как в живом проекте) — иначе status свернул бы
#     всё в «?? System/» или «?? .claude/», и проверка мерила бы не то.
RREPO="$SBX/recovery_repo"
MARKER="$RREPO/.claude/.session_incomplete.json"
mkdir -p "$RREPO/System/scripts/__pycache__" "$RREPO/.claude"
( cd "$RREPO" && git init -q && git config user.email s@s && git config user.name s && git config commit.gpgsign false \
  && printf 'x' > System/scripts/tool.sh && printf '{}' > .claude/settings.json && printf 'base' > notes.md \
  && git add -A && git commit -q -m base )
printf 'pyc' > "$RREPO/System/scripts/__pycache__/session_liveness.cpython-314.pyc"
printf '{"session_id":"sched1","reason":"other"}' | CLAUDE_PROJECT_DIR="$RREPO" bash "$HOOKS/session_end_snapshot.sh" >/dev/null 2>&1
[ ! -f "$MARKER" ] && ok "грязь = только __pycache__ → маркер НЕ пишется" \
  || bad "ложный маркер «сессия не закрыта» из-за __pycache__"

# R3) live-маркер соседней живой сессии (scheduled-прогон кончился, пока открыта сессия владельца) → не работа
rm -f "$MARKER"
mkdir -p "$RREPO/.claude/live_sessions" && printf 'now' > "$RREPO/.claude/live_sessions/OTHER.marker"
printf '{"session_id":"sched2","reason":"other"}' | CLAUDE_PROJECT_DIR="$RREPO" bash "$HOOKS/session_end_snapshot.sh" >/dev/null 2>&1
[ ! -f "$MARKER" ] && ok "live-маркер соседней сессии → маркер НЕ пишется" \
  || bad "ложный маркер из-за .claude/live_sessions/ соседней сессии"

# R3б) отметка прогона stamp_run (System/state/ — локальный факт машины) без .gitignore → не работа
rm -f "$MARKER"
mkdir -p "$RREPO/System/state/runs" && printf '2026-11-02 10:00' > "$RREPO/System/state/runs/digest.txt"
printf '{"session_id":"sched4","reason":"other"}' | CLAUDE_PROJECT_DIR="$RREPO" bash "$HOOKS/session_end_snapshot.sh" >/dev/null 2>&1
[ ! -f "$MARKER" ] && ok "отметка прогона в System/state/ → маркер НЕ пишется" \
  || bad "ложный маркер из-за отметки прогона в System/state/"

# R4) старый маркер не считает работой сам себя — иначе он вечен: каждый прогон без /end его переписывает
printf '{"stale":true}' > "$MARKER"
printf '{"session_id":"sched3","reason":"other"}' | CLAUDE_PROJECT_DIR="$RREPO" bash "$HOOKS/session_end_snapshot.sh" >/dev/null 2>&1
grep -q '"stale"' "$MARKER" 2>/dev/null && ok "старый маркер сам себя не переписывает" \
  || bad "маркер переписал сам себя → ложный RECOVERY продлевается каждым прогоном"

# R5) позитивный контроль: настоящая незакоммиченная правка → маркер ПИШЕТСЯ и называет файл
#     (фильтры R2–R4 не глушат работу; старый маркер из R4 заменён свежим)
printf ' changed' >> "$RREPO/notes.md"
printf '{"session_id":"live1","reason":"other"}' | CLAUDE_PROJECT_DIR="$RREPO" bash "$HOOKS/session_end_snapshot.sh" >/dev/null 2>&1
grep -q 'notes.md' "$MARKER" 2>/dev/null && ok "настоящая правка → маркер пишется (фильтр не глушит работу)" \
  || bad "маркер НЕ записан при реальной незакоммиченной правке"

echo "=== SMOKE: dead-path детектор (логика quick_health) ==="
# Контракт ДОЛЖЕН совпадать с блоком dead-path в quick_health.sh (секция [HARNESS]).
DEADJSON="$SBX/sched.json"
cat > "$DEADJSON" <<'JSON'
{"scheduledTasks":[
 {"id":"task-A","enabled":true,"cwd":"/nonexistent/path/A"},
 {"id":"task-B","enabled":true,"cwd":"/nonexistent/path/B"},
 {"id":"task-C-disabled","enabled":false,"cwd":"/nonexistent/path/C"},
 {"id":"task-D-live","enabled":true,"cwd":"/tmp"}
]}
JSON
RES=$(python3 - "$DEADJSON" <<'PYEOF'
import json,os,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
tasks=d.get("scheduledTasks")
if isinstance(tasks,dict): tasks=list(tasks.values())
dead=set()
for t in (tasks or []):
    if isinstance(t,dict):
        if t.get("enabled",True) is False: continue
        cwd=t.get("cwd","")
        if cwd and not os.path.isdir(cwd): dead.add(t.get("id") or t.get("taskId") or "?")
print(len(dead)); [print(x) for x in sorted(dead)]
PYEOF
)
COUNT=$(echo "$RES" | head -1)
IDS=$(echo "$RES" | tail -n +2 | tr '\n' ',' | sed 's/,$//')
{ [ "$COUNT" = "2" ] && echo "$IDS" | grep -q 'task-A' && echo "$IDS" | grep -q 'task-B' && ! echo "$IDS" | grep -q '?'; } \
  && ok "2 мёртвых cwd → count=2, оба id [$IDS] (не '?')" || bad "dead-path: count=$COUNT ids=[$IDS] (ожидалось 2 + task-A,task-B)"
echo "$IDS" | grep -q 'task-C-disabled' && bad "disabled-задача попала в мёртвые " || ok "disabled-задача исключена из подсчёта"

echo "=== SMOKE: детектор пульса (анти-ложный-якорь + окно свежести) ==="
# Контракт ДОЛЖЕН совпадать с check_pulse_freshness.sh: якорный grep ^шаблон + окно MAX_AGE=9.
PREPO="$SBX/pulse_repo"
mkdir -p "$PREPO" && ( cd "$PREPO" && git init -q && git config user.email s@s && git config user.name s && git config commit.gpgsign false )
# ловушка ложного срабатывания: heartbeat-жалоба, упоминающая фразу В СЕРЕДИНЕ сообщения
( cd "$PREPO" && echo a > a && git add -A && git commit -q -m "heartbeat (вт): watchdog — weekly digest пн не вышел" )
TRAP=$(git -C "$PREPO" log --grep="^weekly digest" --oneline 2>/dev/null | wc -l | tr -d ' ')
[ "$TRAP" = "0" ] && ok "якорь ^ исключает heartbeat-жалобу (анти-ложный-скип)" || bad "якорь: жалоба попала в матч (=$TRAP, ожидалось 0)"
NOANCHOR=$(git -C "$PREPO" log --grep="weekly digest" --oneline 2>/dev/null | wc -l | tr -d ' ')
[ "$NOANCHOR" = "1" ] && ok "без якоря жалоба ловится (=1) — подтверждает необходимость ^" || bad "без якоря: ожидалось 1, получено $NOANCHOR"
# реальная доставка дайджеста
( cd "$PREPO" && echo b > b && git add -A && git commit -q -m "weekly digest 2026-06-22" )
REAL=$(git -C "$PREPO" log --grep="^weekly digest" --oneline 2>/dev/null | wc -l | tr -d ' ')
[ "$REAL" = "1" ] && ok "реальная доставка ловится якорем (=1)" || bad "доставка: ожидалось 1, получено $REAL"
# окно свежести: свежая доставка (сегодня) ≤ MAX_AGE → НЕ stale
DTODAY=$(git -C "$PREPO" log -1 --grep="^weekly digest" --format=%cd --date=short 2>/dev/null)
TS=$(date -j -f "%Y-%m-%d" "$DTODAY" +%s 2>/dev/null || date -d "$DTODAY" +%s 2>/dev/null || echo 0)
AGE=$(( ($(date +%s) - TS) / 86400 ))
{ [ "$AGE" -ge 0 ] && [ "$AGE" -le 9 ]; } && ok "свежая доставка age=$AGE ≤ 9 → НЕ stale" || bad "окно свежести: age=$AGE вне [0..9]"

echo ""
echo "=== ИТОГ: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] && { echo "SMOKE: ЗЕЛЁНЫЙ"; exit 0; } || { echo "SMOKE: КРАСНЫЙ ($FAIL провалов)"; exit 1; }
