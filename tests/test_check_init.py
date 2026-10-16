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
    proj = tmp_path / "newproj"
    proj.mkdir()
    monkeypatch.chdir(proj)
    assert cli.main(["init"]) == 0
    assert (proj / "agents" / "team.yaml").is_file() and (proj / "agents" / "roles" / "manager.md").is_file()
    assert "newproj" in (proj / "agents" / "team.yaml").read_text(encoding="utf-8")
    capsys.readouterr()
    assert cli.main(["check"]) == 0                 # заготовка сама проходит проверку
    assert cli.main(["init"]) == 1                  # повторный init ничего не затирает
