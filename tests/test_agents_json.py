"""Нумерация агентов, миграция state.json и status --json."""
import json
import shutil
import subprocess
import time

import pytest

from agent_team import cli, tmuxctl
from agent_team.config import TeamError, canonical, load_team, split_agent

needs_tmux = pytest.mark.skipif(shutil.which("tmux") is None, reason="нет tmux")


def wait_for(fn, timeout=20.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        val = fn()
        if val:
            return val
        time.sleep(0.1)
    return None


def test_split_and_canonical_names():
    assert split_agent("worker") == ("worker", 1)
    assert split_agent("worker#3") == ("worker", 3)
    assert canonical("worker") == "worker#1"
    for bad in ("worker#0", "worker#x", "#2", "worker#"):
        with pytest.raises(TeamError):
            split_agent(bad)


def test_old_state_keys_are_read_as_number_one(project):
    team = load_team()
    team.state_dir.mkdir(parents=True)
    (team.state_dir / "state.json").write_text(json.dumps({"worker": {"session_id": "old"}, "idle#2": {"session_id": "n"}}))
    state = cli.load_state(team)
    assert state["worker#1"]["session_id"] == "old" and state["idle#2"]["session_id"] == "n"
    assert "worker" not in state
    cli.save_state(team, state)
    assert "worker#1" in json.loads((team.state_dir / "state.json").read_text())


@needs_tmux
@pytest.mark.both_layouts
def test_spawn_takes_next_free_number_with_own_worktree_and_branch(project):
    team = load_team()
    cli.main(["up"])
    assert cli.main(["spawn", "worker"]) == 0
    assert cli.main(["spawn", "worker"]) == 0
    live = tmuxctl.panes(team.session)
    assert {"worker#1", "worker#2", "worker#3"} <= set(live)
    assert (team.worktree_root / "worker").is_dir()
    assert (team.worktree_root / "worker-2").is_dir() and (team.worktree_root / "worker-3").is_dir()
    br = subprocess.run(["git", "-C", str(team.worktree_root / "worker-2"), "rev-parse", "--abbrev-ref", "HEAD"],
                        capture_output=True, text=True).stdout.strip()
    assert br == "worker-2"
    assert cli.load_state(team)["worker#2"]["cwd"].endswith("/worker-2")
    cli.main(["down", "worker#2"])                       # №2 останавливается отдельно
    assert "worker#2" not in tmuxctl.panes(team.session) and "worker#1" in tmuxctl.panes(team.session)
    cli.main(["spawn", "worker"])                        # свободный номер 2 занимается снова
    assert "worker#2" in tmuxctl.panes(team.session)
    assert cli.main(["peek", "worker#2"]) == 0
    assert cli.main(["peek", "worker#9"]) == 1


@needs_tmux
@pytest.mark.both_layouts
def test_status_json_contract(project, capsys):
    team = load_team()
    cli.main(["status", "--json"])                       # до запуска: сессии нет, роли с alive=false
    data = json.loads(capsys.readouterr().out)
    assert data["session_alive"] is False and data["tracker"] is None
    assert [a["name"] for a in data["agents"]] == ["boss#1", "worker#1", "idle#1"]
    assert all(a["alive"] is False and a["pane_id"] is None and a["idle_s"] is None for a in data["agents"])

    cli.main(["up"])
    cli.main(["spawn", "worker"])
    capsys.readouterr()
    cli.main(["status", "--json"])
    data = json.loads(capsys.readouterr().out)
    assert set(data) >= {"project", "repo", "session", "session_alive", "tracker", "agents"}
    assert data["project"] == team.project and data["session"] == team.session and data["session_alive"] is True
    assert data["repo"] == str(team.home)
    assert [a["name"] for a in data["agents"]] == ["boss#1", "worker#1", "worker#2", "idle#1"]
    w2 = data["agents"][2]
    assert set(w2) >= {"name", "role", "n", "title", "kind", "model", "alive", "pane_id", "session_id", "cwd", "branch",
                       "started", "idle_s", "waiting_human", "addr"}
    assert w2["role"] == "worker" and w2["n"] == 2 and w2["title"] == "Исполнитель" and w2["kind"] == "executor"
    assert w2["alive"] is True and w2["pane_id"].startswith("%") and w2["branch"] == "worker-2"
    assert isinstance(w2["started"], int) and isinstance(w2["idle_s"], int)
    assert w2["session_id"] and w2["cwd"].endswith("/worker-2") and w2["addr"] is None
    assert w2["waiting_human"] is False and w2["model"] == "inherit"
    assert data["agents"][0]["kind"] == "manager" and data["agents"][0]["alive"] is True
    assert data["agents"][3]["alive"] is False and data["agents"][3]["pane_id"] is None


@needs_tmux
def test_old_pane_label_without_number_is_number_one(project):
    team = load_team()
    cli.main(["spawn", "worker"])
    pane = tmuxctl.panes(team.session)["worker#1"]
    tmuxctl._run(["set-option", "-p", "-t", pane.id, "@team_role", "worker"])        # метка старого формата
    assert "worker#1" in tmuxctl.panes(team.session)


def test_status_json_task_and_dirty(project, capsys):
    team = load_team()
    cli.log_event(team, "task", "worker#1", "взял", task="TASK-1")
    cli.log_event(team, "report", "worker#1", "отчёт", task="TASK-9")
    cli.log_event(team, "task", "worker#1", "взял другую", task="TASK-2")
    cli.log_event(team, "task", "idle#1", "без номера", task=None)
    cli.main(["status", "--json"])
    agents = {a["name"]: a for a in json.loads(capsys.readouterr().out)["agents"]}
    assert agents["worker#1"]["task"] == "TASK-2"              # последняя задача, report не считается
    assert agents["idle#1"]["task"] is None and agents["boss#1"]["task"] is None
    assert agents["boss#1"]["dirty"] == [".team/"]            # cwd менеджера — репозиторий проекта; журнал событий не в .gitignore теста
    assert agents["worker#1"]["dirty"] is None                # worktree ещё не создан


def test_status_json_dirty_lists_paths_and_none_outside_git(project, capsys, tmp_path):
    team = load_team()
    (team.home / "new.txt").write_text("x", encoding="utf-8")
    (team.home / "README.md").write_text("y", encoding="utf-8")
    subprocess.run(["git", "-C", str(team.home), "add", "README.md"], check=True)
    cli.main(["status", "--json"])
    boss = json.loads(capsys.readouterr().out)["agents"][0]
    assert sorted(boss["dirty"]) == ["README.md", "new.txt"]
    plain = tmp_path / "plain"
    plain.mkdir()
    assert cli._git_dirty(plain) is None and cli._git_dirty(plain / "missing") is None


def test_git_reads_use_no_optional_locks(project, monkeypatch):
    team = load_team()
    calls = []
    real = subprocess.run

    def spy(argv, *a, **kw):
        calls.append(argv)
        return real(argv, *a, **kw)
    monkeypatch.setattr(cli.subprocess, "run", spy)
    (team.home / "new.txt").write_text("x", encoding="utf-8")
    assert cli._git_dirty(team.home) == ["new.txt"]
    cli._git_branch(team.home)
    assert len(calls) == 2 and all(c[:2] == ["git", "--no-optional-locks"] for c in calls)
    assert not (team.home / ".git" / "index.lock").exists()
