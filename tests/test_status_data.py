"""Данные агентов в status --json: ширина панели менеджера, текущая сессия по цепочке continued-in, простой панели."""
import json
import shutil
import time

import pytest

from agent_team import cli, tmuxctl
from agent_team.config import TeamError, load_team

needs_tmux = pytest.mark.skipif(shutil.which("tmux") is None, reason="нет tmux")


def _set_yaml(repo, extra: str) -> None:
    path = repo / "agents" / "team.yaml"
    path.write_text(path.read_text(encoding="utf-8") + extra, encoding="utf-8")


# --- manager_width ---

def test_manager_width_defaults_to_half(project):
    assert load_team().manager_width == "50%"


@pytest.mark.parametrize("value, expected", [("60%", "60%"), ("120", "120"), ('"35%"', "35%")])
def test_manager_width_is_read_from_team_yaml(project, value, expected):
    _set_yaml(project, f"manager_width: {value}\n")
    assert load_team().manager_width == expected


@pytest.mark.parametrize("value", ["0%", "100%", "wide", "-5"])
def test_bad_manager_width_is_an_error(project, value):
    _set_yaml(project, f"manager_width: {value}\n")
    with pytest.raises(TeamError, match="manager_width"):
        load_team()


@needs_tmux
@pytest.mark.panes_only
def test_manager_width_reaches_tmux_in_panes_layout(project):
    team = load_team()
    _set_yaml(project, "manager_width: 70%\n")
    cli.main(["up"])
    out = tmuxctl._run(["show-options", "-w", "-v", "-t", f"={team.session}:{tmuxctl.SHARED_WINDOW}",
                        "main-pane-width"]).stdout.strip()
    assert out == "70%"


# --- текущая сессия по цепочке continued-in ---

from agent_team import sessions, transcripts  # noqa: E402


def _write_session(cwd: str, sid: str, next_sid: str | None = None, extra_dir: str | None = None):
    d = transcripts.projects_dir() / (extra_dir or transcripts.slug(cwd))
    d.mkdir(parents=True, exist_ok=True)
    lines = [json.dumps({"type": "user", "sessionId": sid, "message": {"role": "user", "content": "привет"}})]
    if next_sid:
        lines.append(json.dumps({"type": "continued-in", "timestamp": "2026-10-17T09:01:00.000Z",
                                 "sessionId": sid, "continuedInSessionId": next_sid}, separators=(",", ":")))
    path = d / f"{sid}.jsonl"
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


def test_slug_matches_claude_code_projects_dir():
    assert transcripts.slug("/Users/u/dev/a.b_c/wt-1") == "-Users-u-dev-a-b-c-wt-1"
    assert transcripts.slug("/x/проект") == "-x-------"


def test_current_follows_continued_in_to_the_end_of_chain():
    _write_session("/w/p", "s1", "s2")
    _write_session("/w/p", "s2", "s3")
    last = _write_session("/w/p", "s3")
    assert transcripts.current("/w/p", "s1") == ("s3", last)


def test_current_without_continuation_is_launch_session():
    path = _write_session("/w/p", "s1")
    assert transcripts.current("/w/p", "s1") == ("s1", path)


def test_current_stays_on_last_found_file_when_next_is_missing():
    path = _write_session("/w/p", "s4", "gone")
    assert transcripts.current("/w/p", "s4") == ("s4", path)


def test_current_survives_a_ring():
    _write_session("/w/p", "a", "b")
    _write_session("/w/p", "b", "a")
    sid, path = transcripts.current("/w/p", "a")
    assert sid == "b" and path.name == "b.jsonl"


def test_current_finds_session_in_another_projects_dir():
    # продолжение записано в каталоге другого cwd: ищется по имени файла во всех каталогах проектов
    _write_session("/w/p", "s1", "s2")
    other = _write_session("/w/elsewhere", "s2")
    assert transcripts.current("/w/p", "s1") == ("s2", other)


def test_current_takes_the_last_continuation_in_file():
    path = _write_session("/w/p", "s1", "s2")
    with path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps({"type": "continued-in", "sessionId": "s1", "continuedInSessionId": "s5"}) + "\n")
    _write_session("/w/p", "s2")
    last = _write_session("/w/p", "s5")
    assert transcripts.current("/w/p", "s1") == ("s5", last)


def test_current_without_session_or_file():
    assert transcripts.current("/w/p", None) == (None, None)
    assert transcripts.current("/w/p", "nofile") == ("nofile", None)


@needs_tmux
def test_status_json_reports_current_session_and_launch_session(project, capsys):
    cli.main(["up"])
    team = load_team()
    st = cli.load_state(team)["worker#1"]
    _write_session(st["cwd"], st["session_id"], "cont-1")
    cont = _write_session(st["cwd"], "cont-1")
    capsys.readouterr()
    cli.main(["status", "--json"])
    w = next(a for a in json.loads(capsys.readouterr().out)["agents"] if a["name"] == "worker#1")
    assert w["session_id"] == "cont-1"
    assert w["launch_session_id"] == st["session_id"]
    assert w["transcript"] == str(cont)


# --- состояние, простой и ожидание по записи сессии ~/.claude/sessions/<pid>.json ---

@pytest.mark.parametrize("status, expected", [("busy", "busy"), ("idle", "idle"), ("waiting", "waiting"),
                                              ("shell", None), (None, None)])
def test_state_takes_only_checked_values(status, expected):
    assert sessions.state({"status": status} if status else {}) == expected
    assert sessions.state(None) is None


def test_idle_seconds_from_status_change():
    assert sessions.idle_seconds({"status": "idle", "statusUpdatedAt": 940_500}, now=1000) == 60
    assert sessions.idle_seconds({"status": "waiting", "statusUpdatedAt": 990_000}, now=1000) == 10
    assert sessions.idle_seconds({"status": "busy", "statusUpdatedAt": 100_000}, now=1000) == 0     # ход идёт
    assert sessions.idle_seconds({"status": "idle", "statusUpdatedAt": 2_000_000}, now=1000) == 0  # часы впереди
    assert sessions.idle_seconds({"status": "idle"}, now=1000) is None
    assert sessions.idle_seconds({"status": "shell", "statusUpdatedAt": 1}, now=1000) is None
    assert sessions.idle_seconds(None, now=1000) is None


def _status_agents(capsys) -> dict:
    capsys.readouterr()
    cli.main(["status", "--json"])
    return {a["name"]: a for a in json.loads(capsys.readouterr().out)["agents"]}


def _register(tmp_path, monkeypatch, pane, **rec) -> None:
    reg = tmp_path / "sessions"
    reg.mkdir(exist_ok=True)
    (reg / f"{pane.pid}.json").write_text(json.dumps({"pid": pane.pid, **rec}), encoding="utf-8")
    monkeypatch.setenv("TEAM_SESSIONS_DIR", str(reg))


@needs_tmux
def test_status_takes_state_idle_and_waiting_from_session_record(project, tmp_path, monkeypatch, capsys):
    """Простой у каждого агента свой, даже в общем окне panes: он из записи сессии, а не из окна tmux."""
    cli.main(["up"])
    team = load_team()
    live = tmuxctl.panes(team.session)
    now_ms = int(time.time() * 1000)
    _register(tmp_path, monkeypatch, live["boss#1"], status="idle", statusUpdatedAt=now_ms - 600_000)
    _register(tmp_path, monkeypatch, live["worker#1"], status="waiting", statusUpdatedAt=now_ms - 30_000)
    agents = _status_agents(capsys)
    assert agents["boss#1"]["state"] == "idle" and 595 <= agents["boss#1"]["idle_s"] <= 610
    assert agents["boss#1"]["waiting_human"] is False
    assert agents["worker#1"]["state"] == "waiting" and 25 <= agents["worker#1"]["idle_s"] <= 40
    assert agents["worker#1"]["waiting_human"] is True
    _register(tmp_path, monkeypatch, live["worker#1"], status="busy", statusUpdatedAt=now_ms - 300_000)
    agents = _status_agents(capsys)
    assert agents["worker#1"]["state"] == "busy" and agents["worker#1"]["idle_s"] == 0
    assert agents["worker#1"]["waiting_human"] is False


@needs_tmux
def test_status_without_session_record_falls_back_to_window_and_screen(project, tmp_path, monkeypatch, capsys):
    cli.main(["up"])
    monkeypatch.setenv("TEAM_SESSIONS_DIR", str(tmp_path / "no-sessions"))
    agents = _status_agents(capsys)
    for name in ("boss#1", "worker#1"):
        assert agents[name]["state"] is None
        assert isinstance(agents[name]["idle_s"], int) and agents[name]["waiting_human"] is False
    assert agents["idle#1"]["state"] is None and agents["idle#1"]["idle_s"] is None   # не запущен


@needs_tmux
def test_status_does_not_write_to_project_or_panes(project, capsys):
    cli.main(["up"])
    team = load_team()
    before = sorted(p.name for p in team.state_dir.iterdir())
    _status_agents(capsys)
    assert sorted(p.name for p in team.state_dir.iterdir()) == before
    opts = tmuxctl._run(["show-options", "-p", "-t", tmuxctl.panes(team.session)["worker#1"].id]).stdout
    assert "@team_seen" not in opts


def test_status_without_session_does_not_create_team_dir(project, capsys):
    team = load_team()
    cli.main(["status", "--json"])
    assert not team.state_dir.exists()


# --- разговор панели отправлен в фон: адрес и состояние — у фоновой задачи ---

def _parked_registry(tmp_path, monkeypatch, pane_pid: int, job_status="busy"):
    """Записи как у claude 2.1.295 после ← в пустой строке: панель с parkedJobId и процесс фоновой задачи."""
    reg = tmp_path / "sessions"
    reg.mkdir(exist_ok=True)
    pane_sock, job_sock = tmp_path / "pane.sock", tmp_path / "job.sock"
    pane_sock.write_text("")
    job_sock.write_text("")
    (reg / f"{pane_pid}.json").write_text(json.dumps({
        "pid": pane_pid, "sessionId": "cbf102dd-0000", "kind": "interactive", "parkedJobId": "8e14ec69",
        "status": "idle", "statusUpdatedAt": 1, "messagingSocketPath": str(pane_sock)}), encoding="utf-8")
    (reg / "54183.json").write_text(json.dumps({
        "pid": 54183, "sessionId": "8e14ec69-0000", "kind": "bg", "jobId": "8e14ec69",
        "status": job_status, "statusUpdatedAt": int(time.time() * 1000), "messagingSocketPath": str(job_sock)}),
        encoding="utf-8")
    monkeypatch.setenv("TEAM_SESSIONS_DIR", str(reg))
    return pane_sock, job_sock


def test_lookup_follows_parked_job(tmp_path, monkeypatch):
    _, job_sock = _parked_registry(tmp_path, monkeypatch, 59451)
    rec = sessions.lookup(59451, "cbf102dd-0000")
    assert rec["jobId"] == "8e14ec69" and rec["status"] == "busy"
    assert sessions.address(59451) == f"uds:{job_sock}"


def test_lookup_stays_on_pane_when_job_is_gone(tmp_path, monkeypatch):
    pane_sock, _ = _parked_registry(tmp_path, monkeypatch, 59451)
    (tmp_path / "sessions" / "54183.json").unlink()
    assert sessions.address(59451) == f"uds:{pane_sock}"


def test_lookup_by_session_ids_in_order(tmp_path, monkeypatch):
    _, job_sock = _parked_registry(tmp_path, monkeypatch, 59451)
    assert sessions.lookup(None, "nope", "8e14ec69-0000")["pid"] == 54183      # pid не известен — по sessionId
    assert sessions.lookup(None, "cbf102dd-0000")["pid"] == 54183             # и запись панели ведёт к задаче
    assert sessions.lookup(None, None, "nope") is None


@needs_tmux
@pytest.mark.both_layouts
def test_status_of_parked_pane_points_to_background_job_and_addr_refuses(project, tmp_path, monkeypatch, capsys):
    """Состояние и сокет — у фоновой задачи, но промпта роли у неё нет: status это помечает, addr адрес не отдаёт."""
    cli.main(["up"])
    team = load_team()
    pane = tmuxctl.panes(team.session)["worker#1"]
    _, job_sock = _parked_registry(tmp_path, monkeypatch, pane.pid)
    w = _status_agents(capsys)["worker#1"]
    assert w["addr"] == f"uds:{job_sock}"
    assert w["state"] == "busy" and w["idle_s"] == 0
    assert w["role_check"] == {"ok": False, "reason": "background", "pid": 54183, "pane_pid": pane.pid,
                               "job_id": "8e14ec69", "session_id": "8e14ec69-0000"}
    (tmp_path / "sessions" / "54183.json").write_text(json.dumps({             # задача давно ждёт: «тихо» считается часами
        "pid": 54183, "sessionId": "8e14ec69-0000", "kind": "bg", "jobId": "8e14ec69", "status": "idle",
        "statusUpdatedAt": 1, "messagingSocketPath": str(job_sock)}), encoding="utf-8")
    capsys.readouterr()
    cli.main(["status"])
    out = capsys.readouterr().out
    row = next(line for line in out.splitlines() if line.startswith("worker#1"))
    assert "! в фоне" in row and " ч" in row
    assert "worker#1: ВНИМАНИЕ — в панели не сессия роли" in out and "team restart worker#1" in out
    capsys.readouterr()
    assert cli.main(["addr", "worker"]) == 1
    err = capsys.readouterr().err
    assert "не сессия роли" in err and "team restart worker#1" in err


# --- restart продолжает текущую сессию цепочки ---

@needs_tmux
def test_restart_resumes_current_session_of_chain(project, monkeypatch):
    cli.main(["up"])
    team = load_team()
    st = cli.load_state(team)["worker#1"]
    _write_session(st["cwd"], st["session_id"], "cont-1")
    _write_session(st["cwd"], "cont-1")
    seen = {}
    real = cli.build.claude_argv

    def spy(team_, role, instruction, sid, resume=False, **kw):
        seen.update(sid=sid, resume=resume)
        return real(team_, role, instruction, sid, resume=resume, **kw)

    monkeypatch.setattr(cli.build, "claude_argv", spy)
    assert cli.main(["restart", "worker"]) == 0
    assert seen == {"sid": "cont-1", "resume": True}
    assert cli.load_state(team)["worker#1"]["session_id"] == "cont-1"


@needs_tmux
def test_restart_without_transcript_resumes_launch_session(project, monkeypatch):
    cli.main(["up"])
    team = load_team()
    first = cli.load_state(team)["worker#1"]["session_id"]
    assert cli.main(["restart", "worker"]) == 0
    assert cli.load_state(team)["worker#1"]["session_id"] == first


# --- столбец «состояние» в текстовом status ---

def _status_row(monkeypatch, capsys, name, **over):
    a = {"name": name, "role": "worker", "alive": True, "pane_id": None, "task": None, "task_title": None,
         "task_cleared_ts": None, "state": "idle", "idle_s": 3600, "waiting_human": False, "waiting_reason": None,
         "role_check": {"ok": True}, "addr": None, "cwd": "/x", **over}
    monkeypatch.setattr(cli, "collect_agents", lambda team: [a])
    monkeypatch.setattr(cli.tmuxctl, "panes", lambda session: {})
    monkeypatch.setattr(cli.tmuxctl, "has_session", lambda session: True)
    assert cli.main(["status"]) == 0
    return next(l for l in capsys.readouterr().out.splitlines() if l.startswith(name))


@pytest.mark.parametrize("over, word", [
    ({"state": "idle", "idle_s": 2100}, "простаивает"),
    ({"state": "busy", "idle_s": 0}, "работает"),
    ({"state": None, "idle_s": None}, "нет данных"),
    ({"state": None, "idle_s": 30}, "работает"),                       # записи сессии нет, жив по активности панели
])
def test_status_state_column(project, monkeypatch, capsys, over, word):
    row = _status_row(monkeypatch, capsys, "worker#1", **over)
    assert word in row
    if word == "простаивает":
        assert "35 мин" in row
