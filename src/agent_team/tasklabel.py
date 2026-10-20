"""Название текущей задачи агента: короткая подпись для владельца, а не номер и не технический след."""
from __future__ import annotations

import re

MIN_LEN, MAX_LEN = 8, 48

BARE_ID_RE = re.compile(r"^\s*(?:#\d+|[A-Za-z][A-Za-z0-9]{0,9}-\d+)\s*$")
FILE_RE = re.compile(r"(?<![\w.])[\w-]+\.[A-Za-z][A-Za-z0-9]{0,5}(?![\w])")        # name.ext
PATH_RE = re.compile(r"(?:^|\s)[~.]{0,2}/\S|\S+/\S+/|\\")                          # /a, ~/a, ./a, a/b/c, обратная косая


def problems(title: str) -> list[str]:
    """Нарушения формы названия; каждое — с тем, что поправить. Пустой список — название годится."""
    out: list[str] = []
    if "\n" in title or "\r" in title:
        out.append("название в одну строку: уберите переводы строки")
    flat = " ".join(title.split())
    n = len(flat)
    if n < MIN_LEN:
        out.append(f"название короче {MIN_LEN} знаков ({n}): опишите словами, что станет иначе для владельца")
    elif n > MAX_LEN:
        out.append(f"название длиннее {MAX_LEN} знаков ({n}): сократите до сути")
    if BARE_ID_RE.match(flat):
        out.append("название — голый номер задачи: номер передайте через --id, а в названии опишите работу словами")
    if "`" in title:
        out.append("в названии обратные кавычки (код): назовите, что видит владелец, без имён из кода")
    if PATH_RE.search(flat) or FILE_RE.search(flat):
        out.append("в названии путь или имя файла: опишите результат для владельца, без путей и расширений")
    return out


def normalize(title: str) -> str:
    return " ".join(title.split())
