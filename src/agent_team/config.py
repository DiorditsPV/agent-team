"""Чтение описания команды проекта: agents/team.yaml и agents/roles/*.md."""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

import yaml


class TeamError(Exception):
    """Ошибка описания команды или запуска; сообщение предназначено человеку."""


@dataclass
class Role:
    name: str
    meta: dict
    body: str
    path: Path

    @property
    def title(self) -> str:
        return str(self.meta.get("title") or self.name)

    @property
    def kind(self) -> str:
        return str(self.meta.get("kind") or "executor")

    @property
    def includes(self) -> list[str]:
        return list(self.meta.get("includes") or [])

    @property
    def allow(self) -> list[str]:
        return list(self.meta.get("allow") or [])

    @property
    def add_dirs(self) -> list[str]:
        return list(self.meta.get("add_dirs") or [])

    @property
    def worktree(self) -> dict | None:
        wt = self.meta.get("worktree")
        return wt if isinstance(wt, dict) and wt.get("dir") else None


@dataclass
class Team:
    root: Path                 # где найден agents/team.yaml
    project: str
    home: Path                 # опорная точка: repo из team.yaml, иначе корень; здесь .team/ и менеджер, от неё считаются пути
    worktree_root: Path
    manager: str
    test_command: str
    layout: str = "windows"   # windows: окно на роль; panes: все роли панелями одного окна
    roles: list[dict] = field(default_factory=list)   # [{role, start}]

    @property
    def agents_dir(self) -> Path:
        return self.root / "agents"

    @property
    def state_dir(self) -> Path:
        return self.home / ".team"

    @property
    def session(self) -> str:
        return f"team-{self.project}"

    def role_names(self) -> list[str]:
        return [r["role"] for r in self.roles]

    def start_mode(self, role: str) -> str:
        for r in self.roles:
            if r["role"] == role:
                return str(r.get("start") or "on_demand")
        raise TeamError(f"роли «{role}» нет в team.yaml (есть: {', '.join(self.role_names())})")

    def worktree_path(self, role: Role) -> Path | None:
        wt = role.worktree
        return (self.worktree_root / wt["dir"]) if wt else None

    def worktree_repo(self, role: Role) -> Path | None:
        """Репозиторий, от которого создаётся worktree роли: worktree.repo от home, по умолчанию сам home."""
        wt = role.worktree
        if not wt:
            return None
        repo = wt.get("repo")
        return (self.home / Path(str(repo)).expanduser()).resolve() if repo else self.home


def find_root(start: Path | None = None) -> Path:
    here = (start or Path.cwd()).resolve()
    for p in [here, *here.parents]:
        if (p / "agents" / "team.yaml").is_file():
            return p
    raise TeamError("agents/team.yaml не найден ни в текущем каталоге, ни выше; запускайте team в каталоге проекта")


def load_team(start: Path | None = None) -> Team:
    root = find_root(start)
    raw = yaml.safe_load((root / "agents" / "team.yaml").read_text(encoding="utf-8")) or {}
    for key in ("project", "manager", "roles"):
        if not raw.get(key):
            raise TeamError(f"в team.yaml нет поля «{key}»")
    home = Path(raw.get("repo") or root).expanduser()
    if not home.is_dir():
        home = root
    wt_root = Path(raw.get("worktree_root") or "../wt")
    if not wt_root.is_absolute():
        wt_root = (home / wt_root)
    roles = []
    for r in raw["roles"]:
        if isinstance(r, str):
            r = {"role": r}
        if "role" not in r:
            raise TeamError(f"в team.yaml у записи роли нет поля «role»: {r}")
        roles.append(r)
    team = Team(root=root, project=str(raw["project"]), home=home.resolve(),
                worktree_root=wt_root.resolve(), manager=str(raw["manager"]),
                test_command=str(raw.get("test_command") or ""),
                layout=str(raw.get("layout") or "windows"), roles=roles)
    if team.layout not in ("windows", "panes"):
        raise TeamError(f"layout в team.yaml: windows или panes, а не «{team.layout}»")
    if team.manager not in team.role_names():
        raise TeamError(f"менеджер «{team.manager}» не описан в roles")
    return team


def parse_role(path: Path) -> Role:
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        raise TeamError(f"{path.name}: файл роли должен начинаться с frontmatter (---)")
    try:
        end = next(i for i in range(1, len(lines)) if lines[i].strip() == "---")
    except StopIteration:
        raise TeamError(f"{path.name}: frontmatter не закрыт") from None
    try:
        meta = yaml.safe_load("\n".join(lines[1:end])) or {}
    except yaml.YAMLError as e:
        raise TeamError(f"{path.name}: frontmatter не разобран ({e}); значения с «: » берите в кавычки") from None
    if not isinstance(meta, dict):
        raise TeamError(f"{path.name}: frontmatter должен быть словарём")
    body = "\n".join(lines[end + 1:]).strip("\n") + "\n"
    return Role(name=path.stem, meta=meta, body=body, path=path)


def load_role(team: Team, name: str) -> Role:
    path = team.agents_dir / "roles" / f"{name}.md"
    if not path.is_file():
        raise TeamError(f"файла роли нет: {path}")
    return parse_role(path)
