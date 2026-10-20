"""Доверие Claude Code к каталогу роли: только чтение, team его не ставит.

В каталоге без доверия claude при запуске спрашивает «Is this a project you created or one you trust?», и роль
стоит на этом экране, пока человек не ответит. Ответ хранится в глобальном конфиге Claude Code
(`$CLAUDE_CONFIG_DIR/.claude.json`, по умолчанию `~/.claude.json`): projects[<путь>].hasTrustDialogAccepted.
Доверие к каталогу распространяется на вложенные: worktree под доверенным родителем вопроса не задаёт.

team этот файл не пишет: доверие — решение владельца, а файл целиком переписывают живые сессии claude, и запись
со стороны гонялась бы с ними. Отсюда team только узнаёт заранее, встанет ли роль на вопросе, и подсказывает
владельцу, какой один каталог доверить, чтобы новые worktree проходили без вопроса.
"""
from __future__ import annotations

import json
import os
from pathlib import Path


def config_path() -> Path:
    base = os.environ.get("CLAUDE_CONFIG_DIR")
    return Path(base).expanduser() / ".claude.json" if base else Path("~/.claude.json").expanduser()


def _projects() -> dict | None:
    try:
        data = json.loads(config_path().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    projects = data.get("projects") if isinstance(data, dict) else None
    return projects if isinstance(projects, dict) else None


def _chain(path: Path) -> list[Path]:
    """Каталог и его родители — в записанном виде и после разрешения ссылок (/var и /private/var на macOS)."""
    seen: list[Path] = []
    for p in (Path(path).expanduser().absolute(), Path(path).expanduser().resolve()):
        for q in (p, *p.parents):
            if q not in seen:
                seen.append(q)
    return seen


def trusted_by(path: Path) -> Path | bool | None:
    """Каталог, чьё доверие покрывает path (он сам или родитель); False — не покрыт; None — конфиг не прочесть."""
    projects = _projects()
    if projects is None:
        return None
    for p in _chain(path):
        entry = projects.get(str(p))
        if isinstance(entry, dict) and entry.get("hasTrustDialogAccepted") is True:
            return p
    return False


def advice(cwd: Path, common: Path | None) -> str:
    """Что делать владельцу, если роль встанет на вопросе о доверии."""
    target = common or cwd
    return (f"каталог {cwd} не доверен в Claude Code: роль встанет на вопросе о доверии к папке, пока его не ответят "
            f"(team attach). Чтобы роли в нём и рядом поднимались без вопроса, владелец один раз доверяет общий "
            f"каталог: cd {target} && claude, ответ «Yes, I trust this folder», затем /exit")
