"""Транскрипт сессии Claude Code: ~/.claude/projects/<slug cwd>/<session_id>.jsonl.

Продолжив работу в новой сессии (продолжение после прерывания, /clear, /resume), Claude Code дописывает в старый
файл запись {"type":"continued-in","continuedInSessionId":…} и пишет дальше в новый. В state.json остаётся сессия
запуска, поэтому текущую ищем по цепочке таких записей.
"""
from __future__ import annotations

import json
import os
import re
from pathlib import Path

MAX_HOPS = 8          # переходов по цепочке не больше; защита от кольца — отдельно
TAIL_BYTES = 65536    # continued-in пишется в конец файла


def projects_dir() -> Path:
    return Path(os.environ.get("TEAM_PROJECTS_DIR", "~/.claude/projects")).expanduser()


def slug(cwd: str) -> str:
    """Имя каталога проекта у Claude Code: всё, кроме латинских букв и цифр, заменено на «-»."""
    return re.sub(r"[^A-Za-z0-9]", "-", cwd)


def locate_file(cwd: str | None, session_id: str) -> Path | None:
    """Файл сессии: сначала в каталоге cwd, затем в любом каталоге проектов."""
    root = projects_dir()
    if cwd:
        p = root / slug(cwd) / f"{session_id}.jsonl"
        if p.is_file():
            return p
    if root.is_dir():
        for p in root.glob(f"*/{session_id}.jsonl"):
            if p.is_file():
                return p
    return None


def continuation(path: Path) -> str | None:
    """Сессия, в которую продолжена эта: последняя запись continued-in в хвосте файла."""
    try:
        with path.open("rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            fh.seek(max(0, size - TAIL_BYTES))
            data = fh.read()
    except OSError:
        return None
    for line in reversed(data.split(b"\n")):
        if b'"continued-in"' not in line or len(line) > 4096:
            continue
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        if isinstance(rec, dict) and rec.get("type") == "continued-in" and rec.get("continuedInSessionId"):
            return str(rec["continuedInSessionId"])
    return None


def current(cwd: str | None, session_id: str | None) -> tuple[str | None, Path | None]:
    """Текущая сессия и её файл по цепочке continued-in. Следующего файла нет — остаёмся на последнем найденном."""
    if not session_id:
        return None, None
    path = locate_file(cwd, session_id)
    sid, seen = session_id, {session_id}
    for _ in range(MAX_HOPS):
        nxt = continuation(path) if path else None
        if not nxt or nxt in seen:
            break
        seen.add(nxt)
        nxt_path = locate_file(cwd, nxt)
        if not nxt_path:
            break
        sid, path = nxt, nxt_path
    return sid, path


READ_BLOCK = 262144          # хвост читается блоками с конца; файлы бывают в десятки мегабайт
MAX_TAIL = 16 * 1024 * 1024  # дальше этого от конца записи с usage не ищем
COMPACT_MARK = b'"subtype":"compact_boundary"'


def usage_context(usage: dict) -> int | None:
    """Контекст хода по usage: input + cache_creation + cache_read.

    На ходах с advisor сводка usage складывает запросы исполнителя и советника, поэтому берётся последняя итерация
    типа message из usage.iterations; без итераций — сам usage.
    """
    its = usage.get("iterations")
    if isinstance(its, list):
        msgs = [i for i in its if isinstance(i, dict) and i.get("type") == "message"]
        if msgs:
            usage = msgs[-1]
    total = 0
    for key in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"):
        v = usage.get(key)
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            total += int(v)
    return total or None


def _tail_lines(path: Path):
    """Строки файла с конца к началу; файл читается блоками, целиком не загружается. Неполную первую строку отдаёт последней."""
    with path.open("rb") as fh:
        fh.seek(0, os.SEEK_END)
        pos = fh.tell()
        floor = max(0, pos - MAX_TAIL)
        carry = b""
        while pos > floor:
            step = min(READ_BLOCK, pos - floor)
            pos -= step
            fh.seek(pos)
            parts = (fh.read(step) + carry).split(b"\n")
            carry = parts[0]
            for line in reversed(parts[1:]):
                if line:
                    yield line
        if carry and pos == 0:
            yield carry


def last_context(path: Path | None) -> int | None:
    """Контекст последнего хода ассистента сессии: из последней записи assistant с usage, читая файл с конца."""
    if path is None:
        return None
    try:
        for line in _tail_lines(path):
            if b'"usage"' not in line or b'"assistant"' not in line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if not isinstance(rec, dict) or rec.get("type") != "assistant" or rec.get("isSidechain"):
                continue
            usage = (rec.get("message") or {}).get("usage")
            ctx = usage_context(usage) if isinstance(usage, dict) else None
            if ctx:                                   # синтетические ответы (ошибки API) приходят с нулями
                return ctx
    except OSError:
        return None
    return None


def count_compactions(path: Path | None) -> int | None:
    """Число сжатий в сессии: записей system/compact_boundary в файле. Считается по байтам блоками (50 МБ — доли секунды),
    файл не разбирается и не загружается целиком; status ничего не пишет, поэтому кеша нет."""
    if path is None:
        return None
    keep = len(COMPACT_MARK) - 1
    count, tail = 0, b""
    try:
        with path.open("rb") as fh:
            while True:
                block = fh.read(READ_BLOCK * 8)
                if not block:
                    break
                data = tail + block
                count += data.count(COMPACT_MARK)
                tail = data[-keep:]                                # короче метки: дважды она не посчитается
    except OSError:
        return None
    return count
