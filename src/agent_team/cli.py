"""Команда team: up, spawn, send, peek, status, attach, restart, down."""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

from . import build, sessions, tmuxctl
from .config import Role, Team, TeamError, load_role, load_team


# ---------- состояние (кеш; истина — tmux) ----------

def _state_path(team: Team) -> Path:
    return team.state_dir / "state.json"


def load_state(team: Team) -> dict:
    p = _state_path(team)
    return json.loads(p.read_text(encoding="utf-8")) if p.is_file() else {}


def save_state(team: Team, state: dict) -> None:
    team.state_dir.mkdir(parents=True, exist_ok=True)
    _state_path(team).write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")


# ---------- worktree ----------

def ensure_worktree(team: Team, role: Role) -> Path:
    path = team.worktree_path(role)
    if path is None:
        return team.home
    if path.is_dir():
        return path
    branch = role.worktree["branch"]
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

def spawn(team: Team, name: str, resume: bool = False) -> str:
    team.start_mode(name)                       # проверка, что роль описана в team.yaml
    role = load_role(team, name)
    live = tmuxctl.panes(team.session)
    if name in live:
        if not live[name].dead:
            return f"{name}: уже запущена"
        tmuxctl.close_role(live[name].id)
    cwd = ensure_worktree(team, role)
    instruction = build.write_instruction(team, role)
    state = load_state(team)
    sid = (state.get(name) or {}).get("session_id") if resume else None
    resumed = bool(sid)
    sid = sid or build.new_session_id()
    argv = build.claude_argv(team, role, instruction, sid, resume=resumed)
    env = {"TEAM_ROLE": name, "TEAM_PROJECT": team.project, "TEAM_REPO": str(team.home)}
    pane = tmuxctl.open_role(team.session, name, str(cwd), build.shell_command(argv, env), team.layout)
    state[name] = {"session_id": sid, "started": int(time.time()), "cwd": str(cwd)}
    save_state(team, state)
    return f"{name}: запущена, панель {pane} в tmux-сессии {team.session} ({cwd})"


def cmd_up(team: Team, args) -> int:
    order = [team.manager] + [r for r in team.role_names() if r != team.manager]
    for name in order:
        if name != team.manager and team.start_mode(name) != "always":
            continue
        print(spawn(team, name, resume=args.resume))
    print(f"Подключиться: team attach   (tmux-сессия {team.session})")
    return 0


def cmd_spawn(team: Team, args) -> int:
    print(spawn(team, args.role, resume=args.resume))
    return 0


def _require_window(team: Team, name: str) -> tmuxctl.Pane:
    live = tmuxctl.panes(team.session)
    if name not in live:
        raise TeamError(f"роль «{name}» не запущена (team spawn {name})")
    return live[name]


def role_address(team: Team, name: str) -> str | None:
    pane = tmuxctl.panes(team.session).get(name)
    sid = (load_state(team).get(name) or {}).get("session_id")
    return sessions.address(pane.pid if pane else None, sid)


def cmd_addr(team: Team, args) -> int:
    _require_window(team, args.role)
    addr = role_address(team, args.role)
    if not addr:
        raise TeamError(f"у роли «{args.role}» не найден сокет обмена сообщениями (сессия ещё стартует или не регистрируется); "
                        f"запасной путь: team send {args.role} --paste")
    print(addr)
    return 0


def cmd_send(team: Team, args) -> int:
    win = _require_window(team, args.role)
    if win.dead:
        raise TeamError(f"окно роли «{args.role}» завершилось (team restart {args.role})")
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


def _ago(seconds: int) -> str:
    if seconds < 90:
        return f"{seconds} с"
    if seconds < 5400:
        return f"{seconds // 60} мин"
    return f"{seconds // 3600} ч"


def cmd_status(team: Team, args) -> int:
    live = tmuxctl.panes(team.session)
    state = load_state(team)
    now = int(time.time())
    print(f"проект {team.project}, tmux-сессия {team.session}: {'есть' if live else 'нет'}")
    print(f"{'роль':<14}{'состояние':<14}{'тихо':<10}{'адрес для SendMessage'}")
    for name in team.role_names():
        w = live.get(name)
        if w is None:
            st, quiet = "не запущена", "-"
        elif w.dead:
            st, quiet = "завершена", "-"
        else:
            st, quiet = "работает", _ago(max(0, now - w.activity))
        sid = (state.get(name) or {}).get("session_id")
        addr = sessions.address(w.pid, sid) if w and not w.dead else None
        print(f"{name:<14}{st:<14}{quiet:<10}{addr or '-'}")
    return 0


def cmd_attach(team: Team, args) -> int:
    if not tmuxctl.has_session(team.session):
        raise TeamError(f"tmux-сессии {team.session} нет (team up)")
    pane = tmuxctl.panes(team.session).get(args.role or team.manager)
    tmuxctl.attach(team.session, pane.id if pane else None)
    return 0


def cmd_restart(team: Team, args) -> int:
    pane = tmuxctl.panes(team.session).get(args.role)
    if pane:
        tmuxctl.close_role(pane.id)
    print(spawn(team, args.role, resume=not args.fresh))
    return 0


def cmd_down(team: Team, args) -> int:
    if args.role:
        pane = tmuxctl.panes(team.session).get(args.role)
        if pane:
            tmuxctl.close_role(pane.id)
        print(f"{args.role}: остановлена")
    else:
        tmuxctl.close_session(team.session)
        print(f"{team.session}: остановлена вся команда")
    return 0


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


def cmd_check(team: Team, args) -> int:
    """Проверка описания команды без запуска агентов."""
    errors, warns = [], []
    if shutil.which("tmux") is None:
        errors.append("tmux не найден в PATH")
    if shutil.which("claude") is None:
        warns.append("claude не найден в PATH (для запуска нужен)")
    roles = {}
    for name in team.role_names():
        try:
            roles[name] = load_role(team, name)
            build.assemble_instruction(team, roles[name])
        except TeamError as e:
            errors.append(str(e))
    if team.manager in roles and roles[team.manager].kind != "manager":
        errors.append(f"роль {team.manager} назначена менеджером, но её kind = {roles[team.manager].kind}")
    wts = {}
    for name, r in roles.items():
        if r.worktree:
            key = r.worktree["dir"]
            if key in wts:
                errors.append(f"worktree «{key}» у ролей {wts[key]} и {name}")
            wts[key] = name
            repo = team.worktree_repo(r)
            if not _is_git(repo):
                # черновик ещё не запускают: worktree ему не нужен, поэтому только предупреждение
                sink = warns if r.meta.get("status") == "draft" else errors
                if r.worktree.get("repo"):
                    sink.append(f"{name}: worktree.repo {repo} — не git-репозиторий")
                else:
                    sink.append(f"{name}: у роли worktree без repo, а {team.home} — не git-репозиторий; задайте worktree.repo")
        if r.meta.get("status") == "draft":
            warns.append(f"{name}: роль-черновик (status: draft)")
    warns += _zone_overlaps(team)
    for w in warns:
        print(f"предупреждение: {w}")
    for e in errors:
        print(f"ошибка: {e}")
    print(f"роли: {', '.join(roles) or '-'}; ошибок {len(errors)}, предупреждений {len(warns)}")
    return 1 if errors else 0


HANDOFF_REQUEST = ("Подготовь передачу по шаблону agents/templates/handoff.md: заполни все поля и выведи текстом в этом окне, "
                   "а также комментарием в задаче трекера. Незакоммиченное зафиксируй или перечисли. После этого ничего не делай.")


def cmd_handoff(team: Team, args) -> int:
    """Просит роль выгрузить состояние перед остановкой или пересозданием."""
    win = _require_window(team, args.role)
    if args.paste:
        tmuxctl.send_text(win.id, HANDOFF_REQUEST)
        print(f"→ {args.role}: запрос передачи вставлен в строку ввода")
        return 0
    addr = role_address(team, args.role)
    if not addr:
        raise TeamError(f"адрес роли «{args.role}» не найден; запасной путь: team handoff {args.role} --paste")
    print(f"Отправьте SendMessage на {addr} текст:\n{HANDOFF_REQUEST}")
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
                       team addr <роль>     адрес роли для SendMessage;  team peek <роль> — что она показывает
  4. Смена сессии:     team handoff <роль>  запрос передачи состояния (текст для SendMessage)
                       team restart <роль>  пересоздать (продолжить прежнюю сессию, --fresh — новую)
  5. Конец работы:     team down [роль]     остановить роль или всю команду

Подробнее: README.md и docs/SPEC.md репозитория agent-team.
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


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="team", description="Команда агентов Claude Code в tmux")
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

    s = sub.add_parser("status", help="состояние ролей")
    s.set_defaults(fn=cmd_status)

    s = sub.add_parser("attach", help="подключиться к tmux")
    s.add_argument("role", nargs="?")
    s.set_defaults(fn=cmd_attach)

    s = sub.add_parser("restart", help="пересоздать сессию роли")
    s.add_argument("role")
    s.add_argument("--fresh", action="store_true", help="новая сессия Claude, не продолжение")
    s.set_defaults(fn=cmd_restart)

    s = sub.add_parser("check", help="проверить описание команды")
    s.set_defaults(fn=cmd_check)

    s = sub.add_parser("handoff", help="запрос передачи состояния роли (адрес и текст для SendMessage)")
    s.add_argument("role")
    s.add_argument("--paste", action="store_true")
    s.set_defaults(fn=cmd_handoff)

    s = sub.add_parser("init", help="создать agents/ в текущем каталоге")
    s.set_defaults(fn=None, standalone=True)

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
