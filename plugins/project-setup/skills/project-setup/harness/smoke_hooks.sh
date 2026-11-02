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
#   распознавание сессий (8.1.2): все виды установки claude по точному argv[0], но не помощники, GUI и
#                       чужие аргументы · вложенный claude — часть сессии, PID 1 — сессия · блокирует только
#                       работающая сессия, в т.ч. через субагента · подметание не трогает свой маркер ·
#                       журнал ищется по пути из маркера и в CLAUDE_CONFIG_DIR · папка со скобками [GitHub] (8.1.3)
#   «не закрыта» только за работу этой сессии (8.1.2, разница снимков старта и конца): давний черновик и
#                       давнее удаление — не работа; правка, git mv, cp -p, chmod — работа · устаревший
#                       маркер без снапшота при чистом дереве снимается молча, со снапшотом — нет · при
#                       незакоммиченной работе — RECOVERY · сжатие не сдвигает старт и не переснимает снимок ·
#                       окно без снимка судит по старту процесса · имя с пробелом в маркере целиком (8.1.3)
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

echo "=== SMOKE: распознавание сессий (модуль живости проекта) ==="
LIVE_MOD="$PROJECT_ROOT/System/scripts"
# T1) кто считается сессией claude: по точному argv[0] (`ps -o comm`), по заголовку процесса «claude»
#     и node/bun со скриптом claude. Класс бага 8.1.2: десктоп сменил путь к claude — страж месяцами
#     молча никого не видел. Отрицательные случаи — помощник disclaimer, GUI и чужие аргументы с «/claude».
PAT_RES=$(python3 -B - "$LIVE_MOD" 2>&1 <<'PYEOF'
import sys; sys.path.insert(0, sys.argv[1]); import session_liveness as L
APP = "/Users/u/Library/Application Support/Claude/claude-code"
NEW = APP + "/2.1.309/5af865b9901c/claude.app/Contents/MacOS/claude"
GUI = "/Applications/Claude.app/Contents"
yes = [(NEW, NEW + " --output-format stream-json"), (APP + "/2.1.150/claude", APP + "/2.1.150/claude --verbose"),
       ("claude", "claude --resume"), ("/Users/u/.local/bin/claude", "/Users/u/.local/bin/claude -p hi"),
       ("/home/u/.local/share/claude/versions/2.1.220", "/home/u/.local/share/claude/versions/2.1.220 --continue"),
       ("node", "claude --resume"), ("node", "node /usr/local/bin/claude"),
       ("/opt/homebrew/bin/node", "/opt/homebrew/bin/node /opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"),
       ("node", "node --max-old-space-size=4096 /Users/u/.npm/_npx/1/node_modules/.bin/claude")]
no = [(GUI + "/Helpers/disclaimer", GUI + "/Helpers/disclaimer --pgroup -- " + NEW + " --output-format stream-json"),
      (GUI + "/MacOS/Claude", GUI + "/MacOS/Claude"),
      (GUI + "/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)",
       GUI + "/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer) --type=renderer"),
      ("node", "node /Users/u/.claude/plugins/cache/x/server.js"), ("python3", "python3 System/scripts/session_liveness.py self"),
      ("grep", "grep claude"), ("vim", "vim claude.md"), ("/bin/zsh", "/bin/zsh -c claude plugin list"),
      ("/bin/zsh", "/bin/zsh -c export X=/Users/u/.local/bin/claude"), ("/usr/bin/python3", "/usr/bin/python3 ./claude"),
      ("/opt/homebrew/bin/uv", "/opt/homebrew/bin/uv run --directory=/Users/u/mcp/claude"),
      ("/usr/bin/claude-monitor", "/usr/bin/claude-monitor")]
bad = ["не узнал: " + c for a, c in yes if not L.is_claude_proc(a, c)] + \
      ["ложно узнал: " + c for a, c in no if L.is_claude_proc(a, c)]
print("\n".join(bad) if bad else "OK")
PYEOF
)
[ "$PAT_RES" = "OK" ] && ok "сессии claude узнаются во всех видах установки; помощники, GUI и чужие аргументы — нет" \
  || bad "распознавание сессий: $(echo "$PAT_RES" | tail -3 | tr '\n' ';')"

# T2) сессия = самый верхний claude в цепочке: claude, запущенный изнутри сессии, — не соперник;
#     claude с PID 1 (контейнер) — тоже сессия
NEST=$(python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import session_liveness as L
parent = {"100": "1", "101": "100", "102": "101", "103": "102", "200": "1", "201": "200"}
claude = {"101", "103", "201"}
r = sorted(L._roots(parent, claude)); t = L._top_claude("103", parent, claude)
c = {"1": "0", "5": "1"}; p1 = L._roots(c, {"1"}) == ["1"] and L._top_claude("5", c, {"1"}) == "1"
print("OK" if r == ["101", "201"] and t == "101" and p1 else "roots=%s top=%s pid1=%s" % (r, t, p1))' "$LIVE_MOD" 2>&1 | tail -1)
[ "$NEST" = "OK" ] && ok "вложенный claude — часть своей сессии; claude с PID 1 (контейнер) — сессия" || bad "вложенность: $NEST"

# T3) мешает только сессия, которая работает сейчас: её журнал или журнал её субагента писался
#     < ACTIVE_MIN мин назад. Простаивающая, по расписанию, без маркера и без журнала — не блокируют.
AH="$SBX/home"; AD="$SBX/act_proj"; AP="$AH/.claude/projects/p"
mkdir -p "$AP/sE/subagents" "$AD/.claude/live_sessions"
for pair in sA:111 sB:222 sC:333 sE:555 sF:666; do printf 't\n%s\n0\n' "${pair#*:}" > "$AD/.claude/live_sessions/${pair%%:*}.marker"; done
printf '%s\n' '{"type":"user","message":{"content":"работаю"}}' > "$AP/sA.jsonl"
printf '%s\n' '{"type":"user","message":{"content":"старое окно"}}' > "$AP/sB.jsonl"
printf '%s\n' '{"type":"user","message":{"content":"<scheduled-task name=\"digest\">прогон</scheduled-task>"}}' > "$AP/sC.jsonl"
printf '%s\n' '{"type":"user","message":{"content":"жду субагента"}}' > "$AP/sE.jsonl"
printf '%s\n' '{"type":"assistant"}' > "$AP/sE/subagents/agent-1.jsonl"
touch -t 202601010000 "$AP/sB.jsonl" "$AP/sE.jsonl"
ST=$(HOME="$AH" CLAUDE_CONFIG_DIR="" python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import session_liveness as L
print(" ".join(L._state(sys.argv[2], p)[0] for p in ("111", "222", "333", "444", "555", "666")))' "$LIVE_MOD" "$AD" 2>&1 | tail -1)
[ "$ST" = "active idle scheduled unknown active nolog" ] \
  && ok "блокирует только работающая сессия (в т.ч. через субагента); простаивающая, по расписанию, без маркера — нет" \
  || bad "состояния сессий: [$ST], ожидалось [active idle scheduled unknown active nolog]"

# T4) подметание снимает маркер мёртвой сессии, но не свой (иначе старт сессии стирается сразу после
#     записи). Снимок мёртвой сессии остаётся — она может вернуться после сбоя (resume); осиротевшие
#     снимки старше 7 дней и брошенные *.dirty.tmp старше часа — убираются.
SW=$(python3 -B -c 'import sys, os, time; sys.path.insert(0, sys.argv[1]); import session_liveness as L
d = sys.argv[2]; reg = os.path.join(d, ".claude", "live_sessions"); os.makedirs(reg, exist_ok=True)
def mk(name, body, age=0):
    p = os.path.join(reg, name); open(p, "w").write(body)
    if age: os.utime(p, (time.time() - age, time.time() - age))
mk("me.marker", "t\n999\n0\n"); mk("dead.marker", "t\n998\n0\n"); mk("dead.dirty", "")
mk("old.dirty", "", 8 * 86400); mk("x.dirty.tmp", "", 7200)
L.live_pids = lambda _d: []
L.self_pid = lambda start=None: "999"
L.sweep(d); left = sorted(os.listdir(reg))
print("OK" if left == ["dead.dirty", "me.marker"] else "осталось: %s" % left)' "$LIVE_MOD" "$SBX/sweep_proj" 2>&1 | tail -1)
[ "$SW" = "OK" ] && ok "подметание: маркер мёртвой сессии снят, свой и снимок для возврата после сбоя — на месте, мусор убран" \
  || bad "подметание: $SW"

# T5) журнал ищется там, где его держит Claude Code: путь из маркера (строка 4) и $CLAUDE_CONFIG_DIR
CF="$SBX/cfg"; CD="$SBX/cfg_proj"
mkdir -p "$CF/projects/q" "$CD/.claude/live_sessions" "$SBX/elsewhere"
printf '%s\n' '{"type":"user","message":{"content":"x"}}' > "$CF/projects/q/sG.jsonl"
printf '%s\n' '{"type":"user","message":{"content":"y"}}' > "$SBX/elsewhere/any-name.jsonl"
printf 't\n777\n0\n\n' > "$CD/.claude/live_sessions/sG.marker"
printf 't\n888\n0\n%s\n' "$SBX/elsewhere/any-name.jsonl" > "$CD/.claude/live_sessions/sH.marker"
CS=$(HOME="$SBX/nohome" CLAUDE_CONFIG_DIR="$CF" python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import session_liveness as L
print(L._state(sys.argv[2], "777")[0], L._state(sys.argv[2], "888")[0])' "$LIVE_MOD" "$CD" 2>&1 | tail -1)
[ "$CS" = "active active" ] && ok "журнал сессии находится по пути из маркера и в CLAUDE_CONFIG_DIR" \
  || bad "поиск журнала: [$CS], ожидалось [active active]"

# T6) путь проекта со скобками (8.1.3): «7. Venture Lovers [GitHub]» — для glob это шаблон, и маркеры
#     не находились никогда; страж молча не блокировал. Маркер, работающая сессия и подметание — в такой папке.
BD="$SBX/proj [GitHub]"; mkdir -p "$BD/.claude/live_sessions"
printf '%s\n' '{"type":"user","message":{"content":"z"}}' > "$SBX/br.jsonl"
printf 't\n555\n0\n%s\n' "$SBX/br.jsonl" > "$BD/.claude/live_sessions/sB.marker"
printf 't\n554\n0\n' > "$BD/.claude/live_sessions/sDead.marker"
BR=$(python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import session_liveness as L
d = sys.argv[2]; st = L._state(d, "555")[0]
L.live_pids = lambda _d: ["555"]; L.self_pid = lambda start=None: "555"; L.sweep(d)
import os; left = sorted(os.listdir(os.path.join(d, ".claude", "live_sessions")))
print(st, ",".join(left))' "$LIVE_MOD" "$BD" 2>&1 | tail -1)
[ "$BR" = "active sB.marker" ] && ok "папка со скобками в имени ([GitHub]): маркер найден, работающая сессия видна, подметание работает" \
  || bad "папка со скобками: [$BR], ожидалось [active sB.marker] — страж слеп в таких узлах"

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

echo "=== SMOKE: «не закрыта» — только за работу этой сессии ==="
# Класс бага 8.1.2: давний незакоммиченный черновик делал «незакрытой» КАЖДУЮ сессию, а маркер при
# чистом дереве висел месяцами. Работа сессии = разница снимков незакоммиченного на старте и в конце
# (снимки пишет модуль живости проекта, поэтому он копируется в песочницу).
WREPO="$SBX/work_repo"; WM="$WREPO/.claude/.session_incomplete.json"
mkdir -p "$WREPO/System/scripts" "$WREPO/.claude/live_sessions"
cp "$LIVE_MOD/session_liveness.py" "$WREPO/System/scripts/" 2>/dev/null
( cd "$WREPO" && git init -q && git config user.email s@s && git config user.name s && git config commit.gpgsign false \
  && printf 'x' > System/scripts/tool.sh && printf '{}' > .claude/settings.json && printf 'base' > notes.md \
  && printf 'old' > old.txt && git add -A && git commit -q -m base )
start_hook() { printf '{"session_id":"%s","source":"%s"}' "$1" "${2:-startup}" \
  | CLAUDE_PROJECT_DIR="$WREPO" bash "$HOOKS/session_start_recovery.sh" 2>/dev/null; }
end_hook() { printf '{"session_id":"%s","reason":"other"}' "$1" \
  | CLAUDE_PROJECT_DIR="$WREPO" bash "$HOOKS/session_end_snapshot.sh" >/dev/null 2>&1; }

# W1) давний черновик и давнее удаление лежат в дереве ДО старта → сессия ничего не сделала → маркера нет
printf 'draft' > "$WREPO/draft.docx"; rm -f "$WREPO/old.txt"
start_hook w1 >/dev/null; end_hook w1
[ ! -f "$WM" ] && ok "давний черновик и давнее удаление → маркер НЕ пишется (работа не этой сессии)" \
  || bad "давняя незакоммиченная грязь делает каждую сессию «незакрытой»"

# W2) та же давняя грязь + правка этой сессии → маркер пишется и называет файл
start_hook w2 >/dev/null; printf ' edit' >> "$WREPO/notes.md"; end_hook w2
grep -q 'notes.md' "$WM" 2>/dev/null && ok "правка этой сессии поверх давней грязи → маркер пишется" \
  || bad "работа этой сессии не попала в маркер"
rm -f "$WM"; ( cd "$WREPO" && git checkout -q -- notes.md )

# W2б) работа без свежей даты файла — git mv, cp -p старого файла, chmod — тоже работа сессии
touch -t 202601010000 "$WREPO/System/scripts/tool.sh"
i=0; MISSED=""
for act in "git mv notes.md notes2.md" "cp -p System/scripts/tool.sh copy.sh" "chmod +x notes.md"; do
  i=$((i + 1)); rm -f "$WM"
  start_hook "w2b$i" >/dev/null; ( cd "$WREPO" && eval "$act" ); end_hook "w2b$i"
  [ -f "$WM" ] || MISSED="$MISSED [$act]"
  ( cd "$WREPO" && git reset -q --hard && rm -f copy.sh )
done
[ -z "$MISSED" ] && ok "git mv, cp -p и chmod → маркер пишется (работа без свежей даты файла)" \
  || bad "не увидел работу сессии:$MISSED"

# W3) старт: маркер при чистом дереве и без снапшота устарел → снимается молча, без RECOVERY
( cd "$WREPO" && git reset -q --hard && rm -f draft.docx )
printf '{"timestamp":"old","snapshot_ref":""}' > "$WM"
OUT=$(start_hook w3)
{ [ ! -f "$WM" ] && ! echo "$OUT" | grep -q "RECOVERY"; } && ok "старт: устаревший маркер в чистом дереве снят молча" \
  || bad "старт: устаревший маркер при чистом дереве всё ещё даёт RECOVERY"

# W3б) маркер со снапшотом (там может лежать отброшенная правка) при чистом дереве НЕ снимается
printf '{"timestamp":"t","snapshot_ref":"0123abcd"}' > "$WM"
OUT=$(start_hook w3b)
{ [ -f "$WM" ] && echo "$OUT" | grep -q "RECOVERY MODE"; } && ok "старт: маркер со снапшотом при чистом дереве не снимается (RECOVERY)" \
  || bad "старт: снят маркер, в снапшоте которого может лежать отброшенная правка"

# W4) старт: маркер + незакоммиченная работа → RECOVERY, маркер на месте (защита P-001 не ослабла)
printf ' edit' >> "$WREPO/notes.md"; printf '{"timestamp":"t"}' > "$WM"
OUT=$(start_hook w4)
{ [ -f "$WM" ] && echo "$OUT" | grep -q "RECOVERY MODE"; } && ok "старт: маркер + незакоммиченная работа → RECOVERY" \
  || bad "старт: настоящая незавершённая сессия НЕ дала RECOVERY"
rm -f "$WM"; ( cd "$WREPO" && git checkout -q -- notes.md )

# W5) повторный старт той же сессии (сжатие контекста) не сдвигает её начало и не переснимает снимок
start_hook w5 >/dev/null
OLD_START=$(( $(date +%s) - 7200 ))
sed -i.bak "3s/.*/$OLD_START/" "$WREPO/.claude/live_sessions/w5.marker"; rm -f "$WREPO/.claude/live_sessions/w5.marker.bak"
printf 'stamp\n' >> "$WREPO/.claude/live_sessions/w5.dirty"
start_hook w5 compact >/dev/null
{ [ "$(sed -n 3p "$WREPO/.claude/live_sessions/w5.marker" 2>/dev/null)" = "$OLD_START" ] \
  && grep -q stamp "$WREPO/.claude/live_sessions/w5.dirty" 2>/dev/null; } \
  && ok "повторный старт (сжатие контекста) не сдвигает начало сессии и не переснимает снимок" \
  || bad "повторный SessionStart сдвинул начало сессии или переснял её снимок"

# W5б) сжатие у сессии без снимка (открыта до обновления) снимок НЕ создаёт → конец судит по-старому
start_hook w5b compact >/dev/null
[ ! -f "$WREPO/.claude/live_sessions/w5b.dirty" ] && ok "сжатие без снимка его не создаёт (работа до сжатия не потеряется)" \
  || bad "сжатие создало снимок с середины сессии → работа до сжатия не попадёт в маркер"

# W6) окно без снимка старта (открыто до обновления обвязки, 8.1.3): его работа — значимое, изменённое
#     после старта его процесса; давний черновик не в счёт (раньше такое окно считало работой всё).
W6=$(python3 -B -c 'import sys, os, time; sys.path.insert(0, sys.argv[1]); import session_liveness as L
d = sys.argv[2]; old = os.path.join(d, "w6_old.md"); new = os.path.join(d, "w6_new.md")
open(old, "w").write("o"); open(new, "w").write("n"); os.utime(old, (time.time() - 7200, time.time() - 7200))
L.self_pid = lambda start=None: "4242"; L._proc_start = lambda pid: time.time() - 3600
got = [l.split("\t")[1] for l in L.work_since_start(d)]
L.self_pid = lambda start=None: None
try: L.work_since_start(d); none = "без исключения"
except Exception: none = "исключение"
os.remove(old); os.remove(new)
print(",".join(got), none)' "$LIVE_MOD" "$WREPO" 2>&1 | tail -1)
[ "$W6" = "w6_new.md исключение" ] && ok "окно без снимка: работа — только изменённое после старта процесса; своей сессии нет — судит по-старому" \
  || bad "окно без снимка: [$W6], ожидалось [w6_new.md исключение]"

# W7) имя с пробелом и запятой попадает в маркер целиком (8.1.3: awk резал по пробелу, склейка — по запятой)
rm -f "$WM"; start_hook w7 >/dev/null; printf 'x' > "$WREPO/новый файл, версия 2.md"; end_hook w7
grep -q '"новый файл, версия 2.md"' "$WM" 2>/dev/null && ok "имя файла с пробелом и запятой попадает в маркер целиком" \
  || bad "имя файла в маркере искажено: $(grep -A3 changed_files "$WM" 2>/dev/null | tr '\n' ' ')"
rm -f "$WM" "$WREPO/новый файл, версия 2.md"

# W8) время старта процесса читается и в русской локали (8.1.3: ps печатал «понедельник, 2 ноября…»,
#     разбор падал, окно без снимка судило по-старому). Настоящий _proc_start, без заглушек.
W8=$(LANG=ru_RU.UTF-8 LC_ALL=ru_RU.UTF-8 python3 -B -c 'import sys, os, time; sys.path.insert(0, sys.argv[1]); import session_liveness as L
print("OK" if abs(L._proc_start(os.getpid()) - time.time()) < 120 else "далеко")' "$LIVE_MOD" 2>&1 | tail -1)
[ "$W8" = "OK" ] && ok "время старта процесса читается в русской локали" || bad "время старта в русской локали: $W8"

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
