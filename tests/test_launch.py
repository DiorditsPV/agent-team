"""Лёгкий старт роли: поля mcp, plugins, settings, chrome, env в роли и в defaults team.yaml (launch.py)."""
import json
import os
import shlex
import shutil
import stat

import pytest

from agent_team import asks, build, cli, config, launch
from agent_team.config import TeamError, launch_fields, load_role, load_team

SECRET = "tok-SECRET-123"


@pytest.fixture(autouse=True)
def real_argv(project, monkeypatch):
    monkeypatch.delenv("TEAM_CLAUDE_BIN", raising=False)         # подмена отключает все флаги claude


@pytest.fixture
def owner(tmp_path, monkeypatch):
    """Каталог настроек владельца вместо настоящего ~/.claude и ~/.claude.json."""
    home = tmp_path / "claude-config"
    home.mkdir(exist_ok=True)
    return home


def write_claude_json(owner, data):
    (owner / ".claude.json").write_text(json.dumps(data), encoding="utf-8")


def team_yaml(extra):
    path = load_team().root / "agents" / "team.yaml"
    path.write_text(path.read_text(encoding="utf-8") + extra, encoding="utf-8")


def role_fields(name, extra, kind="executor"):
    path = load_team().root / "agents" / "roles" / f"{name}.md"
    path.write_text(path.read_text(encoding="utf-8").replace(f"kind: {kind}\n", f"kind: {kind}\n{extra}\n", 1),
                    encoding="utf-8")


def argv_of(name="worker", key="worker#1"):
    team = load_team()
    role = load_role(team, name)
    return build.claude_argv(team, role, team.state_dir / "x.txt", "SID", settings=asks.write_settings(team, key, role),
                             mcp_config=launch.mcp_config_for(team, role, key))


def settings_of(name="worker", key="worker#1"):
    team = load_team()
    role = load_role(team, name)
    return json.loads(asks.write_settings(team, key, role).read_text(encoding="utf-8"))


# --- без новых полей поведение прежнее ---

def test_without_fields_nothing_changes(project, owner):
    argv = argv_of()
    assert "--strict-mcp-config" not in argv and "--mcp-config" not in argv and "--no-chrome" not in argv
    assert sorted(settings_of()) == ["disableAgentView", "hooks", "statusLine"]
    team = load_team()
    assert launch_fields(team, load_role(team, "worker")) == {"mcp": None, "plugins": {}, "settings": {}, "chrome": None, "env": {}, "context": {}}
    assert not (team.state_dir / "build" / "worker#1-mcp.json").exists()
    role_fields("worker", "chrome: true")                        # явное true — тоже без флага
    assert "--no-chrome" not in argv_of()


# --- mcp ---

def test_mcp_writes_private_file_and_strict_flags(project, owner):
    team_yaml(f"mcp_servers:\n  tracker: {{command: tracker-mcp, env: {{TOKEN: {SECRET}}}}}\n")
    role_fields("worker", "mcp: [tracker]")
    argv = argv_of()
    path = argv[argv.index("--mcp-config") + 1]
    assert "--strict-mcp-config" in argv and path.endswith("/.team/build/worker#1-mcp.json")
    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
    assert json.load(open(path, encoding="utf-8")) == {"mcpServers": {"tracker": {"command": "tracker-mcp", "env": {"TOKEN": SECRET}}}}


def test_mcp_file_permissions_are_tightened_on_rewrite(project, owner):
    team_yaml("mcp_servers:\n  a: {command: a}\n")
    role_fields("worker", "mcp: [a]")
    path = argv_of()[argv_of().index("--mcp-config") + 1]
    os.chmod(path, 0o644)
    argv_of()
    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600


def test_empty_mcp_means_no_servers_but_strict(project, owner):
    role_fields("worker", "mcp: []")
    argv = argv_of()
    assert "--strict-mcp-config" in argv
    assert json.load(open(argv[argv.index("--mcp-config") + 1], encoding="utf-8")) == {"mcpServers": {}}


def test_mcp_lookup_order(project, owner):
    team = load_team()
    write_claude_json(owner, {
        "mcpServers": {"s1": {"command": "global-s1"}, "s2": {"command": "global-s2"}, "s3": {"command": "global-s3"}},
        "projects": {str(team.home): {"mcpServers": {"s2": {"command": "proj-s2"}, "s3": {"command": "proj-s3"}}}}})
    (team.home / ".mcp.json").write_text(json.dumps({"mcpServers": {"s3": {"command": "file-s3"}, "s4": {"command": "file-s4"}}}),
                                         encoding="utf-8")
    team_yaml("mcp_servers:\n  s3: {command: yaml-s3}\n")
    team = load_team()
    found = launch.resolve_mcp(team, ["s1", "s2", "s3", "s4"])
    assert {k: v["command"] for k, v in found.items()} == {"s1": "global-s1", "s2": "proj-s2", "s3": "yaml-s3", "s4": "file-s4"}


def test_claude_json_is_read_from_home_without_config_dir(project, tmp_path, monkeypatch):
    monkeypatch.delenv("CLAUDE_CONFIG_DIR")
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    (tmp_path / "home").mkdir()
    (tmp_path / "home" / ".claude.json").write_text(json.dumps({"mcpServers": {"x": {"command": "x"}}}), encoding="utf-8")
    assert launch.resolve_mcp(load_team(), ["x"]) == {"x": {"command": "x"}}


def test_unknown_mcp_name_is_error_without_secrets(project, owner, capsys):
    write_claude_json(owner, {"mcpServers": {"known": {"command": "k", "env": {"TOKEN": SECRET}}}})
    role_fields("worker", "mcp: [missing]")
    assert cli.main(["check"]) == 1
    out = capsys.readouterr().out
    assert "missing" in out and "known" in out and SECRET not in out
    with pytest.raises(TeamError, match="missing"):
        launch.mcp_config_for(load_team(), load_role(load_team(), "worker"), "worker#1")


def test_check_warns_when_tracker_rule_and_mcp_empty(project, owner, capsys):
    (load_team().agents_dir / "shared" / "tracker-cycle.md").write_text("Работай с трекером.\n", encoding="utf-8")
    role_fields("worker", "mcp: []\nincludes: [tracker-cycle.md]")
    path = load_team().agents_dir / "roles" / "worker.md"
    path.write_text(path.read_text(encoding="utf-8").replace("includes: [rules.md]\n", ""), encoding="utf-8")
    assert cli.main(["check"]) == 0
    assert "mcp пуст" in capsys.readouterr().out


def test_check_silent_when_mcp_not_set_or_filled(project, owner, capsys):
    team_yaml("mcp_servers:\n  t: {command: t}\n")
    (load_team().agents_dir / "shared" / "tracker-cycle.md").write_text("Работай с трекером.\n", encoding="utf-8")
    role_fields("worker", "mcp: [t]\nincludes: [tracker-cycle.md]")
    path = load_team().agents_dir / "roles" / "worker.md"
    path.write_text(path.read_text(encoding="utf-8").replace("includes: [rules.md]\n", ""), encoding="utf-8")
    assert cli.main(["check"]) == 0
    assert "mcp пуст" not in capsys.readouterr().out


# --- plugins ---

def test_plugins_off(project, owner):
    role_fields("worker", "plugins: {off: [a@m, b@m]}")
    assert settings_of()["enabledPlugins"] == {"a@m": False, "b@m": False}


def test_plugins_only_disables_the_rest_of_owner_plugins(project, owner):
    (owner / "settings.json").write_text(json.dumps({"enabledPlugins": {"a@m": True, "b@m": True, "c@m": False}}), encoding="utf-8")
    role_fields("worker", "plugins: {only: [a@m]}")
    assert settings_of()["enabledPlugins"] == {"a@m": True, "b@m": False, "c@m": False}


def test_plugins_only_without_owner_settings_adds_nothing(project, owner):
    role_fields("worker", "plugins: {only: [a@m]}")
    assert "enabledPlugins" not in settings_of()


def test_plugins_shape_is_validated(project, owner):
    role_fields("worker", "plugins: {maybe: [a]}")
    with pytest.raises(TeamError, match="plugins"):
        load_role(load_team(), "worker")


# --- settings ---

def test_settings_merge_into_the_same_file(project, owner):
    role_fields("worker", "settings: {includeCoAuthoredBy: false, env: {A: '1'}}\nplugins: {off: [a@m]}")
    s = settings_of()
    assert s["includeCoAuthoredBy"] is False and s["env"] == {"A": "1"} and s["enabledPlugins"] == {"a@m": False}
    assert s["disableAgentView"] is True and "hooks" in s and "statusLine" in s


def test_settings_cannot_override_team_keys_or_permissions(project, owner, capsys):
    role_fields("worker", "settings: {hooks: {}, disableAgentView: false, statusLine: {type: command, command: x}, "
                          "permissions: {defaultMode: bypassPermissions}, defaultMode: bypassPermissions, "
                          "enabledPlugins: {z@m: true}, model: opus}")
    s = settings_of()
    assert s["disableAgentView"] is True and "PreToolUse" in s["hooks"] and s["statusLine"]["command"] != "x"
    assert not {"permissions", "defaultMode", "enabledPlugins"} & set(s) and s["model"] == "opus"
    assert cli.main(["check"]) == 0                              # предупреждение не валит проверку
    out = capsys.readouterr().out
    assert "игнорируются" in out and "settings.hooks" in out and "settings.permissions" in out


# --- chrome ---

def test_chrome_false_adds_no_chrome(project, owner):
    role_fields("worker", "chrome: false")
    assert "--no-chrome" in argv_of()


def test_chrome_must_be_boolean(project, owner):
    role_fields("worker", "chrome: нет")
    with pytest.raises(TeamError, match="chrome"):
        load_role(load_team(), "worker")


# --- env ---

def test_env_is_added_after_team_env_and_quoted(project, owner):
    role_fields("worker", "env: {FOO_BAR: 'a b; rm -rf /', N: 5}")
    team = load_team()
    role = load_role(team, "worker")
    env = {**build.ROLE_CLAUDE_ENV, **launch.role_env(team, role, build.ROLE_CLAUDE_ENV), "TEAM_ROLE": "worker"}
    assert env["FOO_BAR"] == "a b; rm -rf /" and env["N"] == "5" and env["CLAUDE_CODE_DISABLE_AGENT_VIEW"] == "1"
    script = shlex.split(build.shell_command(["claude"], env))[-1]
    assert "FOO_BAR='a b; rm -rf /'" in script


def test_env_cannot_override_team_variables(project, owner, capsys):
    role_fields("worker", "env: {CLAUDE_CODE_DISABLE_AGENT_VIEW: '0', TEAM_ROLE: x, OK: y}")
    team = load_team()
    env = launch.role_env(team, load_role(team, "worker"), build.ROLE_CLAUDE_ENV)
    assert env == {"OK": "y"}
    assert cli.main(["check"]) == 0
    assert "CLAUDE_CODE_DISABLE_AGENT_VIEW, TEAM_ROLE" in capsys.readouterr().out


@pytest.mark.parametrize("bad", ["lower: x", "'A-B': x", "A: [1]"])
def test_env_names_and_values_are_validated(project, owner, bad):
    role_fields("worker", "env: {%s}" % bad)
    with pytest.raises(TeamError, match="env"):
        load_role(load_team(), "worker")


# --- наследование ---

@pytest.fixture
def lib(tmp_path, monkeypatch):
    root = tmp_path / "lib"
    (root / "shared").mkdir(parents=True)
    (root / "base.md").write_text(
        "---\nrole: base\nkind: executor\nmcp: [from_lib]\nchrome: true\nplugins: {off: [lib@m]}\n"
        "settings: {a: lib, b: lib}\nenv: {X: lib, Y: lib}\n---\nТело.\n", encoding="utf-8")
    monkeypatch.setattr(config, "library_dir", lambda: root)
    monkeypatch.setattr(build, "library_dir", lambda: root)
    return root


def test_defaults_apply_to_every_role_and_role_overrides(project, owner):
    team_yaml("defaults:\n  mcp: [t]\n  chrome: false\n  plugins: {off: [d@m]}\n  settings: {a: d, b: d}\n  env: {X: d, Y: d}\n"
              "mcp_servers:\n  t: {command: t}\n")
    role_fields("worker", "settings: {b: role}\nenv: {Y: role}\nplugins: {only: [o@m]}")
    team = load_team()
    worker, idle = launch_fields(team, load_role(team, "worker")), launch_fields(team, load_role(team, "idle"))
    assert idle == {"mcp": ["t"], "chrome": False, "plugins": {"off": ["d@m"]}, "settings": {"a": "d", "b": "d"}, "env": {"X": "d", "Y": "d"}, "context": {}}
    assert worker["settings"] == {"a": "d", "b": "role"} and worker["env"] == {"X": "d", "Y": "role"}   # словари — по ключам
    assert worker["plugins"] == {"off": ["d@m"], "only": ["o@m"]}
    assert "--no-chrome" in argv_of("idle", "idle#1")                                    # defaults дошёл до argv


def test_role_mcp_replaces_defaults_list_instead_of_merging(project, owner):
    team_yaml("defaults:\n  mcp: [a, b]\nmcp_servers:\n  a: {command: a}\n  b: {command: b}\n  c: {command: c}\n")
    role_fields("worker", "mcp: [c]")
    team = load_team()
    assert launch_fields(team, load_role(team, "worker"))["mcp"] == ["c"]
    role_fields("idle", "mcp: []")
    assert launch_fields(team, load_role(team, "idle"))["mcp"] == []                     # сузить можно до пустого


def test_chain_defaults_library_role_project_role(project, owner, lib):
    team_yaml("defaults:\n  settings: {a: d, c: d}\n  env: {Z: d}\n  mcp: [d]\n  chrome: false\n")
    team = load_team()
    (team.agents_dir / "roles" / "child.md").write_text(
        "---\nrole: child\nextends: base\nsettings: {b: child}\nenv: {Y: child}\n---\nУточнение.\n", encoding="utf-8")
    got = launch_fields(team, load_role(team, "child"))
    assert got["mcp"] == ["from_lib"] and got["chrome"] is True                          # роль библиотеки перекрыла defaults
    assert got["settings"] == {"a": "lib", "b": "child", "c": "d"}
    assert got["env"] == {"X": "lib", "Y": "child", "Z": "d"}
    assert got["plugins"] == {"off": ["lib@m"]}


def test_defaults_reject_unknown_fields(project, owner):
    team_yaml("defaults:\n  model: opus\n")
    with pytest.raises(TeamError, match="defaults"):
        load_team()


# --- team roles --json ---

def test_roles_json_shows_assembled_fields_without_server_definitions(project, owner, capsys):
    write_claude_json(owner, {"mcpServers": {"known": {"command": "k", "env": {"TOKEN": SECRET}}}})
    team_yaml("defaults:\n  chrome: false\n")
    role_fields("worker", "mcp: [known]\nplugins: {off: [a@m]}\nsettings: {k: v}\nenv: {E: '1'}")
    assert cli.main(["roles", "--json"]) == 0
    out = capsys.readouterr().out
    assert SECRET not in out
    worker = next(r for r in json.loads(out) if r["role"] == "worker")
    assert (worker["mcp"], worker["plugins"], worker["settings"], worker["chrome"], worker["env"]) == (
        ["known"], {"off": ["a@m"]}, {"k": "v"}, False, {"E": "1"})


# --- spawn ---

@pytest.mark.skipif(shutil.which("tmux") is None, reason="нет tmux")
def test_spawn_writes_mcp_file_and_passes_role_env(project, owner, monkeypatch):
    monkeypatch.setenv("TEAM_CLAUDE_BIN", "cat")
    team_yaml("mcp_servers:\n  t: {command: t}\n")
    role_fields("idle", "mcp: [t]\nenv: {FOO: bar}")
    seen = {}
    real = build.shell_command
    monkeypatch.setattr(cli.build, "shell_command", lambda argv, env: seen.update(env=env) or real(argv, env))
    cli.main(["spawn", "idle"])
    assert seen["env"]["FOO"] == "bar" and seen["env"]["TEAM_ROLE"] == "idle"
    assert (load_team().state_dir / "build" / "idle#1-mcp.json").is_file()


# --- вложенный worktree не читает бриф основного каталога ---

def _set_worktree_root(value):
    path = load_team().root / "agents" / "team.yaml"
    text = path.read_text(encoding="utf-8").replace("worktree_root: ../wt", f"worktree_root: {value}")
    path.write_text(text, encoding="utf-8")


def test_nested_worktree_excludes_parent_briefs(project, owner):
    _set_worktree_root(".claude/worktrees")
    repo = project.resolve()
    ex = settings_of()["claudeMdExcludes"]
    dirs = (repo, repo / ".claude", repo / ".claude" / "worktrees")
    want = [str(d / n) for d in dirs for n in ("CLAUDE.md", "CLAUDE.local.md", ".claude/CLAUDE.md")]
    assert ex == list(dict.fromkeys(want))                   # `.claude/CLAUDE.md` корня и `CLAUDE.md` каталога .claude — один файл
    assert str(repo / ".claude" / "CLAUDE.md") in ex
    assert str(repo.parent / "CLAUDE.md") not in ex           # выше репозитория бриф читается как прежде


def test_worktree_outside_repo_leaves_settings_alone(project, owner):
    assert "claudeMdExcludes" not in settings_of()            # worktree_root: ../wt


def test_role_without_worktree_leaves_settings_alone(project, owner):
    _set_worktree_root(".claude/worktrees")
    assert "claudeMdExcludes" not in settings_of("idle", "idle#1")


def test_nested_excludes_merge_with_role_settings(project, owner):
    _set_worktree_root("wt")
    role_fields("worker", 'settings: {claudeMdExcludes: ["/own/CLAUDE.md"], model: opus}')
    s = settings_of()
    assert s["claudeMdExcludes"][0] == "/own/CLAUDE.md" and str(project.resolve() / "CLAUDE.md") in s["claudeMdExcludes"]
    assert s["model"] == "opus"
