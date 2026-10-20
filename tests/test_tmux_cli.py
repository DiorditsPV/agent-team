"""Живые проверки на настоящем tmux; вместо claude запускается cat (TEAM_CLAUDE_BIN)."""
import os
import shutil
import time

import pytest

from agent_team import cli, tmuxctl
from agent_team.config import TeamError, load_team

pytestmark = pytest.mark.skipif(shutil.which("tmux") is None, reason="нет tmux")


def wait_for(fn, timeout=20.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        val = fn()
        if val:
            return val
        time.sleep(0.1)
    return None


@pytest.mark.both_layouts
def test_up_spawns_manager_and_always_roles_and_creates_worktree(project):
    team = load_team()
    assert cli.main(["up"]) == 0
    live = tmuxctl.panes(team.session)
    assert sorted(live) == ["boss#1", "worker#1"]          # on_demand не поднят
    if team.layout == "panes":
        assert live["boss#1"].window == live["worker#1"].window == tmuxctl.SHARED_WINDOW
    else:
        assert live["boss#1"].index < live["worker#1"].index        # менеджер первым
    assert (team.worktree_root / "worker").is_dir()     # worktree создан
    state = cli.load_state(team)
    assert state["worker#1"]["session_id"] and state["worker#1"]["cwd"].endswith("/worker")


@pytest.mark.both_layouts
def test_up_is_idempotent(project, capsys):
    cli.main(["up"])
    capsys.readouterr()
    cli.main(["up"])
    assert "уже запущена" in capsys.readouterr().out


@pytest.mark.both_layouts
def test_send_reaches_the_role_and_peek_shows_it(project, capsys):
    cli.main(["up"])
    team = load_team()
    assert cli.main(["send", "worker", "--paste", "привет", "из", "менеджера"]) == 0
    pane = tmuxctl.panes(team.session)["worker#1"].id
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


@pytest.mark.both_layouts
def test_restart_and_down_role(project):
    team = load_team()
    cli.main(["up"])
    first = cli.load_state(team)["worker#1"]["session_id"]
    cli.main(["restart", "worker", "--fresh"])
    assert cli.load_state(team)["worker#1"]["session_id"] != first
    cli.main(["down", "worker"])
    assert "worker" not in tmuxctl.panes(team.session)
    cli.main(["down"])
    assert not tmuxctl.has_session(team.session)


@pytest.mark.both_layouts
def test_send_to_stopped_role_is_an_error(project, capsys):
    cli.main(["up"])
    assert cli.main(["send", "idle", "--paste", "ау"]) == 1
    assert "не запущен" in capsys.readouterr().err


@pytest.mark.both_layouts
def test_dead_window_is_replaced_on_spawn(project, monkeypatch):
    team = load_team()
    monkeypatch.setenv("TEAM_CLAUDE_BIN", "true")       # завершится сразу
    cli.main(["spawn", "idle"])
    assert wait_for(lambda: tmuxctl.panes(team.session).get("idle#1") and tmuxctl.panes(team.session)["idle#1"].dead)
    monkeypatch.setenv("TEAM_CLAUDE_BIN", "cat")
    cli.main(["spawn", "idle"])
    assert not tmuxctl.panes(team.session)["idle#1"].dead


@pytest.mark.panes_only
def test_panes_layout_shares_one_window_with_titles(project):
    team = load_team()
    cli.main(["up"])
    cli.main(["spawn", "idle"])
    live = tmuxctl.panes(team.session)
    assert {p.window for p in live.values()} == {tmuxctl.SHARED_WINDOW}
    assert len({p.id for p in live.values()}) == 3


def test_handoff_request_reaches_the_role(project):
    cli.main(["up"])
    team = load_team()
    assert cli.main(["handoff", "worker", "--paste"]) == 0
    pane = tmuxctl.panes(team.session)["worker#1"].id
    assert wait_for(lambda: "handoff" in tmuxctl.capture(pane))


@pytest.mark.both_layouts
def test_send_without_paste_refuses_and_points_to_sendmessage(project, capsys, monkeypatch):
    cli.main(["up"])
    capsys.readouterr()
    monkeypatch.setattr(tmuxctl, "send_text", lambda *a, **k: pytest.fail("без --paste в панель ничего не вставляется"))
    assert cli.main(["send", "worker", "проба"]) == 1
    err = capsys.readouterr().err
    assert "SendMessage" in err and "--paste" in err


@pytest.mark.both_layouts
def test_addr_and_status_use_the_session_registry(project, tmp_path, monkeypatch, capsys):
    import json
    team = load_team()
    yaml_path = team.root / "agents" / "team.yaml"
    yaml_path.write_text(yaml_path.read_text() + "tracker: Linear DEMO\n")
    cli.main(["up"])
    pane = tmuxctl.panes(team.session)["worker#1"]
    tmuxctl.send_text(pane.id, "Do you want to proceed?")
    assert wait_for(lambda: "Do you want to proceed" in tmuxctl.capture(pane.id))
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
    cli.main(["status", "--json"])
    data = json.loads(capsys.readouterr().out)
    assert data["tracker"] == "Linear DEMO"
    w = next(a for a in data["agents"] if a["name"] == "worker#1")
    assert w["waiting_human"] is True and w["addr"] == f"uds:{sock}"
    assert cli.main(["addr", "boss"]) == 1                  # у менеджера записи нет — явная ошибка


def test_pane_does_not_inherit_claude_vars_from_the_tmux_server(project, monkeypatch):
    import subprocess
    team = load_team()
    cli.main(["up"])                                         # сервер и сессия уже есть
    subprocess.run(["tmux", "-L", os.environ["TEAM_TMUX_SOCKET"], "set-environment", "-g", "CLAUDE_LEAK_TEST", "1"], check=True)
    try:
        monkeypatch.setenv("TEAM_CLAUDE_BIN", "env")
        cli.main(["spawn", "idle"])
        pane = tmuxctl.panes(team.session)["idle#1"].id
        out = wait_for(lambda: (lambda c: c if "TEAM_ROLE=idle" in c else None)(tmuxctl.capture(pane, 200)))
        assert out and "CLAUDE_LEAK_TEST" not in out
    finally:
        subprocess.run(["tmux", "-L", os.environ["TEAM_TMUX_SOCKET"], "set-environment", "-g", "-u", "CLAUDE_LEAK_TEST"])


def test_project_with_dot_in_name_spawns_second_role(project, capsys):
    """Имя проекта с точкой (tmp.XXXX из mktemp): цель «=team-tmp.X» tmux читает как сессию и панель «X»,
    поэтому сессия должна находиться и вторая роль — вставать в неё, а не падать на «duplicate session»."""
    yp = project / "agents" / "team.yaml"
    team = load_team()
    yp.write_text(yp.read_text(encoding="utf-8").replace(f"project: {team.project}", f"project: tmp.{team.project}"),
                  encoding="utf-8")
    team = load_team()
    assert "." in team.session
    assert cli.main(["up"]) == 0
    assert tmuxctl.has_session(team.session)
    assert cli.main(["spawn", "idle"]) == 0
    assert sorted(tmuxctl.panes(team.session)) == ["boss#1", "idle#1", "worker#1"]
    capsys.readouterr()
    cli.main(["down"])
    assert not tmuxctl.has_session(team.session)


@pytest.mark.parametrize("pane_layout", ["windows", "panes"])
def test_cwd_with_hash_is_not_expanded_by_tmux(project, tmp_path, pane_layout):
    """«#» в пути worktree не раскрывается как формат tmux: панель стоит в своём каталоге, а не в $HOME."""
    team = load_team()
    first = tmp_path / "a#Sb"
    second = tmp_path / "x##y"
    first.mkdir()
    second.mkdir()
    session = team.session + "-hash"
    try:
        p1 = tmuxctl.open_role(session, "one", str(first), "cat", layout=pane_layout)
        p2 = tmuxctl.open_role(session, "two", str(second), "cat", layout=pane_layout)
        for pid, want in ((p1, first), (p2, second)):
            got = wait_for(lambda: tmuxctl._run(["display-message", "-p", "-t", pid, "#{pane_current_path}"]).stdout.strip())
            assert os.path.realpath(got) == os.path.realpath(want)
    finally:
        tmuxctl._run(["kill-session", "-t", session], check=False)
