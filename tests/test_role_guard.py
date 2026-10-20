"""Проверка роли: разговор агента ведёт процесс панели с файлом роли, а не фоновая задача Claude Code без него.

Записи сессий и процессы — подменные: реальный claude не запускается. Фоновую задачу изображает процесс python,
в командной строке которого есть --session-id задачи.
"""
import json
import shutil
import subprocess
import sys

import pytest

from agent_team import asks, build, cli, roleguard, tmuxctl, transcripts
from agent_team.config import load_team

needs_tmux = pytest.mark.skipif(shutil.which("tmux") is None, reason="нет tmux")

INSTR = "/p/.team/build/worker.txt"


# --- roleguard.check ---

def _claude_cmd(monkeypatch, cmd):
    monkeypatch.setattr(roleguard, "process_command", lambda pid: cmd)


def test_parked_pane_is_background_with_job_pid(monkeypatch):
    own = {"pid": 10, "sessionId": "a", "parkedJobId": "j1"}
    job = {"pid": 20, "sessionId": "j1-s", "jobId": "j1", "kind": "bg"}
    c = roleguard.check(10, own, job, INSTR)
    assert c == {"ok": False, "reason": "background", "pid": 20, "pane_pid": 10, "job_id": "j1", "session_id": "j1-s"}


def test_parked_pane_without_live_job_is_still_background():
    own = {"pid": 10, "sessionId": "a", "parkedJobId": "j1"}
    c = roleguard.check(10, own, own, INSTR)
    assert c["ok"] is False and c["reason"] == "background" and c["pid"] is None and c["job_id"] == "j1"


@pytest.mark.parametrize("kind, reason", [("bg", "background"), ("interactive", "other_process")])
def test_conversation_held_by_another_process(kind, reason):
    rec = {"pid": 30, "sessionId": "s", "kind": kind, "jobId": "j" if kind == "bg" else None}
    c = roleguard.check(10, None, rec, INSTR)
    assert c["ok"] is False and c["reason"] == reason and c["pid"] == 30


def test_background_job_found_after_the_pane_is_gone():
    rec = {"pid": 30, "sessionId": "s", "kind": "bg", "jobId": "j"}
    c = roleguard.check(None, None, rec, INSTR)
    assert c["ok"] is False and c["reason"] == "background" and c["pane_pid"] is None


def test_pane_claude_with_role_file_is_ok(monkeypatch):
    _claude_cmd(monkeypatch, f"claude --name Исполнитель --append-system-prompt-file {INSTR} --allowedTools Read")
    rec = {"pid": 10, "sessionId": "s"}
    assert roleguard.check(10, rec, dict(rec), INSTR)["ok"] is True


def test_pane_claude_without_role_file_is_flagged(monkeypatch):
    _claude_cmd(monkeypatch, "/opt/homebrew/bin/claude --resume s")
    rec = {"pid": 10, "sessionId": "s"}
    c = roleguard.check(10, rec, dict(rec), INSTR)
    assert c["ok"] is False and c["reason"] == "no_role_prompt" and c["pid"] == 10


@pytest.mark.parametrize("cmd", [None, "cat"])
def test_no_verdict_without_claude_in_the_pane(monkeypatch, cmd):
    _claude_cmd(monkeypatch, cmd)
    rec = {"pid": 10, "sessionId": "s"}
    assert roleguard.check(10, rec, dict(rec), INSTR)["ok"] is None


def test_no_record_gives_no_verdict_and_no_agent_gives_none():
    assert roleguard.check(10, None, None, INSTR)["ok"] is None
    assert roleguard.check(None, None, None, INSTR) is None


def test_process_command_reads_a_live_process_and_none_for_a_finished_one():
    proc = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)", "--session-id", "zz"])
    try:
        assert "--session-id zz" in roleguard.process_command(proc.pid)
    finally:
        proc.kill()
        proc.wait()
    assert roleguard.process_command(proc.pid) is None


def test_stop_job_refuses_a_process_of_another_session():
    proc = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)", "--session-id", "other"])
    try:
        with pytest.raises(RuntimeError, match="не ведёт сессию"):
            roleguard.stop_job(proc.pid, "mine")
        assert proc.poll() is None                               # не тронут
    finally:
        proc.kill()
        proc.wait()


def _spare(tmp_path, monkeypatch, **rec) -> subprocess.Popen:
    """Подхваченный запасной процесс и его запись Claude Code."""
    proc = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)", "bg-spare", "--bg-spare", "/x.claim.sock"])
    _registry(tmp_path, monkeypatch, [{"pid": proc.pid, "kind": "bg", **rec}])
    return proc


def test_stop_job_accepts_a_claimed_spare_process(tmp_path, monkeypatch):
    """Задачу у владельца вёл подхваченный запасной процесс: в его командной строке нет --session-id."""
    proc = _spare(tmp_path, monkeypatch, sessionId="j1-s", jobId="j1")
    try:
        roleguard.stop_job(proc.pid, "j1-s", "j1")
        assert proc.wait(timeout=5) is not None
    finally:
        proc.kill()
        proc.wait()


def test_stop_job_refuses_when_the_record_of_the_pid_is_about_another_job(tmp_path, monkeypatch):
    proc = _spare(tmp_path, monkeypatch, sessionId="other-s", jobId="other")
    try:
        with pytest.raises(RuntimeError, match="уже не о задаче"):
            roleguard.stop_job(proc.pid, "j1-s", "j1")
        assert proc.poll() is None
    finally:
        proc.kill()
        proc.wait()


def test_process_command_is_not_cut_without_locale_in_a_narrow_terminal(tmp_path, monkeypatch):
    """Приложение запускает team без LANG; путь файла роли идёт после --name по-русски и длинный."""
    for var in ("LANG", "LC_ALL", "LC_CTYPE"):
        monkeypatch.delenv(var, raising=False)
    monkeypatch.setenv("COLUMNS", "80")
    instr = str(tmp_path / ("каталог-" + "x" * 160) / "build" / "manager.txt")
    proc = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)", "--name", "Менеджер проекта",
                             "--append-system-prompt-file", instr])
    try:
        assert roleguard.process_command(proc.pid).endswith(f"--append-system-prompt-file {instr}")
    finally:
        proc.kill()
        proc.wait()


def test_job_running_reads_state_of_the_job(tmp_path, monkeypatch):
    jobs = tmp_path / "jobs"
    monkeypatch.setenv("TEAM_JOBS_DIR", str(jobs))
    assert roleguard.job_running("j1") is None
    (jobs / "j1").mkdir(parents=True)
    (jobs / "j1" / "state.json").write_text(json.dumps({"state": "working"}), encoding="utf-8")
    assert roleguard.job_running("j1") is True
    (jobs / "j1" / "state.json").write_text(json.dumps({"state": "done"}), encoding="utf-8")
    assert roleguard.job_running("j1") is False


@needs_tmux
@pytest.mark.both_layouts
def test_restart_of_parked_pane_whose_job_has_ended(project, tmp_path, monkeypatch, capsys):
    cli.main(["up"])
    team = load_team()
    pane = tmuxctl.panes(team.session)["worker#1"]
    _registry(tmp_path, monkeypatch, [{"pid": pane.pid, "sessionId": "pane-s", "parkedJobId": "j1"}])
    capsys.readouterr()
    assert cli.main(["restart", "worker"]) == 0
    assert "задача j1 уже завершена" in capsys.readouterr().out


@needs_tmux
@pytest.mark.both_layouts
def test_restart_refuses_when_job_runs_but_its_process_is_unknown(project, tmp_path, monkeypatch, capsys):
    """Запись задачи не нашлась, а state.json говорит, что она идёт: поднять панель рядом — два агента на разговоре."""
    cli.main(["up"])
    team = load_team()
    pane = tmuxctl.panes(team.session)["worker#1"]
    _registry(tmp_path, monkeypatch, [{"pid": pane.pid, "sessionId": "pane-s", "parkedJobId": "j1"}])
    jobs = tmp_path / "claude-jobs" / "j1"
    jobs.mkdir(parents=True)
    (jobs / "state.json").write_text(json.dumps({"state": "working"}), encoding="utf-8")
    capsys.readouterr()
    assert cli.main(["restart", "worker"]) == 1
    assert "ctrl+x" in capsys.readouterr().err
    assert tmuxctl.panes(team.session)["worker#1"].id == pane.id


# --- запрет фона при запуске роли ---

def test_spawn_sets_the_background_ban_after_unsetting_claude_vars(project, monkeypatch):
    seen = {}
    monkeypatch.setattr(tmuxctl, "panes", lambda session: {})
    monkeypatch.setattr(tmuxctl, "open_role", lambda session, key, cwd, command, *a, **k: seen.setdefault("cmd", command) and "%1")
    team = load_team()
    cli.spawn(team, "boss")
    cmd = seen["cmd"]
    assert cmd.index("CLAUDE_CODE_DISABLE_AGENT_VIEW=1") > cmd.index("unset")      # снятие CLAUDE_* его не снимает
    assert "CLAUDE_CODE_DISABLE_BG_EXIT_HANDOFF=1" in cmd
    st = cli.load_state(team)["boss#1"]
    assert st["instruction"] == str(team.state_dir / "build" / "boss.txt")
    settings = json.loads((team.state_dir / "build" / "boss#1-settings.json").read_text(encoding="utf-8"))
    assert settings["disableAgentView"] is True
    assert asks.hook_settings(team, "boss#1")["disableAgentView"] is True


# --- status, addr, restart на живом tmux ---

def _registry(tmp_path, monkeypatch, records: list[dict]) -> None:
    reg = tmp_path / "sessions"
    reg.mkdir(exist_ok=True)
    for r in records:
        (reg / f"{r['pid']}.json").write_text(json.dumps(r), encoding="utf-8")
    monkeypatch.setenv("TEAM_SESSIONS_DIR", str(reg))


def _status(capsys, *args):
    capsys.readouterr()
    cli.main(["status", *args])
    return capsys.readouterr().out


def _agents(capsys):
    return {a["name"]: a for a in json.loads(_status(capsys, "--json"))["agents"]}


@needs_tmux
@pytest.mark.both_layouts
def test_status_confirms_role_of_the_pane_process(project, tmp_path, monkeypatch, capsys):
    cli.main(["up"])
    team = load_team()
    pane = tmuxctl.panes(team.session)["worker#1"]
    instr = cli.load_state(team)["worker#1"]["instruction"]
    _registry(tmp_path, monkeypatch, [{"pid": pane.pid, "sessionId": "s", "kind": "interactive", "status": "idle"}])
    _claude_cmd(monkeypatch, f"claude --append-system-prompt-file {instr} --session-id s")
    assert _agents(capsys)["worker#1"]["role_check"]["ok"] is True
    assert "ВНИМАНИЕ" not in _status(capsys)
    _claude_cmd(monkeypatch, "claude --session-id s")
    assert _agents(capsys)["worker#1"]["role_check"]["reason"] == "no_role_prompt"
    assert cli.main(["addr", "worker"]) == 1


def _fake_job(session_id: str) -> subprocess.Popen:
    return subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)", "--session-id", session_id])


@needs_tmux
@pytest.mark.both_layouts
def test_restart_stops_background_job_and_resumes_its_session(project, tmp_path, monkeypatch, capsys):
    cli.main(["up"])
    team = load_team()
    pane = tmuxctl.panes(team.session)["worker#1"]
    cwd = cli.load_state(team)["worker#1"]["cwd"]
    job_sid = "3fe54e80-0000-0000-0000-000000000001"
    d = transcripts.projects_dir() / transcripts.slug(cwd)
    d.mkdir(parents=True, exist_ok=True)
    (d / f"{job_sid}.jsonl").write_text(json.dumps({"type": "user", "sessionId": job_sid}) + "\n", encoding="utf-8")
    proc = _fake_job(job_sid)
    try:
        _registry(tmp_path, monkeypatch, [
            {"pid": pane.pid, "sessionId": "pane-s", "kind": "interactive", "parkedJobId": "3fe54e80"},
            {"pid": proc.pid, "sessionId": job_sid, "kind": "bg", "jobId": "3fe54e80", "status": "idle"}])
        capsys.readouterr()
        assert cli.main(["restart", "worker"]) == 0
        out = capsys.readouterr().out
        assert proc.wait(timeout=5) is not None                      # задача остановлена
        assert "остановлена фоновая задача 3fe54e80" in out
        st = cli.load_state(team)["worker#1"]
        assert st["session_id"] == job_sid                           # продолжение — с сессии задачи
        new_pane = tmuxctl.panes(team.session)["worker#1"]
        assert new_pane.id != pane.id and not new_pane.dead
        ev = [e for e in cli.read_events(team) if e["type"] == "restart"][-1]
        assert "фоновая задача" in ev["text"]
    finally:
        proc.kill()
        proc.wait()


@needs_tmux
@pytest.mark.both_layouts
def test_restart_refuses_when_job_pid_belongs_to_another_session(project, tmp_path, monkeypatch, capsys):
    cli.main(["up"])
    team = load_team()
    pane = tmuxctl.panes(team.session)["worker#1"]
    proc = _fake_job("someone-else")
    try:
        _registry(tmp_path, monkeypatch, [
            {"pid": pane.pid, "sessionId": "pane-s", "parkedJobId": "j1"},
            {"pid": proc.pid, "sessionId": "j1-s", "kind": "bg", "jobId": "j1"}])
        capsys.readouterr()
        assert cli.main(["restart", "worker"]) == 1
        assert "не остановить" in capsys.readouterr().err
        assert proc.poll() is None
        assert tmuxctl.panes(team.session)["worker#1"].id == pane.id  # панель не тронута
    finally:
        proc.kill()
        proc.wait()


@needs_tmux
@pytest.mark.both_layouts
def test_restart_refuses_other_process_unless_fresh(project, tmp_path, monkeypatch, capsys):
    cli.main(["up"])
    team = load_team()
    sid = cli.load_state(team)["worker#1"]["session_id"]
    _registry(tmp_path, monkeypatch, [{"pid": 999_998, "sessionId": sid, "kind": "interactive"}])
    capsys.readouterr()
    assert cli.main(["restart", "worker"]) == 1
    assert "другой процесс (pid 999998)" in capsys.readouterr().err
    assert cli.main(["restart", "worker", "--fresh"]) == 0
