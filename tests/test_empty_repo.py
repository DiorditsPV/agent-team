"""Репозиторий без единого коммита: роли с worktree не поднимаются, check предупреждает."""
import shutil
import subprocess

import pytest

from agent_team import cli, tmuxctl
from agent_team.config import load_team

needs_tmux = pytest.mark.skipif(shutil.which("tmux") is None, reason="нет tmux")


@pytest.fixture
def empty_repo(project):
    shutil.rmtree(project / ".git")
    subprocess.run(["git", "init", "-q", "-b", "main", str(project)], check=True)
    return project


def test_check_warns_about_repo_without_commits(empty_repo, capsys):
    assert cli.main(["check"]) == 0                              # предупреждение, а не ошибка
    out = capsys.readouterr().out
    assert out.count("нет коммитов") == 1                       # один раз на репозиторий, не на роль
    assert "роли с worktree не поднимутся" in out and "первый коммит" in out


def test_check_silent_when_repo_has_commits(project, capsys):
    assert cli.main(["check"]) == 0
    assert "нет коммитов" not in capsys.readouterr().out


@needs_tmux
def test_spawn_refuses_role_with_worktree_and_creates_nothing(empty_repo, capsys):
    team = load_team()
    assert cli.main(["spawn", "worker"]) == 1
    err = capsys.readouterr().err
    assert "нет коммитов" in err and "worker" in err
    assert not team.worktree_path(cli.load_role(team, "worker")).exists()
    assert subprocess.run(["git", "-C", str(team.home), "branch", "--list", "worker"], capture_output=True, text=True).stdout == ""
    assert not tmuxctl.has_session(team.session)


@needs_tmux
def test_spawn_manager_without_worktree_works(empty_repo):
    team = load_team()
    assert cli.main(["spawn", "boss"]) == 0
    assert "boss#1" in tmuxctl.panes(team.session)


@needs_tmux
def test_up_refuses_before_starting_anything(empty_repo, capsys):
    team = load_team()
    assert cli.main(["up"]) == 1                                 # worker (start: always) с worktree
    assert "нет коммитов" in capsys.readouterr().err
    assert not tmuxctl.has_session(team.session)
    assert not team.worktree_path(cli.load_role(team, "worker")).exists()


@needs_tmux
def test_after_first_commit_spawn_works(empty_repo):
    team = load_team()
    subprocess.run(["git", "-C", str(team.home), "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init"], check=True)
    assert cli.main(["spawn", "worker"]) == 0
    assert team.worktree_path(cli.load_role(team, "worker")).is_dir()


def test_existing_worktree_dir_is_not_blocked(empty_repo):
    team = load_team()
    role = cli.load_role(team, "worker")
    team.worktree_path(role).mkdir(parents=True)
    assert cli.worktree_blocker(team, role) is None
