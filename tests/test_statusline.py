"""statusLine роли (statusline.py): лимиты подписки — в .team/statusline.json, строка — от команды пользователя."""
import json
import os
import shlex
import subprocess

from agent_team import asks
from agent_team.config import load_team

LIMITS = {"five_hour": {"used_percentage": 62, "resets_at": 1792400000},
          "seven_day": {"used_percentage": 41, "resets_at": 1792900000}}


def _session(**over):
    data = {"session_id": "S1", "model": {"display_name": "Opus"}, "workspace": {"current_dir": "/w"},
            "rate_limits_available": True, "rate_limits": LIMITS}
    data.update(over)
    return data


def _command(team) -> str:
    line = json.loads(asks.write_settings(team, "worker#1").read_text(encoding="utf-8"))["statusLine"]
    assert line["type"] == "command"
    return line["command"]


def _run(command, stdin, cwd):
    """Ровно та строка, что лежит в настройках: так её запустит Claude Code, в каталоге сессии."""
    text = stdin if isinstance(stdin, str) else json.dumps(stdin)
    return subprocess.run(command, shell=True, input=text, capture_output=True, text=True, timeout=10, cwd=cwd)


def _user_settings(statusline: dict | None, **extra):
    home = os.environ["CLAUDE_CONFIG_DIR"]
    os.makedirs(home, exist_ok=True)
    data = dict(extra)
    if statusline is not None:
        data["statusLine"] = statusline
    with open(os.path.join(home, "settings.json"), "w", encoding="utf-8") as f:
        json.dump(data, f)


def test_settings_point_status_line_to_wrapper_and_limits_file(project):
    team = load_team()
    _user_settings({"type": "command", "command": "echo x", "padding": 0})
    line = json.loads(asks.write_settings(team, "worker#1").read_text(encoding="utf-8"))["statusLine"]
    argv = shlex.split(line["command"])
    assert argv[0].startswith("/") and argv[1:3] == ["-I", "-S"]          # интерпретатор team, без PATH панели
    assert argv[3] == str(asks.STATUSLINE_SCRIPT) and argv[4] == str(asks.limits_path(team))
    assert line["padding"] == 0                                           # отступ строки — как у пользователя


def test_wrapper_saves_limits_and_prints_user_line(project, tmp_path):
    team = load_team()
    got = tmp_path / "user-stdin.json"
    _user_settings({"type": "command", "command": f"cat > {shlex.quote(str(got))}; printf 'моя строка'"})
    r = _run(_command(team), _session(), cwd=project)
    assert r.returncode == 0 and r.stdout == "моя строка"
    assert json.loads(got.read_text(encoding="utf-8")) == _session()       # команда пользователя получила тот же stdin
    saved = json.loads(asks.limits_path(team).read_text(encoding="utf-8"))
    assert saved["rate_limits"] == LIMITS
    assert not [p for p in asks.limits_path(team).parent.iterdir() if p.name.endswith(".tmp")]


def test_without_limits_file_is_kept(project):
    team = load_team()
    _user_settings(None)
    _run(_command(team), _session(), cwd=project)
    before = asks.limits_path(team).read_text(encoding="utf-8")
    r = _run(_command(team), _session(rate_limits=None), cwd=project)      # ответа API ещё не было
    assert r.returncode == 0 and r.stdout == ""                            # команды пользователя нет — строка пустая
    assert asks.limits_path(team).read_text(encoding="utf-8") == before


def test_unavailable_limits_are_saved(project):
    """Ключ API, Bedrock, Vertex: лимитов подписки нет — по записи приложение скрывает строку."""
    team = load_team()
    _user_settings(None)
    _run(_command(team), _session(rate_limits=None, rate_limits_available=False), cwd=project)
    assert json.loads(asks.limits_path(team).read_text(encoding="utf-8"))["rate_limits_available"] is False


def test_project_local_settings_override_user(project):
    """Порядок Claude Code: пользовательские, проекта, локальные проекта — последняя заданная команда побеждает."""
    team = load_team()
    _user_settings({"type": "command", "command": "printf user"})
    r = _run(_command(team), _session(), cwd=project)
    assert r.stdout == "user"
    (project / ".claude").mkdir(exist_ok=True)
    (project / ".claude" / "settings.json").write_text(json.dumps({"statusLine": {"type": "command", "command": "printf proj"}}))
    assert _run(_command(team), _session(), cwd=project).stdout == "proj"
    (project / ".claude" / "settings.local.json").write_text(json.dumps({"statusLine": {"type": "command", "command": "printf local"}}))
    assert _run(_command(team), _session(), cwd=project).stdout == "local"


def test_wrapper_never_breaks_the_line(project):
    """Битый stdin, падающая команда пользователя, недоступный каталог лимитов — выход 0, вывод команды пользователя."""
    team = load_team()
    _user_settings({"type": "command", "command": "printf ok; exit 3"})
    r = _run(_command(team), "не JSON", cwd=project)
    assert r.returncode == 0 and r.stdout == "ok"
    blocked = project / "blocked"
    blocked.write_text("файл, а не каталог")
    cmd = _command(team).replace(shlex.quote(str(asks.limits_path(team))), shlex.quote(str(blocked / "statusline.json")))
    r = _run(cmd, _session(), cwd=project)
    assert r.returncode == 0 and r.stdout == "ok"
    assert not asks.limits_path(team).exists()


def test_own_wrapper_in_user_settings_is_not_called_again(project):
    team = load_team()
    _user_settings({"type": "command", "command": _command(team)})
    r = _run(_command(team), _session(), cwd=project)
    assert r.returncode == 0 and r.stdout == ""
