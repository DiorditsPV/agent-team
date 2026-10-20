"""Лента событий, команда log и хранение передач."""
import json
import shutil

import pytest

from agent_team import cli, handoffs
from agent_team.config import load_team

needs_tmux = pytest.mark.skipif(shutil.which("tmux") is None, reason="нет tmux")


def fill_first(team, agent="worker#1"):
    path = next(handoffs.handoffs_dir(team).glob(f"*-{agent}.md"))
    path.write_text(path.read_text(encoding="utf-8").replace("## Сделано\n", "## Сделано\n\nготово\n", 1), encoding="utf-8")


def run_json(capsys, *argv):
    capsys.readouterr()
    assert cli.main(list(argv)) == 0
    return json.loads(capsys.readouterr().out)


def test_log_and_events_json_newest_first_since_limit(project, capsys):
    assert cli.main(["log", "task", "worker", "взял", "задачу", "--task", "TASK-1"]) == 0
    assert cli.main(["log", "report", "worker#2", "готово"]) == 0
    assert cli.main(["log", "owner", "owner", "стоп"]) == 0
    evs = run_json(capsys, "events", "--json")
    assert [e["type"] for e in evs] == ["owner", "report", "task"]       # новые первыми
    assert evs[2] == {"ts": evs[2]["ts"], "type": "task", "agent": "worker#1", "text": "взял задачу", "task": "TASK-1"}
    assert evs[1]["agent"] == "worker#2" and evs[1]["task"] is None
    assert evs[0]["agent"] == "owner"
    assert len(run_json(capsys, "events", "--json", "--limit", "2")) == 2
    assert run_json(capsys, "events", "--json", "--since", str(evs[0]["ts"] + 10)) == []
    assert len(run_json(capsys, "events", "--json", "--since", str(evs[0]["ts"]))) == 3


def test_log_rejects_unknown_type(project, capsys):
    assert cli.main(["log", "bogus", "worker", "x"]) == 1
    assert "допустимы" in capsys.readouterr().err


@needs_tmux
@pytest.mark.both_layouts
def test_cli_writes_spawn_restart_down_handoff_events(project, capsys):
    cli.main(["spawn", "worker"])
    cli.main(["restart", "worker", "--fresh"])
    cli.main(["handoff", "worker", "--task", "TASK-2"])
    cli.main(["down", "worker"])
    evs = run_json(capsys, "events", "--json")
    types = [e["type"] for e in reversed(evs)]
    assert types == ["spawn", "restart", "handoff", "down"]
    assert {e["agent"] for e in evs} == {"worker#1"}
    assert evs[1]["task"] == "TASK-2"


@needs_tmux
@pytest.mark.both_layouts
def test_handoff_creates_template_file_and_lists_it(project, capsys):
    cli.main(["spawn", "worker"])
    capsys.readouterr()
    assert cli.main(["handoff", "worker", "--task", "TASK-3", "--reason", "контекст полон", "--paste"]) == 0
    team = load_team()
    files = list((team.state_dir / "handoffs").glob("*-worker#1.md"))
    assert len(files) == 1
    text = files[0].read_text(encoding="utf-8")
    for title in ("Сделано", "Проверено", "В работе", "Подводные камни", "Дальше"):
        assert f"## {title}" in text
    assert str(files[0]) in capsys.readouterr().out
    # роль заполняет файл
    files[0].write_text(text.replace("## Сделано\n", "## Сделано\n\nсделал A\n").replace("## Дальше\n", "## Дальше\n\nшаг 1\n"),
                        encoding="utf-8")
    items = run_json(capsys, "handoffs", "--json")
    assert len(items) == 1
    h = items[0]
    assert h["id"] == files[0].stem and h["agent"] == "worker#1" and h["status"] == "waiting"
    assert h["task"] == "TASK-3" and h["reason"] == "контекст полон" and isinstance(h["ts"], int)
    assert h["worktree"].endswith("/worker") and h["branch"] == "worker"
    assert h["sections"] == {"done": "сделал A", "verified": "", "in_progress": "", "pitfalls": "", "next": "шаг 1"}


@needs_tmux
def test_restart_fresh_marks_last_handoff_used(project, capsys):
    cli.main(["spawn", "worker"])
    cli.main(["handoff", "worker", "--paste"])
    fill_first(load_team())                              # заполненная передача повтором не затирается
    cli.main(["handoff", "worker#1", "--paste"])
    cli.main(["restart", "worker", "--fresh"])
    items = run_json(capsys, "handoffs", "--json")
    assert [h["status"] for h in items] == ["used", "waiting"]       # новые первыми; использована последняя
    assert isinstance(items[0]["used_at"], int) and items[1]["used_at"] is None


def test_mark_last_used_ignores_other_agents(project):
    team = load_team()
    handoffs.create(team, "worker#2", None, None, None, None)
    assert handoffs.mark_last_used(team, "worker#1") is None
    assert handoffs.list_all(team)[0]["status"] == "waiting"


def test_used_at_written_to_frontmatter_and_listed(project):
    team = load_team()
    handoffs.create(team, "worker#1", None, None, None, None)
    handoffs.create(team, "other#1", None, None, None, None)
    before = int(__import__("time").time())
    hid = handoffs.mark_last_used(team, "worker#1")
    items = {h["id"]: h for h in handoffs.list_all(team)}
    used = items[hid]
    assert used["status"] == "used" and before <= used["used_at"] <= before + 5
    assert "used_at: " in (handoffs.handoffs_dir(team) / f"{hid}.md").read_text(encoding="utf-8")
    others = [h for h in items.values() if h["agent"] == "other#1"]
    assert others[0]["status"] == "waiting" and others[0]["used_at"] is None


def test_repeated_handoff_reuses_empty_waiting_file(project):
    team = load_team()
    first, again1 = handoffs.reuse_or_create(team, "worker#1", None, None, "b1", "/w1")
    second, again2 = handoffs.reuse_or_create(team, "worker#1", "TASK-7", "контекст", "b2", "/w2")
    assert (again1, again2) == (False, True) and first == second
    items = handoffs.list_all(team)
    assert len(items) == 1 and items[0]["status"] == "waiting"
    assert (items[0]["task"], items[0]["reason"], items[0]["branch"], items[0]["worktree"]) == ("TASK-7", "контекст", "b2", "/w2")
    assert "# Передача worker#1" in first.read_text(encoding="utf-8")             # тело файла сохранено


def test_repeated_handoff_keeps_task_when_not_given(project):
    team = load_team()
    handoffs.reuse_or_create(team, "worker#1", "TASK-7", "r", None, None)
    handoffs.reuse_or_create(team, "worker#1", None, None, None, None)
    assert (handoffs.list_all(team)[0]["task"], handoffs.list_all(team)[0]["reason"]) == ("TASK-7", "r")


def test_handoff_after_filled_or_used_file_creates_new(project):
    team = load_team()
    first, _ = handoffs.reuse_or_create(team, "worker#1", None, None, None, None)
    fill_first(team)
    second, again = handoffs.reuse_or_create(team, "worker#1", None, None, None, None)
    assert not again and second != first
    handoffs.mark_last_used(team, "worker#1")
    third, again = handoffs.reuse_or_create(team, "worker#1", None, None, None, None)
    assert not again and third not in (first, second)


def test_repeated_handoff_ignores_other_agents_files(project):
    team = load_team()
    handoffs.reuse_or_create(team, "other#1", None, None, None, None)
    path, again = handoffs.reuse_or_create(team, "worker#1", None, None, None, None)
    assert not again and len(handoffs.list_all(team)) == 2


@needs_tmux
def test_handoff_retry_after_missing_address_writes_same_file(project, capsys):
    cli.main(["spawn", "worker"])
    assert cli.main(["handoff", "worker"]) == 1                    # адреса нет → ошибка, файл создан
    assert cli.main(["handoff", "worker", "--paste"]) == 0         # повтор запасным путём
    items = run_json(capsys, "handoffs", "--json")
    assert len(items) == 1 and items[0]["status"] == "waiting"
    texts = [e["text"] for e in run_json(capsys, "events", "--json") if e["type"] == "handoff"]
    assert any("повторный запрос" in t for t in texts)


def test_events_and_handoffs_text_output(project, capsys):
    team = load_team()
    cli.main(["log", "task", "worker", "взял задачу", "--task", "TASK-1"])
    handoffs.create(team, "worker#1", "TASK-1", None, None, None)
    capsys.readouterr()
    assert cli.main(["events"]) == 0
    line = capsys.readouterr().out.strip()
    assert line.split()[1:3] == ["task", "worker#1"] and line.endswith("взял задачу")
    assert cli.main(["handoffs"]) == 0
    row = capsys.readouterr().out.split()
    assert row[1:] == ["waiting", "TASK-1"] and row[0].endswith("-worker#1")


def test_broken_line_in_events_file_is_skipped(project, capsys):
    team = load_team()
    cli.main(["log", "report", "worker", "первое"])
    with cli._events_path(team).open("a", encoding="utf-8") as f:
        f.write("{обрыв записи\n")
    cli.main(["log", "report", "worker", "второе"])
    assert [e["text"] for e in run_json(capsys, "events", "--json")] == ["второе", "первое"]
