"""Адрес сессии Claude Code для встроенного обмена сообщениями (SendMessage).

Каждая сессия пишет о себе файл ~/.claude/sessions/<pid>.json с sessionId и messagingSocketPath.
SendMessage принимает адрес вида uds:<путь к сокету>; он однозначен, в отличие от имени сессии.
"""
from __future__ import annotations

import json
import os
from pathlib import Path


def sessions_dir() -> Path:
    return Path(os.environ.get("TEAM_SESSIONS_DIR", "~/.claude/sessions")).expanduser()


def _read(path: Path) -> dict | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def lookup(pid: int | None, session_id: str | None) -> dict | None:
    """Запись о сессии: сначала по pid процесса панели, затем по sessionId."""
    d = sessions_dir()
    if pid:
        rec = _read(d / f"{pid}.json")
        if rec:
            return rec
    if session_id and d.is_dir():
        for f in d.glob("*.json"):
            rec = _read(f)
            if rec and rec.get("sessionId") == session_id:
                return rec
    return None


def address(pid: int | None, session_id: str | None) -> str | None:
    rec = lookup(pid, session_id)
    sock = (rec or {}).get("messagingSocketPath")
    return f"uds:{sock}" if sock and Path(sock).exists() else None
