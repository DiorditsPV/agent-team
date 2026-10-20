"""Лёгкий старт роли: MCP, плагины и настройки Claude Code, которые проект задаёт ролью или блоком defaults.

Что задано — собирает config.launch_fields; здесь оно превращается в файл MCP, ключи --settings и переменные
панели. Имён серверов и плагинов в коде нет: всё берётся из описания проекта и настроек владельца.
Настройки владельца (~/.claude.json, ~/.claude/settings.json) только читаются; значения из них (токены в env и
headers серверов) не печатаются — наружу выходят только имена.
"""
from __future__ import annotations

import json
import os
from pathlib import Path

from .config import Role, Team, TeamError, context_limits, launch_fields

# Ключи, которые ставит сам team или которые задают режим разрешений: поле settings проекта их не перекрывает.
# enabledPlugins собирается из поля plugins.
TEAM_SETTINGS_KEYS = ("hooks", "disableAgentView", "statusLine")
PERMISSION_SETTINGS_KEYS = ("permissions", "defaultMode", "permissionMode", "allowedTools", "disallowedTools",
                            "additionalDirectories", "skipDangerousModePermissionPrompt",
                            "disableBypassPermissionsMode")
RESERVED_SETTINGS = (*TEAM_SETTINGS_KEYS, *PERMISSION_SETTINGS_KEYS, "enabledPlugins")
TRACKER_RULES = ("tracker-cycle.md", "reporting.md")     # общие правила, где роль работает с трекером


def claude_config_dir() -> Path:
    return Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")


def read_json(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _claude_json() -> dict:
    """~/.claude.json (при CLAUDE_CONFIG_DIR — файл .claude.json в этом каталоге)."""
    env = os.environ.get("CLAUDE_CONFIG_DIR")
    return read_json((Path(env) / ".claude.json") if env else Path.home() / ".claude.json")


def _servers(value) -> dict:
    return {str(k): v for k, v in value.items() if isinstance(v, dict)} if isinstance(value, dict) else {}


def mcp_sources(team: Team) -> list[tuple[str, dict]]:
    """Где искать определения серверов, по убыванию приоритета: (источник, {имя: описание})."""
    cj = _claude_json()
    paths = {str(team.home), str(team.root)}
    projects = cj.get("projects") if isinstance(cj.get("projects"), dict) else {}
    out = [("mcp_servers в team.yaml", team.mcp_servers)]
    for p in sorted(paths):
        out.append((f"~/.claude.json, проект {p}", _servers((projects.get(p) or {}).get("mcpServers")
                                                          if isinstance(projects.get(p), dict) else None)))
    out.append(("~/.claude.json", _servers(cj.get("mcpServers"))))
    for p in sorted(paths):
        out.append((f"{p}/.mcp.json", _servers(read_json(Path(p) / ".mcp.json").get("mcpServers"))))
    return out


def resolve_mcp(team: Team, names: list[str]) -> dict[str, dict]:
    """Определения серверов по именам; неизвестное имя — ошибка с перечнем известных имён (без значений)."""
    sources = mcp_sources(team)
    found: dict[str, dict] = {}
    unknown = []
    for name in names:
        for _, servers in sources:
            if name in servers:
                found[name] = servers[name]
                break
        else:
            unknown.append(name)
    if unknown:
        known = sorted({n for _, servers in sources for n in servers})
        raise TeamError(f"MCP-сервер «{', '.join(unknown)}» не найден ни в team.yaml (mcp_servers), ни в ~/.claude.json, "
                        f"ни в .mcp.json проекта (известны: {', '.join(known) or 'нет'})")
    return found


def write_mcp_config(team: Team, key: str, servers: dict[str, dict]) -> Path:
    """.team/build/<агент>-mcp.json с правами 0600: в описаниях серверов бывают токены."""
    out = team.state_dir / "build" / f"{key}-mcp.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(json.dumps({"mcpServers": servers}, ensure_ascii=False, indent=2) + "\n")
    os.chmod(out, 0o600)                 # файл мог остаться от прежнего запуска с другими правами
    return out


def mcp_config_for(team: Team, role: Role, key: str) -> Path | None:
    """Файл --mcp-config роли; None, если поле mcp нигде не задано (MCP остаются как есть)."""
    names = launch_fields(team, role)["mcp"]
    return None if names is None else write_mcp_config(team, key, resolve_mcp(team, names))


def plugin_flags(plugins: dict) -> dict[str, bool]:
    """enabledPlugins для --settings: off → false; only → false всем плагинам владельца, кроме перечисленных."""
    flags: dict[str, bool] = {}
    if "only" in plugins:
        user = read_json(claude_config_dir() / "settings.json").get("enabledPlugins")
        for name in user if isinstance(user, dict) else ():
            flags[str(name)] = str(name) in plugins["only"]
    for name in plugins.get("off", []):
        flags[name] = False
    return flags


def reserved_in(settings: dict) -> list[str]:
    return [k for k in settings if k in RESERVED_SETTINGS]


def settings_overlay(team: Team, role: Role) -> dict:
    """Ключи --settings из полей роли (plugins, settings): без зарезервированных ключей."""
    launch = launch_fields(team, role)
    out = {k: v for k, v in launch["settings"].items() if k not in RESERVED_SETTINGS}
    flags = plugin_flags(launch["plugins"])
    if flags:
        out["enabledPlugins"] = flags
    return out


def brief_excludes(team: Team, role: Role, n: int = 1) -> list[str]:
    """Пути CLAUDE.md, CLAUDE.local.md и .claude/CLAUDE.md каталогов от корня репозитория роли до родителя её worktree.

    Claude Code поднимается от cwd вверх и подгружает бриф каждого каталога. Если worktree лежит внутри
    репозитория, он подтянул бы бриф основного каталога (в том числе личный CLAUDE.local.md менеджера) поверх
    собственного CLAUDE.md worktree. Выше корня репозитория бриф читается как прежде. Worktree вне репозитория
    и роль без worktree — пусто.
    """
    wt, repo = team.worktree_path(role, n), team.worktree_repo(role)
    if wt is None or repo is None:
        return []
    wt, repo = wt.resolve(), repo.resolve()
    if repo not in wt.parents:
        return []
    out = []
    for d in (*reversed([p for p in wt.parents if p == repo or repo in p.parents]),):
        out += [str(d / "CLAUDE.md"), str(d / "CLAUDE.local.md"), str(d / ".claude" / "CLAUDE.md")]
    return out


def merge_excludes(own: dict, extra: list[str]) -> dict:
    """claudeMdExcludes из поля settings роли дополняется путями team, а не заменяется ими."""
    if not extra:
        return own
    mine = own.get("claudeMdExcludes")
    merged = [*(mine if isinstance(mine, list) else []), *extra]
    return {**own, "claudeMdExcludes": list(dict.fromkeys(merged))}


def role_env(team: Team, role: Role, reserved: dict[str, str]) -> dict[str, str]:
    """Переменные панели из поля env; имена, которые ставит сам team, проект не перекрывает."""
    return {k: v for k, v in launch_fields(team, role)["env"].items() if k not in reserved and not k.startswith("TEAM_")}


def compact_env(team: Team, role: Role) -> dict[str, str]:
    """Окно автосжатия Claude Code из порога context.hard (переменная проверена по бинарю claude 2.1.292:
    CLAUDE_CODE_AUTO_COMPACT_WINDOW, токены от 100000 до 1000000)."""
    return {"CLAUDE_CODE_AUTO_COMPACT_WINDOW": str(context_limits(team, role)["hard"])}


def check_role(team: Team, role: Role, reserved_env: dict[str, str]) -> list[tuple[str, str]]:
    """Проверка полей запуска роли: [(error|warn, текст)]."""
    out: list[tuple[str, str]] = []
    launch = launch_fields(team, role)
    try:
        context_limits(team, role)
    except TeamError as e:
        out.append(("error", str(e)))
    if launch["mcp"] is not None:
        try:
            resolve_mcp(team, launch["mcp"])
        except TeamError as e:
            out.append(("error", f"{role.name}: {e}"))
        if not launch["mcp"] and role.kind in ("executor", "manager") and any(i in TRACKER_RULES for i in role.includes):
            out.append(("warn", f"{role.name}: mcp пуст, а в includes есть правило про трекер "
                                f"({', '.join(i for i in role.includes if i in TRACKER_RULES)}) — роль не достанет задачу "
                                f"через MCP; добавьте сервер трекера в mcp"))
    bad = reserved_in(launch["settings"])
    if bad:
        out.append(("warn", f"{role.name}: settings.{', settings.'.join(bad)} игнорируются — эти ключи ставит team "
                            f"(хуки, строка состояния, режим разрешений; плагины — полем plugins)"))
    clash = [k for k in launch["env"] if k in reserved_env or k.startswith("TEAM_")]
    if clash:
        out.append(("warn", f"{role.name}: env {', '.join(clash)} игнорируются — эти переменные ставит team"))
    return out
