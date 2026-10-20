"""Команда team: управление командой агентов Claude Code (список команд — в OVERVIEW ниже и в `team --help`)."""
from __future__ import annotations

import argparse
import importlib.metadata
import json
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

from . import asks, build, handoffs, launch, roleedit, roleguard, sessions, tasklabel, tmuxctl, transcripts, trust
from .config import (DEFAULT_CONTEXT, Role, Team, TeamError, agent_key, canonical, context_limits, launch_fields, library_dir, library_role_names, load_library_role,
                     load_role, load_team, parse_role, split_agent)


# ---------- состояние (кеш; истина — tmux) ----------

def _state_path(team: Team) -> Path:
    return team.state_dir / "state.json"


def load_state(team: Team) -> dict:
    """Ключи «роль#n». Старый формат (ключ без номера) читается как №1."""
    p = _state_path(team)
    raw = json.loads(p.read_text(encoding="utf-8")) if p.is_file() else {}
    state: dict = {}
    for key, val in raw.items():
        state.setdefault(canonical(key), val)
    for key, val in raw.items():
        if "#" in key:
            state[key] = val                     # запись нового формата главнее старой
    return state


def save_state(team: Team, state: dict) -> None:
    team.state_dir.mkdir(parents=True, exist_ok=True)
    _state_path(team).write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")


# ---------- журнал событий ----------

EVENT_TYPES = ("spawn", "restart", "down", "handoff", "task", "report", "commit", "waiting", "owner")


def _events_path(team: Team) -> Path:
    return team.state_dir / "events.jsonl"


_NO_TITLE = object()


def log_event(team: Team, type_: str, agent: str, text: str = "", task: str | None = None, title=_NO_TITLE) -> dict:
    ev = {"ts": int(time.time()), "type": type_, "agent": agent, "text": text, "task": task}
    if title is not _NO_TITLE:                    # ключ title — только у событий `team task`: название или None (снята)
        ev["title"] = title
    team.state_dir.mkdir(parents=True, exist_ok=True)
    with _events_path(team).open("a", encoding="utf-8") as f:
        f.write(json.dumps(ev, ensure_ascii=False) + "\n")
    return ev


def read_events(team: Team) -> list[dict]:
    p = _events_path(team)
    out = []
    if p.is_file():
        for line in p.read_text(encoding="utf-8").splitlines():
            try:
                out.append(json.loads(line))
            except ValueError:
                continue                          # битая строка не должна ронять ленту
    return out


# ---------- worktree ----------

def _has_commits(repo: Path) -> bool:
    return subprocess.run(["git", "-C", str(repo), "rev-parse", "--verify", "--quiet", "HEAD"],
                          capture_output=True).returncode == 0


def worktree_blocker(team: Team, role: Role, n: int = 1) -> str | None:
    """Почему worktree роли не создать: в репозитории нет коммитов (ветка вышла бы без общей истории с main)."""
    path = team.worktree_path(role, n)
    if path is None or path.is_dir():
        return None
    repo = team.worktree_repo(role)
    if repo is None or not _is_git(repo) or _has_commits(repo):
        return None
    return (f"в репозитории {repo} нет коммитов: роль «{role.name}» с worktree не поднимется — ветка вышла бы без общей истории "
            f"с основной. Сделайте первый коммит (например, git -C {repo} commit --allow-empty -m init) и повторите")


def ensure_worktree(team: Team, role: Role, n: int = 1) -> Path:
    path = team.worktree_path(role, n)
    if path is None:
        return team.home
    if path.is_dir():
        return path
    blocker = worktree_blocker(team, role, n)
    if blocker:
        raise TeamError(blocker)
    branch = team.worktree_branch(role, n)
    repo = team.worktree_repo(role)
    exists = subprocess.run(["git", "-C", str(repo), "rev-parse", "--verify", "--quiet", f"refs/heads/{branch}"],
                            capture_output=True).returncode == 0
    args = ["git", "-C", str(repo), "worktree", "add", str(path)]
    args += [branch] if exists else ["-b", branch]
    path.parent.mkdir(parents=True, exist_ok=True)
    res = subprocess.run(args, capture_output=True, text=True)
    if res.returncode != 0:
        raise TeamError(f"не удалось создать worktree {path}: {res.stderr.strip()}")
    return path


# ---------- команды ----------

RESERVED_ENV = {**build.ROLE_CLAUDE_ENV, "CLAUDE_CODE_AUTO_COMPACT_WINDOW": ""}     # имена, которые ставит team сам


def next_free(live: dict, role: str) -> int:
    n = 1
    while agent_key(role, n) in live and not live[agent_key(role, n)].dead:
        n += 1
    return n


def spawn(team: Team, name: str, resume: bool = False, event: str = "spawn", note: str | None = None) -> str:
    """Поднимает агента «роль#n» (имя без номера — №1)."""
    role_name, n = split_agent(name)
    key = agent_key(role_name, n)
    team.start_mode(role_name)                  # проверка, что роль описана в team.yaml
    role = load_role(team, role_name)
    live = tmuxctl.panes(team.session)
    if key in live:
        if not live[key].dead:
            return f"{key}: уже запущена"
        tmuxctl.close_role(live[key].id)
    cwd = ensure_worktree(team, role, n)
    instruction = build.write_instruction(team, role)
    state = load_state(team)
    prev = state.get(key) or {}
    # продолжаем текущую сессию цепочки continued-in, а не сессию запуска: в неё Claude Code давно не пишет
    sid = transcripts.current(prev.get("cwd"), prev.get("session_id"))[0] if resume else None
    resumed = bool(sid)
    sid = sid or build.new_session_id()
    asks.clear(team, key)                       # вопросы прежнего запуска закрыты вместе с ним
    argv = build.claude_argv(team, role, instruction, sid, resume=resumed, settings=asks.write_settings(team, key, role),
                             mcp_config=launch.mcp_config_for(team, role, key))
    env = {**build.ROLE_CLAUDE_ENV, **launch.compact_env(team, role), **launch.role_env(team, role, RESERVED_ENV), "TEAM_ROLE": role_name, "TEAM_AGENT": key, "TEAM_PROJECT": team.project, "TEAM_REPO": str(team.home)}
    pane = tmuxctl.open_role(team.session, key, str(cwd), build.shell_command(argv, env), team.layout,
                              team.manager_width)
    state[key] = {"session_id": sid, "started": int(time.time()), "cwd": str(cwd), "instruction": str(instruction)}
    save_state(team, state)
    log_event(team, event, key, f"{'продолжена прежняя сессия' if resumed else 'новая сессия'}, {cwd}"
                                + (f"; {note}" if note else ""))
    msg = f"{key}: запущена, панель {pane} в tmux-сессии {team.session} ({cwd})"
    if resume and not resumed and prev.get("session_id"):
        msg += (f"\n  прежней сессии не найдено — поднята новая; состояние передайте файлом передачи "
                f"(team handoffs, team handoff {key})")
    if trust.trusted_by(cwd) is False:
        msg += f"\n  внимание: {trust.advice(cwd, trust_root(team, role))}"
    return msg


def trust_root(team: Team, role: Role) -> Path:
    """Один каталог, доверие к которому покрывает каталоги агентов роли: корень worktree или home."""
    return team.worktree_root if role.worktree else team.home


def cmd_up(team: Team, args) -> int:
    order = [team.manager] + [r for r in team.role_names() if r != team.manager]
    todo = [n for n in order if n == team.manager or team.start_mode(n) == "always"]
    for name in todo:                                   # отказ до первой панели: up не оставляет команду наполовину
        blocker = worktree_blocker(team, load_role(team, name))
        if blocker:
            raise TeamError(blocker)
    for name in todo:
        print(spawn(team, agent_key(name, 1), resume=args.resume))
    print(f"Подключиться: team attach   (tmux-сессия {team.session})")
    return 0


def cmd_spawn(team: Team, args) -> int:
    if "#" in args.role:
        name = canonical(args.role)
    else:
        name = agent_key(args.role, next_free(tmuxctl.panes(team.session), args.role))
    print(spawn(team, name, resume=args.resume))
    return 0


def _require_window(team: Team, name: str) -> tmuxctl.Pane:
    key = canonical(name)
    live = tmuxctl.panes(team.session)
    if key not in live:
        raise TeamError(f"агент «{key}» не запущен (team spawn {split_agent(key)[0]})")
    return live[key]


def live_session(team: Team, key: str, pane: tmuxctl.Pane | None, st: dict | None = None) -> tuple[str | None, Path | None]:
    """Текущая сессия агента и её транскрипт — единое место для status, ctx, адреса и проверки роли.

    Живой агент: sessionId записи ~/.claude/sessions по pid панели (при parkedJobId — записи задачи), если у него есть
    транскрипт: /clear начинает новую сессию, а отметки continued-in в старом транскрипте не оставляет.
    Иначе (записи нет, панель мертва, транскрипта нет) — цепочка continued-in от сессии запуска.
    Сменившаяся сессия записывается в state.json (session_id), чтобы restart продолжил актуальный разговор;
    сессия запуска остаётся в launch_session_id.
    """
    st = load_state(team).get(key) or {} if st is None else st
    cwd, launch = st.get("cwd"), st.get("session_id")
    sid, transcript = transcripts.current(cwd, launch)
    if pane is None or pane.dead:
        return sid, transcript
    rec = sessions.lookup(pane.pid, sid, launch)
    live_sid = (rec or {}).get("sessionId")
    if not live_sid or live_sid == sid:
        return sid, transcript
    path = transcripts.locate_file(cwd, live_sid)
    if not path:
        return sid, transcript
    if live_sid != launch and key in (state := load_state(team)):
        cur = state[key]
        cur.setdefault("launch_session_id", cur.get("session_id"))
        cur["session_id"] = live_sid
        save_state(team, state)
        st["session_id"], st["launch_session_id"] = live_sid, cur["launch_session_id"]
    return live_sid, path


def role_address(team: Team, name: str) -> str | None:
    key = canonical(name)
    pane = tmuxctl.panes(team.session).get(key)
    st = load_state(team).get(key) or {}
    sid = live_session(team, key, pane, st)[0]
    return sessions.address(pane.pid if pane else None, sid, st.get("session_id"))


def role_check(team: Team, key: str, pane: tmuxctl.Pane | None, st: dict, sid: str | None) -> tuple[dict | None, dict | None]:
    """Проверка роли агента (roleguard.check) и запись того, кто ведёт его разговор.

    Панели нет или она завершилась — ищем разговор по сессиям: фоновая задача переживает закрытие панели.
    """
    alive = pane is not None and not pane.dead
    pid = pane.pid if alive else None
    rec = sessions.lookup(pid, sid, st.get("session_id"))
    instruction = st.get("instruction") or str(team.state_dir / "build" / f"{split_agent(key)[0]}.txt")
    return roleguard.check(pid, sessions.record(pid), rec, instruction), rec


def cmd_addr(team: Team, args) -> int:
    pane = _require_window(team, args.role)
    key = canonical(args.role)
    st = load_state(team).get(key) or {}
    check, _ = role_check(team, key, pane, st, live_session(team, key, pane, st)[0])
    if check and check["ok"] is False:
        raise TeamError(f"в панели «{key}» не сессия роли: {roleguard.describe(check)}. Сообщение ушло бы агенту без "
                        f"роли; восстановить: team restart {key}")
    addr = role_address(team, args.role)
    if not addr:
        raise TeamError(f"у агента «{args.role}» не найден сокет обмена сообщениями (сессия ещё стартует или не регистрируется); "
                        f"запасной путь: team send {args.role} --paste")
    print(addr)
    return 0


def cmd_send(team: Team, args) -> int:
    win = _require_window(team, args.role)
    if win.dead:
        raise TeamError(f"окно агента «{args.role}» завершилось (team restart {args.role})")
    if not args.paste:
        addr = role_address(team, args.role)
        hint = (f"отправьте инструментом SendMessage на адрес {addr}" if addr
                else "адрес для SendMessage не найден")
        raise TeamError(f"team send без --paste не доставляет: сообщение роли идёт через SendMessage, чтобы роль видела "
                        f"отправителя; {hint}. Вставка в строку ввода — только явно: team send {args.role} --paste …")
    tmuxctl.send_text(win.id, " ".join(args.text))
    print(f"→ {args.role}: вставлено в строку ввода (роль увидит это как ввод пользователя)")
    return 0


def cmd_peek(team: Team, args) -> int:
    win = _require_window(team, args.role)
    print(tmuxctl.capture(win.id, args.lines))
    return 0


def _ago(seconds: int | None) -> str:
    if seconds is None:                                 # запись сессии без времени смены status
        return "-"
    if seconds < 90:
        return f"{seconds} с"
    if seconds < 5400:
        return f"{seconds // 60} мин"
    return f"{seconds // 3600} ч"


# Экран доверия к каталогу при первом запуске claude в нём (снят на claude 2.1.292). Подсказка внизу
# «Enter to confirm · Esc to cancel» отдельно признаком не служит: такая же бывает и в других меню.
TRUST_PATTERNS = (
    re.compile(r"Is this a project you created or one you trust", re.I),
    re.compile(r"Yes, I trust this folder", re.I),
)

WAITING_PATTERNS = (
    re.compile(r"Do you want to (proceed|make this edit|create|allow|run|overwrite)", re.I),
    re.compile(r"Would you like to proceed", re.I),
    re.compile(r"❯\s*1\.\s*Yes"),
    # форма вопроса агента (AskUserQuestion) и экран проверки ответов; одно «Esc to cancel» — это и меню
    # владельца (/rewind: «Enter to continue · Esc to cancel»), ожиданием оно не считается
    re.compile(r"Enter to select.*Esc to cancel", re.I),
    re.compile(r"Review your answers", re.I),
)


def waiting_human(tail: str) -> bool:
    return waiting_kind(tail) is not None


def waiting_kind(tail: str) -> str | None:
    """На чём сессия стоит, по хвосту панели: trust — вопрос о доверии к каталогу, prompt — запрос права или
    вопрос агента; None — не стоит.

    Признак ищется в каждой строке и в каждой паре соседних строк, склеенных пробелом: в узкой панели Claude Code
    сам переносит подсказку формы («Enter to select · … · ctrl+g to edit» / «in VS Code · Esc to cancel»).
    Шире пары не склеиваем, чтобы старое «Enter to select» выше не сошлось с чужим «Esc to cancel».
    """
    lines = tail.splitlines()
    chunks = lines + [f"{a.rstrip()} {b.lstrip()}" for a, b in zip(lines, lines[1:])]
    if any(p.search(c) for p in TRUST_PATTERNS for c in chunks):
        return "trust"
    if any(p.search(c) for p in WAITING_PATTERNS for c in chunks):
        return "prompt"
    return None


ANSI_RE = re.compile(r"\x1b\[([0-9;]*)m|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-9;?]*[A-Za-ln-z]")
RULE_RE = re.compile(r"^[─━]{10,}$")


def input_draft(raw: str) -> bool:
    """В строке ввода Claude Code набран неотправленный текст. raw — захват панели с цветом (capture escapes=True).

    Поле ввода — между двумя линиями «────», строка начинается с «❯ ». Подсказка-заглушка («Try "…"») напечатана
    приглушённым цветом (SGR 2), введённый текст — обычным: черновик — это видимый текст без приглушения.
    Поля не нашли (другой экран, окно без claude) — черновика нет.
    """
    lines = raw.splitlines()
    plain = [ANSI_RE.sub("", l).strip() for l in lines]
    rules = [i for i, l in enumerate(plain) if RULE_RE.match(l)]
    start = next((a for a, b in zip(reversed(rules[:-1]), reversed(rules[1:])) if b - a > 1 and plain[a + 1].startswith("❯")), None)
    if start is None:
        return False
    end = rules[rules.index(start) + 1]
    dim, prompt_cut = False, False
    for k in range(start + 1, end):
        pos = 0
        for m in ANSI_RE.finditer(lines[k] + "\x1b[0m"):
            text = lines[k][pos:m.start()]
            if k == start + 1 and not prompt_cut and "❯" in text:
                text, prompt_cut = text.replace("❯", "", 1), True
            if text.replace("\xa0", " ").strip() and not dim:
                return True
            pos = m.end()
            if m.group(1) is not None:
                for code in (m.group(1) or "0").split(";"):
                    if code == "2":
                        dim = True
                    elif code in ("0", "22", ""):
                        dim = False
    return False


def _git_branch(path: Path) -> str | None:
    res = subprocess.run(["git", "--no-optional-locks", "-C", str(path), "rev-parse", "--abbrev-ref", "HEAD"], capture_output=True, text=True)
    out = res.stdout.strip()
    return out if res.returncode == 0 and out and out != "HEAD" else None


def _git_status_lines(path: Path) -> list[str] | None:
    """Строки `git status --porcelain` целиком (код состояния и путь); None, если каталога нет или это не git."""
    if not path.is_dir():
        return None
    res = subprocess.run(["git", "--no-optional-locks", "-c", "core.quotepath=false", "-C", str(path), "status", "--porcelain"], capture_output=True, text=True)
    if res.returncode != 0:
        return None
    return [line for line in res.stdout.splitlines() if len(line) > 3]


def _git_dirty(path: Path) -> list[str] | None:
    """Пути из `git status --porcelain`; None, если каталога нет или это не git."""
    lines = _git_status_lines(path)
    return None if lines is None else [line[3:] for line in lines]


def _config_prefixes(team: Team, cwd: Path) -> list[str]:
    """Каталоги конфигурации (каталог агентов проекта и .claude) относительно cwd, с косой чертой в конце."""
    out = [".claude/"]
    try:
        out.append(team.agents_dir.resolve().relative_to(cwd.resolve()).as_posix().rstrip("/") + "/")
    except ValueError:
        pass
    return out


def handoff_changes(team: Team, role_name: str, cwd: Path) -> list[str]:
    """Работа в worktree агента, которую сброс сессии потеряет из виду.

    У роли без своего worktree (worktree: null) cwd — основной каталог проекта: неотслеживаемые каталоги
    конфигурации (агенты проекта, .claude) работой не считаются. Изменения отслеживаемых файлов — считаются."""
    lines = _git_status_lines(cwd)
    if lines is None:
        return []
    if load_role(team, role_name).worktree is None:
        prefixes = _config_prefixes(team, cwd)
        lines = [ln for ln in lines
                 if not (ln.startswith("?? ") and any((ln[3:].strip('"') + ("/" if not ln.endswith("/") else "")).startswith(p) for p in prefixes))]
    return real_changes([ln[3:] for ln in lines])


JUNK_RE = re.compile(r"(^|/)(\.DS_Store|__pycache__|\.team|\.venv|node_modules|\.pytest_cache|\.build)(/|$)|\.(pyc|swp)$")


def real_changes(dirty: list[str] | None) -> list[str]:
    """Пути из git status без мусора окружения (.DS_Store, __pycache__, .team, *.pyc, *.swp)."""
    return [p for p in (dirty or []) if not JUNK_RE.search(p.strip().strip('"'))]


def context_state(team: Team, role: Role, a: dict, transcript: Path | None) -> dict:
    """Размер контекста и признаки сброса/предупреждения для агента (поля status --json)."""
    try:
        limits = context_limits(team, role)
    except TeamError:
        limits = dict(DEFAULT_CONTEXT)
    ctx = transcripts.last_context(transcript) if a["alive"] else None
    out = {"ctx": ctx, "ctx_limits": limits,
           "compactions": transcripts.count_compactions(transcript) if a["alive"] else None,
           "reset_due": False, "reset_ready": None, "reset_blockers": [], "context_warning": False}
    if ctx is None:
        return out
    out["context_warning"] = a["state"] == "busy" and ctx > limits["warn"]
    if a["state"] == "idle" and ctx > limits["soft"]:
        out["reset_due"] = True
        blockers = []
        changed = real_changes(a["dirty"])
        if changed:
            blockers.append(f"worktree грязный: {len(changed)} файлов")
        check = a["role_check"]
        if check and check["ok"] is False:
            blockers.append("в панели не сессия роли")
        if a["pane_id"] and dialog_open(ANSI_RE.sub("", tmuxctl.capture(a["pane_id"], 15, escapes=True))):
            blockers.append("в панели открыт диалог")
        out["reset_blockers"], out["reset_ready"] = blockers, not blockers
    return out


def _last_tasks(events: list[dict]) -> dict[str, dict]:
    """Текущая задача агента — по последнему событию type=task: {task, title, ts}.

    Событие от `team task` несёт ключ title (None — задача снята). Событие без title (`team log task … --task X`)
    даёт только номер.
    """
    out: dict[str, dict] = {}
    for ev in events:
        if ev.get("type") == "task" and ev.get("agent"):
            out[ev["agent"]] = {"task": ev.get("task"), "title": ev.get("title"), "ts": ev.get("ts")}
    for key, t in list(out.items()):
        if t["task"] is None and t["title"] is None:
            out[key] = {"task": None, "title": None, "ts": None, "cleared_ts": t["ts"]}   # момент снятия — для отсчёта простоя reap
    return out


def agent_info(team: Team, role: Role, n: int, pane: tmuxctl.Pane | None, state: dict, now: int,
               tasks: dict[str, dict] | None = None) -> dict:
    key = agent_key(role.name, n)
    st = state.get(key) or {}
    alive = pane is not None and not pane.dead
    sid, transcript = live_session(team, key, pane, st)
    check, found = role_check(team, key, pane, st, sid)
    rec = found if alive else None
    agent_state = sessions.state(rec)
    if agent_state:                                     # запись сессии: состояние ставит сам Claude Code
        idle_s, reason = sessions.idle_seconds(rec, now), "prompt" if agent_state == "waiting" else None
    elif alive:                                         # записи нет — по окну tmux и экрану панели
        idle_s, reason = max(0, now - pane.activity), waiting_kind(tmuxctl.capture(pane.id, 15))
    else:
        idle_s, reason = None, None
    # Запись хука — вопрос текущей сессии; сессию берём из живой записи claude: цепочка continued-in может отстать.
    # Известное состояние, кроме waiting, значит, что формы на экране нет.
    question = asks.open_question(team, key, (rec or {}).get("sessionId") or sid) \
        if alive and agent_state in (None, "waiting") else None
    cwd = st.get("cwd") or str(team.worktree_path(role, n) or team.home)
    branch = _git_branch(Path(cwd)) if Path(cwd).is_dir() else None
    branch = branch or team.worktree_branch(role, n)
    model = role.meta.get("model")
    info = {
        "name": key, "role": role.name, "n": n, "title": role.title, "kind": role.kind,
        "model": str(model) if model else "inherit",
        "alive": alive,
        "pane_id": pane.id if pane else None,
        "session_id": sid,
        "launch_session_id": st.get("launch_session_id") or st.get("session_id"),
        "transcript": str(transcript) if transcript else None,
        "cwd": cwd,
        "branch": branch,
        "started": st.get("started") if alive else None,
        "state": agent_state,
        "idle_s": idle_s,
        "waiting_human": reason is not None,
        "waiting_reason": reason,
        "question": question,
        "addr": sessions.address(pane.pid, sid, st.get("session_id")) if alive else None,
        "role_check": check,
        "task": ((tasks or {}).get(key) or {}).get("task"),
        "task_title": ((tasks or {}).get(key) or {}).get("title"),
        "task_ts": ((tasks or {}).get(key) or {}).get("ts"),
        "task_cleared_ts": ((tasks or {}).get(key) or {}).get("cleared_ts"),
        "dirty": _git_dirty(Path(cwd)),
    }
    info.update(context_state(team, role, info, transcript))
    return info


def collect_agents(team: Team) -> list[dict]:
    """Все агенты команды: живые и остановленные панели, а у роли без агентов — незапущенный №1."""
    live = tmuxctl.panes(team.session)
    state = load_state(team)
    now = int(time.time())
    tasks = _last_tasks(read_events(team))
    out = []
    for name in team.role_names():
        try:
            role = load_role(team, name)
        except TeamError:
            role = Role(name=name, meta={}, body="", path=team.agents_dir / "roles" / f"{name}.md")
        nums = sorted(split_agent(k)[1] for k in live if split_agent(k)[0] == name) or [1]
        for n in nums:
            out.append(agent_info(team, role, n, live.get(agent_key(name, n)), state, now, tasks))
    return out


TASK_COL = 34
STATE_COL = 17
CTX_COL = 14


def _ctx_cell(a: dict) -> str:
    """Контекст в тысячах токенов; «сброс» — пора начинать с чистого контекста (звёздочка — роль пока не готова), «!» — рост при работе."""
    if a.get("ctx") is None:
        return "-"
    cell = f"{round(a['ctx'] / 1000)}k"
    if a.get("reset_due"):
        cell += " сброс" + ("" if a["reset_ready"] else "*")
    if a.get("context_warning"):
        cell += " !"
    return cell

# Пометка в текстовом status, когда разговор агента ведёт не сессия роли (role_check.ok = False)
ROLE_MARK = {"background": "! в фоне", "other_process": "! чужой процесс", "no_role_prompt": "! без роли"}


def _cut(text: str, width: int) -> str:
    return text if len(text) <= width else text[:width - 1] + "…"


def cmd_status(team: Team, args) -> int:
    agents = collect_agents(team)
    alive = tmuxctl.has_session(team.session)
    if args.json:
        print(json.dumps({"project": team.project, "repo": str(team.home), "session": team.session,
                          "session_alive": alive, "tracker": team.tracker, "agents": agents},
                         ensure_ascii=False, indent=2, default=str))
        return 0
    print(f"проект {team.project}, tmux-сессия {team.session}: {'есть' if alive else 'нет'}")
    name_w = max([len("агент")] + [len(a["name"]) for a in agents]) + 2          # длинное имя не слипается со «состоянием»
    print(f"{'агент':<{name_w}}{'состояние':<{STATE_COL}}{'тихо':<10}{'ctx':<{CTX_COL}}{'задача':<{TASK_COL}}{'адрес для SendMessage'}")
    live = tmuxctl.panes(team.session)
    trust_wait, not_role = [], []
    for a in agents:
        w = live.get(a["name"])
        check = a["role_check"]
        if check and check["ok"] is False:
            st, quiet = ROLE_MARK[check["reason"]], _ago(a["idle_s"])
            not_role.append(a)
        elif a["alive"] and a["waiting_reason"] == "trust":
            st, quiet = "ждёт: доверие", _ago(a["idle_s"])
            trust_wait.append(a)
        elif a["alive"] and a["waiting_human"]:
            st, quiet = "ждёт ответа", _ago(a["idle_s"])
        elif a["alive"] and a["state"] == "idle":
            st, quiet = "простаивает", _ago(a["idle_s"])
        elif a["alive"] and a["state"] is None and a["idle_s"] is None:
            st, quiet = "нет данных", "-"
        elif a["alive"]:
            st, quiet = "работает", _ago(a["idle_s"])
        elif w is not None:
            st, quiet = "завершена", "-"
        else:
            st, quiet = "не запущена", "-"
        print(f"{a['name']:<{name_w}}{st:<{STATE_COL}}{quiet:<10}{_ctx_cell(a):<{CTX_COL}}{_cut(a['task_title'] or '-', TASK_COL - 2):<{TASK_COL}}{a['addr'] or '-'}")
    for a in agents:
        if a.get("reset_due") and a["reset_blockers"]:
            print(f"{a['name']}: контекст {round(a['ctx'] / 1000)}k выше порога, но сбросить пока нельзя — {'; '.join(a['reset_blockers'])}")
    for a in trust_wait:
        print(f"{a['name']}: стоит на вопросе о доверии к каталогу {a['cwd']} — ответ человека: team attach {a['name']}")
    for a in not_role:
        print(f"{a['name']}: ВНИМАНИЕ — в панели не сессия роли: {roleguard.describe(a['role_check'])}; "
              f"восстановить: team restart {a['name']}")
    return 0


def cmd_attach(team: Team, args) -> int:
    if not tmuxctl.has_session(team.session):
        raise TeamError(f"tmux-сессии {team.session} нет (team up)")
    pane = tmuxctl.panes(team.session).get(canonical(args.role or team.manager))
    tmuxctl.attach(team.session, pane.id if pane else None)
    return 0


def stop_background(team: Team, key: str, pane: tmuxctl.Pane | None, fresh: bool) -> str | None:
    """Перед пересозданием: если разговор агента ведёт фоновая задача Claude Code, останавливает её (иначе разговор
    вели бы два процесса) и переводит продолжение на её сессию. Вызывать до закрытия панели: ссылку на задачу
    (parkedJobId) держит запись процесса панели."""
    state = load_state(team)
    st = state.get(key) or {}
    check, _ = role_check(team, key, pane, st, live_session(team, key, pane, st)[0])
    if not check or check["ok"] is not False or check["reason"] == "no_role_prompt":
        return None
    if check["reason"] == "other_process":
        if fresh:
            return None
        raise TeamError(f"разговор «{key}» ведёт другой процесс (pid {check['pid']}), не запущенный team: закройте его "
                        f"и повторите, или team restart {key} --fresh — новая сессия")
    job, pid, job_sid = check["job_id"] or "?", check["pid"], check["session_id"]
    by_hand = (f"Остановите её в списке задач Claude Code (team attach {key}, выбрать задачу, ctrl+x) и повторите")
    if pid and job_sid:
        try:
            roleguard.stop_job(pid, job_sid, check["job_id"])
        except RuntimeError as e:
            raise TeamError(f"{key}: фоновую задачу {job} не остановить: {e}. {by_hand}") from None
    elif check["job_id"] and roleguard.job_running(check["job_id"]):
        raise TeamError(f"{key}: фоновая задача {job} идёт, но её процесс не найден в записях сессий Claude Code. {by_hand}")
    if not fresh and job_sid and transcripts.locate_file(st.get("cwd"), job_sid):
        st["session_id"] = job_sid                # продолжаем разговор с того места, где его вела задача
        state[key] = st
        save_state(team, state)
    if pid and job_sid:
        return f"{key}: остановлена фоновая задача {job} (pid {pid}) — у неё не было промпта роли"
    return f"{key}: панель показывала список фоновых задач Claude Code; задача {job} уже завершена"


def cmd_restart(team: Team, args) -> int:
    key = canonical(args.role)
    pane = tmuxctl.panes(team.session).get(key)
    note = stop_background(team, key, pane, args.fresh)
    if pane:
        tmuxctl.close_role(pane.id)
    used = None
    if args.fresh:
        used = handoffs.mark_last_used(team, key)
        clear_task(team, key, "новая сессия")
    if note:
        print(note)
    print(spawn(team, key, resume=not args.fresh, event="restart", note=note))
    if args.fresh:
        addr = wait_address(team, key)
        print(f"адрес для SendMessage: {addr}" if addr else
              f"адрес для SendMessage пока не зарегистрирован (сессия стартует); позже: team addr {key}")
        print(f"последняя передача: {handoffs.handoffs_dir(team) / (used + '.md')}" if used else "файла передачи у роли нет")
    return 0


ADDR_WAIT_S = 10.0       # сколько ждать регистрации новой сессии после restart --fresh


def wait_address(team: Team, key: str) -> str | None:
    end = time.time() + ADDR_WAIT_S
    while True:
        addr = role_address(team, key)
        if addr or time.time() >= end:
            return addr
        time.sleep(0.5)


def clear_task(team: Team, key: str, why: str) -> None:
    """Снимает задачу агента, если она стоит; без задачи события не пишет."""
    cur = _last_tasks(read_events(team)).get(key)
    if cur and (cur["title"] or cur["task"]):
        log_event(team, "task", key, f"задача снята: {why}", None, title=None)


def cmd_task(team: Team, args) -> int:
    """task <агент> "<название>" [--id N] — поставить; --clear — снять; без названия — показать текущую."""
    role_name, _ = split_agent(args.agent)
    if role_name not in team.role_names():
        raise TeamError(f"роли «{role_name}» нет в team.yaml (есть: {', '.join(team.role_names())})")
    key = canonical(args.agent)
    if args.clear:
        if args.title is not None or args.id:
            raise TeamError("--clear не сочетается с названием и --id")
        clear_task(team, key, "по просьбе")
        print(f"{key}: задача снята")
        return 0
    if args.title is None:
        if args.id:
            raise TeamError("--id без названия: укажите название задачи")
        cur = _last_tasks(read_events(team)).get(key) or {}
        title = cur.get("title")
        if not title and not cur.get("task"):
            print(f"{key}: задачи нет")
        else:
            print(f"{key}: {title or '(без названия)'}" + (f" [{cur['task']}]" if cur.get("task") else ""))
        return 0
    bad = tasklabel.problems(args.title)
    if args.id and ("\n" in args.id or "\r" in args.id):
        bad.append("--id в одну строку: номер задачи без переводов строки")
    if bad:
        raise TeamError("название задачи не принято:\n  - " + "\n  - ".join(bad))
    title = tasklabel.normalize(args.title)
    log_event(team, "task", key, title, args.id or None, title=title)
    print(f"{key}: задача «{title}»" + (f" [{args.id}]" if args.id else ""))
    return 0


def stop_agent(team: Team, key: str, reason: str = "остановлена") -> None:
    """Остановка одного агента: закрыть панель, записать событие, снять задачу и вопрос."""
    pane = tmuxctl.panes(team.session).get(key)
    if pane:
        tmuxctl.close_role(pane.id)
        log_event(team, "down", key, reason)
    clear_task(team, key, "роль остановлена")
    asks.clear(team, key)


def cmd_down(team: Team, args) -> int:
    if args.role:
        key = canonical(args.role)
        stop_agent(team, key)
        print(f"{key}: остановлена")
    else:
        for key in tmuxctl.panes(team.session):
            log_event(team, "down", key, "остановлена вместе с командой")
            clear_task(team, key, "роль остановлена")
        asks.clear(team)
        tmuxctl.close_session(team.session)
        print(f"{team.session}: остановлена вся команда")
    return 0


DIALOG_RE = re.compile(r"Enter to (confirm|select|continue)|^\s*❯\s*\d+\.\s", re.I | re.M)


def dialog_open(plain: str) -> bool:
    """На экране панели диалог Claude Code: выбор, подтверждение, запрос права, мастер настроек."""
    return waiting_kind(plain) is not None or bool(DIALOG_RE.search(plain))


def reap_decision(team: Team, a: dict, keep: set[str], now: int | None = None) -> tuple[bool, str]:
    """Можно ли остановить агента по простою: (да/нет, причина). Данные — из agent_info, как в status --json."""
    limit = (team.idle_stop_minutes or 0) * 60
    check = a["role_check"]
    if a["name"] in keep:
        return False, "назван в --keep"
    if a["name"] == canonical(team.manager):
        return False, "менеджер"
    if team.start_mode(a["role"]) != "on_demand":
        return False, f"start: {team.start_mode(a['role'])}"
    if not a["alive"]:
        return False, "не запущен"
    if check and check["ok"] is False:
        return False, "в панели не сессия роли"
    if a["waiting_human"]:
        return False, "ждёт ответа"
    if a["state"] == "busy":
        return False, "работает"
    if a["task"] or a["task_title"]:                    # отчёт или вопрос обычным текстом хук не видит: задача снята — работа принята
        return False, f"есть задача: {a['task_title'] or a['task']}"
    if a["idle_s"] is None:
        return False, "нет данных о простое"
    idle = a["idle_s"]
    if a.get("task_cleared_ts") and now is not None:    # простой — от более позднего из последнего действия и снятия задачи
        idle = min(idle, max(0, now - a["task_cleared_ts"]))
    if idle < limit:
        return False, f"простой {idle // 60} мин < {team.idle_stop_minutes}"
    return True, f"простой {idle // 60} мин"


def cmd_reap(team: Team, args) -> int:
    """Останавливает простаивающих агентов start: on_demand (idle_stop_minutes в team.yaml)."""
    if team.idle_stop_minutes is None:
        if args.json:
            print("[]")
        else:
            print("автоостановка выключена: idle_stop_minutes: off")
        return 0
    keep = {canonical(k) for k in args.keep}
    out = []
    now = int(time.time())
    for a in collect_agents(team):
        if not a["alive"]:
            continue
        stop, reason = reap_decision(team, a, keep, now)
        if stop and a["pane_id"]:
            screen = tmuxctl.capture(a["pane_id"], 15, escapes=True)
            if dialog_open(ANSI_RE.sub("", screen)):
                stop, reason = False, "в панели открыт диалог"
            elif input_draft(screen):
                stop, reason = False, "в строке ввода набран текст"
        if stop and not args.dry_run:
            stop_agent(team, a["name"], f"остановлена: {reason}")
        action = ("would_stop" if args.dry_run else "stopped") if stop else "kept"
        out.append({"name": a["name"], "idle_s": a["idle_s"], "action": action, "reason": reason})
    if args.json:
        print(json.dumps(out, ensure_ascii=False, indent=2))
    elif not out:
        print("живых агентов нет")
    else:
        for o in out:
            print(f"{o['name']}: {o['action']} ({o['reason']})")
    return 0


KNOWN_KINDS = ("manager", "executor", "reviewer", "watcher")


def _zone_overlaps(team: Team) -> list[str]:
    owner: dict[str, str] = {}
    out = []
    for name in team.role_names():
        try:
            role = load_role(team, name)
        except TeamError:
            continue
        for z in role.meta.get("zone") or []:
            z = str(z)
            if z in owner and owner[z] != name:
                out.append(f"зона «{z}» записана и у {owner[z]}, и у {name}")
            owner.setdefault(z, name)
    return out


def _is_git(path: Path) -> bool:
    return path.is_dir() and subprocess.run(["git", "-C", str(path), "rev-parse", "--git-dir"],
                                            capture_output=True).returncode == 0


def _check(team: Team) -> list[dict]:
    """Проверки описания команды: [{level: error|warn|ok, title, detail}]."""
    out: list[dict] = []

    def add(level: str, title: str, detail: str) -> None:
        out.append({"level": level, "title": title, "detail": detail})

    if shutil.which("tmux") is None:
        add("error", "tmux", "tmux не найден в PATH")
    else:
        add("ok", "tmux", "tmux найден")
    if shutil.which("claude") is None:
        add("warn", "claude", "claude не найден в PATH (для запуска нужен)")
    else:
        add("ok", "claude", "claude найден")
    roles = {}
    for name in team.role_names():
        try:
            roles[name] = load_role(team, name)
            build.assemble_instruction(team, roles[name])
            add("ok", f"роль {name}", "описание читается, инструкция собирается")
        except TeamError as e:
            add("error", f"роль {name}", str(e))
    if team.manager in roles:
        if roles[team.manager].kind != "manager":
            add("error", "менеджер", f"роль {team.manager} назначена менеджером, но её kind = {roles[team.manager].kind}")
        else:
            add("ok", "менеджер", f"{team.manager} — kind manager")
    for name, r in roles.items():
        if r.kind not in KNOWN_KINDS:
            add("warn", f"роль {name}", f"неизвестный kind «{r.kind}»: инструмент знает {', '.join(KNOWN_KINDS)}; "
                "различает он только manager, остальное считает исполнителем")
    wts = {}
    no_commits: set = set()
    for name, r in roles.items():
        if r.worktree:
            key = r.worktree["dir"]
            if key in wts:
                add("error", f"worktree {name}", f"worktree «{key}» у ролей {wts[key]} и {name}")
            wts[key] = name
            repo = team.worktree_repo(r)
            if not _is_git(repo):
                # черновик ещё не запускают: worktree ему не нужен, поэтому только предупреждение
                level = "warn" if r.meta.get("status") == "draft" else "error"
                if r.worktree.get("repo"):
                    add(level, f"worktree {name}", f"{name}: worktree.repo {repo} — не git-репозиторий")
                else:
                    add(level, f"worktree {name}", f"{name}: у роли worktree без repo, а {team.home} — не git-репозиторий; задайте worktree.repo")
            else:
                add("ok", f"worktree {name}", f"репозиторий {repo}")
                if not _has_commits(repo) and repo not in no_commits:
                    no_commits.add(repo)
                    add("warn", f"репозиторий {repo.name}", f"в репозитории {repo} нет коммитов: роли с worktree не поднимутся; "
                                                           f"сделайте первый коммит (git commit --allow-empty -m init)")
        if r.meta.get("status") == "draft":
            add("warn", f"роль {name}", f"{name}: роль-черновик (status: draft)")
    for name, r in roles.items():
        for item in r.unmatched_excludes:
            add("warn", f"роль {name}", f"{name}: exclude {item} — такого элемента нет в общей роли «{r.extends}», исключать нечего")
        if r.extends is None and r.meta.get("exclude"):
            add("warn", f"роль {name}", f"{name}: exclude без extends ничего не делает")
    try:
        shared_names = set(library_role_names())
    except TeamError:
        shared_names = set()
    for name, r in roles.items():
        if r.extends is None and r.path.stem in shared_names:
            add("warn", f"роль {name}", f"{name}: файл назван как общая роль библиотеки, но extends не задан; "
                                         f"копия будет расходиться с библиотекой (extends: {r.path.stem})")
    for name, r in roles.items():
        for level, text in launch.check_role(team, r, RESERVED_ENV):
            add(level, f"запуск {name}", text)
    untrusted: dict[Path, list[str]] = {}
    for name, r in roles.items():
        if r.meta.get("status") == "draft":
            continue
        cwd = team.worktree_path(r) or team.home
        if trust.trusted_by(cwd) is False:
            untrusted.setdefault(trust_root(team, r), []).append(name)
    for root, names in untrusted.items():
        add("warn", "доверие", f"роли {', '.join(names)}: {trust.advice(root, None)}")
    overlaps = _zone_overlaps(team)
    for w in overlaps:
        add("warn", "зоны", w)
    if not overlaps:
        add("ok", "зоны", "зоны ролей не пересекаются")
    return out


def cmd_check(team: Team, args) -> int:
    """Проверка описания команды без запуска агентов."""
    issues = _check(team)
    errors = [i for i in issues if i["level"] == "error"]
    warns = [i for i in issues if i["level"] == "warn"]
    if args.json:
        print(json.dumps({"passed": sum(i["level"] == "ok" for i in issues), "issues": issues}, ensure_ascii=False, indent=2))
        return 1 if errors else 0
    for w in warns:
        print(f"предупреждение: {w['detail']}")
    for e in errors:
        print(f"ошибка: {e['detail']}")
    print(f"роли: {', '.join(team.role_names()) or '-'}; ошибок {len(errors)}, предупреждений {len(warns)}")
    return 1 if errors else 0


def _raw_extends(path: Path):
    """extends из frontmatter файла, который не удалось собрать; None, если не читается."""
    try:
        return parse_role(path).meta.get("extends")
    except (TeamError, OSError):
        return None


def role_fields(role: Role, team: Team, source: str, start, running: int) -> dict:
    wt = role.worktree
    model = role.meta.get("model")
    return {
        "role": role.name, "source": source, "extends": role.extends,
        "title": role.title, "kind": role.kind,
        "model": str(model) if model else "inherit",
        "description": str(role.meta.get("description") or ""),
        "start": start, "file": str(role.path),
        "worktree": {"dir": str(wt["dir"]), "branch": wt.get("branch"), "repo": wt.get("repo")} if wt else None,
        "zone": [str(z) for z in role.meta.get("zone") or []],
        "includes": role.includes, "allow": role.allow, "exclude": role.exclude,
        "tracker_zone": role.meta.get("tracker_zone"),
        "effective_allow": build.allowed_tools(team, role), **launch_fields(team, role),    # mcp — имена серверов, определения не выводятся
        "running": running, "body": role.body, "instruction": build.assemble_instruction(team, role),
    }


def role_info(team: Team, name: str, live: dict | None = None) -> dict:
    live = tmuxctl.panes(team.session) if live is None else live
    running = sum(1 for k, p in live.items() if split_agent(k)[0] == name and not p.dead)
    path = team.agents_dir / "roles" / f"{name}.md"
    try:
        return role_fields(load_role(team, name), team, "project", team.start_mode(name), running)
    except TeamError as e:
        return {"role": name, "source": "project", "extends": _raw_extends(path), "file": str(path),
                "start": team.start_mode(name), "running": running, "error": str(e)}


def library_info(team: Team, name: str) -> dict:
    path = library_dir() / f"{name}.md"
    try:
        return role_fields(load_library_role(name), team, "library", None, 0)
    except TeamError as e:
        return {"role": name, "source": "library", "extends": None, "file": str(path), "start": None,
                "running": 0, "error": str(e)}


def cmd_set(team: Team, args) -> int:
    """set: правка ключа верхнего уровня team.yaml (сейчас только idle_stop_minutes)."""
    parse = roleedit.SETTABLE_KEYS.get(args.key)
    if parse is None:
        raise TeamError(f"ключ «{args.key}» командой set не правится (поддерживаются: {', '.join(roleedit.SETTABLE_KEYS)})")
    value = parse(args.value)                       # тот же валидатор, что при загрузке team.yaml
    roleedit.set_top_level(team.root / "agents" / "team.yaml", args.key, "off" if value is None else value)
    if args.json:
        print(json.dumps({"key": args.key, "value": value}, ensure_ascii=False))
    elif value is None:
        print(f"{args.key}: off (выключено)")
    else:
        print(f"{args.key}: {value}")
    return 0


def cmd_role(team: Team, args) -> int:
    """role set / role new: правка описания роли; печатает JSON роли."""
    if args.action == "set":
        roleedit.edit_role(team, args.role, args.title, args.model, args.description, args.start, args.extends)
    else:
        roleedit.new_role(team, args.role, args.title, args.model, args.description, args.start or ("manual" if args.extends else "on_demand"), args.extends)
    team = load_team()                                        # team.yaml изменился
    print(json.dumps(role_info(team, args.role), ensure_ascii=False, indent=2))
    return 0


def cmd_roles(team: Team, args) -> int:
    live = tmuxctl.panes(team.session)
    infos = [role_info(team, n, live) for n in team.role_names()]
    if args.library:
        infos += [library_info(team, n) for n in library_role_names()]
    if args.json:
        print(json.dumps(infos, ensure_ascii=False, indent=2))
        return 0
    print(f"{'роль':<16}{'kind':<10}{'start':<11}{'запущено':<10}{'название'}")
    for i in infos:
        base = f" (extends {i['extends']})" if i.get("extends") else ""
        src = "  [библиотека]" if i["source"] == "library" else ""
        print(f"{i['role']:<16}{i.get('kind') or '-':<10}{i['start'] or '-':<11}{i['running']:<10}"
              f"{i.get('title') or i.get('error')}{base}{src}")
    return 0


HANDOFF_REQUEST = ("Подготовь передачу: заполни файл {path} (разделы «Сделано», «Проверено», «В работе», «Подводные камни», "
                   "«Дальше»; комментарии-подсказки удали) и продублируй итог комментарием в задаче трекера. "
                   "Незакоммиченное зафиксируй или перечисли. После этого ничего не делай.")


def cmd_handoff(team: Team, args) -> int:
    """Создаёт файл передачи и просит агента заполнить его перед остановкой или пересозданием."""
    win = _require_window(team, args.role)
    key = canonical(args.role)
    role_name, n = split_agent(key)
    st = load_state(team).get(key) or {}
    cwd = st.get("cwd")
    changed = handoff_changes(team, role_name, Path(cwd)) if cwd else []
    if changed and not args.force:
        raise TeamError(f"worktree агента «{key}» грязный ({len(changed)} файлов: {', '.join(changed[:5])}"
                        f"{'…' if len(changed) > 5 else ''}): после сброса сессии несохранённое теряется из виду. "
                        f"Попросите роль закоммитить или отложить правки; если сброс всё равно нужен — team handoff {key} --force")
    branch = (_git_branch(Path(cwd)) if cwd and Path(cwd).is_dir() else None)
    path, again = handoffs.reuse_or_create(team, key, args.task, args.reason, branch, cwd)
    request = HANDOFF_REQUEST.format(path=path)
    log_event(team, "handoff", key, f"{'повторный запрос' if again else 'запрос'} передачи: {path}", args.task)
    if args.paste:
        tmuxctl.send_text(win.id, request)
        print(f"→ {key}: запрос передачи вставлен в строку ввода ({path})")
        return 0
    addr = role_address(team, key)
    if not addr:
        raise TeamError(f"адрес агента «{key}» не найден (файл передачи создан: {path}); запасной путь: team handoff {key} --paste")
    print(f"Отправьте SendMessage на {addr} текст:\n{request}")
    return 0


def cmd_handoffs(team: Team, args) -> int:
    items = handoffs.list_all(team)
    if args.json:
        print(json.dumps(items, ensure_ascii=False, indent=2))
        return 0
    for h in items:
        print(f"{h['id']}  {h['status']:<8}{h['task'] or '-'}")
    return 0


def cmd_events(team: Team, args) -> int:
    evs = [e for e in read_events(team) if args.since is None or e.get("ts", 0) >= args.since]
    evs.reverse()                                       # поздняя запись раньше; сортировка по ts устойчива
    evs.sort(key=lambda e: e.get("ts", 0), reverse=True)
    if args.limit is not None:
        evs = evs[:args.limit]
    if args.json:
        print(json.dumps(evs, ensure_ascii=False, indent=2))
    else:
        for e in evs:
            print(f"{e['ts']}  {e['type']:<8}{e['agent']:<16}{e['text']}")
    return 0


def cmd_log(team: Team, args) -> int:
    if args.type not in EVENT_TYPES:
        raise TeamError(f"тип события «{args.type}»: допустимы {', '.join(EVENT_TYPES)}")
    agent = args.agent
    if agent.split("#")[0] in team.role_names():
        agent = canonical(agent)                        # роль без номера — №1; чужие метки (owner) остаются как есть
    log_event(team, args.type, agent, " ".join(args.text), args.task)
    return 0


OVERVIEW = """\
Команда агентов Claude Code в tmux: вы говорите с одним менеджером, роли постоянны, а сессии одноразовы — состояние живёт в git и трекере, а не в контексте агента.

team — единая точка входа для команды агентов проекта.

Поток работы:
  1. Новый проект:     team init            создать agents/ (роли, правила, шаблоны), затем отредактировать роли
                       team check           проверить описание команды
  2. Начало работы:    team up              поднять менеджера (и роли со start: always)
                       team attach          подключиться к tmux; говорить только с менеджером
  3. По ходу дела:     team status          кто жив и давно ли молчит
                       team spawn <роль>    поднять роль (менеджер делает это сам)
                       team task <роль> "<название>"  подпись «над чем работает» для владельца (--clear снимает)
                       team addr <роль>     адрес роли для SendMessage;  team peek <роль> — что она показывает
                       team roles, team role set|new — роли и их правка;  --json у status, roles, check, events, handoffs
  4. Смена сессии:     team handoff <роль>  запрос передачи состояния (текст для SendMessage)
                       team restart <роль>  пересоздать (продолжить прежнюю сессию, --fresh — новую)
  5. Конец работы:     team down [роль]     остановить роль или всю команду
                       team reap            остановить простаивающих агентов start: on_demand (idle_stop_minutes)

Подробнее: docs/agent-guide.md репозитория agent-team.
"""


def cmd_init(args) -> int:
    root = Path.cwd()
    target = root / "agents"
    if (target / "team.yaml").exists():
        raise TeamError(f"{target}/team.yaml уже есть; init ничего не перезаписывает")
    src = Path(__file__).parent / "scaffold"
    project = root.name
    for f in sorted(src.rglob("*")):
        if f.is_dir():
            continue
        dst = target / f.relative_to(src)
        dst.parent.mkdir(parents=True, exist_ok=True)
        text = f.read_text(encoding="utf-8").replace("__PROJECT__", project).replace("__REPO__", str(root))
        dst.write_text(text, encoding="utf-8")
        print(f"создан {dst.relative_to(root)}")
    print("Дальше: отредактируйте agents/roles/*.md под проект, затем team check и team up.")
    return 0


def package_version() -> str:
    """Версия установленного пакета; из исходников без установки метаданных нет."""
    try:
        return importlib.metadata.version("agent-team")
    except importlib.metadata.PackageNotFoundError:
        return "unknown"


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="team", description="Команда агентов Claude Code в tmux")
    p.add_argument("--version", action="version", version=f"team {package_version()}")
    sub = p.add_subparsers(dest="cmd")

    s = sub.add_parser("up", help="поднять менеджера и роли со start: always")
    s.add_argument("--resume", action="store_true", help="продолжить прежние сессии Claude")
    s.set_defaults(fn=cmd_up)

    s = sub.add_parser("spawn", help="поднять роль")
    s.add_argument("role")
    s.add_argument("--resume", action="store_true")
    s.set_defaults(fn=cmd_spawn)

    s = sub.add_parser("addr", help="адрес роли для SendMessage")
    s.add_argument("role")
    s.set_defaults(fn=cmd_addr)

    s = sub.add_parser("send", help="запасной путь: вставить текст в строку ввода роли (--paste)")
    s.add_argument("role")
    s.add_argument("--paste", action="store_true", help="вставить в строку ввода; роль увидит это как ввод пользователя")
    s.add_argument("text", nargs="+")
    s.set_defaults(fn=cmd_send)

    s = sub.add_parser("peek", help="последние строки окна роли")
    s.add_argument("role")
    s.add_argument("lines", nargs="?", type=int, default=40)
    s.set_defaults(fn=cmd_peek)

    s = sub.add_parser("status", help="состояние агентов")
    s.add_argument("--json", action="store_true", help="машиночитаемый вывод")
    s.set_defaults(fn=cmd_status)

    s = sub.add_parser("attach", help="подключиться к tmux")
    s.add_argument("role", nargs="?")
    s.set_defaults(fn=cmd_attach)

    s = sub.add_parser("restart", help="пересоздать сессию роли")
    s.add_argument("role")
    s.add_argument("--fresh", action="store_true", help="новая сессия Claude, не продолжение")
    s.set_defaults(fn=cmd_restart)

    s = sub.add_parser("check", help="проверить описание команды")
    s.add_argument("--json", action="store_true", help="машиночитаемый вывод")
    s.set_defaults(fn=cmd_check)

    s = sub.add_parser("role", help="править роль (set) или завести новую (new); печатает JSON роли")
    rsub = s.add_subparsers(dest="action", required=True)
    for action in ("set", "new"):
        r = rsub.add_parser(action)
        r.add_argument("role")
        r.add_argument("--title")
        r.add_argument("--extends", metavar="ОБЩАЯ_РОЛЬ",
                       help="наследовать общую роль библиотеки" + ("; пустое значение снимает наследование" if action == "set" else ""))
        r.add_argument("--model", choices=["opus", "sonnet", "haiku"])
        r.add_argument("--description")
        r.add_argument("--json", action="store_true", help="принимается для единообразия: роль всегда печатается JSON")
        r.add_argument("--start", choices=["manual", "always", "on_demand"])
        r.set_defaults(fn=cmd_role)

    s = sub.add_parser("set", help="изменить ключ верхнего уровня team.yaml (idle_stop_minutes: число минут, по умолчанию 15, или off)")
    s.add_argument("key")
    s.add_argument("value")
    s.add_argument("--json", action="store_true", help="машиночитаемый вывод")
    s.set_defaults(fn=cmd_set)

    s = sub.add_parser("roles", help="роли команды")
    s.add_argument("--library", action="store_true", help="добавить общие роли библиотеки (source: library)")
    s.add_argument("--json", action="store_true", help="машиночитаемый вывод")
    s.set_defaults(fn=cmd_roles)

    s = sub.add_parser("handoff", help="создать файл передачи и запрос агенту (адрес и текст для SendMessage)")
    s.add_argument("role")
    s.add_argument("--paste", action="store_true")
    s.add_argument("--task", help="задача трекера, к которой относится передача")
    s.add_argument("--reason", help="почему меняется сессия")
    s.add_argument("--force", action="store_true", help="запросить передачу, даже если worktree роли грязный")
    s.set_defaults(fn=cmd_handoff)

    s = sub.add_parser("handoffs", help="список передач")
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_handoffs)

    s = sub.add_parser("events", help="лента событий, новые первыми")
    s.add_argument("--json", action="store_true")
    s.add_argument("--since", type=int, help="unix-секунды: события с ts не раньше этого")
    s.add_argument("--limit", type=int)
    s.set_defaults(fn=cmd_events)

    s = sub.add_parser("log", help="записать событие в ленту (task, report и др.)")
    s.add_argument("type")
    s.add_argument("agent")
    s.add_argument("text", nargs="+")
    s.add_argument("--task")
    s.set_defaults(fn=cmd_log)

    s = sub.add_parser("task", help="название текущей задачи агента для владельца: поставить, снять (--clear) или показать")
    s.add_argument("agent")
    s.add_argument("title", nargs="?", help="8–48 знаков, словами для владельца; без номера, путей и кода")
    s.add_argument("--id", help="номер задачи в трекере (необязателен)")
    s.add_argument("--clear", action="store_true", help="снять задачу")
    s.set_defaults(fn=cmd_task)

    s = sub.add_parser("init", help="создать agents/ в текущем каталоге")
    s.set_defaults(fn=None, standalone=True)

    s = sub.add_parser("reap", help="остановить простаивающих агентов start: on_demand (idle_stop_minutes в team.yaml, по умолчанию 15 минут)")
    s.add_argument("--keep", nargs="+", action="extend", default=[], metavar="АГЕНТ", help="не останавливать этих агентов (роль или роль#n)")
    s.add_argument("--dry-run", action="store_true", help="только показать, кого остановили бы")
    s.add_argument("--json", action="store_true", help="машиночитаемый вывод")
    s.set_defaults(fn=cmd_reap)

    s = sub.add_parser("down", help="остановить роль или всю команду")
    s.add_argument("role", nargs="?")
    s.set_defaults(fn=cmd_down)
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.cmd is None:
        print(OVERVIEW)
        return 0
    try:
        if getattr(args, "standalone", False):
            return cmd_init(args)
        return args.fn(load_team(), args)
    except TeamError as e:
        print(f"team: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
