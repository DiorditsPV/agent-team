"""Запись сессии Claude Code: адрес для SendMessage и состояние агента.

Каждая сессия пишет о себе файл ~/.claude/sessions/<pid>.json с sessionId и messagingSocketPath.
SendMessage принимает адрес вида uds:<путь к сокету>; он однозначен, в отличие от имени сессии.

В той же записи Claude Code держит status и statusUpdatedAt (мс) — время последней смены status.
Проверено на claude 2.1.295:
- busy — ход идёт, в том числе долгий инструмент; statusUpdatedAt внутри хода не меняется;
- idle — ход закончен;
- waiting — запрос права или форма вопроса агента (AskUserQuestion);
- после выхода процесса записи нет.
Другие значения (встречается shell) не сверены и считаются отсутствием данных.
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


def _records() -> list[dict]:
    d = sessions_dir()
    return [r for r in (_read(f) for f in d.glob("*.json")) if r] if d.is_dir() else []


def record(pid: int | None) -> dict | None:
    """Запись процесса как есть, без перехода к фоновой задаче."""
    return _read(sessions_dir() / f"{pid}.json") if pid else None


def lookup(pid: int | None, *session_ids: str | None) -> dict | None:
    """Запись живого разговора агента: по pid процесса панели, иначе по sessionId (по порядку).

    Если в панели разговор отправлен в фон (← в пустой строке, /background), запись панели получает
    parkedJobId, а разговор продолжает отдельный процесс фоновой задачи со своим сокетом и status.
    Сообщение на сокет панели ложится в очередь старой сессии и не обрабатывается (проверено на claude
    2.1.295), поэтому берётся запись задачи с jobId = parkedJobId. Задачи нет — остаётся запись панели.
    """
    rec = record(pid)
    if not rec:
        wanted = [s for s in session_ids if s]
        by_sid = {r.get("sessionId"): r for r in _records() if r.get("sessionId") in wanted} if wanted else {}
        rec = next((by_sid[s] for s in wanted if s in by_sid), None)
    parked = (rec or {}).get("parkedJobId")
    if parked:
        job = next((r for r in _records() if r.get("jobId") == parked), None)
        if job:
            return job
    return rec


def address(pid: int | None, *session_ids: str | None) -> str | None:
    rec = lookup(pid, *session_ids)
    sock = (rec or {}).get("messagingSocketPath")
    return f"uds:{sock}" if sock and Path(sock).exists() else None


STATES = ("busy", "idle", "waiting")


def state(rec: dict | None) -> str | None:
    """Состояние агента по записи: busy, idle, waiting; без записи или с непроверенным значением — None."""
    status = (rec or {}).get("status")
    return status if status in STATES else None


def idle_seconds(rec: dict | None, now: int) -> int | None:
    """Простой по записи: при busy — 0, при idle и waiting — с последней смены status; без данных — None."""
    st = state(rec)
    if st == "busy":
        return 0
    upd = (rec or {}).get("statusUpdatedAt")
    if st is None or not isinstance(upd, (int, float)) or isinstance(upd, bool):
        return None
    return max(0, now - int(upd // 1000))
