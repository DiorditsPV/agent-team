"""Сборка инструкции роли и командной строки запуска claude."""
from __future__ import annotations

import os
import shlex
import uuid
from pathlib import Path

from .config import Role, Team, TeamError

DEFAULT_TOOLS = ["Read", "Edit", "Write", "Glob", "Grep", "Bash(git *)"]

MANAGER_APPENDIX = """\
## Команда

Ты работаешь в окне tmux проекта; остальные роли — в соседних панелях. Управление командой — командой `team`, а сообщения ролям — твоим инструментом SendMessage:

- `team status` — роли, живы ли, давно ли было действие, адрес для SendMessage;
- `team spawn <роль>` — поднять роль;
- `team addr <роль>` — адрес роли (`uds:…`). Сообщения ролям отправляй SendMessage на этот адрес, а не по имени: так роль видит, что пишет менеджер, а не пользователь, и имя сессии не может оказаться чужим. Выдачу задачи оформляй по `agents/templates/task-assignment.md`;
- `team send <роль> --paste "<текст>"` — запасной путь, только если SendMessage на адрес не доставляет: вставляет текст в строку ввода роли, и роль примет его за слова пользователя;
- `team peek <роль> [строк]` — прочитать последние строки окна роли;
- `team handoff <роль>` — печатает адрес и текст запроса передачи (шаблон `agents/templates/handoff.md`); отправь его SendMessage;
- `team restart <роль>` — пересоздать сессию роли (после передачи);
- `team down <роль>` — остановить роль, когда её работа закончена.

Роли отчитываются тебе SendMessage и комментарием в трекере. Не считай задачу сделанной по отчёту: сверяй с фактом (коммит, тест).
"""


def assemble_instruction(team: Team, role: Role) -> str:
    parts = [role.body.rstrip("\n") + "\n"]
    for inc in role.includes:
        path = team.agents_dir / "shared" / inc
        if not path.is_file():
            raise TeamError(f"{role.name}: подключённого файла нет: {path}")
        parts.append("\n---\n\n" + path.read_text(encoding="utf-8").rstrip("\n") + "\n")
    if role.kind == "manager":
        parts.append("\n---\n\n" + MANAGER_APPENDIX)
    return "".join(parts)


def write_instruction(team: Team, role: Role) -> Path:
    out = team.state_dir / "build" / f"{role.name}.txt"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(assemble_instruction(team, role), encoding="utf-8")
    return out


def allowed_tools(team: Team, role: Role) -> list[str]:
    tools = list(DEFAULT_TOOLS)
    test = team.test_command.strip()
    if test:
        exe = test.split()[0]
        if exe.startswith("."):
            exe = str((team.home / exe).resolve())
        tools.append(f"Bash({exe} *)")
    if role.kind == "manager":
        tools.append("Bash(team *)")
    for t in role.allow:
        if t not in tools:
            tools.append(t)
    return tools


def claude_argv(team: Team, role: Role, instruction: Path, session_id: str, resume: bool = False) -> list[str]:
    binary = os.environ.get("TEAM_CLAUDE_BIN")
    if binary:                      # подмена для тестов: никаких флагов claude
        return shlex.split(binary)
    argv = ["claude", "--name", role.title,
            "--append-system-prompt-file", str(instruction),
            "--permission-mode", "acceptEdits",
            "--allowedTools", ",".join(allowed_tools(team, role))]
    argv += ["--resume", session_id] if resume else ["--session-id", session_id]
    if role.meta.get("model") not in (None, "", "inherit"):
        argv += ["--model", str(role.meta["model"])]
    for d in role.add_dirs:
        argv += ["--add-dir", str(Path(d).expanduser())]
    return argv


def new_session_id() -> str:
    return str(uuid.uuid4())


# Переменные родительской сессии Claude (сокет и токен обмена сообщениями, id сессии, признаки фоновой задачи)
# снимаются внутри панели в момент запуска, а не по списку вызывающего процесса: панель получает окружение
# tmux-сервера, а сервер помнит окружение сессии, из которой его когда-то подняли. С такими переменными роль
# регистрируется как дочерняя чужой сессии и получает её имя.
UNSET_CLAUDE_VARS = (
    'for v in $(env | sed -n "s/^\\(CLAUDE[A-Za-z0-9_]*\\)=.*/\\1/p"); do '
    '[ "$v" = CLAUDE_CONFIG_DIR ] || unset "$v"; done'
)


def shell_command(argv: list[str], env: dict[str, str]) -> str:
    prefix = " ".join(f"{k}={shlex.quote(v)}" for k, v in env.items())
    script = f"{UNSET_CLAUDE_VARS}; exec env {prefix} " + " ".join(shlex.quote(a) for a in argv)
    return "sh -c " + shlex.quote(script)
