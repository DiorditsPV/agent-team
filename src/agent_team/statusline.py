"""Строка состояния роли: сохраняет лимиты подписки и рисует строку состояния пользователя.

Claude Code передаёт команде statusLine JSON сессии на stdin. В нём `rate_limits` — текущее окно (`five_hour`) и
недельный лимит (`seven_day`): процент и время сброса из заголовков ответа API, без отдельных запросов. Приложение
показывает их в боковой панели, поэтому обёртка кладёт последний такой JSON в `.team/statusline.json` проекта
(временный файл и rename: читатель не увидит половину записи). JSON без лимитов файл не трогает; JSON с
`rate_limits_available: false` (ключ API, Bedrock, Vertex) записывается: по нему приложение скрывает строку.

Затем обёртка запускает прежнюю команду statusLine пользователя с тем же stdin и печатает её вывод — строка выглядит
как без team. Прежняя команда ищется при каждом вызове, в порядке старшинства настроек Claude Code: пользовательские
(`$CLAUDE_CONFIG_DIR` или `~/.claude`, `settings.json`), проекта (`.claude/settings.json`), локальные проекта
(`.claude/settings.local.json`); последняя заданная побеждает. Каталог проекта — каталог запуска (Claude Code
запускает команду в каталоге сессии). Команды нет — вывод пустой.

Запуск: `python -I -S statusline.py <путь файла лимитов>`. Скрипт самостоятельный, только стандартная библиотека, без
сети. Любая ошибка обёртки молча пропускается и выход — код 0: строка состояния не должна ломаться из-за лимитов.
"""
import json
import os
import subprocess
import sys

USER_COMMAND_TIMEOUT_S = 5


def _settings_files(cwd: str) -> list:
    home = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    return [os.path.join(home, "settings.json"),
            os.path.join(cwd, ".claude", "settings.json"),
            os.path.join(cwd, ".claude", "settings.local.json")]


def user_command(cwd: str):
    """Команда statusLine пользователя по настройкам Claude Code; своя обёртка не считается — иначе вызов по кругу."""
    found = None
    for path in _settings_files(cwd):
        try:
            with open(path, encoding="utf-8") as f:
                line = json.load(f).get("statusLine")
        except (OSError, ValueError, AttributeError):
            continue
        if isinstance(line, dict) and line.get("type", "command") == "command" and isinstance(line.get("command"), str):
            found = line["command"]
    if found and os.path.abspath(__file__) in found:
        return None
    return found or None


def save(data, out: str) -> None:
    if not isinstance(data, dict):
        return
    limits = data.get("rate_limits")
    if not (isinstance(limits, dict) and limits) and data.get("rate_limits_available") is not False:
        return
    tmp = "%s.%d.tmp" % (out, os.getpid())
    try:
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False)
        os.replace(tmp, out)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def main(argv) -> int:
    try:
        raw = sys.stdin.buffer.read()
    except OSError:
        raw = b""
    try:
        data = json.loads(raw.decode("utf-8")) if raw else None
    except ValueError:
        data = None
    if len(argv) > 1:
        try:
            save(data, argv[1])
        except Exception:
            pass
    try:
        command = user_command(os.getcwd())
        if command:
            r = subprocess.run(command, shell=True, input=raw, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               timeout=USER_COMMAND_TIMEOUT_S)
            sys.stdout.buffer.write(r.stdout)
            sys.stdout.flush()
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
