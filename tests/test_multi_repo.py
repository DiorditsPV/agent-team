"""Проект с несколькими репозиториями и корнем без git: worktree роли — от её worktree.repo."""
import shutil
import subprocess

import pytest

from agent_team import cli, tmuxctl
from agent_team.config import load_role, load_team


def _common_dir(path):
    out = subprocess.run(["git", "-C", str(path), "rev-parse", "--path-format=absolute", "--git-common-dir"],
                         capture_output=True, text=True, check=True).stdout.strip()
    return out


def test_home_is_root_and_worktree_repo_is_per_role(multi_project):
    team = load_team()
    assert team.home == multi_project.resolve()
    assert team.state_dir == multi_project.resolve() / ".team"
    assert team.worktree_repo(load_role(team, "de")) == (multi_project / "de-repo").resolve()
    assert team.worktree_repo(load_role(team, "boss")) is None


def test_check_passes_on_multi_repo(multi_project, capsys):
    assert cli.main(["check"]) == 0
    assert "ошибок 0" in capsys.readouterr().out


def test_check_rejects_worktree_without_repo_in_non_git_home(multi_project, capsys):
    p = multi_project / "agents" / "roles" / "de.md"
    p.write_text(p.read_text(encoding="utf-8").replace("repo: de-repo, ", ""), encoding="utf-8")
    assert cli.main(["check"]) == 1
    assert "задайте worktree.repo" in capsys.readouterr().out


def test_check_rejects_repo_that_is_not_git(multi_project, capsys):
    shutil.rmtree(multi_project / "back-repo" / ".git")
    assert cli.main(["check"]) == 1
    assert "не git-репозиторий" in capsys.readouterr().out


@pytest.mark.skipif(shutil.which("tmux") is None, reason="нет tmux")
def test_up_puts_manager_in_home_and_worktrees_in_their_repos(multi_project):
    team = load_team()
    assert cli.main(["up"]) == 0
    assert sorted(tmuxctl.panes(team.session)) == ["back", "boss", "de"]
    state = cli.load_state(team)
    assert state["boss"]["cwd"] == str(team.home)
    for role in ("de", "back"):
        wt = team.worktree_root / role
        assert state[role]["cwd"] == str(wt)
        assert _common_dir(wt) == str((multi_project / f"{role}-repo" / ".git").resolve())
    assert (multi_project / ".team" / "state.json").is_file()
