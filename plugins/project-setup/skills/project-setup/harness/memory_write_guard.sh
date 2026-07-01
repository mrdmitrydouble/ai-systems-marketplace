#!/bin/bash
# memory_write_guard.sh v4 — PreToolUse (Edit|Write) страж записи.
# История: v1 Фаза C 10.06 (CRITICAL-1). v2 11.06. v3 11.06 — увод записей в inbox при чужой live.
# v4 29.06 (правка Димы): живость по ПРОЦЕССУ, не по таймеру. Маркер моложе 2ч больше НЕ значит «жив»
#   (долгий запрос/мобильный простой ломали таймер). Теперь соперник = живой claude-процесс этой папки.
#   Логику живости держит System/scripts/session_liveness.py (один источник истины, переиспользуют /end и старт).
# 1) Frozen zones: блок записи в Project/Sources, System/archive, _backup, Project/Archive.
# 2) Коллизия сессий: запись в System/memory/ или CLAUDE.md при ЖИВОМ не-scheduled сопернике → инбокс.

set -u
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$PROJECT_DIR" || exit 0

# INPUT во временный файл, путь — через env (большой Write → E2BIG в env). Heredoc занят python.
INPUT=$(cat 2>/dev/null || echo '{}')
MWG_TMP=$(mktemp 2>/dev/null || echo "/tmp/mwg_$$.json")
printf '%s' "$INPUT" > "$MWG_TMP"
export MWG_INPUT_FILE="$MWG_TMP" MWG_PROJECT_DIR="$PROJECT_DIR"
trap 'rm -f "$MWG_TMP"' EXIT

python3 <<'PYEOF'
import json, os, sys

proj = os.environ.get("MWG_PROJECT_DIR", os.getcwd())
try:
    with open(os.environ.get("MWG_INPUT_FILE", ""), encoding="utf-8") as _f:
        d = json.load(_f)
except Exception:
    sys.exit(0)

fp = (d.get("tool_input") or {}).get("file_path", "") or ""
sid = d.get("session_id", "")

# --- 1. Frozen zones (exit 2 = блок) ---
for frozen in ("/Project/Sources/", "/Project/Archive/", "/System/archive/", "_backup"):
    if frozen in fp:
        print(f"Запись в frozen zone заблокирована: {fp}. Для легитимной архивации — Bash (cp/mv).",
              file=sys.stderr)
        sys.exit(2)

# --- 2. Коллизия сессий: только файлы памяти ---
if "/inbox_sessions/" in fp:      # инбокс — личная зона сессии, всегда можно
    sys.exit(0)
is_memory = ("/System/memory/" in fp) or fp.endswith("/CLAUDE.md")
if not is_memory or not sid:
    sys.exit(0)

# Живость по ПРОЦЕССУ: блокирующие соперники = живые claude-сессии этой папки, КРОМЕ scheduled и меня.
sys.path.insert(0, os.path.join(proj, "System", "scripts"))
try:
    import session_liveness as L
except Exception:
    sys.exit(0)   # хелпер недоступен — не мешаем записи (fail-open: лучше пустить, чем сломать)

try:
    rivals = L.blocking_rivals(proj)
except Exception:
    sys.exit(0)   # любой сбой определения живости — fail-open

if rivals:
    import datetime
    who = L.describe(proj, rivals).rstrip()
    inbox = f"System/memory/inbox_sessions/{datetime.date.today().isoformat()}_{sid[:8]}.md"
    out = {"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": (
            "ПАРАЛЛЕЛЬНАЯ РАБОТА (это не ошибка): в папке есть другая ЖИВАЯ сессия —\n"
            f"{who}\n"
            "Общие файлы памяти сейчас не редактируем, чтобы не затирать друг друга. "
            f"Запиши свою дельту в персональный инбокс: Write → {inbox} "
            f"(добавь заголовок «## для {os.path.basename(fp)}» и содержимое записи). "
            "Слияние инбоксов сделает /end последней сессии или STARTUP следующей. "
            "Владельца НЕ беспокой — это штатный режим параллельности.")}}
    print(json.dumps(out, ensure_ascii=False))

sys.exit(0)
PYEOF
