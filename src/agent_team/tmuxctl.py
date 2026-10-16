"""Тонкая обёртка над tmux. Роль живёт в панели, помеченной опцией @team_role.

Раскладка windows: у каждой роли своё окно (с одной панелью).
Раскладка panes: все роли — панели одного окна `team`, менеджер слева крупно.
Адресуем всегда по id панели (%N): он не зависит от раскладки.
"""
from __future__ import annotations

import subprocess
import time
import uuid
from dataclasses import dataclass

from .config import TeamError

SHARED_WINDOW = "team"


def _run(args: list[str], input: str | None = None, check: bool = True) -> subprocess.CompletedProcess:
    try:
        res = subprocess.run(["tmux", *args], input=input, capture_output=True, text=True)
    except FileNotFoundError:
        raise TeamError("tmux не найден в PATH") from None
    if check and res.returncode != 0:
        raise TeamError(f"tmux {' '.join(args[:2])}: {res.stderr.strip() or 'ошибка'}")
    return res


@dataclass
class Pane:
    id: str
    role: str
    window: str
    index: int             # номер окна
    dead: bool
    activity: int          # время последнего вывода в окне (панельного счётчика у tmux нет)
    command: str
    pid: int = 0           # pid процесса панели; это и есть процесс claude (запуск через exec)


def has_session(session: str) -> bool:
    return _run(["has-session", "-t", f"={session}"], check=False).returncode == 0


def panes(session: str) -> dict[str, Pane]:
    """Роли сессии → панели. Панели без метки @team_role не учитываются."""
    if not has_session(session):
        return {}
    fmt = "\t".join(["#{pane_id}", "#{@team_role}", "#{window_name}", "#{window_index}",
                     "#{pane_dead}", "#{window_activity}", "#{pane_current_command}", "#{pane_pid}"])
    out = _run(["list-panes", "-s", "-t", f"={session}", "-F", fmt]).stdout
    res = {}
    for line in out.splitlines():
        pid, role, wname, widx, dead, act, cmd, ppid = line.split("\t")
        if role:
            res[role] = Pane(pid, role, wname, int(widx), dead == "1", int(act or 0), cmd, int(ppid or 0))
    return res


def _new_pane(session: str, role: str, cwd: str, layout: str) -> str:
    """Создаёт пустую панель с оболочкой и возвращает её id."""
    fmt = "#{pane_id}"
    if not has_session(session):
        name = SHARED_WINDOW if layout == "panes" else role
        return _run(["new-session", "-d", "-P", "-F", fmt, "-s", session, "-n", name, "-c", cwd]).stdout.strip()
    if layout == "panes":
        return _run(["split-window", "-d", "-P", "-F", fmt, "-t", f"={session}:{SHARED_WINDOW}", "-c", cwd]).stdout.strip()
    return _run(["new-window", "-d", "-P", "-F", fmt, "-t", f"={session}:", "-n", role, "-c", cwd]).stdout.strip()


def open_role(session: str, role: str, cwd: str, command: str, layout: str = "windows") -> str:
    # Панель сначала создаётся с оболочкой, remain-on-exit включается, и только потом запускается команда:
    # иначе упавшая сразу команда унесла бы панель (а для первой — и сессию) до настройки.
    pid = _new_pane(session, role, cwd, layout)
    _run(["set-option", "-p", "-t", pid, "@team_role", role])
    _run(["set-option", "-w", "-t", pid, "remain-on-exit", "on"])
    if layout == "panes":
        _run(["set-option", "-w", "-t", pid, "pane-border-status", "top"])
        _run(["set-option", "-w", "-t", pid, "pane-border-format", " #{@team_role} "])
        _run(["set-option", "-w", "-t", pid, "main-pane-width", "50%"])
        _run(["select-layout", "-t", pid, "main-vertical"], check=False)
    _run(["respawn-pane", "-k", "-t", pid, "-c", cwd, command])
    return pid


def close_role(pane_id: str) -> None:
    _run(["kill-pane", "-t", pane_id], check=False)


def close_session(session: str) -> None:
    _run(["kill-session", "-t", f"={session}"], check=False)


def send_text(pane_id: str, text: str, enter_delay: float = 0.4) -> None:
    """Вставляет текст в панель как ввод пользователя и нажимает Enter."""
    buf = f"team-{uuid.uuid4().hex[:8]}"
    _run(["load-buffer", "-b", buf, "-"], input=text)
    _run(["paste-buffer", "-b", buf, "-t", pane_id, "-d", "-p"])
    time.sleep(enter_delay)
    _run(["send-keys", "-t", pane_id, "Enter"])


def capture(pane_id: str, lines: int = 40) -> str:
    out = _run(["capture-pane", "-p", "-J", "-t", pane_id, "-S", f"-{lines}"]).stdout
    return out.rstrip("\n")


def attach(session: str, pane_id: str | None = None) -> None:
    if pane_id:
        _run(["select-window", "-t", pane_id], check=False)
        _run(["select-pane", "-t", pane_id], check=False)
    subprocess.run(["tmux", "attach-session", "-t", f"={session}"])
