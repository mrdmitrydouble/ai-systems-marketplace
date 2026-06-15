#!/bin/bash
# memory_write_guard.sh v3 — PreToolUse (Edit|Write) страж записи.
# v1: Фаза C 10.06 (CRITICAL-1 аудита). v2: 11.06 — дедуп предупреждений, человекочитаемые имена.
# v3: записи в общие файлы памяти при чужой live-сессии уводятся в inbox_sessions/ (deny с инструкцией
#     агенту); владельцу кнопок не показываем; scheduled-прогоны исключены по label.
# 1) Frozen zones: блок записи в Исходники/архив/_backup/Проект-Архив.
# 2) Коллизия сессий: запись в Система/память/ или CLAUDE.md при чужой live → инбокс сессии.
# Заодно освежает маркер собственной live-сессии (иначе он «протухает» за 2ч в долгой сессии).

set -u
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$PROJECT_DIR" || exit 0

# INPUT во временный файл, путь к нему — через env (НЕ сам INPUT: большой Write → E2BIG в env).
# Heredoc занят скриптом python, поэтому stdin для данных недоступен — отсюда temp-файл.
INPUT=$(cat 2>/dev/null || echo '{}')
MWG_TMP=$(mktemp 2>/dev/null || echo "/tmp/mwg_$$.json")
printf '%s' "$INPUT" > "$MWG_TMP"
export MWG_INPUT_FILE="$MWG_TMP"
trap 'rm -f "$MWG_TMP"' EXIT

python3 <<'PYEOF'
import json, os, sys, time, glob, datetime

try:
    with open(os.environ.get("MWG_INPUT_FILE", ""), encoding="utf-8") as _f:
        d = json.load(_f)
except Exception:
    sys.exit(0)

fp = (d.get("tool_input") or {}).get("file_path", "") or ""
sid = d.get("session_id", "")

# Освежить собственный live-маркер (долгая сессия не должна «протухать» за 2ч и отключать стража).
if sid:
    try:
        os.makedirs(".claude/live_sessions", exist_ok=True)
        with open(f".claude/live_sessions/{sid}.marker", "w") as _m:
            _m.write(datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"))
    except Exception:
        pass

# --- 1. Frozen zones (exit 2 = блок) ---
for frozen in ("/Проект/Исходники/", "/Проект/Архив/", "/Система/архив/", "_backup"):
    if frozen in fp:
        print(f"Запись в frozen zone заблокирована: {fp}. Для легитимной архивации — Bash (cp/mv).",
              file=sys.stderr)
        sys.exit(2)

# --- 2. Коллизия сессий: только файлы памяти ---
if "/inbox_sessions/" in fp:      # v3: инбокс — личная зона сессии, всегда можно
    sys.exit(0)
is_memory = ("/Система/память/" in fp) or fp.endswith("/CLAUDE.md")
if not is_memory or not sid:
    sys.exit(0)

import re

def transcript_of(other_sid):
    hits = glob.glob(os.path.expanduser(f"~/.claude/projects/*/{other_sid}.jsonl"))
    return hits[0] if hits else None

def session_label(other_sid):
    """v2.2: человеческое имя сессии (scheduled-задача / summary / первое сообщение)."""
    try:
        tr = transcript_of(other_sid)
        if not tr:
            return None
        with open(tr, encoding="utf-8", errors="ignore") as f:
            for i, line in enumerate(f):
                if i > 30: break
                try: rec = json.loads(line)
                except Exception: continue
                if rec.get("type") == "summary" and rec.get("summary"):
                    return rec["summary"][:60]
                if rec.get("type") == "user":
                    m = rec.get("message", {}); c = m.get("content", "")
                    t = c if isinstance(c, str) else next(
                        (x.get("text", "") for x in c if isinstance(x, dict) and x.get("type") == "text"), "")
                    t = t.strip()
                    if not t: continue
                    st = re.match(r'<scheduled-task name="([^"]+)"', t)  # v2.2: прогон задачи по расписанию
                    if st: return f"задача по расписанию «{st.group(1)}»"
                    return f"«{t[:55]}…»" if len(t) > 55 else f"«{t}»"
    except Exception:
        pass
    return None

def is_scheduled_run(other_sid):
    """v2.3: это прогон задачи по расписанию? Наши задачи спроектированы бесконфликтными
    (свои файлы, git pull, перезаписываемые сводки) — о них НЕ спрашиваем вообще (фидбек Димы)."""
    lbl = session_label(other_sid)
    return bool(lbl and lbl.startswith("задача по расписанию"))

# v3 (архитектура по логике Димы 11.06): таймеры активности — ненадёжны (research-сессия
# молчит полчаса, оставаясь живой). Вместо угадывания «кто жив» — разводим ЗАПИСИ:
# при любом чужом live-маркере (<2ч) запись в общие файлы памяти уходит в инбокс сессии.
# Это deny С ИНСТРУКЦИЕЙ АГЕНТУ — владельцу кнопки не показываются вообще.

reg = ".claude/live_sessions"
now = time.time()
rivals = []
for m in glob.glob(os.path.join(reg, "*.marker")):
    other = os.path.basename(m)[:-7]
    if other == sid:
        continue
    mt = os.path.getmtime(m)
    if now - mt >= 7200:                 # маркер старше 2ч — мёртв (чистится SessionStart'ом)
        continue
    if is_scheduled_run(other):          # scheduled-прогоны бесконфликтны по дизайну
        continue
    started = datetime.datetime.fromtimestamp(mt).strftime("%H:%M")
    label = session_label(other)
    rivals.append(f"{label} (с {started})" if label else f"сессия с {started} (id {other[:8]}…)")

if rivals:
    who = "; ".join(rivals)
    inbox = f"Система/память/inbox_sessions/{datetime.date.today().isoformat()}_{sid[:8]}.md"
    out = {"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": (
            f"ПАРАЛЛЕЛЬНАЯ РАБОТА (это не ошибка): в папке есть другая live-сессия — {who}. "
            f"Общие файлы памяти сейчас не редактируем, чтобы не затирать друг друга. "
            f"Запиши свою дельту в персональный инбокс: Write → {inbox} "
            f"(добавь заголовок «## для {os.path.basename(fp)}» и содержимое записи). "
            f"Слияние инбоксов сделает /end последней сессии или STARTUP следующей (шаг «слияние инбоксов»). "
            f"Владельца НЕ беспокой — это штатный режим параллельности.")}}
    print(json.dumps(out, ensure_ascii=False))

sys.exit(0)
PYEOF
