"""Точечная правка описания ролей: frontmatter файла роли и строка роли в team.yaml.

Правка идёт по строкам текста, а не через yaml.dump: тело файла, комментарии и остальные поля сохраняются байт в байт.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

import yaml

from .config import Role, Team, TeamError, _idle_stop_minutes, load_base_role, load_role, load_team

NAME_RE = re.compile(r"^[a-z][a-z0-9_-]*$")
PLAIN_RE = re.compile(r"^[\w][\w .\-]*$")


def _scalar(value: str, always_quote: bool = False) -> str:
    if not always_quote and PLAIN_RE.match(value) and value.lower() not in ("null", "true", "false", "yes", "no") \
            and not value.strip().isdigit():
        return value
    return json.dumps(value, ensure_ascii=False)


def _read(path: Path) -> list[str]:
    with path.open(encoding="utf-8", newline="") as f:
        return f.read().splitlines(keepends=True)


def _write(path: Path, lines: list[str]) -> None:
    with path.open("w", encoding="utf-8", newline="") as f:
        f.write("".join(lines))


def _eol(lines: list[str]) -> str:
    return "\r\n" if lines and lines[0].endswith("\r\n") else "\n"


def set_frontmatter(path: Path, fields: dict[str, str]) -> None:
    """Переписывает строки ключей во frontmatter; отсутствующий ключ добавляется перед закрывающей ---."""
    lines = _read(path)
    if not lines or lines[0].strip() != "---":
        raise TeamError(f"{path.name}: файл роли должен начинаться с frontmatter (---)")
    try:
        end = next(i for i in range(1, len(lines)) if lines[i].strip() == "---")
    except StopIteration:
        raise TeamError(f"{path.name}: frontmatter не закрыт") from None
    eol = _eol(lines)
    for key, text in fields.items():
        new = f"{key}: {text}{eol}"
        idx = next((i for i in range(1, end) if re.match(rf"{re.escape(key)}\s*:", lines[i])), None)
        if idx is None:
            lines.insert(end, new)
            end += 1
            continue
        stop = idx + 1                       # значение могло занимать несколько строк с отступом
        while stop < end and (lines[stop].startswith((" ", "\t")) and lines[stop].strip()):
            stop += 1
        lines[idx:stop] = [new]
        end -= (stop - idx) - 1
    _write(path, lines)


def remove_frontmatter(path: Path, key: str) -> None:
    """Удаляет ключ из frontmatter вместе с продолжением значения на следующих строках; нет ключа — ничего."""
    lines = _read(path)
    if not lines or lines[0].strip() != "---":
        raise TeamError(f"{path.name}: файл роли должен начинаться с frontmatter (---)")
    try:
        end = next(i for i in range(1, len(lines)) if lines[i].strip() == "---")
    except StopIteration:
        raise TeamError(f"{path.name}: frontmatter не закрыт") from None
    idx = next((i for i in range(1, end) if re.match(rf"{re.escape(key)}\s*:", lines[i])), None)
    if idx is None:
        return
    stop = idx + 1
    while stop < end and lines[stop].startswith((" ", "\t")) and lines[stop].strip():
        stop += 1
    del lines[idx:stop]
    _write(path, lines)


def _roles_block(lines: list[str]) -> tuple[int, int]:
    """Индекс строки «roles:» и конец блока (первая строка после последнего элемента списка)."""
    start = next((i for i, ln in enumerate(lines) if re.match(r"roles\s*:", ln)), None)
    if start is None:
        raise TeamError("в team.yaml нет блока roles")
    last = start
    for i in range(start + 1, len(lines)):
        s = lines[i]
        if not s.strip() or s.lstrip().startswith("#"):
            continue
        if s[0] not in " \t-":
            break
        last = i
    return start, last + 1


def _drop_comment(code: str) -> str:
    """Строка без комментария «# …» в конце. Значения в строках роли — простые слова, кавычек с «#» в них нет."""
    return re.sub(r"\s+#.*$", "", code)


def set_start(team_yaml: Path, role: str, start: str) -> None:
    """Пишет start в строку роли. Комментарий строки, где стоит start, убирается: он мог описывать прежний режим,
    а отличить такой комментарий от прочих по тексту нельзя. Комментарии на других строках остаются."""
    lines = _read(team_yaml)
    begin, end = _roles_block(lines)
    eol = _eol(lines)
    name = re.escape(role)
    for i in range(begin + 1, end):
        ln = lines[i]
        body = ln.rstrip("\r\n")
        m = re.match(rf"^(\s*-\s*)\{{(.*)\}}(.*)$", body)
        if m and re.search(rf"\brole:\s*{name}\s*(,|$)", m.group(2).strip() + ","):
            inner = m.group(2)
            if re.search(r"\bstart:\s*[\w-]+", inner):
                inner = re.sub(r"(\bstart:\s*)[\w-]+", rf"\g<1>{start}", inner, count=1)
            else:
                inner = inner.rstrip() + f", start: {start}"
            lines[i] = f"{m.group(1)}{{{inner}}}{_drop_comment(m.group(3))}{eol}"
            _write(team_yaml, lines)
            return
        m = re.match(rf"^(\s*)-\s*role:\s*{name}\s*(#.*)?$", body)
        if m:
            indent = len(m.group(1)) + 2
            j = i + 1
            while j < end and (not lines[j].strip() or len(lines[j]) - len(lines[j].lstrip()) >= indent) \
                    and not re.match(r"^\s*-", lines[j]):
                if re.match(rf"^\s{{{indent}}}start:\s*", lines[j]):
                    code = lines[j].rstrip("\r\n")
                    end_of_line = lines[j][len(code):]
                    lines[j] = re.sub(r"(start:\s*)[\w-]+", rf"\g<1>{start}", _drop_comment(code), count=1) + end_of_line
                    _write(team_yaml, lines)
                    return
                j += 1
            lines.insert(i + 1, " " * indent + f"start: {start}{eol}")
            _write(team_yaml, lines)
            return
        m = re.match(rf"^(\s*-\s*){name}\s*(#.*)?$", body)
        if m:
            lines[i] = f"{m.group(1)}{{role: {role}, start: {start}}}{eol}"
            _write(team_yaml, lines)
            return
    raise TeamError(f"строка роли «{role}» в team.yaml не найдена в понятной форме; поправьте start вручную")


def add_role_line(team_yaml: Path, role: str, start: str) -> None:
    lines = _read(team_yaml)
    begin, end = _roles_block(lines)
    eol = _eol(lines)
    first = next((ln for ln in lines[begin + 1:end] if ln.lstrip().startswith("-")), "  -")
    indent = first[:len(first) - len(first.lstrip())]
    if end > 0 and not lines[end - 1].endswith(("\n", "\r")):
        lines[end - 1] += eol
    lines.insert(end, f"{indent}- {{role: {role}, start: {start}}}{eol}")
    _write(team_yaml, lines)


def edit_role(team: Team, role: str, title=None, model=None, description=None, start=None, extends=None) -> None:
    team.start_mode(role)                                    # роль должна быть описана в team.yaml
    path = team.agents_dir / "roles" / f"{role}.md"
    if not path.is_file():
        raise TeamError(f"файла роли нет: {path}")
    if all(v is None for v in (title, model, description, start, extends)):
        raise TeamError("нечего менять: задайте --title, --model, --description, --start или --extends")
    if extends:                                              # ошибки базы — до любой записи
        load_base_role(extends, role)
    fields = {}
    if title is not None:
        fields["title"] = _scalar(title)
    if model is not None:
        fields["model"] = model
    if description is not None:
        fields["description"] = _scalar(description, always_quote=True)
    if extends:
        fields["extends"] = extends
    if fields:
        set_frontmatter(path, fields)
    if extends == "":
        remove_frontmatter(path, "extends")
    if start is not None and start != team.start_mode(role):     # тот же режим — team.yaml и его комментарии не трогаем
        set_start(team.root / "agents" / "team.yaml", role, start)


def _template_includes(team: Team) -> list[str]:
    for name in team.role_names():
        try:
            r = load_role(team, name)
        except TeamError:
            continue
        if r.kind == "executor":
            return r.includes
    return []


def new_role(team: Team, role: str, title=None, model=None, description=None, start="on_demand", extends=None) -> None:
    if not NAME_RE.match(role):
        raise TeamError(f"имя роли «{role}»: строчные латинские буквы, цифры, «-» и «_», с буквы")
    if role in team.role_names():
        raise TeamError(f"роль «{role}» уже есть в team.yaml")
    path = team.agents_dir / "roles" / f"{role}.md"
    if path.exists():
        raise TeamError(f"файл {path} уже есть")
    if extends:
        _new_thin_role(team, path, role, extends, title, model, description, start)
        return
    if not title:
        raise TeamError("для новой роли нужен --title (или --extends: название возьмётся из общей роли)")
    includes = yaml.safe_dump(_template_includes(team), default_flow_style=True, allow_unicode=True).strip()
    head = ["---", f"role: {role}", f"title: {_scalar(title)}", "kind: executor", "status: active",
            f"description: {_scalar(description or '', always_quote=True)}"]
    if model:
        head.append(f"model: {model}")
    head += [f"worktree: {{dir: {role}, branch: team/{role}}}", "zone: []", f"includes: {includes}", "---", ""]
    body = f"Ты {title}. Задачи получаешь от менеджера сообщением; работаешь в своём worktree.\n"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(head) + "\n" + body, encoding="utf-8")
    add_role_line(team.root / "agents" / "team.yaml", role, start)


def _new_thin_role(team: Team, path: Path, role: str, extends: str, title, model, description, start) -> None:
    """Тонкий файл роли: только extends и то, что задано явно; остальное придёт из общей роли."""
    base = load_base_role(extends, role)
    head = ["---", f"role: {role}", f"extends: {extends}"]
    if title:
        head.append(f"title: {_scalar(title)}")
    if description:
        head.append(f"description: {_scalar(description, always_quote=True)}")
    if model:
        head.append(f"model: {model}")
    if base.worktree:                                        # worktree общая роль не передаёт: он свой у каждого проекта
        head.append(f"worktree: {{dir: {role}, branch: team/{role}}}")
    head += ["zone: []", "---", ""]
    body = "<!-- Уточнения проекта к общей роли «%s»: что роль делает здесь иначе. Раздел пуст — удалите комментарий. -->\n" % extends
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(head) + "\n" + body, encoding="utf-8")
    add_role_line(team.root / "agents" / "team.yaml", role, start)


def _parse_idle_stop(text: str) -> int | None:
    if text.strip().lower() == "off":
        return None                      # выключено; в team.yaml пишется строкой off
    try:
        value = int(text.strip())
    except ValueError:
        value = text or "пусто"          # пустая строка валидатор читает как «ключа нет», а set её не принимает
    return _idle_stop_minutes(value)


# Ключи верхнего уровня team.yaml, которые правит `team set`: имя → разбор значения (None — выключено, пишется как off).
SETTABLE_KEYS = {"idle_stop_minutes": _parse_idle_stop}


def set_top_level(team_yaml: Path, key: str, value: int | str) -> None:
    """Пишет ключ верхнего уровня team.yaml одной строкой «ключ: значение»; выключение пишется значением «off», ключ не убирается.

    Остальные строки и комментарий в конце своей строки сохраняются. Нет ключа — строка встаёт перед «roles:». Форма
    строки, которую нельзя заменить как простое значение, — ошибка без записи.
    """
    lines = _read(team_yaml)
    eol = _eol(lines)
    idx = next((i for i, ln in enumerate(lines) if re.match(rf"{re.escape(key)}\s*:", ln)), None)
    if idx is None:
        at = next((i for i, ln in enumerate(lines) if re.match(r"roles\s*:", ln)), None)
        if at is None:
            raise TeamError("в team.yaml нет блока roles")
        lines.insert(at, f"{key}: {value}{eol}")
        _write(team_yaml, lines)
        return
    m = re.match(rf"^({re.escape(key)}\s*:\s*)([\w.+-]*)(\s+#.*?)?(\r?\n?)$", lines[idx])
    nxt = lines[idx + 1] if idx + 1 < len(lines) else ""
    if not m or (not m.group(2) and not m.group(3) and nxt.startswith((" ", "\t"))):
        raise TeamError(f"строка «{key}» в team.yaml в непонятной форме; поправьте её вручную")
    lines[idx] = f"{m.group(1)}{value}{m.group(3) or ''}{m.group(4)}"
    _write(team_yaml, lines)
