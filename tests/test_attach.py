"""team attach и tmuxctl.attach: сам attach не запускается, tmux подменён."""
import pytest

from agent_team import cli, tmuxctl
from agent_team.config import load_team


def _pane(role="worker#1", pane_id="%7"):
    return tmuxctl.Pane(id=pane_id, role=role, window="w", index=1, dead=False, activity=0, command="cat", pid=1)


def test_attach_without_session_is_an_error(project, capsys):
    assert cli.main(["attach"]) == 1
    assert "team up" in capsys.readouterr().err


@pytest.mark.parametrize("argv, want", [(["attach", "worker"], "%7"), (["attach"], "%1"), (["attach", "idle"], None)])
def test_attach_selects_role_pane_or_manager(project, monkeypatch, argv, want):
    team = load_team()
    seen = []
    monkeypatch.setattr(tmuxctl, "has_session", lambda session: True)
    monkeypatch.setattr(tmuxctl, "panes", lambda session: {"worker#1": _pane(), "boss#1": _pane("boss#1", "%1")})
    monkeypatch.setattr(tmuxctl, "attach", lambda session, pane_id=None: seen.append((session, pane_id)))
    assert cli.main(argv) == 0
    assert seen == [(team.session, want)]          # без запущенной роли — просто сессия, без выбора панели


def test_attach_selects_pane_before_attaching(monkeypatch):
    calls = []
    monkeypatch.setattr(tmuxctl, "_run", lambda argv, check=True: calls.append(argv))
    monkeypatch.setattr(tmuxctl.subprocess, "run", lambda argv, *a, **k: calls.append(argv))
    tmuxctl.attach("team-x", "%7")
    assert calls[0][:3] == ["select-window", "-t", "%7"] and calls[1][:3] == ["select-pane", "-t", "%7"]
    assert "attach-session" in calls[2]
    calls.clear()
    tmuxctl.attach("team-x")
    assert len(calls) == 1 and "attach-session" in calls[0]
