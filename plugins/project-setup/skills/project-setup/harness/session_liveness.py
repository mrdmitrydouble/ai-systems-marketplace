#!/usr/bin/env python3
# session_liveness.py — живые сессии проекта ПО ФАКТУ ПРОЦЕССА, а не по таймеру.
# Принцип (правка Димы 29.06): мерим предмет (жив ли claude-процесс этой папки), не прокси (минуты).
# Источник истины: claude-процесс, чей cwd == папка проекта (сравнение по inode, минуя кодировку).
# Маркеры .claude/live_sessions/<sid>.marker — метаданные: строка1=ISO-время старта, строка2=root-PID,
#   строка3=эпоха старта, строка4=путь к журналу сессии. Рядом <sid>.dirty — снимок незакоммиченного
#   на старте: по разнице снимков старта и конца SessionEnd видит работу ЭТОЙ сессии.
#
# v5.2.3 (06.11, спора 8.1.5; найдено живой работой VL после раскатки):
#   - Сессию, закрытую через /end и сутки простоявшую, отправили в архив — SessionEnd приписал ей
#     незакоммиченную работу СОСЕДНИХ сессий, и «не закрыта» двое суток видели все новые сессии.
#     Теперь правки, сделанные позже последнего действия простаивающей сессии, — не её работа (own).
#   - Последнее действие — по меткам времени записей журнала, не по дате файла: приложение дописывает
#     в журнал служебные строки без метки (название, стоимость) и при архивации, и при открытии окна.
#   - Соперник назван так, как в боковой панели приложения (custom-title), а не первой строкой
#     переписки — там бывает служебное «<system-reminder>…».
#   - Журналы субагентов — на любой глубине (агенты воркфлоу пишут в subagents/workflows/wf-*/); висящий
#     вызов инструмента = сессия работала до конца. Найдено двумя независимыми сверками правки.
#
# v5.2.1 (02.11, спора 8.1.3): путь проекта в glob экранируется (glob.escape). Папка вида
#   «7. Venture Lovers [GitHub]» — для glob это шаблон «один из символов», маркеры не находились никогда:
#   страж считал все сессии «без маркера» и не блокировал (fail-open). Найдено живой проверкой раскатки.
#   Окно без снимка старта (открыто до обновления) судит о своей работе по времени старта процесса (since).
# v5.2 (02.11, спора 8.1.2):
#   - claude узнаём по ТОЧНОМУ argv[0] (`ps -o comm`: на macOS — полный путь, в т.ч. с пробелами)
#     во всех видах установки: десктоп нового вида …/claude-code/<вер>/<хеш>/claude.app/Contents/
#     MacOS/claude (старый PAT его не видел — страж был слеп), CLI, нативный CLI, npm/npx (node или
#     bun со скриптом claude). Помощник disclaimer (несёт путь к claude аргументом) и GUI — не сессии.
#   - Сессия = самый верхний claude среди предков: claude, запущенный изнутри сессии
#     (`claude plugin …`), — её часть, а не соперник. claude с PID 1 (контейнер) тоже сессия.
#   - Блокирует только соперник, который РАБОТАЕТ СЕЙЧАС: его журнал или журнал его субагента писался
#     последние ACTIVE_MIN мин. Десктоп держит открытые окна живыми сутками; простаивающее окно не
#     мешает, а если проснётся и возьмётся за изменённый файл — Claude Code сам отклонит правку
#     («modified since read»).
#
# Дефекты среды, учтённые: macOS bash 3.2 (нет assoc-массивов → ядро на python, 1 процесс);
#   lsof экранирует кириллицу в пути (\xNN) → берём inode (-Fi), путь вообще не парсим.
#
# CLI:  python3 session_liveness.py <cmd> [dir]
#   self [pid]      → root-PID моей сессии
#   live  <dir>     → root-PID'ы живых сессий папки (по строке)
#   rivals <dir>    → живые соперники (кроме моего)
#   blocking <dir>  → соперники, которые работают сейчас, кроме scheduled (для стража и /end)
#   describe <dir>  → человекочитаемый список соперников с состоянием
#   sweep <dir>     → удалить маркеры мёртвых процессов (печатает что снято)
#   dirty <dir> [сек] → снимок значимого незакоммиченного (для SessionStart/SessionEnd; сек — потолок)
#   since <dir> [сек] → значимое незакоммиченное, изменённое после старта моей сессии (SessionEnd без снимка)
#   own <журнал>    → stdin: строки снимка; stdout: без правок, сделанных после последнего действия
#                     простаивающей сессии (SessionEnd: работа соседей — не её работа)
#   report <dir>    → всё вместе (диагностика)

import sys, os, re, glob, subprocess, time

ACTIVE_MIN = 10   # «работает сейчас» = журнал сессии писался не позже стольких минут назад

# argv[0] сессии claude. Компонент пути может содержать пробелы («Application Support»): argv[0]
# берётся из `ps -o comm` целиком, без аргументов, поэтому путь не «перетечёт» в аргументы.
_COMP = r'[^/]*[^/\s]'
_ABS = r'(?:/' + _COMP + r')*/'
ARGV0 = re.compile(
    r'^(?:'
    r'(?:/' + _COMP + r')*/claude-code/\d[\d.]*/(?:[^/\s]+/)*claude'   # десктоп: …/claude-code/<вер>/[…/]claude
    r'|(?:' + _ABS + r')?claude'                                        # CLI: claude, ~/.local/bin/claude
    r'|' + _ABS + r'claude/versions/\d[\d.]*'                           # нативный CLI по реальному пути
    r')$')
# node/bun, которым передан скрипт claude (npm -g, npx, Agent SDK), если заголовок процесса не переписан
_SCRIPT = re.compile(r'(?:^|/)(?:\.?bin/claude|@anthropic-ai/claude-(?:code|agent-sdk)/cli\.js)$')
_INTERP = ("node", "bun")

def is_claude_proc(argv0, command=""):
    """claude-сессия ли это: по точному argv[0], по первому слову командной строки (заголовок
       процесса «claude»), либо node/bun со скриптом claude первым не-флаговым аргументом."""
    if ARGV0.match(argv0.strip()):
        return True
    words = command.split()
    if words and ARGV0.match(words[0]):
        return True
    if words and os.path.basename(words[0]) in _INTERP:
        script = next((w for w in words[1:] if not w.startswith("-")), "")
        return bool(_SCRIPT.search(script))
    return False

def _sh(args, timeout=8):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout).stdout
    except Exception:
        return ""

def _ps():
    """Снимок процессов: ({pid: ppid} для всех, множество pid claude-процессов)."""
    parent, argv0, cmd = {}, {}, {}
    for line in _sh(["ps", "axo", "pid=,ppid=,comm="]).splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) == 3:
            parent[parts[0]], argv0[parts[0]] = parts[1], parts[2]
    for line in _sh(["ps", "axo", "pid=,command="]).splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2:
            cmd[parts[0]] = parts[1]
    claude = {p for p in parent if is_claude_proc(argv0.get(p, ""), cmd.get(p, ""))}
    return parent, claude

def _top_claude(pid, parent, claude):
    """Самый верхний claude среди pid и его предков (None — claude в цепочке нет)."""
    top, hops = None, 0
    while pid and pid != "0" and hops < 64:
        if pid in claude:
            top = pid
        if pid == "1":
            break
        pid = parent.get(pid)
        hops += 1
    return top

def _roots(parent, claude):
    """Сессии = claude-процессы без claude-предков (вложенный claude — часть своей сессии)."""
    return [p for p in claude if _top_claude(p, parent, claude) == p]

def _cwd_inodes(pids):
    """{pid: inode} cwd процессов.
       Linux: /proc/<pid>/cwd через os.stat — надёжно и БЕЗ зависимости от lsof
              (на minimal Ubuntu lsof часто не установлен → раньше страж молча отключался).
       macOS/BSD: lsof, поле inode (-Fi), путь не парсим (минуем кодировку кириллицы)."""
    if not pids:
        return {}
    res = {}
    if os.path.isdir("/proc"):                       # Linux
        for p in pids:
            try:
                res[p] = str(os.stat("/proc/%s/cwd" % p).st_ino)
            except Exception:
                pass
        return res
    out = _sh(["lsof", "-a", "-d", "cwd", "-Fpi", "-p", ",".join(pids)])
    cur = None
    for line in out.splitlines():
        if line.startswith("p"):
            cur = line[1:]
        elif line.startswith("i") and cur:
            res[cur] = line[1:]   # номер inode (строка)
    return res

def _dir_inode(path):
    try:
        return str(os.stat(path).st_ino)
    except Exception:
        return None

def live_pids(d):
    target = _dir_inode(d)
    if not target:
        return []
    roots = _roots(*_ps())
    ci = _cwd_inodes(roots)
    return [p for p in roots if ci.get(p) == target]

def self_pid(start=None):
    """root-PID сессии, внутри которой я запущен (подъём от start или от родителя)."""
    parent, claude = _ps()
    return _top_claude(str(start if start is not None else os.getppid()), parent, claude)

def rivals(d, me=None):
    me = me or self_pid()
    return [p for p in live_pids(d) if p != me]

# --- маркеры, журналы и активность сессий (для «назови соперника» и «мешает ли он») ---

def _marker_for_pid(d, pid):
    """(sid, строки маркера) сессии с этим root-PID; (None, []) — маркера нет."""
    reg = os.path.join(d, ".claude", "live_sessions")
    for m in glob.glob(os.path.join(glob.escape(reg), "*.marker")):
        try:
            with open(m, encoding="utf-8", errors="ignore") as f:
                lines = f.read().splitlines()
            if len(lines) >= 2 and lines[1].strip() == pid:
                return os.path.basename(m)[:-7], lines
        except Exception:
            pass
    return None, []

def _transcript(sid, lines=()):
    """Журнал сессии: путь из её маркера (строка 4), иначе поиск по sid в каталоге проектов
       ($CLAUDE_CONFIG_DIR или ~/.claude — Claude Code хранит журналы там же)."""
    if len(lines) >= 4 and lines[3].strip() and os.path.isfile(lines[3].strip()):
        return lines[3].strip()
    if not sid:
        return None
    bases = {os.environ.get("CLAUDE_CONFIG_DIR") or "", os.path.expanduser("~/.claude")} - {""}
    for base in bases:
        hits = glob.glob(os.path.join(glob.escape(base), "projects", "*", f"{sid}.jsonl"))
        if hits:
            return hits[0]
    return None

def _tail(path, size=262144):
    """Последние строки журнала (до size байт) — журнал долгой сессии весит десятки мегабайт."""
    with open(path, "rb") as f:
        f.seek(0, 2)
        n = f.tell()
        f.seek(max(0, n - size))
        lines = f.read().decode("utf-8", "ignore").split("\n")   # не splitlines: U+2028 в тексте не разделитель JSONL
    return lines[1:] if n > size else lines

def _title(path):
    """Название сессии, как в боковой панели приложения: <sid>/custom-title.json или последняя запись
       custom-title в журнале (окно могли переименовать); у старого CLI — запись summary."""
    import json
    try:
        with open(os.path.join(path[:-len(".jsonl")], "custom-title.json"), encoding="utf-8") as f:
            t = json.load(f).get("customTitle")
        if t:
            return t
    except Exception:
        pass
    try:
        for line in reversed(_tail(path)):
            if '"custom-title"' in line or '"summary"' in line:
                r = json.loads(line)
                t = r.get("customTitle") if r.get("type") == "custom-title" else (
                    r.get("summary") if r.get("type") == "summary" else None)
                if t:
                    return t
    except Exception:
        pass
    return None

def _transcript_label(path):
    if not path:
        return None
    import json
    first = None
    try:
        with open(path, encoding="utf-8", errors="ignore") as f:
            for i, line in enumerate(f):
                if i > 30:
                    break
                try:
                    r = json.loads(line)
                except Exception:
                    continue
                if r.get("type") == "summary" and r.get("summary"):
                    first = r["summary"]
                    break
                if r.get("type") == "user":
                    c = r.get("message", {}).get("content", "")
                    t = c if isinstance(c, str) else next(
                        (x.get("text", "") for x in c if isinstance(x, dict) and x.get("type") == "text"), "")
                    sm = re.match(r'\s*<scheduled-task name="([^"]+)"', t)
                    if sm:
                        return f'задача по расписанию «{sm.group(1)}»'
                    # служебные вставки приложения — не то, чем человек узнаёт окно
                    t = re.sub(r'<system-reminder>.*?</system-reminder>', ' ', t, flags=re.S)
                    t = " ".join(re.sub(r'</?pasted_content[^>]*>', ' ', t).split())
                    if t:
                        first = t
                        break
    except Exception:
        pass
    t = _title(path) or first
    if not t:
        return None
    return f'«{t[:55]}…»' if len(t) > 55 else f'«{t}»'

_STAMP = re.compile(r'"timestamp"\s*:\s*"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)')

def _last_stamp(path):
    """Метка времени последней записи журнала (UTC, эпоха). Служебные строки приложения (название,
       стоимость, привязка окна) метки не несут — их дописывает и архивация, и открытие окна."""
    import json, calendar
    for line in reversed(_tail(path)):
        if '"timestamp"' not in line:
            continue
        try:
            ts = json.loads(line).get("timestamp")
        except Exception:
            continue
        m = _STAMP.match(f'"timestamp":"{ts}"') if isinstance(ts, str) else None
        if m:
            return calendar.timegm(time.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S"))
    return None

def _last_activity(path, exact=False):
    """Время последней записи сессии: её журнал и журналы её субагентов на любой глубине
       (<sid>/subagents/*.jsonl, у агентов воркфлоу — subagents/workflows/wf-*/agent-*.jsonl): пока они
       работают, основной журнал может молчать часами. Файл, тронутый недавно (exact — любой), уточняется
       по меткам записей: свежая дата бывает и от служебной строки без действия сессии."""
    times = []
    subs = glob.glob(os.path.join(glob.escape(path[:-len(".jsonl")]), "subagents", "**", "*.jsonl"), recursive=True)
    for p in [path] + subs:
        try:
            mt = os.path.getmtime(p)
        except OSError:
            continue
        if exact or time.time() - mt < ACTIVE_MIN * 60:
            try:
                st = _last_stamp(p)
            except Exception:
                st = None
            if st is not None:
                mt = min(mt, st)
        times.append(mt)
    return max(times) if times else None

def _state(d, pid):
    """(состояние, метка, минут простоя); состояние: active | idle | scheduled | nolog | unknown."""
    sid, lines = _marker_for_pid(d, pid)
    if not sid:
        return "unknown", None, None
    path = _transcript(sid, lines)
    lbl = _transcript_label(path)
    if lbl and lbl.startswith("задача по расписанию"):
        return "scheduled", lbl, None
    last = _last_activity(path) if path else None
    if last is None:
        return "nolog", lbl, None
    idle = max(0.0, (time.time() - last) / 60)
    return ("active" if idle < ACTIVE_MIN else "idle"), lbl, idle

def _etime(pid):
    return _sh(["ps", "-o", "etime=", "-p", pid]).strip()

def blocking_rivals(d):
    """Соперники, которые РАБОТАЮТ СЕЙЧАС. Scheduled-задачи бесконфликтны по дизайну (реш. Димы
       29.06). Простаивающее окно, сессия без маркера и без журнала не блокируют: от затирания
       файла страхует сам Claude Code — правку файла, изменённого после чтения, он отклоняет."""
    return [p for p in rivals(d) if _state(d, p)[0] == "active"]

def _ago(m):
    m = int(m)
    return f"{m} мин" if m < 120 else (f"{m // 60} ч" if m < 2880 else f"{m // 1440} дн")

def describe(d, pids=None):
    pids = rivals(d) if pids is None else pids
    out = []
    for pid in pids:
        st, lbl, idle = _state(d, pid)
        name = lbl or f"сессия PID {pid}"
        if st == "active":
            out.append(f"  • {name} — PID {pid}, РАБОТАЕТ СЕЙЧАС (активность {_ago(idle)} назад)")
        elif st == "idle":
            out.append(f"  • {name} — PID {pid}, открыта, простаивает {_ago(idle)} — не мешает")
        elif st == "scheduled":
            out.append(f"  • {name} — PID {pid} — не мешает")
        elif st == "nolog":
            out.append(f"  • {name} — PID {pid}, журнал сессии не найден — не мешает")
        else:
            out.append(f"  • сессия PID {pid} (работает {_etime(pid)}) — без маркера (открыта до "
                       f"установки harness; перезапусти её, чтобы страж её видел) — не мешает")
    return "\n".join(out) if out else "  (других сессий в папке нет)"

def sweep(d):
    """Удалить маркеры МЁРТВЫХ процессов (pid не среди живых root'ов; pidless — фолбэк >8ч).
       Маркер своей сессии не трогаем: тот, кто подметает, жив по определению (даже если его cwd
       не совпал с папкой — иначе сессия стёрла бы собственный старт). Снимок <sid>.dirty мёртвой
       сессии оставляем: она может вернуться после сбоя (resume) — иначе её работа до сбоя
       пропадёт для маркера. Осиротевшие снимки убираем через 7 дней, брошенные *.tmp — через час."""
    reg = os.path.join(d, ".claude", "live_sessions")
    if not os.path.isdir(reg):
        return []
    live = set(live_pids(d))
    me = self_pid()
    swept = []
    for m in glob.glob(os.path.join(glob.escape(reg), "*.marker")):
        try:
            with open(m, encoding="utf-8", errors="ignore") as f:
                lines = f.read().splitlines()
            pid = lines[1].strip() if len(lines) >= 2 else ""
            dead = (pid not in live and pid != me) if pid else (time.time() - os.path.getmtime(m) > 8 * 3600)
            if dead:
                os.remove(m)
                swept.append(f"{os.path.basename(m)} (" + (f"pid {pid} мёртв" if pid else "без pid, >8ч") + ")")
        except Exception:
            pass
    now = time.time()
    for snap in glob.glob(os.path.join(glob.escape(reg), "*.dirty")):      # осиротевшие снимки без маркера
        try:
            if not os.path.exists(snap[:-len(".dirty")] + ".marker") and now - os.path.getmtime(snap) > 7 * 86400:
                os.remove(snap)
        except Exception:
            pass
    for tmp in glob.glob(os.path.join(glob.escape(reg), "*.dirty.tmp")):   # снимок, прерванный посреди записи
        try:
            if now - os.path.getmtime(tmp) > 3600:
                os.remove(tmp)
        except Exception:
            pass
    return swept

# --- снимок незакоммиченного: работа сессии = разница снимков старта и конца ---

# «Не работа» — тот же фильтр, что grep в session_end_snapshot.sh и session_start_recovery.sh (держать
# синхронно): телеметрия, кэш Python, отметки прогонов и служебные файлы самого harness.
SKIP = re.compile(r'as-metrics\.jsonl|__pycache__/|\.pyc$|System/state/'
                  r'|\.claude/(live_sessions/|\.session_incomplete\.json|\.session_closed\.flag|\.sess_marker_)')

def dirty_entries(d, timeout=None):
    """Значимое незакоммиченное: строки «XY<TAB>путь<TAB>режим<TAB>размер<TAB>mtime_ns», по алфавиту.
       Сравнение снимков старта и конца видит любую работу сессии, в т.ч. без свежей даты файла
       (git mv, cp -p, tar, chmod), а давние черновики и давние удаления в обоих снимках одинаковы.
       timeout — потолок для git: на огромном неотслеживаемом дереве хук не должен выйти за свой
       бюджет времени; не успели — исключение, и вызывающий судит по-старому."""
    top = subprocess.run(["git", "-C", d, "rev-parse", "--show-toplevel"],
                         capture_output=True, text=True, check=True, timeout=timeout).stdout.strip()
    raw = subprocess.run(["git", "-C", d, "status", "--porcelain=v1", "-z", "-uall"],
                         capture_output=True, check=True, timeout=timeout).stdout
    out, parts, i = [], raw.split(b"\0"), 0
    while i < len(parts):
        entry = parts[i]; i += 1
        if len(entry) < 4:
            continue
        code, path = entry[:2].decode(), os.fsdecode(entry[3:])
        if code[0] in "RC" and i < len(parts):        # переименование/копия: следом исходный путь
            path += " <- " + os.fsdecode(parts[i]); i += 1
        if SKIP.search(path):
            continue
        try:
            st = os.lstat(os.path.join(top, path.split(" <- ")[0]))
            meta = f"{st.st_mode:o}\t{st.st_size}\t{st.st_mtime_ns}"
        except OSError:
            meta = "-\t-\t-"                           # удалён
        safe = path.replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t")
        out.append(f"{code}\t{safe}\t{meta}")
    return sorted(out)

def _proc_start(pid):
    """Эпоха старта процесса (ps -o lstart: «Mon Nov  2 14:03:21 2026» — одинаково на macOS и Linux).
       LC_ALL=C обязателен: в русской локали macOS печатает «понедельник, 2 ноября 2026 г. …», разбор падал,
       и окно без снимка тихо судило по-старому (найдено третьей сверкой раскатки)."""
    out = _sh(["env", "LC_ALL=C", "ps", "-o", "lstart=", "-p", str(pid)]).strip()
    return time.mktime(time.strptime(" ".join(out.split()), "%a %b %d %H:%M:%S %Y"))

def work_since_start(d, timeout=None, slack=60):
    """Работа сессии, у которой нет снимка старта (окно открыто до обновления обвязки, 8.1.3): значимое
       незакоммиченное, изменённое после старта её процесса. git mv / cp -p / chmod / удаления так не
       видны — компромисс переходного окна; до 8.1.3 такое окно считало работой ВСЁ незакоммиченное,
       включая давние черновики. Свою сессию не нашли — исключение, и вызывающий судит по-старому."""
    pid = self_pid()
    if not pid:
        raise RuntimeError("своя сессия не найдена")
    edge = (_proc_start(pid) - slack) * 1e9
    out = []
    for line in dirty_entries(d, timeout):
        mt = line.rsplit("\t", 1)[-1]
        if mt.isdigit() and int(mt) >= edge:
            out.append(line)
    return out

def _tool_pending(path):
    """Висит ли в конце журнала вызов инструмента без ответа (долгий MCP, ожидание задачи): сессия тогда
       не простаивала, а ждала — её действие могло писать файлы и после последней записи журнала."""
    import json
    pending = set()
    try:
        for line in _tail(path):
            if '"tool_use"' not in line and '"tool_result"' not in line:
                continue
            try:
                r = json.loads(line)
            except Exception:
                continue
            if r.get("type") not in ("assistant", "user"):   # api-request-blob повторяет tool_use уже после ответа
                continue
            c = r.get("message", {}).get("content") if isinstance(r.get("message"), dict) else None
            for x in c if isinstance(c, list) else []:
                if isinstance(x, dict) and x.get("type") == "tool_use":
                    pending.add(x.get("id"))
                elif isinstance(x, dict) and x.get("type") == "tool_result":
                    pending.discard(x.get("tool_use_id"))
    except Exception:
        return True
    return bool(pending)

def own_work(lines, transcript, slack=120):
    """Из работы, найденной в конце сессии, — только её собственная. Сессия простаивала (последнее
       действие раньше ACTIVE_MIN мин) — правки позже её последнего действия сделали соседи: так сессия,
       закрытая через /end и через сутки отправленная в архив, получала «не закрыта» за чужую работу
       (VL, 04.11). Работала до конца, ждала ответа инструмента или журнал не найден — всё её, как
       раньше: прерванный посреди действия процесс оставляет правки новее последней записи журнала.
       Удаления (без даты) — её."""
    last = _last_activity(transcript, exact=True) if transcript and os.path.isfile(transcript) else None
    if last is None or time.time() - last < ACTIVE_MIN * 60 or _tool_pending(transcript):
        return lines
    edge = (last + slack) * 1e9
    return [l for l in lines if not (l.rsplit("\t", 1)[-1].isdigit() and int(l.rsplit("\t", 1)[-1]) > edge)]

def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "report"
    d = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("CLAUDE_PROJECT_DIR", os.getcwd())
    if cmd == "self":
        print(self_pid(sys.argv[2] if len(sys.argv) > 2 else None) or "")
    elif cmd == "live":
        print("\n".join(live_pids(d)))
    elif cmd == "rivals":
        print("\n".join(rivals(d)))
    elif cmd == "blocking":
        print("\n".join(blocking_rivals(d)))
    elif cmd == "describe":
        print(describe(d))
    elif cmd == "sweep":
        for s in sweep(d):
            print(s)
    elif cmd == "since":
        limit = float(sys.argv[3]) if len(sys.argv) > 3 else None
        for line in work_since_start(d, limit):
            print(line)
    elif cmd == "dirty":
        limit = float(sys.argv[3]) if len(sys.argv) > 3 else None
        for line in dirty_entries(d, limit):
            print(line)
    elif cmd == "own":
        for line in own_work([l for l in sys.stdin.read().splitlines() if l], d):
            print(line)
    else:
        print(f"Проект: {d}")
        print(f"inode папки: {_dir_inode(d)}")
        print(f"Мой root-PID: {self_pid()}")
        print(f"Живые сессии папки: {' '.join(live_pids(d))}")
        print(f"Работают сейчас (блокируют запись памяти): {' '.join(blocking_rivals(d)) or 'нет'}")
        print("Соперники:")
        print(describe(d))

if __name__ == "__main__":
    main()
