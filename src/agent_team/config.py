"""Чтение описания команды проекта: agents/team.yaml и agents/roles/*.md."""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

import yaml


class TeamError(Exception):
    """Ошибка описания команды или запуска; сообщение предназначено человеку."""


def numbered(base: str, n: int, sep: str) -> str:
    return base if n == 1 else f"{base}{sep}{n}"


def split_agent(name: str) -> tuple[str, int]:
    """«роль#n» → (роль, n); имя без номера — №1."""
    role, sep, num = name.partition("#")
    if not sep:
        return name, 1
    if not role or not num.isdigit() or int(num) < 1:
        raise TeamError(f"имя агента «{name}»: ожидается роль или роль#номер (номер от 1)")
    return role, int(num)


def agent_key(role: str, n: int = 1) -> str:
    return f"{role}#{n}"


def canonical(name: str) -> str:
    return agent_key(*split_agent(name))


@dataclass
class Role:
    name: str
    meta: dict                 # поля после наследования; у роли без extends — как в файле
    body: str                  # тело файла самой роли
    path: Path
    extends: str | None = None
    base_body: str | None = None   # тело общей роли из библиотеки, если роль наследует
    unmatched_excludes: list[str] = field(default_factory=list)   # «поле: элемент» из exclude, которых нет в общей роли
    base_meta: dict | None = None  # поля общей роли (для сборки полей запуска claude: defaults → общая → проект)

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
    def exclude(self) -> dict[str, list[str]]:
        """exclude из файла роли: элементы общей роли, которые проект убирает; всегда словарь из трёх списков."""
        raw = self.meta.get("exclude")
        raw = raw if isinstance(raw, dict) else {}
        return {k: [str(x) for x in raw.get(k) or []] for k in MERGE_FIELDS}

    @property
    def worktree(self) -> dict | None:
        wt = self.meta.get("worktree")
        return wt if isinstance(wt, dict) and wt.get("dir") else None


DEFAULT_IDLE_STOP_MINUTES = 15   # порог автоостановки, когда в team.yaml нет idle_stop_minutes


@dataclass
class Team:
    root: Path                 # где найден agents/team.yaml
    project: str
    home: Path                 # опорная точка: repo из team.yaml, иначе корень; здесь .team/ и менеджер, от неё считаются пути
    worktree_root: Path
    manager: str
    test_command: str
    layout: str = "windows"   # windows: окно на роль; panes: все роли панелями одного окна
    manager_width: str = "50%"   # ширина панели менеджера в раскладке panes: процент окна или число колонок
    tracker: str | dict | None = None   # трекер для людей и приложения (строка или словарь как в team.yaml); инструмент в трекер не ходит
    roles: list[dict] = field(default_factory=list)   # [{role, start}]
    defaults: dict = field(default_factory=dict)      # поля запуска claude (LAUNCH_FIELDS), общие для всех ролей
    mcp_servers: dict = field(default_factory=dict)   # определения MCP-серверов проекта: имя → описание сервера
    idle_stop_minutes: int | None = DEFAULT_IDLE_STOP_MINUTES   # через сколько минут простоя `team reap` гасит агентов start: on_demand; None — выключено (`off`)

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

    def worktree_path(self, role: Role, n: int = 1) -> Path | None:
        """Каталог worktree агента: №1 — dir роли, №n>1 — dir-n."""
        wt = role.worktree
        return (self.worktree_root / numbered(str(wt["dir"]), n, "-")) if wt else None

    def worktree_branch(self, role: Role, n: int = 1) -> str | None:
        wt = role.worktree
        return numbered(str(wt["branch"]), n, "-") if wt and wt.get("branch") else None

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


def _tracker(value) -> str | dict | None:
    """Словарь остаётся словарём (ключи — строками), остальное приводится к строке; пустое — None."""
    if not value:
        return None
    if isinstance(value, dict):
        return {str(k): v for k, v in value.items()}
    return str(value)


def _manager_width(value) -> str:
    """manager_width из team.yaml: «60%» (доля окна, 1–99%) или число колонок; без значения — 50%."""
    if value is None or value == "":
        return "50%"
    text = str(value).strip()
    m = re.fullmatch(r"(\d+)(%?)", text)
    if not m or int(m.group(1)) < 1 or (m.group(2) and int(m.group(1)) > 99):
        raise TeamError(f"manager_width в team.yaml: процент окна (например 60%) или число колонок, а не «{value}»")
    return text


LAUNCH_FIELDS = ("mcp", "plugins", "settings", "chrome", "env", "context")   # поля запуска claude: defaults, роль, роль библиотеки
ENV_NAME_RE = re.compile(r"^[A-Z_][A-Z0-9_]*$")
PLUGIN_KEYS = ("off", "only")
# Пороги контекста роли в токенах (общие значения инструмента, проектные задаются полем context):
# soft — сброс на границе задачи, warn — предупреждение, hard — окно автосжатия Claude Code (допустимо 100000–1000000).
DEFAULT_CONTEXT = {"soft": 250000, "warn": 400000, "hard": 500000}
HARD_RANGE = (100000, 1000000)


def _names(value, where: str, what: str) -> list[str]:
    if not isinstance(value, list) or any(not isinstance(x, str) or not x for x in value):
        raise TeamError(f"{where}: {what} — список имён")
    return list(value)


def _launch_layer(meta: dict, where: str) -> dict:
    """Поля запуска одного слоя (defaults, общая роль или роль проекта): только заданные, проверенные и приведённые."""
    out: dict = {}
    if meta.get("mcp") is not None:
        out["mcp"] = _names(meta["mcp"], where, "mcp")
    if meta.get("chrome") is not None:
        if not isinstance(meta["chrome"], bool):
            raise TeamError(f"{where}: chrome — true или false")
        out["chrome"] = meta["chrome"]
    if meta.get("plugins") is not None:
        raw = meta["plugins"]
        if isinstance(raw, dict):           # YAML 1.1 читает ключ off как false
            raw = {("off" if k is False else k): v for k, v in raw.items()}
        if not isinstance(raw, dict) or any(k not in PLUGIN_KEYS for k in raw):
            raise TeamError(f"{where}: plugins — словарь вида {{off: [...]}} или {{only: [...]}}")
        out["plugins"] = {k: _names(v if v is not None else [], where, f"plugins.{k}") for k, v in raw.items()}
    if meta.get("settings") is not None:
        if not isinstance(meta["settings"], dict):
            raise TeamError(f"{where}: settings — словарь настроек Claude Code")
        out["settings"] = {str(k): v for k, v in meta["settings"].items()}
    if meta.get("env") is not None:
        raw = meta["env"]
        if not isinstance(raw, dict):
            raise TeamError(f"{where}: env — словарь ИМЯ: значение")
        env = {}
        for k, v in raw.items():
            if not isinstance(k, str) or not ENV_NAME_RE.match(k):
                raise TeamError(f"{where}: env.{k} — имя переменной вида [A-Z_][A-Z0-9_]*")
            if isinstance(v, (dict, list)) or v is None:
                raise TeamError(f"{where}: env.{k} — значение должно быть строкой или числом")
            env[k] = str(v).lower() if isinstance(v, bool) else str(v)
        out["env"] = env
    if meta.get("context") is not None:
        raw = meta["context"]
        if not isinstance(raw, dict) or any(k not in DEFAULT_CONTEXT for k in raw):
            raise TeamError(f"{where}: context — словарь вида {{soft: 250000, warn: 400000, hard: 500000}}")
        ctx = {}
        for k, v in raw.items():
            if isinstance(v, bool) or not isinstance(v, int) or v < 1:
                raise TeamError(f"{where}: context.{k} — целое число токенов больше нуля, а не «{v}»")
            ctx[k] = v
        out["context"] = ctx
    return out


def launch_fields(team: Team, role: Role) -> dict:
    """Собранные поля запуска claude: defaults → общая роль → роль проекта.

    mcp и chrome заменяются целиком (роль должна уметь сузить список), plugins, settings и env перекрываются
    по ключам. mcp = None — поле нигде не задано, MCP остаются как есть; [] — без MCP.
    """
    layers = [(team.defaults, "defaults в team.yaml")]
    if role.base_meta is not None:
        layers.append((role.base_meta, f"общая роль «{role.extends}»"))
    layers.append((role.meta, f"роль {role.name}"))
    out: dict = {"mcp": None, "plugins": {}, "settings": {}, "chrome": None, "env": {}, "context": {}}
    for meta, where in layers:
        layer = _launch_layer(meta, where)
        for key in ("mcp", "chrome"):
            if key in layer:
                out[key] = layer[key]
        for key in ("plugins", "settings", "env", "context"):
            out[key].update(layer.get(key, {}))
    return out


def context_limits(team: Team, role: Role) -> dict:
    """Пороги контекста роли {soft, warn, hard}: значения инструмента, поверх них defaults, общая роль, роль проекта."""
    limits = {**DEFAULT_CONTEXT, **launch_fields(team, role)["context"]}
    if not HARD_RANGE[0] <= limits["hard"] <= HARD_RANGE[1]:
        raise TeamError(f"{role.name}: context.hard — от {HARD_RANGE[0]} до {HARD_RANGE[1]} токенов (окно автосжатия Claude Code)")
    if not limits["soft"] < limits["warn"] <= limits["hard"]:
        raise TeamError(f"{role.name}: context — пороги должны идти по возрастанию soft < warn <= hard, "
                        f"а не {limits['soft']} / {limits['warn']} / {limits['hard']}")
    return limits


def _defaults(value) -> dict:
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise TeamError("defaults в team.yaml — словарь полей роли (mcp, plugins, settings, chrome, env, context)")
    unknown = [k for k in value if k not in LAUNCH_FIELDS]
    if unknown:
        raise TeamError(f"defaults в team.yaml: поле «{unknown[0]}» не поддерживается (есть: {', '.join(LAUNCH_FIELDS)})")
    _launch_layer(value, "defaults в team.yaml")
    return value


def _mcp_servers(value) -> dict:
    if value is None:
        return {}
    if not isinstance(value, dict) or any(not isinstance(v, dict) for v in value.values()):
        raise TeamError("mcp_servers в team.yaml — словарь имя: описание сервера")
    return {str(k): v for k, v in value.items()}


def _idle_stop_minutes(value) -> int | None:
    """idle_stop_minutes из team.yaml: целое > 0; без ключа (или пусто) — порог по умолчанию; off (YAML читает как False) — выключено."""
    if value is None or value == "":
        return DEFAULT_IDLE_STOP_MINUTES
    if value is False:
        return None
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise TeamError(f"idle_stop_minutes в team.yaml: целое число минут больше нуля, а не «{value}»")
    return value


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
                layout=str(raw.get("layout") or "windows"), roles=roles,
                manager_width=_manager_width(raw.get("manager_width")),
                tracker=_tracker(raw.get("tracker")),
                defaults=_defaults(raw.get("defaults")), mcp_servers=_mcp_servers(raw.get("mcp_servers")),
                idle_stop_minutes=_idle_stop_minutes(raw.get("idle_stop_minutes")))
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


ROLE_NAME_RE = re.compile(r"^[a-z][a-z0-9_-]*$")
OVERRIDE_FIELDS = ("model", "title", "kind", "description", "status")   # проект перекрывает общую роль
MERGE_FIELDS = ("allow", "includes", "add_dirs")                        # объединяются без повторов
PROJECT_ONLY_FIELDS = ("zone", "worktree", "tracker_zone")              # общая роль их не задаёт


def library_dir() -> Path:
    """Каталог общих ролей: рядом с пакетом, а не от пути к репозиторию.

    В установленном пакете это agent_team/library (roles/ репозитория кладётся туда при сборке);
    при запуске из исходников и в editable-режиме — roles/ в корне репозитория.
    """
    pkg = Path(__file__).resolve().parent
    for cand in (pkg / "library", pkg.parent.parent / "roles"):
        if (cand / "shared").is_dir():
            return cand
    raise TeamError("библиотека общих ролей не найдена рядом с пакетом agent_team")


def library_role_names() -> list[str]:
    return sorted(p.stem for p in library_dir().glob("*.md") if p.stem.lower() != "readme")


def _merge_lists(*lists) -> list:
    out: list = []
    for lst in lists:
        for item in lst or []:
            if item not in out:
                out.append(item)
    return out


def check_exclude(meta: dict, owner: str) -> None:
    """exclude — словарь {includes|allow|add_dirs: [элементы]}; иная форма — ошибка."""
    raw = meta.get("exclude")
    if raw is None:
        return
    if not isinstance(raw, dict):
        raise TeamError(f"{owner}: exclude — словарь вида {{includes: [...], allow: [...], add_dirs: [...]}}")
    for key, value in raw.items():
        if key not in MERGE_FIELDS:
            raise TeamError(f"{owner}: exclude.{key} — убрать можно только {', '.join(MERGE_FIELDS)}")
        if value is not None and (not isinstance(value, list) or any(isinstance(x, (dict, list)) for x in value)):
            raise TeamError(f"{owner}: exclude.{key} — список элементов общей роли")


def merge_roles(base: Role, own: Role, extends: str) -> Role:
    """Роль проекта поверх общей роли: правила слияния полей — в docs/SPEC.md."""
    check_exclude(own.meta, own.name)
    exclude = own.exclude
    unmatched = [f"{key}: {item}" for key in MERGE_FIELDS for item in exclude[key]
                 if item not in [str(x) for x in base.meta.get(key) or []]]
    meta = {k: v for k, v in own.meta.items() if k not in PROJECT_ONLY_FIELDS}
    for key in OVERRIDE_FIELDS:
        if own.meta.get(key) in (None, "") and base.meta.get(key) not in (None, ""):
            meta[key] = base.meta[key]
    for key in MERGE_FIELDS:
        kept = [x for x in base.meta.get(key) or [] if str(x) not in exclude[key]]     # exclude касается только общей роли
        merged = _merge_lists(kept, own.meta.get(key))
        if merged:
            meta[key] = merged
    for key in PROJECT_ONLY_FIELDS:
        if key in own.meta:
            meta[key] = own.meta[key]
    return Role(name=own.name, meta=meta, body=own.body, path=own.path, extends=extends, base_body=base.body,
                unmatched_excludes=unmatched, base_meta=base.meta)


def load_library_role(name: str, owner: str | None = None) -> Role:
    who = f"{owner}: " if owner else ""
    if not isinstance(name, str) or not ROLE_NAME_RE.match(name):
        raise TeamError(f"{who}extends: «{name}» — ожидается имя общей роли из библиотеки")
    path = library_dir() / f"{name}.md"
    if not path.is_file():
        raise TeamError(f"{who}extends: общей роли «{name}» нет в библиотеке (есть: {', '.join(library_role_names())})")
    return parse_role(path)


def load_base_role(name, owner: str) -> Role:
    """Общая роль для extends: есть в библиотеке и сама не наследует."""
    base = load_library_role(name, owner)
    if base.meta.get("extends") is not None:
        raise TeamError(f"{owner}: общая роль «{name}» сама наследует; наследование идёт на один уровень")
    return base


def load_role(team: Team, name: str) -> Role:
    path = team.agents_dir / "roles" / f"{name}.md"
    if not path.is_file():
        raise TeamError(f"файла роли нет: {path}")
    role = parse_role(path)
    extends = role.meta.get("extends")
    if extends is not None:
        role = merge_roles(load_base_role(extends, name), role, str(extends))
    launch_fields(team, role)           # поля запуска проверяются при загрузке: ошибка в роли видна в check, а не при запуске
    return role
