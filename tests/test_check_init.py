import pytest

from agent_team import cli
from agent_team.config import load_team


def test_check_passes_on_good_project(project, capsys):
    assert cli.main(["check"]) == 0
    assert "ошибок 0" in capsys.readouterr().out


def test_check_reports_missing_include_and_shared_worktree(project, capsys):
    team = load_team()
    (team.agents_dir / "shared" / "rules.md").unlink()
    assert cli.main(["check"]) == 1
    assert "подключённого файла нет" in capsys.readouterr().out


def test_check_warns_about_overlapping_zones(project, capsys):
    team = load_team()
    for name in ("worker", "idle"):
        p = team.agents_dir / "roles" / f"{name}.md"
        p.write_text(p.read_text(encoding="utf-8").replace("kind: executor\n", "kind: executor\nzone: [a.py]\n", 1), encoding="utf-8")
    cli.main(["check"])
    assert "a.py" in capsys.readouterr().out


def test_no_args_prints_overview(capsys):
    assert cli.main([]) == 0
    assert "единая точка входа" in capsys.readouterr().out


def test_init_scaffolds_a_project_that_passes_check(tmp_path, monkeypatch, capsys):
    from agent_team import build
    from agent_team.config import load_role
    proj = tmp_path / "newproj"
    proj.mkdir()
    monkeypatch.chdir(proj)
    assert cli.main(["init"]) == 0
    assert (proj / "agents" / "team.yaml").is_file() and (proj / "agents" / "roles" / "manager.md").is_file()
    assert "newproj" in (proj / "agents" / "team.yaml").read_text(encoding="utf-8")
    assert not (proj / "agents" / "shared").exists()                                # общие правила не копируются
    assert not (proj / "agents" / "templates" / "handoff.md").exists()
    assert (proj / "agents" / "templates" / "task-assignment.md").is_file()
    text = (proj / "agents" / "roles" / "manager.md").read_text(encoding="utf-8")
    assert "extends: manager" in text and "Уточнения проекта" in text and "includes" not in text    # тонкая роль
    capsys.readouterr()
    assert cli.main(["check"]) == 0                 # заготовка сама проходит проверку
    out = capsys.readouterr().out
    assert "ошибка" not in out and "расходиться" not in out and "manager:" not in out   # остаются предупреждения черновика executor
    team = load_team()
    for name in ("manager", "executor"):
        inst = build.assemble_instruction(team, load_role(team, name))
        assert "Вопрос или решение по задаче неси менеджеру" in inst            # правило из библиотечного reporting.md
    inst = build.assemble_instruction(team, load_role(team, "manager"))
    assert "## Уточнения проекта" in inst and inst.count("\n---\n") >= 2        # includes общей роли подключены
    assert cli.main(["init"]) == 1                  # повторный init ничего не затирает


def test_check_json_counts_ok_and_lists_issues(project, capsys):
    import json
    assert cli.main(["check", "--json"]) == 0
    data = json.loads(capsys.readouterr().out)
    assert data["passed"] == sum(i["level"] == "ok" for i in data["issues"]) > 0
    assert all(set(i) == {"level", "title", "detail"} for i in data["issues"])
    team = load_team()
    (team.agents_dir / "shared" / "rules.md").unlink()
    assert cli.main(["check", "--json"]) == 1
    data = json.loads(capsys.readouterr().out)
    errs = [i for i in data["issues"] if i["level"] == "error"]
    assert errs and "подключённого файла нет" in errs[0]["detail"] and errs[0]["title"].startswith("роль ")


def test_manager_appendix_names_existing_commands_and_rules():
    """Менеджеру в инструкции названы команды team: каждая существует; ключевые правила на месте."""
    import re
    from agent_team.build import MANAGER_APPENDIX as m
    commands = cli.build_parser()._subparsers._group_actions[0].choices
    named = set(re.findall(r"team ([a-z]+)\b", m))
    assert {"roles", "role", "reap", "set", "task", "handoffs"} <= named
    assert named <= set(commands) | {"up", "send"}, named - set(commands)
    for needle in ("--library", "--extends", "<N|off>", "по умолчанию 15", "--clear", "8–48 знаков", "языком владельца",
                   "сразу после приёмки", "reset_due", "context_warning"):
        assert needle in m


def test_check_warns_about_unknown_kind(project, capsys):
    team = load_team()
    p = team.agents_dir / "roles" / "worker.md"
    p.write_text(p.read_text(encoding="utf-8").replace("kind: executor\n", "kind: assistant\n", 1), encoding="utf-8")
    assert cli.main(["check"]) == 0                      # предупреждение код выхода не меняет
    out = capsys.readouterr().out
    assert "неизвестный kind «assistant»" in out


def test_instruction_carries_zone_and_tracker_zone(project):
    from agent_team import build
    from agent_team.config import load_role
    team = load_team()
    p = team.agents_dir / "roles" / "worker.md"
    p.write_text(p.read_text(encoding="utf-8").replace("kind: executor\n", "kind: executor\nzone: [src/api/, docs/x.md]\ntracker_zone: Бэкенд\n", 1), encoding="utf-8")
    text = build.assemble_instruction(team, load_role(team, "worker"))
    assert "## Зона" in text and "Твоя зона: `src/api/`, `docs/x.md`." in text
    assert "Метка твоей зоны в трекере: «Бэкенд»." in text


def test_executor_without_zone_gets_zone_section_with_task_rule(project):
    from agent_team import build
    from agent_team.config import load_role
    team = load_team()
    text = build.assemble_instruction(team, load_role(team, "worker"))
    assert "## Зона" in text and "Зона в роли не задана" in text and "поле «Файлы»" in text
    assert "Метка твоей зоны" not in text


def test_manager_without_zone_has_no_zone_section(project):
    from agent_team import build
    from agent_team.config import load_role
    team = load_team()
    assert "## Зона" not in build.assemble_instruction(team, load_role(team, team.manager))
