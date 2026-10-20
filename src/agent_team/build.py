"""Сборка инструкции роли и командной строки запуска claude."""
from __future__ import annotations

import os
import shlex
import uuid
from pathlib import Path

from .config import Role, Team, TeamError, launch_fields, library_dir

DEFAULT_TOOLS = ["Read", "Edit", "Write", "Glob", "Grep", "Bash(git *)"]

MANAGER_APPENDIX = """\
## Команда

Ты работаешь в окне tmux проекта; остальные роли — в соседних панелях. Управление командой — командой `team`, а сообщения ролям — твоим инструментом SendMessage:

- `team status [--json]` — агенты, живы ли, давно ли было действие, адрес для SendMessage. Столбец `ctx` — размер контекста в тысячах токенов; «сброс» (`reset_due` в `--json`) — пора начинать с чистого контекста, звёздочка — роль к сбросу пока не готова; «!» (`context_warning`) — контекст растёт при работе;
- `team spawn <роль>` — поднять роль; повторный вызов поднимает следующего агента той же роли (`роль#2`). Команды `addr`, `peek`, `send`, `handoff`, `restart`, `down` принимают `роль#n`, имя без номера — №1;
- `team log <тип> <агент> <текст> [--task X]` — записать в ленту событий task или report (`team events --json` читает ленту);
- `team addr <роль>` — адрес роли (`uds:…`). Сообщения ролям отправляй SendMessage на этот адрес, а не по имени: так роль видит, что пишет менеджер, а не пользователь, и имя сессии не может оказаться чужим. Выдачу задачи оформляй по `agents/templates/task-assignment.md`;
- `team send <роль> --paste "<текст>"` — запасной путь, только если SendMessage на адрес не доставляет: вставляет текст в строку ввода роли, и роль примет его за слова пользователя;
- `team peek <роль> [строк]` — прочитать последние строки окна роли;
- `team handoff <роль> [--task X]` — создаёт файл передачи в `.team/handoffs/` и печатает адрес и текст запроса с путём к файлу; отправь его SendMessage. Готовность смотри по файлу: в `team handoffs --json` у передачи заполнены `sections`, а не по выводу панели. Повторный `handoff` той же роли, пока файл пуст, пишет в тот же файл;
- `team roles [--json] [--library]` — роли проекта и, с `--library`, общие роли библиотеки; в элементе `source`, `extends`, собранные поля и собранная инструкция;
- `team role new <роль> --extends <общая> [--title … --model … --description … --start …]` — завести роль тонким файлом, наследующим общую роль; без `--extends` нужен `--title`. `team role set <роль> [--title … --model … --description … --start … --extends <общая>]` правит поля; `--extends ""` снимает наследование. Обе печатают JSON роли;
- `team restart <роль>` — пересоздать сессию роли (после передачи);
- `team down <роль>` — остановить роль, когда её работа закончена;
- `team task <агент> "<название>" [--id <ID>]` — подпись «над чем работает» для владельца, выдай её агенту вместе с задачей; владелец видит её в `team status` и в шапке приложения. Название — 8–48 знаков, языком владельца, что станет иначе для него: без номера задачи (он идёт в `--id`), путей и кода; `team task` проверяет форму и печатает, что поправить. `team task <агент> --clear` снимает подпись. Снимай задачу сразу после приёмки: пока она стоит, `team reap` агента не остановит;
- `team reap` — останавливает простаивающих агентов `start: on_demand` (порог — `idle_stop_minutes` в team.yaml, без ключа 15 минут); менеджера, занятых, ждущих ответа и агентов с задачей не трогает;
- `team set idle_stop_minutes <N|off>` — задать порог простоя в минутах (по умолчанию 15) или выключить автоостановку.

Роли отчитываются тебе SendMessage и комментарием в трекере. Не считай задачу сделанной по отчёту: сверяй с фактом (коммит, тест).
"""


def _library_shared(name: str) -> Path | None:
    try:
        path = library_dir() / "shared" / name
    except TeamError:
        return None
    return path if path.is_file() else None


def _zone_section(role: Role) -> str:
    """Раздел «Зона» из полей `zone` и `tracker_zone`: до агента доходит то, что автор записал во frontmatter. У не-менеджера раздел есть всегда."""
    zone = [str(z) for z in role.meta.get("zone") or []]
    label = str(role.meta.get("tracker_zone") or "").strip()
    lines = []
    if zone:
        lines.append("Твоя зона: " + ", ".join(f"`{z}`" for z in zone) + ".")
    elif role.kind != "manager":      # тела ролей отсылают к этому разделу, он есть у каждого исполнителя
        lines.append("Зона в роли не задана: что править, называет задача менеджера (поле «Файлы»).")
    if label:
        lines.append(f"Метка твоей зоны в трекере: «{label}».")
    return "## Зона\n\n" + "\n".join(lines) + "\n" if lines else ""


def assemble_instruction(team: Team, role: Role) -> str:
    if role.base_body is not None:
        notes = role.body.strip("\n")
        parts = [role.base_body.rstrip("\n") + "\n" + (f"\n## Уточнения проекта\n\n{notes}\n" if notes else "")]
    else:
        parts = [role.body.rstrip("\n") + "\n"]
    zone = _zone_section(role)
    if zone:
        parts.append("\n---\n\n" + zone)
    for inc in role.includes:
        path = team.agents_dir / "shared" / inc
        if not path.is_file():          # подключение унаследованной роли может лежать только в библиотеке
            lib = _library_shared(inc)
            if lib is None:
                raise TeamError(f"{role.name}: подключённого файла нет: {path}")
            path = lib
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


def claude_argv(team: Team, role: Role, instruction: Path, session_id: str, resume: bool = False,
                settings: Path | None = None, mcp_config: Path | None = None) -> list[str]:
    binary = os.environ.get("TEAM_CLAUDE_BIN")
    if binary:                      # подмена для тестов: никаких флагов claude
        return shlex.split(binary)
    # Режим разрешений не задаётся: роль наследует режим по умолчанию из настроек владельца. Жёсткий флаг
    # перекрывал бы его, и роль вставала бы на вопросах, пока у панели никого нет.
    argv = ["claude", "--name", role.title,
            "--append-system-prompt-file", str(instruction),
            "--allowedTools", ",".join(allowed_tools(team, role))]
    argv += ["--resume", session_id] if resume else ["--session-id", session_id]
    if settings:                    # хуки team (asks.hook_settings); claude добавляет их к хукам владельца
        argv += ["--settings", str(settings)]
    if mcp_config:                  # поле mcp роли: только перечисленные серверы, без коннекторов и MCP плагинов
        argv += ["--strict-mcp-config", "--mcp-config", str(mcp_config)]
    if launch_fields(team, role)["chrome"] is False:
        argv.append("--no-chrome")
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


# Ставятся после снятия CLAUDE_*: роль не уходит в фоновую задачу Claude Code, у которой нет промпта роли
# (roleguard.py). Первая выключает ← в пустой строке и /background, как настройка disableAgentView в --settings;
# вторая — передачу фоновых агентов демону при выходе.
ROLE_CLAUDE_ENV = {"CLAUDE_CODE_DISABLE_AGENT_VIEW": "1", "CLAUDE_CODE_DISABLE_BG_EXIT_HANDOFF": "1"}


def shell_command(argv: list[str], env: dict[str, str]) -> str:
    prefix = " ".join(f"{k}={shlex.quote(v)}" for k, v in env.items())
    script = f"{UNSET_CLAUDE_VARS}; exec env {prefix} " + " ".join(shlex.quote(a) for a in argv)
    return "sh -c " + shlex.quote(script)
