import pytest

from agent_team import asks, build
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
    assert "--permission-mode" not in new          # режим наследуется из настроек владельца
    assert "--add-dir" in new
    settings = asks.write_settings(team, "worker#1")                 # --settings и список инструментов
    with_settings = build.claude_argv(team, role, team.state_dir / "x.txt", "SID", settings=settings)
    assert with_settings[with_settings.index("--settings") + 1] == str(settings)
    assert with_settings[with_settings.index("--allowedTools") + 1] == ",".join(build.allowed_tools(team, role))
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


def test_roles_json_contract(project, capsys):
    import json
    from agent_team import cli
    assert cli.main(["roles", "--json"]) == 0
    roles = json.loads(capsys.readouterr().out)
    assert [r["role"] for r in roles] == ["boss", "worker", "idle"]
    boss, worker, idle = roles
    keys = {"role", "title", "kind", "model", "description", "start", "file", "worktree", "zone", "includes", "allow",
            "tracker_zone", "effective_allow", "running", "body", "instruction"}
    assert keys <= set(worker)
    assert worker["title"] == "Исполнитель" and worker["start"] == "always" and worker["running"] == 0
    assert worker["worktree"] == {"dir": "worker", "branch": "worker", "repo": None}
    assert idle["worktree"] is None and boss["kind"] == "manager"
    assert worker["body"].startswith("Ты исполнитель") and "Не ломать." in worker["instruction"]
    assert worker["includes"] == ["rules.md"] and boss["allow"] == ["mcp__tracker"]
    assert "Bash(team *)" in boss["effective_allow"] and "mcp__tracker" in boss["effective_allow"]
    assert "Bash(team *)" not in worker["effective_allow"]
    assert worker["file"].endswith("agents/roles/worker.md")


@pytest.mark.both_layouts
def test_roles_json_counts_running_agents(project, capsys):
    import json
    from agent_team import cli
    cli.main(["spawn", "worker"])
    cli.main(["spawn", "worker"])
    capsys.readouterr()
    cli.main(["roles", "--json"])
    roles = {r["role"]: r for r in json.loads(capsys.readouterr().out)}
    assert roles["worker"]["running"] == 2 and roles["idle"]["running"] == 0
