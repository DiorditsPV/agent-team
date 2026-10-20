"""Передачи состояния: .team/handoffs/<ts>-<агент>.md. Шапка — frontmatter, ниже пять разделов, которые заполняет роль."""
from __future__ import annotations

import re
import time
from pathlib import Path

import yaml

from .config import Team

SECTIONS = (("done", "Сделано"), ("verified", "Проверено"), ("in_progress", "В работе"),
            ("pitfalls", "Подводные камни"), ("next", "Дальше"))
HINTS = {
    "done": "Что уже сделано: коммиты, файлы, решения.",
    "verified": "Чем проверено: команды и их результат (числа, а не «работает»).",
    "in_progress": "Что начато и не закончено; незакоммиченное — перечислить.",
    "pitfalls": "На чём можно споткнуться: ловушки, нерешённые вопросы, чужие зоны.",
    "next": "Что делать следующему по шагам.",
}


def handoffs_dir(team: Team) -> Path:
    return team.state_dir / "handoffs"


def create(team: Team, agent: str, task: str | None, reason: str | None, branch: str | None, worktree: str | None) -> Path:
    d = handoffs_dir(team)
    d.mkdir(parents=True, exist_ok=True)
    ts = int(time.time())
    while (d / f"{ts}-{agent}.md").exists():
        ts += 1
    meta = {"agent": agent, "ts": ts, "task": task, "reason": reason, "status": "waiting",
            "branch": branch, "worktree": worktree}
    head = yaml.safe_dump(meta, allow_unicode=True, sort_keys=False).rstrip("\n")
    body = "".join(f"\n## {title}\n\n<!-- {HINTS[key]} -->\n" for key, title in SECTIONS)
    path = d / f"{ts}-{agent}.md"
    path.write_text(f"---\n{head}\n---\n\n# Передача {agent}\n{body}", encoding="utf-8")
    return path


def reuse_or_create(team: Team, agent: str, task: str | None, reason: str | None, branch: str | None,
                    worktree: str | None) -> tuple[Path, bool]:
    """Повтор запроса не плодит файлы: последняя передача агента, пока она waiting и пуста, получает новые данные шапки.

    Заполненная передача (или использованная) остаётся нетронутой, и создаётся новая. Возвращает (путь, повторно ли).
    """
    for h in list_all(team):
        if h["agent"] != agent:
            continue
        if h["status"] == "waiting" and not any(h["sections"].values()):
            path = handoffs_dir(team) / f"{h['id']}.md"
            meta, body = _split(path.read_text(encoding="utf-8"))
            meta.update({"task": task if task is not None else meta.get("task"),
                         "reason": reason if reason is not None else meta.get("reason"),
                         "branch": branch, "worktree": worktree})
            head = yaml.safe_dump(meta, allow_unicode=True, sort_keys=False).rstrip("\n")
            path.write_text(f"---\n{head}\n---\n{body}", encoding="utf-8")
            return path, True
        break
    return create(team, agent, task, reason, branch, worktree), False


def _split(text: str) -> tuple[dict, str]:
    m = re.match(r"---\n(.*?)\n---\n(.*)", text, re.S)
    if not m:
        return {}, text
    try:
        meta = yaml.safe_load(m.group(1)) or {}
    except yaml.YAMLError:
        meta = {}
    return (meta if isinstance(meta, dict) else {}), m.group(2)


def _sections(body: str) -> dict[str, str]:
    titles = {title: key for key, title in SECTIONS}
    out = {key: "" for key, _ in SECTIONS}
    cur = None
    buf: list[str] = []

    def flush():
        if cur:
            text = re.sub(r"<!--.*?-->", "", "\n".join(buf), flags=re.S).strip()
            out[cur] = text
    for line in body.splitlines():
        m = re.match(r"##\s+(.+?)\s*$", line)
        if m:
            flush()
            cur, buf = titles.get(m.group(1)), []
        else:
            buf.append(line)
    flush()
    return out


def read(path: Path) -> dict:
    meta, body = _split(path.read_text(encoding="utf-8"))
    return {"id": path.stem, "agent": str(meta.get("agent") or ""), "ts": int(meta.get("ts") or 0),
            "task": meta.get("task"), "reason": meta.get("reason"),
            "status": "used" if meta.get("status") == "used" else "waiting",
            "branch": meta.get("branch"), "worktree": meta.get("worktree"),
            "used_at": int(meta["used_at"]) if meta.get("status") == "used" and meta.get("used_at") else None,
            "sections": _sections(body)}


def list_all(team: Team) -> list[dict]:
    d = handoffs_dir(team)
    items = [read(p) for p in d.glob("*.md")] if d.is_dir() else []
    return sorted(items, key=lambda h: (h["ts"], h["id"]), reverse=True)


def mark_last_used(team: Team, agent: str) -> str | None:
    """Последняя передача агента помечается использованной; возвращает её id."""
    for h in list_all(team):
        if h["agent"] == agent:
            path = handoffs_dir(team) / f"{h['id']}.md"
            text = path.read_text(encoding="utf-8")
            text = re.sub(r"^status: waiting$", f"status: used\nused_at: {int(time.time())}", text, count=1, flags=re.M)
            path.write_text(text, encoding="utf-8")
            return h["id"]
    return None
