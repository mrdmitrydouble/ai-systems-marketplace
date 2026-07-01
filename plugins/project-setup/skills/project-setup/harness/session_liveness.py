#!/usr/bin/env python3
# session_liveness.py — живые сессии проекта ПО ФАКТУ ПРОЦЕССА, а не по таймеру.
# Принцип (правка Димы 29.06): мерим предмет (жив ли claude-процесс этой папки), не прокси (минуты).
# Источник истины: claude-CLI процесс, чей cwd == папка проекта (сравнение по inode, минуя кодировку).
# Маркеры .claude/live_sessions/<sid>.marker — метаданные: строка1=ISO-время, строка2=root-PID.
#
# Дефекты среды, учтённые: macOS bash 3.2 (нет assoc-массивов → ядро на python, 1 процесс);
#   lsof экранирует кириллицу в пути (\xNN) → берём inode (-Fi), путь вообще не парсим;
#   на сессию пара процессов (root ppid=Claude.app + child) → считаем только root.
#
# CLI:  python3 session_liveness.py <cmd> [dir]
#   self [pid]      → root-PID моей сессии
#   live  <dir>     → root-PID'ы живых сессий папки (по строке)
#   rivals <dir>    → живые соперники (кроме моего)
#   blocking <dir>  → живые соперники, КРОМЕ scheduled-задач (для стража)
#   describe <dir>  → человекочитаемый список соперников
#   sweep <dir>     → удалить маркеры мёртвых процессов (печатает что снято)
#   report <dir>    → всё вместе (диагностика)

import sys, os, re, glob, subprocess

# ⚠️ Linux (headless): строка команды claude-CLI в `ps` может отличаться от macOS-формата —
#    верифицировать этот PAT на реальной машине (фаза пилота); при необходимости расширить, но
#    осторожно (слишком широкий паттерн даст ложных «соперников» и сломает страж параллельности).
PAT = re.compile(r'claude-code/[0-9.]+/claude')   # интерактивный claude-CLI (не Claude.app GUI)

def _sh(args, timeout=8):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout).stdout
    except Exception:
        return ""

def _claude_procs():
    """{pid: ppid} для всех claude-CLI процессов."""
    out = _sh(["ps", "axo", "pid=,ppid=,command="])
    procs = {}
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(None, 2)
        if len(parts) < 3:
            continue
        pid, ppid, cmd = parts
        if PAT.search(cmd):
            procs[pid] = ppid
    return procs

def _roots(procs):
    """root сессии = claude-pid, чей родитель НЕ claude (отсекает child из пары и подагентов)."""
    return [pid for pid, ppid in procs.items() if ppid not in procs]

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
    procs = _claude_procs()
    roots = _roots(procs)
    target = _dir_inode(d)
    if not target:
        return []
    ci = _cwd_inodes(roots)
    return [p for p in roots if ci.get(p) == target]

def self_pid(start=None):
    """Подъём по дереву от start(или ppid) до первого claude, затем до root пары."""
    procs = _claude_procs()
    pid = str(start if start is not None else os.getppid())
    hops = 0
    while pid and pid != "1" and hops < 20:
        if pid in procs:
            # climb to root of claude pair
            while procs.get(pid) in procs:
                pid = procs[pid]
            return pid
        ppid = _sh(["ps", "-o", "ppid=", "-p", pid]).strip()
        pid = ppid
        hops += 1
    return None

def rivals(d, me=None):
    me = me or self_pid()
    return [p for p in live_pids(d) if p != me]

# --- метки сессий (для «назови соперника») ---

def _sid_for_pid(d, pid):
    reg = os.path.join(d, ".claude", "live_sessions")
    for m in glob.glob(os.path.join(reg, "*.marker")):
        try:
            with open(m, encoding="utf-8", errors="ignore") as f:
                lines = f.read().splitlines()
            if len(lines) >= 2 and lines[1].strip() == pid:
                return os.path.basename(m)[:-7]
        except Exception:
            pass
    return None

def _transcript_label(sid):
    if not sid:
        return None
    hits = glob.glob(os.path.expanduser(f"~/.claude/projects/*/{sid}.jsonl"))
    if not hits:
        return None
    import json
    try:
        with open(hits[0], encoding="utf-8", errors="ignore") as f:
            for i, line in enumerate(f):
                if i > 30:
                    break
                try:
                    r = json.loads(line)
                except Exception:
                    continue
                if r.get("type") == "summary" and r.get("summary"):
                    return r["summary"][:60]
                if r.get("type") == "user":
                    c = r.get("message", {}).get("content", "")
                    t = c if isinstance(c, str) else next(
                        (x.get("text", "") for x in c if isinstance(x, dict) and x.get("type") == "text"), "")
                    t = t.strip()
                    if not t:
                        continue
                    sm = re.match(r'<scheduled-task name="([^"]+)"', t)
                    if sm:
                        return f'задача по расписанию «{sm.group(1)}»'
                    return f'«{t[:55]}…»' if len(t) > 55 else f'«{t}»'
    except Exception:
        pass
    return None

def _etime(pid):
    return _sh(["ps", "-o", "etime=", "-p", pid]).strip()

def _is_scheduled(d, pid):
    return bool((_transcript_label(_sid_for_pid(d, pid)) or "").startswith("задача по расписанию"))

def blocking_rivals(d):
    """Живые соперники, исключая scheduled-задачи (они бесконфликтны по дизайну — реш. Димы 29.06)."""
    return [p for p in rivals(d) if not _is_scheduled(d, p)]

def describe(d, pids=None):
    pids = rivals(d) if pids is None else pids
    out = []
    for pid in pids:
        sid = _sid_for_pid(d, pid)
        lbl = _transcript_label(sid) if sid else None
        et = _etime(pid)
        if lbl:
            out.append(f"  • {lbl} — PID {pid}, работает {et}")
        else:
            out.append(f"  • claude-сессия PID {pid} (работает {et}) — без маркера, проверь вручную")
    return "\n".join(out) if out else "  (живых соперников нет)"

def sweep(d):
    """Удалить маркеры МЁРТВЫХ процессов (pid не среди живых root'ов; pidless — фолбэк >8ч)."""
    import time
    reg = os.path.join(d, ".claude", "live_sessions")
    if not os.path.isdir(reg):
        return []
    live = set(live_pids(d))
    swept = []
    for m in glob.glob(os.path.join(reg, "*.marker")):
        try:
            with open(m, encoding="utf-8", errors="ignore") as f:
                lines = f.read().splitlines()
            pid = lines[1].strip() if len(lines) >= 2 else ""
            if pid:
                if pid not in live:
                    os.remove(m); swept.append(f"{os.path.basename(m)} (pid {pid} мёртв)")
            else:
                if time.time() - os.path.getmtime(m) > 8 * 3600:
                    os.remove(m); swept.append(f"{os.path.basename(m)} (без pid, >8ч)")
        except Exception:
            pass
    return swept

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
    else:
        print(f"Проект: {d}")
        print(f"inode папки: {_dir_inode(d)}")
        print(f"Мой root-PID: {self_pid()}")
        print(f"Живые сессии папки: {' '.join(live_pids(d))}")
        print("Соперники:")
        print(describe(d))

if __name__ == "__main__":
    main()
