"""Тонкая обёртка над tmux. Роль живёт в панели, помеченной опцией @team_role.

Раскладка windows: у каждой роли своё окно (с одной панелью).
Раскладка panes: все роли — панели одного окна `team`, менеджер слева крупно.
Адресуем всегда по id панели (%N): он не зависит от раскладки.
"""
from __future__ import annotations

import os
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass

from .config import TeamError, canonical

SHARED_WINDOW = "team"


def _tmux() -> list[str]:
    """tmux на отдельном сокете, если задан TEAM_TMUX_SOCKET (тесты не трогают живой сервер пользователя).

    -u: без UTF-8 в локали (приложение из GUI запускает team без LANG) клиент tmux заменяет табуляцию
    и не-ASCII в выводе на «_», и list-panes отдаёт строки без разделителей, а capture-pane — экран без кириллицы.
    """
    sock = os.environ.get("TEAM_TMUX_SOCKET")
    return ["tmux", "-u", "-L", sock] if sock else ["tmux", "-u"]


def _run(args: list[str], input: str | None = None, check: bool = True) -> subprocess.CompletedProcess:
    try:
        res = subprocess.run([*_tmux(), *args], input=input, capture_output=True, text=True)
    except FileNotFoundError:
        raise TeamError("tmux не найден в PATH") from None
    if check and res.returncode != 0:
        raise TeamError(f"tmux {' '.join(args[:2])}: {res.stderr.strip() or 'ошибка'}")
    return res


@dataclass
class Pane:
    id: str
    role: str              # ключ агента «роль#n»
    window: str
    index: int             # номер окна
    dead: bool
    activity: int          # время последнего вывода в окне (панельного счётчика у tmux нет)
    command: str
    pid: int = 0           # pid процесса панели; это и есть процесс claude (запуск через exec)


def _session_target(session: str) -> str:
    """Цель «сессия целиком»: точное имя и двоеточие после него. Без двоеточия tmux читает точку в имени
    (проект tmp.XXXX из mktemp) как разделитель панели и сессию не находит."""
    return f"={session}:"


def has_session(session: str) -> bool:
    return _run(["has-session", "-t", _session_target(session)], check=False).returncode == 0


# Имя окна — последним полем: оно может содержать перевод строки (его ставит программа в панели
# escape-последовательностью). Строка без табуляций после записи — продолжение её имени.
PANE_FIELDS = ["#{pane_id}", "#{@team_role}", "#{window_index}", "#{pane_dead}", "#{window_activity}",
               "#{pane_current_command}", "#{pane_pid}", "#{window_name}"]


def parse_panes(out: str) -> dict[str, Pane]:
    """Разбор вывода list-panes с PANE_FIELDS. Строку, которую не разобрать, пропускаем с предупреждением в stderr."""
    rows: list[list[str]] = []
    skipped = []
    for line in out.splitlines():
        parts = line.split("\t", len(PANE_FIELDS) - 1)
        if len(parts) == len(PANE_FIELDS) and parts[2].isdigit():
            rows.append(parts)
        elif "\t" not in line and rows:
            rows[-1][-1] += "\n" + line
        else:
            skipped.append(line)
    if skipped:
        print(f"team: пропущено строк list-panes, которые не разобрать: {len(skipped)} ({skipped[0][:60]!r})",
              file=sys.stderr)
    res = {}
    for pid, role, widx, dead, act, cmd, ppid, wname in rows:
        if role:
            role = canonical(role)
            res[role] = Pane(pid, role, wname, int(widx), dead == "1", _int(act), cmd, _int(ppid))
    return res


def _int(text: str) -> int:
    return int(text) if text.isdigit() else 0


def panes(session: str) -> dict[str, Pane]:
    """Агенты сессии «роль#n» → панели. Панели без метки @team_role не учитываются; метка без номера — №1."""
    if not has_session(session):
        return {}
    return parse_panes(_run(["list-panes", "-s", "-t", _session_target(session), "-F", "\t".join(PANE_FIELDS)]).stdout)


def _cwd(path: str) -> str:
    """tmux раскрывает форматы (#…) в значении -c: «#» в имени каталога экранируется как «##»."""
    return path.replace("#", "##")


def _new_pane(session: str, role: str, cwd: str, layout: str) -> str:
    """Создаёт пустую панель с оболочкой и возвращает её id."""
    fmt = "#{pane_id}"
    if not has_session(session):
        name = SHARED_WINDOW if layout == "panes" else role.replace("#", "-")
        return _run(["new-session", "-d", "-P", "-F", fmt, "-s", session, "-n", name, "-c", _cwd(cwd)]).stdout.strip()
    if layout == "panes":
        return _run(["split-window", "-d", "-P", "-F", fmt, "-t", f"{_session_target(session)}{SHARED_WINDOW}", "-c", _cwd(cwd)]).stdout.strip()
    return _run(["new-window", "-d", "-P", "-F", fmt, "-t", _session_target(session), "-n", role.replace("#", "-"), "-c", _cwd(cwd)]).stdout.strip()


def open_role(session: str, role: str, cwd: str, command: str, layout: str = "windows",
              manager_width: str = "50%") -> str:
    # Панель сначала создаётся с оболочкой, remain-on-exit включается, и только потом запускается команда:
    # иначе упавшая сразу команда унесла бы панель (а для первой — и сессию) до настройки.
    pid = _new_pane(session, role, cwd, layout)
    _run(["set-option", "-p", "-t", pid, "@team_role", role])
    _run(["set-option", "-w", "-t", pid, "remain-on-exit", "on"])
    if layout == "panes":
        _run(["set-option", "-w", "-t", pid, "pane-border-status", "top"])
        _run(["set-option", "-w", "-t", pid, "pane-border-format", " #{@team_role} "])
        _run(["set-option", "-w", "-t", pid, "main-pane-width", manager_width])
        _run(["select-layout", "-t", pid, "main-vertical"], check=False)
    _run(["respawn-pane", "-k", "-t", pid, "-c", _cwd(cwd), command])
    return pid


def close_role(pane_id: str) -> None:
    _run(["kill-pane", "-t", pane_id], check=False)


def close_session(session: str) -> None:
    _run(["kill-session", "-t", _session_target(session)], check=False)


def send_text(pane_id: str, text: str, enter_delay: float = 0.4) -> None:
    """Вставляет текст в панель как ввод пользователя и нажимает Enter."""
    buf = f"team-{uuid.uuid4().hex[:8]}"
    _run(["load-buffer", "-b", buf, "-"], input=text)
    _run(["paste-buffer", "-b", buf, "-t", pane_id, "-d", "-p"])
    time.sleep(enter_delay)
    _run(["send-keys", "-t", pane_id, "Enter"])


def capture(pane_id: str, lines: int = 40, escapes: bool = False) -> str:
    """Хвост экрана панели; escapes=True — с управляющими последовательностями цвета (нужны, чтобы отличить серый текст)."""
    out = _run(["capture-pane", "-p", "-J", *(["-e"] if escapes else []), "-t", pane_id, "-S", f"-{lines}"]).stdout
    return out.rstrip("\n")


def attach(session: str, pane_id: str | None = None) -> None:
    if pane_id:
        _run(["select-window", "-t", pane_id], check=False)
        _run(["select-pane", "-t", pane_id], check=False)
    subprocess.run([*_tmux(), "attach-session", "-t", _session_target(session)])
