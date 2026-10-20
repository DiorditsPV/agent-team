"""Проверка роли: ведёт ли разговор агента процесс, который team запустил в панели с промптом роли.

Разговор может уйти из процесса панели в фоновую задачу Claude Code. Проверено на claude 2.1.292:
- ← в пустой строке ввода (подсказка «← for agents») и /background (/bg) переносят разговор в фон сразу, без
  подтверждения. Задачу ведёт отдельный процесс — потомок `claude daemon run`, а не tmux — с новым --session-id.
- Задаче передаются --settings, --allowed-tools, --model и --permission-mode, но не --append-system-prompt-file и
  не --name: промпта роли у неё нет. Окружение она берёт у демона, а не у панели.
- Запись панели в ~/.claude/sessions получает parkedJobId; запись задачи — kind bg, jobId, свой сокет. В транскрипт
  панели пишется continued-in на сессию задачи. Процесс панели дальше только показывает список задач.
- Задача переживает закрытие панели. SIGTERM по её pid завершает её, демон её не перезапускает. Отдельной команды
  остановить одну задачу у claude нет: `claude daemon stop` останавливает все фоновые сессии пользователя.
- Настройка disableAgentView: true в --settings или переменная CLAUDE_CODE_DISABLE_AGENT_VIEW=1 выключают ← и
  /background («Unknown command»); сокет и доставка SendMessage при этом работают. team ставит обе при запуске роли,
  а проверка нужна для ролей, поднятых раньше, и на случай, если claude найдёт другой путь в фон.
"""
from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

from . import sessions

REASONS = ("background", "other_process", "no_role_prompt")


def process_command(pid: int) -> str | None:
    """Командная строка процесса (аргументы через пробел, без кавычек); нет процесса или он уже завершён — None."""
    try:
        # -ww: без него BSD ps режет строку по ширине терминала, и путь файла роли после --name мог бы не попасть.
        # Локаль UTF-8 задаётся явно: приложение запускает team без LANG, и тогда ps на macOS выводит не-ASCII
        # экранированным (M-P…), путь с кириллицей не совпал бы.
        env = {**os.environ, "LC_ALL": "en_US.UTF-8" if sys.platform == "darwin" else "C.UTF-8"}
        res = subprocess.run(["ps", "-ww", "-o", "stat=,command=", "-p", str(pid)], capture_output=True, text=True,
                             encoding="utf-8", errors="replace", env=env)
    except OSError:
        return None
    stat, _, cmd = res.stdout.strip().partition(" ")
    if res.returncode != 0 or not cmd or stat.startswith("Z"):
        return None
    return cmd.strip()


def _result(ok, reason=None, pid=None, pane_pid=None, job_id=None, session_id=None) -> dict:
    return {"ok": ok, "reason": reason, "pid": pid, "pane_pid": pane_pid, "job_id": job_id, "session_id": session_id}


def check(pane_pid: int | None, own: dict | None, rec: dict | None, instruction: str | None) -> dict | None:
    """Итог проверки: {ok, reason, pid, pane_pid, job_id, session_id}; None — агента нет и разговор никто не ведёт.

    pane_pid — процесс живой панели (None, если панели нет); own — запись Claude Code этого процесса как есть;
    rec — запись того, кто ведёт разговор (sessions.lookup: для отправленного в фон — запись задачи).
    ok: True — разговор ведёт процесс панели с файлом роли; False — нет, причина в reason; None — данных нет
    (сессия ещё регистрируется или в панели не claude).
    """
    if own and own.get("parkedJobId"):
        job = rec if rec is not None and rec is not own and rec.get("jobId") == own["parkedJobId"] else None
        return _result(False, "background", (job or {}).get("pid"), pane_pid, own["parkedJobId"],
                       (job or {}).get("sessionId"))
    if rec is None:
        return _result(None, pane_pid=pane_pid) if pane_pid else None
    if rec != own and rec.get("pid") != pane_pid:
        reason = "background" if rec.get("kind") == "bg" else "other_process"
        return _result(False, reason, rec.get("pid"), pane_pid, rec.get("jobId"), rec.get("sessionId"))
    cmd = process_command(pane_pid)
    if cmd is None or os.path.basename(cmd.split(" ", 1)[0]) != "claude":     # в панели не claude (подмена в тестах)
        return _result(None, pane_pid=pane_pid, session_id=rec.get("sessionId"))
    ok = bool(instruction) and f"--append-system-prompt-file {instruction}" in cmd
    return _result(True if ok else False, None if ok else "no_role_prompt", pane_pid, pane_pid, None,
                   rec.get("sessionId"))


def describe(c: dict) -> str:
    """Причина словами для владельца."""
    pid = f", pid {c['pid']}" if c.get("pid") else ""
    if c["reason"] == "background":
        job = f"задача {c['job_id']}" if c.get("job_id") else "задача"
        return f"разговор ушёл в фоновую задачу Claude Code ({job}{pid}), у неё нет промпта роли"
    if c["reason"] == "other_process":
        return f"разговор ведёт другой процесс{pid}, не запущенный team"
    return f"процесс панели{pid} запущен без файла роли"


def jobs_dir() -> Path:
    return Path(os.environ.get("TEAM_JOBS_DIR", "~/.claude/jobs")).expanduser()


# Состояние задачи в ~/.claude/jobs/<jobId>/state.json: у живой — working, после остановки — done (claude 2.1.292).
JOB_ENDED = ("done",)


def job_running(job_id: str) -> bool | None:
    """Идёт ли задача по её state.json: True/False; файла нет или он не читается — None."""
    try:
        data = json.loads((jobs_dir() / job_id / "state.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    state = data.get("state") if isinstance(data, dict) else None
    return state not in JOB_ENDED


def stop_job(pid: int, session_id: str, job_id: str | None = None, wait_s: float = 5.0) -> None:
    """Останавливает фоновую задачу по pid из её записи, сверив командную строку: процесс с этим pid должен вести
    ту же сессию. Не сошлось или процесс не вышел — RuntimeError; процесса уже нет — ничего не делает.

    Задачу ведёт либо процесс с --session-id задачи, либо подхваченный демоном запасной процесс
    `claude bg-spare --bg-spare <сокет>`: сессию он получает через сокет, и с ней его связывает только запись
    Claude Code <pid>.json, из которой pid и взят.
    """
    cmd = process_command(pid)
    if cmd is None:
        return
    if f"--session-id {session_id}" not in cmd and "--bg-spare " not in cmd:
        raise RuntimeError(f"процесс {pid} не ведёт сессию {session_id}; не трогаю его")
    rec = sessions.record(pid) or {}                 # запись перечитывается: pid мог достаться другому процессу
    if rec.get("sessionId") != session_id or (job_id and rec.get("jobId") != job_id):
        raise RuntimeError(f"запись процесса {pid} уже не о задаче {job_id or session_id}; не трогаю его")
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    deadline = time.monotonic() + wait_s
    while time.monotonic() < deadline:
        if process_command(pid) is None:
            return
        time.sleep(0.1)
    raise RuntimeError(f"фоновая задача (pid {pid}) не завершилась за {wait_s:.0f} с")
