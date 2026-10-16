"""Живые проверки на настоящем tmux; вместо claude запускается cat (TEAM_CLAUDE_BIN)."""
import shutil
import time

import pytest

from agent_team import cli, tmuxctl
from agent_team.config import TeamError, load_team

pytestmark = pytest.mark.skipif(shutil.which("tmux") is None, reason="нет tmux")


def wait_for(fn, timeout=5.0):
    end = time.time() + timeout
    while time.time() < end:
        val = fn()
        if val:
            return val
        time.sleep(0.1)
    return None


def test_up_spawns_manager_and_always_roles_and_creates_worktree(project):
    team = load_team()
    assert cli.main(["up"]) == 0
    live = tmuxctl.panes(team.session)
    assert sorted(live) == ["boss", "worker"]          # on_demand не поднят
    if team.layout == "panes":
        assert live["boss"].window == live["worker"].window == tmuxctl.SHARED_WINDOW
    else:
        assert live["boss"].index < live["worker"].index        # менеджер первым
    assert (team.worktree_root / "worker").is_dir()     # worktree создан
    state = cli.load_state(team)
    assert state["worker"]["session_id"] and state["worker"]["cwd"].endswith("/worker")


def test_up_is_idempotent(project, capsys):
    cli.main(["up"])
    capsys.readouterr()
    cli.main(["up"])
    assert "уже запущена" in capsys.readouterr().out


def test_send_reaches_the_role_and_peek_shows_it(project, capsys):
    cli.main(["up"])
    team = load_team()
    assert cli.main(["send", "worker", "--paste", "привет", "из", "менеджера"]) == 0
    pane = tmuxctl.panes(team.session)["worker"].id
    seen = wait_for(lambda: "привет из менеджера" in tmuxctl.capture(pane))
    assert seen
    capsys.readouterr()
    assert cli.main(["peek", "worker"]) == 0
    assert "привет из менеджера" in capsys.readouterr().out


def test_status_reports_roles(project, capsys):
    cli.main(["up"])
    capsys.readouterr()
    cli.main(["status"])
    out = capsys.readouterr().out
    assert "boss" in out and "работает" in out
    assert "idle" in out and "не запущена" in out


def test_restart_and_down_role(project):
    team = load_team()
    cli.main(["up"])
    first = cli.load_state(team)["worker"]["session_id"]
    cli.main(["restart", "worker", "--fresh"])
    assert cli.load_state(team)["worker"]["session_id"] != first
    cli.main(["down", "worker"])
    assert "worker" not in tmuxctl.panes(team.session)
    cli.main(["down"])
    assert not tmuxctl.has_session(team.session)


def test_send_to_stopped_role_is_an_error(project, capsys):
    cli.main(["up"])
    assert cli.main(["send", "idle", "--paste", "ау"]) == 1
    assert "не запущена" in capsys.readouterr().err


def test_dead_window_is_replaced_on_spawn(project, monkeypatch):
    team = load_team()
    monkeypatch.setenv("TEAM_CLAUDE_BIN", "true")       # завершится сразу
    cli.main(["spawn", "idle"])
    assert wait_for(lambda: tmuxctl.panes(team.session).get("idle") and tmuxctl.panes(team.session)["idle"].dead)
    monkeypatch.setenv("TEAM_CLAUDE_BIN", "cat")
    cli.main(["spawn", "idle"])
    assert not tmuxctl.panes(team.session)["idle"].dead


def test_panes_layout_shares_one_window_with_titles(project):
    team = load_team()
    if team.layout != "panes":
        pytest.skip("только для раскладки panes")
    cli.main(["up"])
    cli.main(["spawn", "idle"])
    live = tmuxctl.panes(team.session)
    assert {p.window for p in live.values()} == {tmuxctl.SHARED_WINDOW}
    assert len({p.id for p in live.values()}) == 3


def test_handoff_request_reaches_the_role(project):
    cli.main(["up"])
    team = load_team()
    assert cli.main(["handoff", "worker", "--paste"]) == 0
    pane = tmuxctl.panes(team.session)["worker"].id
    assert wait_for(lambda: "handoff.md" in tmuxctl.capture(pane))


def test_send_without_paste_refuses_and_points_to_sendmessage(project, capsys):
    cli.main(["up"])
    capsys.readouterr()
    assert cli.main(["send", "worker", "проба"]) == 1
    err = capsys.readouterr().err
    assert "SendMessage" in err and "--paste" in err
    team = load_team()
    pane = tmuxctl.panes(team.session)["worker"].id
    time.sleep(0.5)
    assert "проба" not in tmuxctl.capture(pane)            # молча не вставили


def test_addr_and_status_use_the_session_registry(project, tmp_path, monkeypatch, capsys):
    import json
    cli.main(["up"])
    team = load_team()
    pane = tmuxctl.panes(team.session)["worker"]
    reg = tmp_path / "sessions"
    reg.mkdir()
    sock = tmp_path / "w.sock"
    sock.write_text("")
    (reg / f"{pane.pid}.json").write_text(json.dumps({"sessionId": "x", "messagingSocketPath": str(sock)}))
    monkeypatch.setenv("TEAM_SESSIONS_DIR", str(reg))
    capsys.readouterr()
    assert cli.main(["addr", "worker"]) == 0
    assert capsys.readouterr().out.strip() == f"uds:{sock}"
    cli.main(["status"])
    assert f"uds:{sock}" in capsys.readouterr().out
    assert cli.main(["addr", "boss"]) == 1                  # у менеджера записи нет — явная ошибка


def test_pane_does_not_inherit_claude_vars_from_the_tmux_server(project, monkeypatch):
    import subprocess
    team = load_team()
    cli.main(["up"])                                         # сервер и сессия уже есть
    subprocess.run(["tmux", "set-environment", "-g", "CLAUDE_LEAK_TEST", "1"], check=True)
    try:
        monkeypatch.setenv("TEAM_CLAUDE_BIN", "env")
        cli.main(["spawn", "idle"])
        pane = tmuxctl.panes(team.session)["idle"].id
        out = wait_for(lambda: (lambda c: c if "TEAM_ROLE=idle" in c else None)(tmuxctl.capture(pane, 200)))
        assert out and "CLAUDE_LEAK_TEST" not in out
    finally:
        subprocess.run(["tmux", "set-environment", "-g", "-u", "CLAUDE_LEAK_TEST"])
