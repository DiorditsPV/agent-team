"""team task: название текущей задачи агента, проверки формы, снятие, status."""
import json
import shutil

import pytest

from agent_team import cli, tasklabel
from agent_team.config import load_team

needs_tmux = pytest.mark.skipif(shutil.which("tmux") is None, reason="нет tmux")
GOOD = "Картинки в сообщениях менеджеру"


def agents(capsys):
    capsys.readouterr()
    assert cli.main(["status", "--json"]) == 0
    return {a["name"]: a for a in json.loads(capsys.readouterr().out)["agents"]}


def test_set_task_shows_in_status_json(project, capsys):
    assert cli.main(["task", "worker", GOOD, "--id", "TASK-484"]) == 0
    a = agents(capsys)["worker#1"]
    assert (a["task"], a["task_title"]) == ("TASK-484", GOOD) and isinstance(a["task_ts"], int)
    b = agents(capsys)["idle#1"]
    assert (b["task"], b["task_title"], b["task_ts"]) == (None, None, None)


def test_task_without_id_and_agent_forms(project, capsys):
    assert cli.main(["task", "worker#2", GOOD]) == 0                 # роль#n; агента может ещё не быть
    assert cli.main(["task", "worker", "Другое название работы"]) == 0
    a = agents(capsys)
    assert a["worker#1"]["task_title"] == "Другое название работы" and a["worker#1"]["task"] is None
    cli.main(["task", "worker", "Первая  задача\tдля теста", "--id", "A-1"])      # пробелы сворачиваются
    assert agents(capsys)["worker#1"]["task_title"] == "Первая задача для теста"
    cli.main(["task", "worker", "Вторая задача для теста"])                      # последняя побеждает, номер сбрасывается
    a = agents(capsys)["worker#1"]
    assert a["task_title"] == "Вторая задача для теста" and a["task"] is None


def test_show_current_and_clear(project, capsys):
    capsys.readouterr()
    assert cli.main(["task", "worker"]) == 0
    assert "задачи нет" in capsys.readouterr().out
    cli.main(["task", "worker", GOOD, "--id", "TASK-1"])
    capsys.readouterr()
    assert cli.main(["task", "worker"]) == 0
    assert capsys.readouterr().out.strip() == f"worker#1: {GOOD} [TASK-1]"
    assert cli.main(["task", "worker", "--clear"]) == 0
    a = agents(capsys)["worker#1"]
    assert (a["task"], a["task_title"], a["task_ts"]) == (None, None, None)
    cli.main(["task", "worker"])
    assert "задачи нет" in capsys.readouterr().out


@pytest.mark.parametrize("title,expect", [
    ("TASK-484", "голый номер"),
    ("#4821", "голый номер"),
    ("Правка в src/agent_team/cli.py", "путь"),
    ("Смотри /etc/hosts сегодня", "путь"),
    ("Исправить cli.py сегодня", "файла"),
    ("Исправить `ComposerField` сегодня", "обратные кавычки"),
    ("Первая строка\nвторая строка", "переводы строки"),
])
def test_bad_titles_are_explained(title, expect):
    assert any(expect in problem for problem in tasklabel.problems(title))


def test_bad_title_is_rejected_without_writing(project, capsys):
    capsys.readouterr()
    assert cli.main(["task", "worker", "TASK-484"]) == 1
    assert "не принято" in capsys.readouterr().err
    assert agents(capsys)["worker#1"]["task_title"] is None            # ничего не записано


def test_all_violations_are_listed_together():
    bad = tasklabel.problems("`a.py`")
    assert len(bad) == 3 and "короче" in bad[0] and "обратные кавычки" in bad[1] and "имя файла" in bad[2]


@pytest.mark.parametrize("title", [GOOD, "Приёмка и/или правка текстов", "Версия 2.1 для владельца", "Картинки в чате, шаг 2",
                                   "Поиск по ролям (черновик)"])
def test_fine_titles_pass(title):
    assert tasklabel.problems(title) == []


def test_boundary_lengths():
    assert tasklabel.problems("а" * 8) == [] and tasklabel.problems("а" * 48) == []
    assert tasklabel.problems("а" * 7) and tasklabel.problems("а" * 49)


def test_unknown_role_and_option_conflicts(project, capsys):
    capsys.readouterr()
    assert cli.main(["task", "ghost", GOOD]) == 1 and "ghost" in capsys.readouterr().err
    assert cli.main(["task", "worker", GOOD, "--clear"]) == 1
    assert cli.main(["task", "worker", "--id", "X-1"]) == 1
    assert cli.main(["task", "worker", GOOD, "--id", "X\n1"]) == 1


def test_legacy_log_task_event_still_gives_task_number(project, capsys):
    team = load_team()
    cli.log_event(team, "task", "worker#1", "взял", task="TASK-5")
    a = agents(capsys)["worker#1"]
    assert (a["task"], a["task_title"]) == ("TASK-5", None) and isinstance(a["task_ts"], int)
    cli.main(["task", "worker", "--clear"])
    assert agents(capsys)["worker#1"]["task"] is None


def test_clear_without_task_writes_no_event(project, capsys):
    team = load_team()
    cli.main(["task", "worker", "--clear"])
    assert not [e for e in cli.read_events(team) if e["type"] == "task"]


def test_task_events_carry_title_key_only_for_team_task(project):
    team = load_team()
    cli.main(["log", "task", "worker", "взял", "--task", "TASK-1"])
    cli.main(["task", "worker", GOOD, "--id", "TASK-2"])
    cli.main(["task", "worker", "--clear"])
    evs = [e for e in cli.read_events(team) if e["type"] == "task"]
    assert "title" not in evs[0]
    assert (evs[1]["title"], evs[1]["task"], evs[1]["text"]) == (GOOD, "TASK-2", GOOD)
    assert evs[2]["title"] is None and evs[2]["task"] is None


def test_status_text_has_task_column_cut_to_width(project, capsys):
    cli.main(["task", "worker", "Очень длинное название которое не влезет в колонку статуса"[:48]])
    capsys.readouterr()
    cli.main(["status"])
    out = capsys.readouterr().out
    head = out.splitlines()[1]
    assert "задача" in head and head.index("задача") < head.index("адрес")
    line = next(ln for ln in out.splitlines() if ln.startswith("worker#1"))
    assert "…" in line and "Очень длинное" in line
    cli.main(["task", "worker", GOOD])
    capsys.readouterr()
    cli.main(["status"])
    assert GOOD in capsys.readouterr().out


@needs_tmux
@pytest.mark.both_layouts
def test_down_clears_task(project, capsys):
    cli.main(["spawn", "worker"])
    cli.main(["task", "worker", GOOD])
    cli.main(["down", "worker"])
    assert agents(capsys)["worker#1"]["task_title"] is None


@needs_tmux
def test_down_all_clears_tasks(project, capsys):
    cli.main(["up"])
    cli.main(["spawn", "worker"])
    cli.main(["task", "worker", GOOD])
    cli.main(["down"])
    assert agents(capsys)["worker#1"]["task_title"] is None


@needs_tmux
def test_restart_fresh_clears_but_resume_keeps_task(project, capsys):
    cli.main(["spawn", "worker"])
    cli.main(["task", "worker", GOOD, "--id", "TASK-3"])
    cli.main(["restart", "worker"])                                    # с продолжением сессии
    a = agents(capsys)["worker#1"]
    assert (a["task_title"], a["task"]) == (GOOD, "TASK-3")
    cli.main(["restart", "worker", "--fresh"])
    a = agents(capsys)["worker#1"]
    assert (a["task_title"], a["task"]) == (None, None)


def test_status_text_name_column_fits_longest_name(project, capsys):
    team = load_team()
    long_role = "app-developer-sonnet"
    ty = team.agents_dir / "team.yaml"
    ty.write_text(ty.read_text(encoding="utf-8") + f"  - {{role: {long_role}, start: manual}}\n", encoding="utf-8")
    (team.agents_dir / "roles" / f"{long_role}.md").write_text("---\nrole: x\ntitle: Длинный\n---\nТело.\n", encoding="utf-8")
    capsys.readouterr()
    cli.main(["status"])
    lines = capsys.readouterr().out.splitlines()
    head, long_line, short_line = lines[1], next(l for l in lines if l.startswith(long_role)), next(l for l in lines if l.startswith("worker#1"))
    assert long_line.startswith(f"{long_role}#1  ")                          # после имени есть отступ
    assert head.index("состояние") == long_line.index("не запущена") == short_line.index("не запущена")
