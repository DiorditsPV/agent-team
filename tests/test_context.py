"""Порог контекста роли: ctx и compactions в status, флаги сброса, поле context, handoff и restart --fresh."""
import json
import shutil
import time

import pytest

from agent_team import build, cli, tmuxctl, transcripts
from agent_team.config import TeamError, context_limits, load_role, load_team

needs_tmux = pytest.mark.skipif(shutil.which("tmux") is None, reason="нет tmux")


def usage(inp=2, create=0, read=0, iterations=None):
    u = {"input_tokens": inp, "cache_creation_input_tokens": create, "cache_read_input_tokens": read, "output_tokens": 5}
    if iterations is not None:
        u["iterations"] = iterations
    return u


def assistant(u, **extra):
    return json.dumps({"type": "assistant", "message": {"role": "assistant", "usage": u}, **extra}, separators=(",", ":"))


# --- ctx из usage ---

def test_context_is_sum_of_input_and_caches():
    assert transcripts.usage_context(usage(2, 145, 145581)) == 145728


def test_iterations_without_advisor_use_the_message_iteration():
    its = [{"type": "message", "input_tokens": 2, "cache_creation_input_tokens": 145, "cache_read_input_tokens": 145581}]
    assert transcripts.usage_context(usage(2, 145, 145581, its)) == 145728


def test_advisor_turn_takes_last_message_iteration_not_the_sum():
    """Снято с реальной записи: сводка складывает исполнителя и советника (176917 в кеше), а контекст — последняя итерация."""
    its = [{"type": "message", "input_tokens": 2, "cache_read_input_tokens": 87047, "cache_creation_input_tokens": 2823},
           {"type": "advisor_message", "input_tokens": 91105, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0},
           {"type": "message", "input_tokens": 2, "cache_read_input_tokens": 89870, "cache_creation_input_tokens": 1445}]
    top = usage(4, 4268, 176917, its)
    assert transcripts.usage_context(top) == 2 + 89870 + 1445
    assert transcripts.usage_context(top) != 4 + 4268 + 176917


def test_iterations_without_message_type_fall_back_to_usage():
    assert transcripts.usage_context(usage(1, 2, 3, [{"type": "advisor_message", "input_tokens": 99}])) == 6


def test_empty_usage_is_none():
    assert transcripts.usage_context(usage(0, 0, 0)) is None


# --- хвостовое чтение ---

def _write(path, lines):
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def test_last_context_takes_the_last_assistant_record(tmp_path):
    f = tmp_path / "s.jsonl"
    _write(f, [assistant(usage(1, 0, 1000)), json.dumps({"type": "user"}), assistant(usage(1, 0, 2000)),
               json.dumps({"type": "system", "subtype": "turn_duration"})])
    assert transcripts.last_context(f) == 2001


def test_last_context_skips_synthetic_zero_sidechain_and_broken_lines(tmp_path):
    f = tmp_path / "s.jsonl"
    _write(f, [assistant(usage(1, 0, 5000)), assistant(usage(1, 0, 9000), isSidechain=True),
               assistant(usage(0, 0, 0)), '{"type":"assistant","message":{"usage": broken', ""])
    assert transcripts.last_context(f) == 5001


def test_last_context_reads_the_tail_not_the_whole_file(tmp_path, monkeypatch):
    f = tmp_path / "s.jsonl"
    filler = json.dumps({"type": "user", "message": {"content": "x" * 5000}})
    _write(f, [assistant(usage(1, 0, 111))] + [filler] * 600 + [assistant(usage(1, 0, 222))] + [filler] * 10)
    monkeypatch.setattr(transcripts, "READ_BLOCK", 4096)
    monkeypatch.setattr(transcripts, "MAX_TAIL", 200_000)              # старая запись дальше предела: хвост её не достаёт
    assert transcripts.last_context(f) == 223
    f2 = tmp_path / "t.jsonl"
    _write(f2, [assistant(usage(1, 0, 111))] + [filler] * 600)
    assert transcripts.last_context(f2) is None                          # дальше MAX_TAIL от конца не ищем


def test_record_longer_than_one_block_is_read_whole(tmp_path, monkeypatch):
    f = tmp_path / "s.jsonl"
    big = json.dumps({"type": "assistant", "message": {"usage": usage(3, 0, 777), "content": "я" * 50_000}})
    _write(f, [json.dumps({"type": "user"}), big])
    monkeypatch.setattr(transcripts, "READ_BLOCK", 1024)
    assert transcripts.last_context(f) == 780


def test_last_context_missing_file_and_none(tmp_path):
    assert transcripts.last_context(tmp_path / "нет.jsonl") is None
    assert transcripts.last_context(None) is None


# --- compactions ---

def boundary():
    return json.dumps({"type": "system", "subtype": "compact_boundary", "content": "Conversation compacted"}, separators=(",", ":"))


def test_compactions_are_counted(tmp_path):
    f = tmp_path / "s.jsonl"
    _write(f, [boundary(), assistant(usage(1, 0, 5)), boundary()])
    assert transcripts.count_compactions(f) == 2


def test_compactions_ignore_quoted_marker_in_text(tmp_path):
    f = tmp_path / "s.jsonl"
    quoted = json.dumps({"type": "user", "message": {"content": 'запись {"subtype":"compact_boundary"} в тексте'}})
    _write(f, [quoted, boundary()])
    assert transcripts.count_compactions(f) == 1


def test_compactions_counted_across_block_boundary(tmp_path, monkeypatch):
    f = tmp_path / "s.jsonl"
    monkeypatch.setattr(transcripts, "READ_BLOCK", 16)                 # блок 128 байт: метки попадают на стыки
    _write(f, [boundary() for _ in range(7)] + ["x" * 37, boundary()])
    assert transcripts.count_compactions(f) == 8


def test_compactions_none_for_missing(tmp_path):
    assert transcripts.count_compactions(None) is None
    assert transcripts.count_compactions(tmp_path / "нет") is None


# --- поле context ---

def _yaml(repo, text):
    p = repo / "agents" / "team.yaml"
    p.write_text(p.read_text(encoding="utf-8") + text, encoding="utf-8")


def _role_field(repo, name, line):
    p = repo / "agents" / "roles" / f"{name}.md"
    p.write_text(p.read_text(encoding="utf-8").replace("\n---\n", f"\n{line}\n---\n", 1), encoding="utf-8")


def test_default_limits(project):
    team = load_team()
    assert context_limits(team, load_role(team, "worker")) == {"soft": 250000, "warn": 400000, "hard": 500000}


def test_limits_from_defaults_and_role_override_by_key(project):
    _yaml(project, "defaults:\n  context: {soft: 200000, warn: 300000}\n")
    _role_field(project, "worker", "context: {soft: 150000}")
    team = load_team()
    assert context_limits(team, load_role(team, "worker")) == {"soft": 150000, "warn": 300000, "hard": 500000}
    assert context_limits(team, load_role(team, "boss")) == {"soft": 200000, "warn": 300000, "hard": 500000}


@pytest.mark.parametrize("value", ["{soft: 0}", "{soft: abc}", "{soft: true}", "{limit: 5}", "[1, 2]"])
def test_bad_context_values_are_errors(project, value):
    _role_field(project, "worker", f"context: {value}")
    team = load_team()
    with pytest.raises(TeamError, match="context"):
        context_limits(team, load_role(team, "worker"))


@pytest.mark.parametrize("value", ["{soft: 300000, warn: 200000}", "{soft: 400000}", "{hard: 390000}"])
def test_bad_limit_order_is_an_error(project, value):
    _role_field(project, "worker", f"context: {value}")
    team = load_team()
    with pytest.raises(TeamError, match="soft < warn <= hard"):
        context_limits(team, load_role(team, "worker"))


@pytest.mark.parametrize("value", ["{hard: 50000}", "{hard: 99999}", "{hard: 1000001}", "{hard: 2000000}"])
def test_hard_outside_range_names_the_range(project, value):
    """hard вне диапазона даёт сообщение про диапазон, а не про порядок порогов, даже когда ломает и порядок."""
    _role_field(project, "worker", f"context: {value}")
    team = load_team()
    with pytest.raises(TeamError, match="context.hard — от 100000 до 1000000"):
        context_limits(team, load_role(team, "worker"))


def test_limit_boundaries(project):
    _role_field(project, "worker", "context: {soft: 100000, warn: 100001, hard: 100001}")      # warn == hard допустимо
    team = load_team()
    assert context_limits(team, load_role(team, "worker")) == {"soft": 100000, "warn": 100001, "hard": 100001}
    _role_field(project, "boss", "context: {hard: 100000, warn: 100000, soft: 99999}")        # нижняя граница hard — включая
    assert context_limits(team, load_role(team, "boss"))["hard"] == 100000
    _role_field(project, "idle", "context: {soft: 300000, warn: 300000}")                      # soft == warn — ошибка
    with pytest.raises(TeamError, match="soft < warn"):
        context_limits(team, load_role(team, "idle"))


def test_check_reports_bad_context(project, capsys):
    _role_field(project, "worker", "context: {soft: 300000, warn: 200000}")
    assert cli.main(["check"]) == 1
    assert "soft < warn" in capsys.readouterr().out


def test_hard_goes_to_claude_as_autocompact_window(project, monkeypatch):
    _role_field(project, "worker", "context: {hard: 450000}")
    captured = {}
    monkeypatch.setattr(build, "shell_command", lambda argv, env: captured.update(env) or "cat")
    cli.main(["spawn", "worker"])
    assert captured["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] == "450000"


@pytest.mark.both_layouts
def test_project_env_cannot_override_compact_window(project, monkeypatch, capsys):
    _role_field(project, "worker", "env: {CLAUDE_CODE_AUTO_COMPACT_WINDOW: '999999'}")
    captured = {}
    monkeypatch.setattr(build, "shell_command", lambda argv, env: captured.update(env) or "cat")
    cli.main(["spawn", "worker"])
    assert captured["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] == "500000"
    cli.main(["check"])
    assert "CLAUDE_CODE_AUTO_COMPACT_WINDOW" in capsys.readouterr().out


# --- флаги в status --json ---

def _agent(**over):
    a = {"alive": True, "state": "idle", "dirty": [], "pane_id": None, "role_check": {"ok": True}}
    a.update(over)
    return a


@pytest.fixture
def ctx_env(project, monkeypatch):
    team = load_team()
    role = load_role(team, "worker")
    box = {"ctx": 300_000, "screen": ""}
    monkeypatch.setattr(cli.transcripts, "last_context", lambda path: box["ctx"])
    monkeypatch.setattr(cli.transcripts, "count_compactions", lambda path: 2)
    monkeypatch.setattr(cli.tmuxctl, "capture", lambda *a, **k: box["screen"])
    return team, role, box


def test_idle_above_soft_is_reset_due_and_ready(ctx_env):
    team, role, _ = ctx_env
    r = cli.context_state(team, role, _agent(), None)
    assert r["ctx"] == 300_000 and r["compactions"] == 2
    assert r["reset_due"] is True and r["reset_ready"] is True and r["reset_blockers"] == []
    assert r["context_warning"] is False and r["ctx_limits"]["soft"] == 250000


def test_below_soft_is_not_due(ctx_env):
    team, role, box = ctx_env
    box["ctx"] = 250_000                                                # порог строгий: ровно soft — ещё не сброс
    r = cli.context_state(team, role, _agent(), None)
    assert r["reset_due"] is False and r["reset_ready"] is None


def test_busy_is_never_due_but_warns_above_warn(ctx_env):
    team, role, box = ctx_env
    assert cli.context_state(team, role, _agent(state="busy"), None)["reset_due"] is False
    assert cli.context_state(team, role, _agent(state="busy"), None)["context_warning"] is False   # 300k < warn
    box["ctx"] = 450_000
    r = cli.context_state(team, role, _agent(state="busy"), None)
    assert r["context_warning"] is True and r["reset_due"] is False
    assert cli.context_state(team, role, _agent(state="idle"), None)["context_warning"] is False   # warn только при работе


def test_dirty_worktree_blocks_reset(ctx_env):
    team, role, _ = ctx_env
    r = cli.context_state(team, role, _agent(dirty=[" M src/a.py", "?? new.txt"]), None)
    assert r["reset_due"] is True and r["reset_ready"] is False
    assert any("worktree грязный" in b for b in r["reset_blockers"])


def test_junk_in_worktree_does_not_block(ctx_env):
    team, role, _ = ctx_env
    junk = ["app/.DS_Store", "src/__pycache__/x.pyc", ".team/state.json", "a.swp"]
    r = cli.context_state(team, role, _agent(dirty=junk), None)
    assert r["reset_ready"] is True


@pytest.mark.both_layouts
def test_open_dialog_blocks_reset(ctx_env):
    team, role, box = ctx_env
    box["screen"] = "Do you want to proceed?\n❯ 1. Yes\n  2. No"
    r = cli.context_state(team, role, _agent(pane_id="%1"), None)
    assert r["reset_ready"] is False and "в панели открыт диалог" in r["reset_blockers"]


def test_foreign_session_blocks_reset(ctx_env):
    team, role, _ = ctx_env
    r = cli.context_state(team, role, _agent(role_check={"ok": False, "reason": "background"}), None)
    assert r["reset_ready"] is False


def test_stopped_agent_has_no_context(ctx_env):
    team, role, _ = ctx_env
    r = cli.context_state(team, role, _agent(alive=False), None)
    assert r["ctx"] is None and r["compactions"] is None and r["reset_due"] is False


def test_no_transcript_means_no_flags(ctx_env):
    team, role, box = ctx_env
    box["ctx"] = None
    r = cli.context_state(team, role, _agent(), None)
    assert r["ctx"] is None and r["reset_due"] is False and r["context_warning"] is False


@needs_tmux
@pytest.mark.both_layouts
def test_status_json_and_text_end_to_end(project, tmp_path, monkeypatch, capsys):
    cli.main(["up"])
    team = load_team()
    st = cli.load_state(team)["worker#1"]
    d = transcripts.projects_dir() / transcripts.slug(st["cwd"])
    d.mkdir(parents=True, exist_ok=True)
    _write(d / f"{st['session_id']}.jsonl", [assistant(usage(2, 1000, 299_000)), boundary()])
    reg = tmp_path / "sessions"
    reg.mkdir()
    live = tmuxctl.panes(team.session)
    (reg / f"{live['worker#1'].pid}.json").write_text(json.dumps(
        {"pid": live["worker#1"].pid, "status": "idle", "statusUpdatedAt": int(time.time() * 1000) - 5000}), encoding="utf-8")
    monkeypatch.setenv("TEAM_SESSIONS_DIR", str(reg))
    capsys.readouterr()
    cli.main(["status", "--json"])
    w = {a["name"]: a for a in json.loads(capsys.readouterr().out)["agents"]}["worker#1"]
    assert w["ctx"] == 300_002 and w["compactions"] == 1 and w["reset_due"] is True
    cli.main(["status"])
    row = next(l for l in capsys.readouterr().out.splitlines() if l.startswith("worker#1"))
    assert "300k" in row and "сброс" in row


def test_ctx_cell_formatting():
    assert cli._ctx_cell({"ctx": None}) == "-"
    assert cli._ctx_cell({"ctx": 312_400, "reset_due": False, "context_warning": False}) == "312k"
    assert cli._ctx_cell({"ctx": 312_400, "reset_due": True, "reset_ready": True, "context_warning": False}) == "312k сброс"
    assert cli._ctx_cell({"ctx": 312_400, "reset_due": True, "reset_ready": False, "context_warning": False}) == "312k сброс*"
    assert cli._ctx_cell({"ctx": 450_000, "reset_due": False, "context_warning": True}) == "450k !"


# --- handoff на грязном worktree и restart --fresh ---

@needs_tmux
@pytest.mark.both_layouts
def test_handoff_refuses_dirty_worktree_and_force_overrides(project, capsys):
    cli.main(["up"])
    team = load_team()
    cwd = cli.load_state(team)["worker#1"]["cwd"]
    (__import__("pathlib").Path(cwd) / "несохранённое.txt").write_text("работа", encoding="utf-8")
    capsys.readouterr()
    assert cli.main(["handoff", "worker"]) == 1
    err = capsys.readouterr().err
    assert "грязный" in err and "несохранённое.txt" in err and "--force" in err
    assert not (team.state_dir / "handoffs").exists() or not list((team.state_dir / "handoffs").glob("*.md"))
    assert cli.main(["handoff", "worker", "--force", "--paste"]) == 0
    assert list((team.state_dir / "handoffs").glob("*.md"))


def test_handoff_changes_ignore_junk_but_keep_real_changes(project):
    from pathlib import Path
    team = load_team()
    (project / ".DS_Store").write_text("x", encoding="utf-8")
    (project / "__pycache__").mkdir()
    (project / "__pycache__" / "m.pyc").write_text("x", encoding="utf-8")
    assert cli.handoff_changes(team, "worker", Path(project)) == []
    (project / "работа.txt").write_text("x", encoding="utf-8")
    assert cli.handoff_changes(team, "worker", Path(project)) == ["работа.txt"]


@needs_tmux
def test_restart_prints_address_and_last_handoff_only_for_fresh(project, capsys, monkeypatch):
    cli.main(["up"])
    team = load_team()
    capsys.readouterr()
    cli.main(["restart", "worker"])                                  # обычный restart адреса не печатает
    assert "адрес для SendMessage" not in capsys.readouterr().out
    monkeypatch.setattr(cli, "role_address", lambda team, key: None)
    assert cli.main(["restart", "worker", "--fresh"]) == 0           # адреса и передачи нет
    out = capsys.readouterr().out
    assert "пока не зарегистрирован" in out and "team addr worker#1" in out
    assert "файла передачи у роли нет" in out
    cli.main(["handoff", "worker", "--paste"])
    path = next((team.state_dir / "handoffs").glob("*.md"))
    monkeypatch.setattr(cli, "role_address", lambda team, key: "uds:/tmp/cc-socks/777.sock")
    capsys.readouterr()
    assert cli.main(["restart", "worker", "--fresh"]) == 0           # есть и адрес, и передача
    out = capsys.readouterr().out
    assert "адрес для SendMessage: uds:/tmp/cc-socks/777.sock" in out
    assert f"последняя передача: {path}" in out


# --- handoff: роль без своего worktree ---

def test_handoff_changes_ignore_untracked_config_dirs_for_role_without_worktree(project):
    from pathlib import Path
    team = load_team()
    (project / ".claude").mkdir()
    (project / ".claude" / "settings.local.json").write_text("{}", encoding="utf-8")
    (project / "agents" / "newdir").mkdir()
    (project / "agents" / "newdir" / "x.md").write_text("x", encoding="utf-8")
    assert cli.handoff_changes(team, "boss", Path(project)) == []
    # другим ролям (со своим worktree) неотслеживаемое не прощается
    assert cli.handoff_changes(team, "worker", Path(project))


def test_handoff_changes_keep_tracked_and_foreign_changes_for_role_without_worktree(project):
    from pathlib import Path
    team = load_team()
    (project / ".claude").mkdir()
    (project / ".claude" / "a.json").write_text("{}", encoding="utf-8")
    boss = project / "agents" / "roles" / "boss.md"
    boss.write_text(boss.read_text(encoding="utf-8") + "\nправка\n", encoding="utf-8")
    (project / "код.py").write_text("x", encoding="utf-8")
    changed = cli.handoff_changes(team, "boss", Path(project))
    assert "agents/roles/boss.md" in changed and "код.py" in changed
    assert not any(p.startswith(".claude") for p in changed)


def test_handoff_changes_take_agents_dir_from_config(project):
    from pathlib import Path
    team = load_team()
    assert cli._config_prefixes(team, Path(project)) == [".claude/", "agents/"]
