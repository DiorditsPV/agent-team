"""Открытый вопрос роли: хук PreToolUse/PostToolUse на AskUserQuestion и поле question в status --json."""
import json
import shlex
import shutil
import subprocess

import pytest

from agent_team import asks, build, cli
from agent_team.config import load_team, load_role

needs_tmux = pytest.mark.skipif(shutil.which("tmux") is None, reason="нет tmux")

QUESTIONS = [{
    "question": "Какую базу взять?", "header": "База", "multiSelect": False,
    "options": [{"label": "SQLite", "description": "Файл рядом", "preview": "db.sqlite"},
                {"label": "Postgres", "description": "Сервер"}],
}]


def _hook_input(event="PreToolUse", tool_use_id="toolu_01A", session_id="S1", transcript=None, **over):
    data = {"session_id": session_id, "transcript_path": str(transcript or "/nonexistent.jsonl"), "cwd": "/w",
            "hook_event_name": event, "tool_name": "AskUserQuestion",
            "tool_input": {"questions": QUESTIONS}, "tool_use_id": tool_use_id}
    data.update(over)
    return data


def _run_hook(command: str, stdin) -> subprocess.CompletedProcess:
    """Запуск ровно той строки, что лежит в настройках хука: так её запустит Claude Code."""
    text = stdin if isinstance(stdin, str) else json.dumps(stdin)
    return subprocess.run(command, shell=True, input=text, capture_output=True, text=True, timeout=10)


def _hook_command(settings_path, event="PreToolUse") -> str:
    settings = json.loads(settings_path.read_text(encoding="utf-8"))
    (entry,) = settings["hooks"][event]
    assert entry["matcher"] == "AskUserQuestion"
    (hook,) = entry["hooks"]
    assert hook["type"] == "command" and hook["timeout"] <= 10
    return hook["command"]


# --- настройки и запуск claude ---

def test_settings_hold_hooks_for_ask_user_question_and_disable_background(project):
    team = load_team()
    path = asks.write_settings(team, "worker#1")
    settings = json.loads(path.read_text(encoding="utf-8"))
    assert sorted(settings) == ["disableAgentView", "hooks", "statusLine"]   # statusLine — test_statusline.py
    assert settings["disableAgentView"] is True              # роль не уходит в фоновую задачу без промпта роли
    assert sorted(settings["hooks"]) == ["PostToolUse", "PreToolUse"]
    cmd = _hook_command(path)
    assert cmd == _hook_command(path, "PostToolUse")
    assert cmd.split()[0].startswith("/")                    # интерпретатор — абсолютный путь, PATH панели не нужен
    assert shlex.split(cmd)[-1] == str(asks.asks_dir(team, "worker#1"))


# --- хук ---

def test_pre_tool_use_writes_record_and_prints_nothing(project, tmp_path):
    team = load_team()
    transcript = tmp_path / "t.jsonl"
    transcript.write_text('{"type":"user"}\n', encoding="utf-8")
    cmd = _hook_command(asks.write_settings(team, "worker#1"))
    res = _run_hook(cmd, _hook_input(transcript=transcript))
    assert (res.returncode, res.stdout, res.stderr) == (0, "", "")
    rec = json.loads((asks.asks_dir(team, "worker#1") / "toolu_01A.json").read_text(encoding="utf-8"))
    assert rec["id"] == "toolu_01A" and rec["session_id"] == "S1"
    assert rec["transcript"] == str(transcript) and rec["offset"] == transcript.stat().st_size
    assert rec["tool_input"] == {"questions": QUESTIONS} and isinstance(rec["ts"], int)


def test_next_question_replaces_older_record(project):
    team = load_team()
    cmd = _hook_command(asks.write_settings(team, "worker#1"))
    _run_hook(cmd, _hook_input(tool_use_id="toolu_old"))
    _run_hook(cmd, _hook_input(tool_use_id="toolu_new"))
    assert sorted(p.name for p in asks.asks_dir(team, "worker#1").iterdir()) == ["toolu_new.json"]


def test_post_tool_use_removes_record(project):
    team = load_team()
    path = asks.write_settings(team, "worker#1")
    _run_hook(_hook_command(path), _hook_input())
    res = _run_hook(_hook_command(path, "PostToolUse"), _hook_input(event="PostToolUse"))
    assert (res.returncode, res.stdout) == (0, "")
    assert list(asks.asks_dir(team, "worker#1").iterdir()) == []


@pytest.mark.parametrize("stdin", [
    "", "[1, 2]",
    _hook_input(tool_name="Bash"),
    _hook_input(tool_use_id="../../escape"),
    _hook_input(tool_use_id=7),
    _hook_input(event="Stop"),
    _hook_input(tool_input="строка"),
])
def test_bad_input_is_skipped_silently(project, stdin):
    team = load_team()
    cmd = _hook_command(asks.write_settings(team, "worker#1"))
    res = _run_hook(cmd, stdin)
    assert (res.returncode, res.stdout, res.stderr) == (0, "", "")
    d = asks.asks_dir(team, "worker#1")
    assert not d.exists() or [p.name for p in d.iterdir()] == []
    assert not (d.parent.parent / "escape.json").exists()


def test_unwritable_store_is_skipped_silently(project):
    team = load_team()
    cmd = _hook_command(asks.write_settings(team, "worker#1"))
    d = asks.asks_dir(team, "worker#1")
    d.parent.mkdir(parents=True, exist_ok=True)
    d.write_text("файл на месте каталога", encoding="utf-8")
    res = _run_hook(cmd, _hook_input())
    assert (res.returncode, res.stdout, res.stderr) == (0, "", "")


# --- чтение открытого вопроса ---

def _record(team, key, tool_use_id="toolu_01A", session_id="S1", transcript=None, ts=100, tool_input=None):
    d = asks.asks_dir(team, key)
    d.mkdir(parents=True, exist_ok=True)
    offset = transcript.stat().st_size if transcript and transcript.exists() else 0
    rec = {"id": tool_use_id, "ts": ts, "session_id": session_id, "transcript": str(transcript or ""),
           "offset": offset, "tool_input": {"questions": QUESTIONS} if tool_input is None else tool_input}
    (d / f"{tool_use_id}.json").write_text(json.dumps(rec), encoding="utf-8")
    return d / f"{tool_use_id}.json"


def _tool_result(tool_use_id):
    return json.dumps({"type": "user", "message": {"role": "user", "content": [
        {"tool_use_id": tool_use_id, "type": "tool_result", "content": "User answered"}]}}, separators=(",", ":"))


def test_open_question_is_normalized(project, tmp_path):
    team = load_team()
    transcript = tmp_path / "t.jsonl"
    transcript.write_text('{"type":"user"}\n', encoding="utf-8")
    _record(team, "worker#1", transcript=transcript)
    q = asks.open_question(team, "worker#1", "S1")
    assert q == {"id": "toolu_01A", "ts": 100, "questions": [{
        "question": "Какую базу взять?", "header": "База", "multiSelect": False,
        "options": [{"label": "SQLite", "description": "Файл рядом", "preview": "db.sqlite"},
                    {"label": "Postgres", "description": "Сервер"}]}]}


def test_missing_fields_get_defaults(project):
    team = load_team()
    _record(team, "worker#1", tool_input={"questions": [{"question": "Да?", "options": [{"label": "Да"}, "мусор"]},
                                                        "мусор"]})
    q = asks.open_question(team, "worker#1", "S1")
    assert q["questions"] == [{"question": "Да?", "header": "", "multiSelect": False,
                               "options": [{"label": "Да", "description": ""}]}]


def test_closed_call_hides_question_but_keeps_file(project, tmp_path):
    team = load_team()
    transcript = tmp_path / "t.jsonl"
    transcript.write_text(_tool_result("toolu_01A") + "\n", encoding="utf-8")   # до смещения: не считается
    path = _record(team, "worker#1", transcript=transcript)
    assert asks.open_question(team, "worker#1", "S1") is not None
    with transcript.open("a", encoding="utf-8") as fh:
        fh.write(_tool_result("toolu_other") + "\n")
    assert asks.open_question(team, "worker#1", "S1") is not None
    with transcript.open("a", encoding="utf-8") as fh:
        fh.write(_tool_result("toolu_01A") + "\n")
    assert asks.open_question(team, "worker#1", "S1") is None
    assert path.exists()                                    # status только читает


def test_other_session_hides_question_but_keeps_file(project):
    team = load_team()
    path = _record(team, "worker#1", session_id="S1")
    assert asks.open_question(team, "worker#1", "S2") is None
    assert path.exists()


def test_latest_record_wins_and_empty_questions_are_none(project):
    team = load_team()
    _record(team, "worker#1", tool_use_id="toolu_a", ts=100)
    _record(team, "worker#1", tool_use_id="toolu_b", ts=200)
    assert asks.open_question(team, "worker#1", "S1")["id"] == "toolu_b"
    _record(team, "idle#1", tool_input={"questions": []})
    assert asks.open_question(team, "idle#1", "S1") is None
    assert asks.open_question(team, "boss#1", "S1") is None


# --- status --json, spawn и down ---

@needs_tmux
def test_status_shows_question_only_while_waiting_and_until_down(project, capsys, monkeypatch):
    cli.main(["up"])
    team = load_team()
    sid = cli.load_state(team)["worker#1"]["session_id"]
    assert not asks.asks_dir(team, "worker#1").exists()
    _record(team, "worker#1", session_id=sid)

    def agents():
        capsys.readouterr()
        cli.main(["status", "--json"])
        return {a["name"]: a for a in json.loads(capsys.readouterr().out)["agents"]}

    assert agents()["worker#1"]["question"]["id"] == "toolu_01A"
    assert agents()["boss#1"]["question"] is None
    real_lookup = cli.sessions.lookup
    for status, shown in (("busy", False), ("idle", False), ("waiting", True)):       # вопрос виден, только пока агент ждёт
        monkeypatch.setattr(cli.sessions, "lookup", lambda *a, _s=status: {"sessionId": sid, "status": _s, "statusUpdatedAt": 0})
        assert (agents()["worker#1"]["question"] is not None) is shown, status
    monkeypatch.setattr(cli.sessions, "lookup", real_lookup)
    cli.main(["down", "worker"])
    assert list(asks.asks_dir(team, "worker#1").iterdir()) == []
    assert agents()["worker#1"]["question"] is None


@needs_tmux
def test_spawn_clears_old_records(project):
    team = load_team()
    path = _record(team, "worker#1")
    assert cli.main(["spawn", "worker"]) == 0
    assert not path.exists()
    assert (team.state_dir / "build" / "worker#1-settings.json").is_file()
