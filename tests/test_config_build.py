import pytest

from agent_team import build
from agent_team.config import TeamError, find_root, load_role, load_team


def test_load_team_and_roles(project):
    team = load_team()
    assert team.project.startswith("t")
    assert team.manager == "boss"
    assert team.role_names() == ["boss", "worker", "idle"]
    assert team.start_mode("worker") == "always"
    worker = load_role(team, "worker")
    assert worker.worktree == {"dir": "worker", "branch": "worker"}
    assert team.worktree_path(worker) == team.worktree_root / "worker"
    assert load_role(team, "idle").worktree is None


def test_find_root_fails_outside_project(tmp_path):
    with pytest.raises(TeamError):
        find_root(tmp_path)


def test_unknown_role_is_rejected(project):
    team = load_team()
    with pytest.raises(TeamError):
        team.start_mode("ghost")


def test_instruction_has_body_includes_and_manager_appendix(project):
    team = load_team()
    boss = build.assemble_instruction(team, load_role(team, "boss"))
    assert "Ты менеджер." in boss and "Не ломать." in boss and "team send" in boss
    worker = build.assemble_instruction(team, load_role(team, "worker"))
    assert "Ты исполнитель." in worker and "team send" not in worker


def test_missing_include_is_an_error(project):
    team = load_team()
    (team.agents_dir / "shared" / "rules.md").unlink()
    with pytest.raises(TeamError):
        build.assemble_instruction(team, load_role(team, "worker"))


def test_allowed_tools_are_limited_and_role_specific(project):
    team = load_team()
    boss = build.allowed_tools(team, load_role(team, "boss"))
    worker = build.allowed_tools(team, load_role(team, "worker"))
    assert "Bash(team *)" in boss and "mcp__tracker" in boss
    assert "Bash(team *)" not in worker
    assert any(t.startswith("Bash(") and t.endswith("/.venv/bin/python *)") for t in worker)
    assert all("dangerously" not in t for t in worker)


def test_claude_argv_for_new_and_resumed_session(project, monkeypatch):
    monkeypatch.delenv("TEAM_CLAUDE_BIN")
    team = load_team()
    role = load_role(team, "worker")
    new = build.claude_argv(team, role, team.state_dir / "x.txt", "SID")
    assert new[0] == "claude" and "--session-id" in new and "--resume" not in new
    assert "--dangerously-skip-permissions" not in new
    assert "--add-dir" in new
    old = build.claude_argv(team, role, team.state_dir / "x.txt", "SID", resume=True)
    assert "--resume" in old and "--session-id" not in old


def test_shell_command_unsets_claude_vars_inside_the_pane():
    cmd = build.shell_command(["claude", "--name", "Роль"], {"TEAM_ROLE": "r"})
    assert cmd.startswith("sh -c ")
    assert "unset" in cmd and "CLAUDE_CONFIG_DIR" in cmd and "exec env TEAM_ROLE=r" in cmd


def test_broken_frontmatter_gives_a_readable_error(project):
    team = load_team()
    (team.agents_dir / "roles" / "idle.md").write_text("---\nrole: idle\ndescription: Зона: сбор\n---\nтело\n", encoding="utf-8")
    with pytest.raises(TeamError, match="в кавычки"):
        load_role(team, "idle")
