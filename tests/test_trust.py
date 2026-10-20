"""Вопрос о доверии к каталогу: распознавание экрана (claude 2.1.292), чтение доверия из конфига Claude Code,
предупреждения spawn и check, состояние в текстовом status. team конфиг Claude Code не пишет."""
import json
import os
import shutil
import time
from pathlib import Path

import pytest

from agent_team import cli, tmuxctl, trust
from agent_team.config import load_team

FIX = Path(__file__).resolve().parent / "fixtures"
APP_FIX = Path(__file__).resolve().parent.parent / "app/Tests/AgentTeamCoreTests/Fixtures"
needs_tmux = pytest.mark.skipif(shutil.which("tmux") is None, reason="нет tmux")


def write_config(projects: dict) -> Path:
    path = trust.config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"projects": projects}), encoding="utf-8")
    return path


def trusted(path) -> dict:
    return {str(path): {"hasTrustDialogAccepted": True}}


@pytest.mark.parametrize("name", ["live-trust-wide.txt", "live-trust-narrow.txt"])
def test_trust_screen_is_waiting_for_trust(name):
    tail = "\n".join((FIX / name).read_text().splitlines()[-15:])
    assert cli.waiting_kind(tail) == "trust"
    assert cli.waiting_human(tail)


def test_permission_prompt_is_not_trust():
    tail = "\n".join((APP_FIX / "live-perm.txt").read_text().rstrip().splitlines()[-15:])
    assert cli.waiting_kind(tail) == "prompt"


def test_confirm_hint_alone_is_not_trust():
    assert cli.waiting_kind("Some menu\nEnter to confirm · Esc to cancel") is None


def test_no_config_means_unknown(tmp_path):
    assert trust.trusted_by(tmp_path) is None


def test_trust_of_a_parent_covers_children(tmp_path):
    child = tmp_path / "wt" / "worker"
    child.mkdir(parents=True)
    write_config({**trusted(tmp_path / "wt"), str(child): {"hasTrustDialogAccepted": False}})
    assert trust.trusted_by(child) == tmp_path / "wt"


def test_untrusted_and_declined_are_false(tmp_path):
    d = tmp_path / "d"
    d.mkdir()
    write_config({str(d): {"hasTrustDialogAccepted": False}, "/elsewhere": {"hasTrustDialogAccepted": True}})
    assert trust.trusted_by(d) is False


def test_trust_is_matched_through_symlinks(tmp_path):
    real = tmp_path / "real"
    real.mkdir()
    link = tmp_path / "link"
    link.symlink_to(real)
    write_config(trusted(real))
    assert trust.trusted_by(link / "sub") == real


def test_broken_config_means_unknown(tmp_path):
    path = trust.config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("{не json", encoding="utf-8")
    assert trust.trusted_by(tmp_path) is None


@pytest.mark.both_layouts
def test_check_warns_about_untrusted_worktree_root(project, capsys):
    write_config(trusted(project))                      # home доверен, корень worktree рядом — нет
    team = load_team()
    cli.main(["check"])
    out = capsys.readouterr().out
    assert f"роли worker: каталог {team.worktree_root} не доверен" in out
    assert "роли boss" not in out                      # менеджер в доверенном home


def test_check_is_silent_when_trust_is_unknown_or_given(project, capsys):
    cli.main(["check"])                                 # конфига нет — молчим
    assert "не доверен" not in capsys.readouterr().out
    write_config({**trusted(project), **trusted(load_team().worktree_root)})
    cli.main(["check"])
    assert "не доверен" not in capsys.readouterr().out


def test_config_file_is_never_written(project):
    path = write_config({})
    before = path.read_bytes(), path.stat().st_mtime_ns
    cli.main(["check"])
    assert (path.read_bytes(), path.stat().st_mtime_ns) == before


@needs_tmux
@pytest.mark.both_layouts
def test_spawn_warns_with_the_one_directory_to_trust(project, capsys):
    write_config(trusted(project))
    team = load_team()
    cli.main(["up"])
    out = capsys.readouterr().out
    lines = [l for l in out.splitlines() if "внимание" in l]
    assert len(lines) == 1                              # менеджер в доверенном home — без предупреждения
    assert f"каталог {team.worktree_root / 'worker'} не доверен" in lines[0]
    assert f"cd {team.worktree_root} && claude" in lines[0]


@needs_tmux
def test_spawn_is_quiet_under_a_trusted_root(project, capsys):
    write_config({**trusted(project), **trusted(load_team().worktree_root)})
    cli.main(["up"])
    assert "внимание" not in capsys.readouterr().out


@needs_tmux
@pytest.mark.both_layouts
def test_text_status_shows_role_waiting_for_trust(project, monkeypatch, capsys):
    team = load_team()
    monkeypatch.setenv("TEAM_CLAUDE_BIN", f"cat {FIX / 'live-trust-narrow.txt'} -")   # экран и ожидание ввода
    cli.main(["spawn", "idle"])
    pane = tmuxctl.panes(team.session)["idle#1"].id
    end = time.monotonic() + 20
    while "trust this folder" not in tmuxctl.capture(pane) and time.monotonic() < end:
        time.sleep(0.1)
    capsys.readouterr()
    cli.main(["status"])
    out = capsys.readouterr().out
    row = next(l for l in out.splitlines() if l.startswith("idle#1"))
    assert "ждёт: доверие" in row
    assert f"idle#1: стоит на вопросе о доверии к каталогу {team.home} — ответ человека: team attach idle#1" in out
    cli.main(["status", "--json"])
    a = next(x for x in json.loads(capsys.readouterr().out)["agents"] if x["name"] == "idle#1")
    assert a["waiting_human"] is True and a["waiting_reason"] == "trust"


@needs_tmux
@pytest.mark.both_layouts
def test_text_status_shows_role_waiting_on_a_prompt(project, monkeypatch, capsys):
    team = load_team()
    monkeypatch.setenv("TEAM_CLAUDE_BIN", f"cat {APP_FIX / 'live-perm.txt'} -")
    cli.main(["spawn", "idle"])
    pane = tmuxctl.panes(team.session)["idle#1"].id
    end = time.monotonic() + 20
    while not cli.waiting_human(tmuxctl.capture(pane, 15)) and time.monotonic() < end:
        time.sleep(0.1)
    capsys.readouterr()
    cli.main(["status"])
    row = next(l for l in capsys.readouterr().out.splitlines() if l.startswith("idle#1"))
    assert "ждёт ответа" in row
