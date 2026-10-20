"""Открытый вопрос агента (AskUserQuestion): настройки хука для запуска claude и чтение записи хука.

Запись кладёт хук askhook.py в .team/asks/<агент>/. Удаляют её сам хук (PostToolUse, следующий вопрос) и
spawn, restart, down агента. status только читает и скрывает запись, если вызов уже закрыт: в транскрипте после
сохранённого хуком смещения есть tool_result с этим id или у агента другая сессия.
"""
from __future__ import annotations

import json
import shlex
import shutil
import sys
from pathlib import Path

from . import launch
from .config import Role, Team, split_agent

HOOK_SCRIPT = Path(__file__).with_name("askhook.py")
STATUSLINE_SCRIPT = Path(__file__).with_name("statusline.py")
HOOK_TIMEOUT_S = 5


def asks_dir(team: Team, key: str) -> Path:
    return team.state_dir / "asks" / key


def hook_settings(team: Team, key: str, role: Role | None = None) -> dict:
    """Хуки team и запрет фона; остальные настройки владельца claude не трогаются, хуки из --settings добавляются
    к его хукам.

    disableAgentView: роль не уходит в фоновую задачу (← в пустой строке, /background) — у задачи нет промпта роли
    (roleguard.py).

    Поля роли settings и plugins (launch.py) кладутся под ключами team: ключи team и режим разрешений они не
    перекрывают.
    """
    # Интерпретатор — тот, под которым запущен team: хук не зависит от PATH панели. -I -S: без каталога запуска
    # и site-packages в sys.path, скрипту нужна только стандартная библиотека.
    command = shlex.join([sys.executable, "-I", "-S", str(HOOK_SCRIPT), str(asks_dir(team, key))])
    entry = [{"matcher": "AskUserQuestion", "hooks": [{"type": "command", "command": command,
                                                       "timeout": HOOK_TIMEOUT_S}]}]
    own = launch.settings_overlay(team, role) if role else {}
    if role:
        own = launch.merge_excludes(own, launch.brief_excludes(team, role, split_agent(key)[1]))
    return {**own, "hooks": {"PreToolUse": entry, "PostToolUse": entry}, "disableAgentView": True,
            "statusLine": status_line(team)}


def limits_path(team: Team) -> Path:
    """Последний JSON строки состояния с лимитами подписки — общий для ролей проекта (statusline.py)."""
    return team.state_dir / "statusline.json"


def status_line(team: Team) -> dict:
    """statusLine роли: обёртка statusline.py сохраняет лимиты подписки и рисует строку состояния пользователя, так что
    вид строки не меняется. Отступ (`padding`) — из пользовательских настроек Claude Code, если он там задан."""
    command = shlex.join([sys.executable, "-I", "-S", str(STATUSLINE_SCRIPT), str(limits_path(team))])
    out: dict = {"type": "command", "command": command}
    user = launch.read_json(launch.claude_config_dir() / "settings.json").get("statusLine")
    if isinstance(user, dict) and isinstance(user.get("padding"), int):
        out["padding"] = user["padding"]
    return out


def write_settings(team: Team, key: str, role: Role | None = None) -> Path:
    out = team.state_dir / "build" / f"{key}-settings.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(hook_settings(team, key, role), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return out


def clear(team: Team, key: str | None = None) -> None:
    """Удаляет записи агента, без ключа — всех агентов."""
    d = asks_dir(team, key) if key else team.state_dir / "asks"
    if key:
        for p in d.glob("*.json") if d.is_dir() else ():
            p.unlink(missing_ok=True)
    else:
        shutil.rmtree(d, ignore_errors=True)


def _records(d: Path) -> list[dict]:
    out = []
    for p in d.glob("*.json") if d.is_dir() else ():
        try:
            rec = json.loads(p.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if isinstance(rec, dict) and isinstance(rec.get("id"), str):
            out.append(rec)
    return out


def _closed(transcript: str, offset, tool_use_id: str) -> bool:
    """Есть ли в транскрипте после offset tool_result этого вызова."""
    if not transcript:
        return False
    needle = tool_use_id.encode()
    start = offset if isinstance(offset, int) and not isinstance(offset, bool) and offset > 0 else 0
    try:
        with open(transcript, "rb") as fh:
            fh.seek(start)
            return any(needle in line and b"tool_result" in line and _has_result(line, tool_use_id) for line in fh)
    except OSError:
        return False


def _has_result(line: bytes, tool_use_id: str) -> bool:
    try:
        rec = json.loads(line)
    except ValueError:
        return False
    content = ((rec or {}).get("message") or {}).get("content") if isinstance(rec, dict) else None
    return isinstance(content, list) and any(
        isinstance(c, dict) and c.get("type") == "tool_result" and c.get("tool_use_id") == tool_use_id
        for c in content)


def _text(value) -> str:
    return value if isinstance(value, str) else ""


def normalize(tool_input) -> list[dict]:
    """Вопросы в стабильном виде для приложения: схема инструмента может меняться, контракт — нет."""
    qs = tool_input.get("questions") if isinstance(tool_input, dict) else None
    out = []
    for q in qs if isinstance(qs, list) else ():
        if not isinstance(q, dict):
            continue
        options = []
        for o in q.get("options") if isinstance(q.get("options"), list) else ():
            if not isinstance(o, dict):
                continue
            item = {"label": _text(o.get("label")), "description": _text(o.get("description"))}
            if _text(o.get("preview")):
                item["preview"] = o["preview"]
            options.append(item)
        out.append({"question": _text(q.get("question")), "header": _text(q.get("header")),
                    "multiSelect": q.get("multiSelect") is True, "options": options})
    return out


def open_question(team: Team, key: str, session_id: str | None) -> dict | None:
    """Открытый вопрос агента в текущей сессии: {id, ts, questions} или None."""
    recs = sorted(_records(asks_dir(team, key)), key=lambda r: r.get("ts") if isinstance(r.get("ts"), int) else 0)
    if not recs:
        return None
    rec = recs[-1]
    if not session_id or rec.get("session_id") != session_id:
        return None
    if _closed(_text(rec.get("transcript")), rec.get("offset"), rec["id"]):
        return None
    questions = normalize(rec.get("tool_input"))
    if not questions:
        return None
    return {"id": rec["id"], "ts": rec.get("ts"), "questions": questions}
