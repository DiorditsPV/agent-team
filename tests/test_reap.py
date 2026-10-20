"""team reap: автоостановка простаивающих агентов start: on_demand (idle_stop_minutes в team.yaml)."""
import json
import shutil
import time

import pytest

from agent_team import cli, tmuxctl
from agent_team.config import TeamError, load_team

needs_tmux = pytest.mark.skipif(shutil.which("tmux") is None, reason="нет tmux")


def _set_minutes(repo, value="30"):
    path = repo / "agents" / "team.yaml"
    path.write_text(path.read_text(encoding="utf-8") + f"idle_stop_minutes: {value}\n", encoding="utf-8")


# --- ключ idle_stop_minutes ---

def test_no_key_means_default_15(project):
    assert load_team().idle_stop_minutes == 15


@pytest.mark.parametrize("value", ["off"])
def test_off_means_disabled(project, value):
    _set_minutes(project, value)
    assert load_team().idle_stop_minutes is None


def test_key_is_read(project):
    _set_minutes(project, "45")
    assert load_team().idle_stop_minutes == 45


@pytest.mark.parametrize("value", ["0", "abc", "true"])
def test_bad_value_is_an_error(project, value):
    _set_minutes(project, value)
    with pytest.raises(TeamError, match="idle_stop_minutes"):
        load_team()


def test_check_reports_bad_value(project, capsys):
    _set_minutes(project, "0")
    assert cli.main(["check"]) == 1
    assert "idle_stop_minutes" in capsys.readouterr().err


# --- правила на подставных данных агента ---

def _agent(name="idle#1", role="idle", **over):
    a = {"name": name, "role": role, "alive": True, "pane_id": None, "task": None, "task_title": None, "task_cleared_ts": None, "state": "idle", "idle_s": 3600,
         "waiting_human": False, "waiting_reason": None, "role_check": {"ok": True}}
    a.update(over)
    return a


@pytest.fixture
def fake(project, monkeypatch):
    """team.yaml с порогом 30 мин; collect_agents и stop_agent подменены — смотрим только решение."""
    _set_minutes(project, "30")
    agents, stopped = [], []
    monkeypatch.setattr(cli, "collect_agents", lambda team: list(agents))
    monkeypatch.setattr(cli, "stop_agent", lambda team, key, reason="остановлена": stopped.append((key, reason)))
    return agents, stopped


def _reap(capsys, *argv):
    assert cli.main(["reap", "--json", *argv]) == 0
    return json.loads(capsys.readouterr().out)


def test_idle_on_demand_agent_is_stopped(fake, capsys):
    agents, stopped = fake
    agents.append(_agent())
    out = _reap(capsys)
    assert out == [{"name": "idle#1", "idle_s": 3600, "action": "stopped", "reason": "простой 60 мин"}]
    assert stopped == [("idle#1", "остановлена: простой 60 мин")]


def test_threshold_is_inclusive_and_below_is_kept(fake, capsys):
    agents, stopped = fake
    agents += [_agent(idle_s=1800), _agent("idle#2", idle_s=1799)]
    out = {o["name"]: o["action"] for o in _reap(capsys)}
    assert out == {"idle#1": "stopped", "idle#2": "kept"}
    assert [k for k, _ in stopped] == ["idle#1"]


@pytest.mark.parametrize("over, why", [
    ({"state": "busy", "idle_s": 0}, "работает"),
    ({"state": "busy"}, "работает"),                                   # busy, даже если idle_s большой
    ({"state": "waiting", "waiting_human": True, "waiting_reason": "prompt"}, "ждёт ответа"),
    ({"state": None, "waiting_human": True, "waiting_reason": "trust"}, "ждёт ответа"),
    ({"idle_s": None}, "нет данных о простое"),
    ({"role_check": {"ok": False, "reason": "other_process"}}, "в панели не сессия роли"),
])
def test_exclusions_keep_the_agent(fake, capsys, over, why):
    agents, stopped = fake
    agents.append(_agent(**over))
    out = _reap(capsys)
    assert out[0]["action"] == "kept" and out[0]["reason"] == why
    assert stopped == []


def test_stopped_agent_is_not_listed(fake, capsys):
    agents, stopped = fake
    agents.append(_agent(alive=False, idle_s=None))
    assert _reap(capsys) == [] and stopped == []


def test_role_check_none_does_not_block(fake, capsys):
    agents, stopped = fake
    agents.append(_agent(role_check=None))
    assert _reap(capsys)[0]["action"] == "stopped"


def test_always_and_manual_roles_are_never_stopped(fake, capsys):
    agents, stopped = fake
    agents += [_agent("worker#1", "worker"), _agent("boss#1", "boss")]       # always и manual (менеджер)
    out = {o["name"]: o for o in _reap(capsys)}
    assert out["worker#1"]["action"] == out["boss#1"]["action"] == "kept"
    assert out["worker#1"]["reason"] == "start: always"
    assert stopped == []


def test_manager_is_kept_even_if_on_demand(fake, capsys, project):
    agents, stopped = fake
    path = project / "agents" / "team.yaml"
    path.write_text(path.read_text(encoding="utf-8").replace("{role: boss, start: manual}", "{role: boss, start: on_demand}"),
                    encoding="utf-8")
    agents.append(_agent("boss#1", "boss"))
    assert _reap(capsys)[0]["reason"] == "менеджер" and stopped == []


def test_keep_accepts_role_and_numbered_name(fake, capsys):
    agents, stopped = fake
    agents += [_agent("idle#1"), _agent("idle#2"), _agent("idle#3")]
    out = {o["name"]: o["action"] for o in _reap(capsys, "--keep", "idle", "idle#3")}
    assert out == {"idle#1": "kept", "idle#2": "stopped", "idle#3": "kept"}
    assert [k for k, _ in stopped] == ["idle#2"]


def test_keep_can_repeat(fake, capsys):
    agents, stopped = fake
    agents += [_agent("idle#1"), _agent("idle#2")]
    out = _reap(capsys, "--keep", "idle#1", "--keep", "idle#2")
    assert [o["action"] for o in out] == ["kept", "kept"] and stopped == []


def test_dry_run_stops_nothing(fake, capsys):
    agents, stopped = fake
    agents.append(_agent())
    out = _reap(capsys, "--dry-run")
    assert out[0]["action"] == "would_stop"
    assert stopped == []


def test_disabled_with_off_stops_nothing(project, monkeypatch, capsys):
    _set_minutes(project, "off")
    monkeypatch.setattr(cli, "collect_agents", lambda team: pytest.fail("при off агентов не смотрим"))
    assert cli.main(["reap"]) == 0
    assert "автоостановка выключена: idle_stop_minutes: off" in capsys.readouterr().out
    assert cli.main(["reap", "--json"]) == 0
    assert json.loads(capsys.readouterr().out) == []


def test_text_output(fake, capsys):
    agents, _ = fake
    agents.append(_agent())
    assert cli.main(["reap"]) == 0
    assert "idle#1: stopped (простой 60 мин)" in capsys.readouterr().out


# --- на живом tmux (cat вместо claude) ---

@needs_tmux
@pytest.mark.both_layouts
def test_live_reap_stops_idle_pane_and_logs_event(project, monkeypatch, capsys):
    _set_minutes(project, "30")
    team = load_team()
    cli.main(["up"])
    cli.main(["spawn", "idle"])
    capsys.readouterr()
    now = time.time()
    monkeypatch.setattr(cli.time, "time", lambda: now + 3 * 3600)          # панель «молчит» три часа
    assert cli.main(["reap", "--dry-run", "--json"]) == 0
    dry = {o["name"]: o for o in json.loads(capsys.readouterr().out)}
    assert dry["idle#1"]["action"] == "would_stop"
    assert dry["worker#1"]["action"] == dry["boss#1"]["action"] == "kept"
    assert "idle#1" in tmuxctl.panes(team.session)                          # dry-run ничего не погасил
    assert cli.main(["reap", "--json"]) == 0
    out = {o["name"]: o for o in json.loads(capsys.readouterr().out)}
    assert out["idle#1"]["action"] == "stopped"
    live = tmuxctl.panes(team.session)
    assert "idle#1" not in live and {"boss#1", "worker#1"} <= set(live)
    ev = [e for e in cli.read_events(team) if e["type"] == "down" and e["agent"] == "idle#1"]
    assert ev and "простой" in ev[-1]["text"] and "мин" in ev[-1]["text"]
    cli.main(["down"])


# --- черновик в строке ввода ---

RULE = "\x1b[38;5;244m" + "─" * 100
FOOT = "\x1b[39m  \x1b[2m\x1b[37m[Sonnet 5.5]\x1b[0m\x1b[38;5;246m ~/dev/x\n  \x1b[38;5;220m⏵⏵ auto mode on\x1b[38;5;246m (shift+tab to cycle)\x1b[39m"
EMPTY_BOX = f'{RULE}\n\x1b[39m❯\xa0\x1b[2mTry "fix typecheck errors"\x1b[0m\n{RULE}\n{FOOT}'      # снято с claude 2.1.x
DRAFT_BOX = f"{RULE}\n\x1b[39m❯\xa0Сократи пометку, чтобы не обрезалась\n{RULE}\n{FOOT}"
MULTI_BOX = f"{RULE}\n\x1b[39m❯\xa0\x1b[2m\x1b[0m\nвторая строка черновика\n{RULE}\n{FOOT}"


def test_input_draft_detects_typed_text():
    assert cli.input_draft(DRAFT_BOX)
    assert cli.input_draft(MULTI_BOX)


def test_input_draft_ignores_placeholder_and_empty_input():
    assert not cli.input_draft(EMPTY_BOX)
    assert not cli.input_draft(f"{RULE}\n\x1b[39m❯\xa0\n{RULE}\n{FOOT}")


def test_input_draft_without_input_box_is_false():
    assert not cli.input_draft("")
    assert not cli.input_draft("$ ls\nfile\n")
    assert not cli.input_draft("\x1b[39m❯ 1. Yes\n  2. No")


def test_input_draft_uses_the_last_box():
    assert not cli.input_draft(f"{RULE}\n❯ старый текст\n{RULE}\nвывод\n{EMPTY_BOX}")


@pytest.mark.parametrize("screen, action", [(DRAFT_BOX, "kept"), (EMPTY_BOX, "stopped")])
def test_reap_keeps_agent_with_draft_in_input(fake, capsys, monkeypatch, screen, action):
    agents, stopped = fake
    agents.append(_agent(pane_id="%7"))
    monkeypatch.setattr(cli.tmuxctl, "capture", lambda pane_id, lines=40, escapes=False: screen if escapes else pytest.fail("нужен цвет"))
    out = _reap(capsys)
    assert out[0]["action"] == action
    if action == "kept":
        assert out[0]["reason"] == "в строке ввода набран текст" and stopped == []
    else:
        assert len(stopped) == 1


def test_dry_run_also_reports_draft_as_kept(fake, capsys, monkeypatch):
    agents, _ = fake
    agents.append(_agent(pane_id="%7"))
    monkeypatch.setattr(cli.tmuxctl, "capture", lambda *a, **k: DRAFT_BOX)
    assert _reap(capsys, "--dry-run")[0]["action"] == "kept"


# --- текущая задача и диалог на экране ---

def test_agent_with_task_is_kept(fake, capsys):
    agents, stopped = fake
    agents.append(_agent(task_title="Автоостановка по простою", task="TASK-676"))
    out = _reap(capsys)
    assert out[0]["action"] == "kept" and out[0]["reason"] == "есть задача: Автоостановка по простою"
    assert stopped == []


def test_task_id_without_title_also_blocks(fake, capsys):
    agents, stopped = fake
    agents.append(_agent(task="TASK-9"))
    assert _reap(capsys)[0]["reason"] == "есть задача: TASK-9" and stopped == []


def test_idle_is_counted_from_task_clear(fake, capsys):
    agents, stopped = fake
    now = int(time.time())
    agents += [_agent("idle#1", task_cleared_ts=now - 120),            # задачу сняли 2 мин назад: рано
               _agent("idle#2", task_cleared_ts=now - 7200)]           # сняли давно: считается обычный простой
    out = {o["name"]: o for o in _reap(capsys)}
    assert out["idle#1"]["action"] == "kept" and "простой 2 мин" in out["idle#1"]["reason"]
    assert out["idle#2"]["action"] == "stopped"
    assert [k for k, _ in stopped] == ["idle#2"]


def test_task_clear_moment_is_read_from_events(project):
    team = load_team()
    cli.log_event(team, "task", "idle#1", "Название задачи", None, title="Название задачи")
    cli.log_event(team, "task", "idle#1", "снята", None, title=None)
    last = cli._last_tasks(cli.read_events(team))["idle#1"]
    assert last["title"] is None and last["ts"] is None and isinstance(last["cleared_ts"], int)


@pytest.mark.parametrize("screen", [
    "Do you want to proceed?\n❯ 1. Yes\n  2. No",
    "\x1b[38;5;153m❯\x1b[39m 1. Dark mode\n  2. Light mode\n\x1b[38;5;246mEnter to confirm · Esc to cancel",
    "Выберите вариант\nEnter to select · ↑/↓ to navigate · Esc to cancel",
])
def test_open_dialog_keeps_the_agent(fake, capsys, monkeypatch, screen):
    agents, stopped = fake
    agents.append(_agent(pane_id="%7"))
    monkeypatch.setattr(cli.tmuxctl, "capture", lambda *a, **k: screen)
    out = _reap(capsys)
    assert out[0]["action"] == "kept" and out[0]["reason"] == "в панели открыт диалог"
    assert stopped == []


def test_plain_idle_screen_is_not_a_dialog():
    assert not cli.dialog_open("Готово.\n" + "─" * 40 + '\n❯ Try "fix"\n' + "─" * 40)
