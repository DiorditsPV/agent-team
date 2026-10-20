"""Сессия живого агента после /clear: запись ~/.claude/sessions по pid панели главнее цепочки continued-in.

Панель подменная (tmuxctl.Pane), записи сессий и транскрипты — во временных каталогах; claude и tmux не нужны.
"""
import json

import pytest

from agent_team import cli, tmuxctl, transcripts
from agent_team.config import load_team

CWD = "/w/p"


@pytest.fixture
def env(project, tmp_path, monkeypatch):
    monkeypatch.setenv("TEAM_PROJECTS_DIR", str(tmp_path / "projects"))
    reg = tmp_path / "sessions"
    reg.mkdir()
    monkeypatch.setenv("TEAM_SESSIONS_DIR", str(reg))
    team = load_team()
    cli.save_state(team, {"worker#1": {"session_id": "s1", "cwd": CWD, "started": 1, "instruction": "x"}})
    return team, reg


def _transcript(sid: str, next_sid: str | None = None) -> None:
    d = transcripts.projects_dir() / transcripts.slug(CWD)
    d.mkdir(parents=True, exist_ok=True)
    lines = [json.dumps({"type": "user", "sessionId": sid})]
    if next_sid:
        lines.append(json.dumps({"type": "continued-in", "sessionId": sid, "continuedInSessionId": next_sid}))
    (d / f"{sid}.jsonl").write_text("\n".join(lines) + "\n", encoding="utf-8")


def _record(reg, pid, **fields) -> None:
    (reg / f"{pid}.json").write_text(json.dumps({"pid": pid, **fields}), encoding="utf-8")


def _pane(dead=False):
    return tmuxctl.Pane(id="%1", role="worker#1", window="w", index=1, dead=dead, activity=0, command="claude", pid=4242)


def _state(team):
    return cli.load_state(team)["worker#1"]


def test_no_record_follows_continued_in_chain(env):
    team, _ = env
    _transcript("s1", "s3")
    _transcript("s3")
    sid, _ = cli.live_session(team, "worker#1", _pane())
    assert sid == "s3"
    assert _state(team)["session_id"] == "s1"          # цепочка state не меняет


def test_record_session_without_transcript_falls_back_to_chain(env):
    team, reg = env
    _transcript("s1")
    _record(reg, 4242, sessionId="fresh-no-file")
    assert cli.live_session(team, "worker#1", _pane())[0] == "s1"
    assert _state(team)["session_id"] == "s1"


def test_dead_pane_ignores_record(env):
    team, reg = env
    _transcript("s1")
    _transcript("s2")
    _record(reg, 4242, sessionId="s2")
    assert cli.live_session(team, "worker#1", _pane(dead=True))[0] == "s1"
    assert cli.live_session(team, "worker#1", None)[0] == "s1"


def test_parked_job_record_defines_session(env):
    team, reg = env
    _transcript("s1")
    _transcript("job-s")
    _record(reg, 4242, sessionId="s1", parkedJobId="j1")
    _record(reg, 999_999, sessionId="job-s", kind="bg", jobId="j1")
    assert cli.live_session(team, "worker#1", _pane())[0] == "job-s"


def test_agent_info_reports_new_session_and_keeps_launch(env):
    team, reg = env
    _transcript("s1")
    _transcript("s2")
    _record(reg, 4242, sessionId="s2", status="idle", statusUpdatedAt=1000)
    role = cli.load_role(team, "worker")
    info = cli.agent_info(team, role, 1, _pane(), cli.load_state(team), 2000)
    assert info["session_id"] == "s2" and info["launch_session_id"] == "s1"
    assert info["transcript"].endswith("s2.jsonl")
    info = cli.agent_info(team, role, 1, _pane(), cli.load_state(team), 2000)
    assert info["session_id"] == "s2" and info["launch_session_id"] == "s1"


def test_second_clear_keeps_original_launch(env):
    team, reg = env
    for s in ("s1", "s2", "s3"):
        _transcript(s)
    _record(reg, 4242, sessionId="s2")
    sid, path = cli.live_session(team, "worker#1", _pane())          # запись без continued-in главнее цепочки
    assert sid == "s2" and path.name == "s2.jsonl"
    st = _state(team)
    assert st["session_id"] == "s2" and st["launch_session_id"] == "s1"
    _record(reg, 4242, sessionId="s3")
    assert cli.live_session(team, "worker#1", _pane())[0] == "s3"
    st = _state(team)
    assert st["session_id"] == "s3" and st["launch_session_id"] == "s1"
