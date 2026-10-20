"""Наследование роли проекта от общей роли библиотеки (extends)."""
import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

from agent_team import build, cli, config
from agent_team.config import TeamError, library_dir, library_role_names, load_role, load_team

CHILD = """\
---
role: judge
extends: judge
title: Судья проекта
zone: [docs/]
worktree: {dir: judge, branch: team/judge}
tracker_zone: Ревью
includes: [rules.md, safety.md]
allow: ["Bash(make *)"]
add_dirs: ["~/docs"]
---
Проверяй ещё и миграции.
"""


@pytest.fixture
def lib(tmp_path, monkeypatch):
    """Маленькая библиотека вместо настоящей: тесты не зависят от текстов roles/."""
    root = tmp_path / "lib"
    (root / "shared").mkdir(parents=True)
    (root / "shared" / "safety.md").write_text("# Безопасность\nТолько чтение.\n", encoding="utf-8")
    (root / "base.md").write_text(
        "---\nrole: base\ntitle: Основа\nkind: reviewer\nstatus: active\ndescription: из библиотеки\nmodel: opus\n"
        "worktree: {dir: lib, branch: lib}\nzone: [lib/]\ntracker_zone: Lib\n"
        "includes: [safety.md]\nallow: [\"Bash(ls *)\", \"Bash(make *)\"]\nadd_dirs: [\"~/docs\", \"~/lib\"]\n---\nТело основы.\n",
        encoding="utf-8")
    (root / "chain.md").write_text("---\nrole: chain\nextends: base\n---\nЦепочка.\n", encoding="utf-8")
    (root / "README.md").write_text("# Библиотека\n", encoding="utf-8")
    monkeypatch.setattr(config, "library_dir", lambda: root)
    monkeypatch.setattr(build, "library_dir", lambda: root)
    monkeypatch.setattr(cli, "library_dir", lambda: root)
    return root


def write_child(team, text, name="child"):
    (team.agents_dir / "roles" / f"{name}.md").write_text(text, encoding="utf-8")


CHILD_OF_BASE = CHILD.replace("role: judge\nextends: judge", "role: child\nextends: base")


def test_instruction_is_base_then_project_notes_then_includes(project, lib):
    team = load_team()
    write_child(team, CHILD_OF_BASE)
    text = build.assemble_instruction(team, load_role(team, "child"))
    base, notes, mine, safety, rules = (text.index(s) for s in (
        "Тело основы.", "## Уточнения проекта", "Проверяй ещё и миграции.", "Только чтение.", "Не ломать."))
    assert base < notes < mine < safety < rules           # includes: сначала общей роли, затем проекта
    assert text.count("Только чтение.") == 1              # safety.md в проекте нет → берётся из библиотеки


def test_project_include_wins_over_library_one(project, lib):
    team = load_team()
    (team.agents_dir / "shared" / "safety.md").write_text("проектная безопасность\n", encoding="utf-8")
    write_child(team, CHILD_OF_BASE)
    text = build.assemble_instruction(team, load_role(team, "child"))
    assert "проектная безопасность" in text and "Только чтение." not in text


def test_fields_merge_rules(project, lib):
    team = load_team()
    write_child(team, CHILD_OF_BASE)
    role = load_role(team, "child")
    assert role.extends == "base"
    assert role.title == "Судья проекта"                      # перекрыто проектом
    assert role.kind == "reviewer"                            # нет в проекте → из библиотеки
    assert role.meta["model"] == "opus" and role.meta["description"] == "из библиотеки"
    assert role.includes == ["safety.md", "rules.md"]         # объединены, повтор убран
    assert role.allow == ["Bash(ls *)", "Bash(make *)"]
    assert role.add_dirs == ["~/docs", "~/lib"]
    assert role.meta["zone"] == ["docs/"] and role.worktree == {"dir": "judge", "branch": "team/judge"}
    assert role.meta["tracker_zone"] == "Ревью"


def test_zone_worktree_tracker_zone_are_not_inherited(project, lib):
    team = load_team()
    write_child(team, "---\nrole: child\nextends: base\n---\nКоротко.\n")
    role = load_role(team, "child")
    assert role.worktree is None and "zone" not in role.meta and "tracker_zone" not in role.meta


def test_project_may_override_every_overridable_field(project, lib):
    team = load_team()
    write_child(team, "---\nrole: child\nextends: base\nmodel: haiku\nkind: executor\nstatus: draft\ndescription: свой\n---\nx\n")
    m = load_role(team, "child").meta
    assert (m["model"], m["kind"], m["status"], m["description"]) == ("haiku", "executor", "draft", "свой")


def test_file_without_extends_works_as_before(project, lib):
    team = load_team()
    role = load_role(team, "worker")
    assert role.extends is None and role.base_body is None
    assert "Уточнения проекта" not in build.assemble_instruction(team, role)


def test_missing_base_is_an_error(project, lib):
    team = load_team()
    write_child(team, "---\nrole: child\nextends: nope\n---\nx\n")
    with pytest.raises(TeamError, match="нет в библиотеке"):
        load_role(team, "child")


def test_chain_is_rejected(project, lib):
    team = load_team()
    write_child(team, "---\nrole: child\nextends: chain\n---\nx\n")
    with pytest.raises(TeamError, match="на один уровень"):
        load_role(team, "child")


@pytest.mark.parametrize("bad", ["../x", "'1'", "[base]"])
def test_extends_must_be_a_plain_library_name(project, lib, bad):
    team = load_team()
    write_child(team, f"---\nrole: child\nextends: {bad}\n---\nx\n")
    with pytest.raises(TeamError, match="extends"):
        load_role(team, "child")


def add_child_to_team(team):
    ty = team.agents_dir / "team.yaml"
    ty.write_text(ty.read_text(encoding="utf-8") + "  - {role: child, start: on_demand}\n", encoding="utf-8")


def test_check_errors_on_missing_base(project, lib, capsys):
    team = load_team()
    write_child(team, "---\nrole: child\nextends: nope\n---\nx\n")
    add_child_to_team(team)
    assert cli.main(["check"]) == 1
    out = capsys.readouterr().out
    assert "ошибка:" in out and "«nope»" in out


def test_check_warns_about_copy_named_like_library_role(project, lib, capsys):
    team = load_team()
    write_child(team, "---\nrole: base\ntitle: Копия\n---\nКопия.\n", name="base")
    ty = team.agents_dir / "team.yaml"
    ty.write_text(ty.read_text(encoding="utf-8") + "  - {role: base, start: manual}\n", encoding="utf-8")
    assert cli.main(["check"]) == 0                              # предупреждение не валит проверку
    out = capsys.readouterr().out
    assert "предупреждение:" in out and "extends" in out and "расходиться" in out
    cli.main(["check", "--json"])
    issues = json.loads(capsys.readouterr().out)["issues"]
    assert [i for i in issues if i["level"] == "warn" and i["title"] == "роль base"]


def test_roles_json_has_source_and_extends(project, lib, capsys):
    team = load_team()
    write_child(team, CHILD_OF_BASE)
    add_child_to_team(team)
    assert cli.main(["roles", "--json"]) == 0
    roles = json.loads(capsys.readouterr().out)
    assert [r["role"] for r in roles] == ["boss", "worker", "idle", "child"]     # без --library — только роли проекта
    assert all(r["source"] == "project" for r in roles)
    boss, child = roles[0], roles[3]
    assert boss["extends"] is None and child["extends"] == "base"
    assert child["title"] == "Судья проекта" and child["kind"] == "reviewer" and child["model"] == "opus"
    assert child["includes"] == ["safety.md", "rules.md"]
    assert child["file"].endswith("agents/roles/child.md")
    assert child["body"] == "Проверяй ещё и миграции.\n"                      # тело файла проекта
    assert child["instruction"].startswith("Тело основы.") and "## Уточнения проекта" in child["instruction"]


def test_roles_json_library_adds_library_roles(project, lib, capsys):
    assert cli.main(["roles", "--json", "--library"]) == 0
    roles = json.loads(capsys.readouterr().out)
    library = [r for r in roles if r["source"] == "library"]
    assert [r["role"] for r in library] == ["base", "chain"]                    # README.md не роль
    base = library[0]
    assert base["extends"] is None and base["start"] is None and base["running"] == 0
    assert base["file"] == str(lib / "base.md") and base["title"] == "Основа"
    assert base["instruction"].startswith("Тело основы.") and "Только чтение." in base["instruction"]


def test_roles_json_error_entry_keeps_source_and_extends(project, lib, capsys):
    team = load_team()
    write_child(team, "---\nrole: child\nextends: nope\n---\nx\n")
    add_child_to_team(team)
    cli.main(["roles", "--json"])
    child = json.loads(capsys.readouterr().out)[3]
    assert child["source"] == "project" and child["extends"] == "nope" and "нет в библиотеке" in child["error"]


def test_roles_text_lists_library(project, lib, capsys):
    assert cli.main(["roles", "--library"]) == 0
    out = capsys.readouterr().out
    assert "[библиотека]" in out and "base" in out


def test_real_library_has_roles_and_shared():
    assert {"judge", "developer", "manager"} <= set(library_role_names())
    assert (library_dir() / "shared" / "safety.md").is_file()


def test_real_judge_extends_end_to_end(project, capsys):
    team = load_team()
    write_child(team, "---\nrole: child\nextends: judge\ndescription: проектный судья\n---\nПроверяй ещё и миграции.\n")
    add_child_to_team(team)
    assert cli.main(["check"]) == 0
    text = build.assemble_instruction(team, load_role(team, "child"))
    assert text.index("## Уточнения проекта") > 0 and "Проверяй ещё и миграции." in text      # тело общей роли идёт раньше


@pytest.mark.skipif(shutil.which("uv") is None, reason="нужен uv")
def test_library_found_from_non_editable_install(tmp_path):
    """Колесо ставится в чистый venv; библиотека находится рядом с установленным пакетом."""
    repo = Path(__file__).resolve().parent.parent
    dist = tmp_path / "dist"
    build_res = subprocess.run(["uv", "build", "--wheel", "--out-dir", str(dist), str(repo)], capture_output=True, text=True)
    if build_res.returncode != 0:
        pytest.skip(f"колесо не собралось (нет доступа к hatchling?): {build_res.stderr[-200:]}")
    wheel = next(dist.glob("*.whl"))
    venv = tmp_path / "venv"
    subprocess.run(["uv", "venv", "-q", str(venv)], check=True)
    py = venv / "bin" / "python"
    inst = subprocess.run(["uv", "pip", "install", "-q", "--python", str(py), str(wheel)], capture_output=True, text=True)
    if inst.returncode != 0:
        pytest.skip(f"не удалось поставить колесо (нет сети для PyYAML?): {inst.stderr[-200:]}")
    code = ("import agent_team.config as c; d = c.library_dir(); "
            "print(d); print(*c.library_role_names()); print((d / 'shared' / 'safety.md').is_file())")
    out = subprocess.run([str(py), "-I", "-c", code], capture_output=True, text=True, cwd=tmp_path)
    assert out.returncode == 0, out.stderr
    lines = out.stdout.splitlines()
    assert "site-packages" in lines[0] and lines[0].endswith("agent_team/library")
    assert "judge" in lines[1].split() and lines[2] == "True"
    assert not str(repo) in lines[0]


# --- team init и team role new/set с extends ------------------------------------------------------------

def test_empty_project_notes_omit_the_heading(project, lib):
    team = load_team()
    write_child(team, "---\nrole: child\nextends: base\n---\n")
    assert "Уточнения проекта" not in build.assemble_instruction(team, load_role(team, "child"))


def test_role_new_extends_creates_thin_file(project, lib, capsys):
    assert cli.main(["role", "new", "jj", "--extends", "base"]) == 0
    info = json.loads(capsys.readouterr().out)
    assert info["extends"] == "base" and info["title"] == "Основа" and info["kind"] == "reviewer"
    team = load_team()
    text = (team.agents_dir / "roles" / "jj.md").read_text(encoding="utf-8")
    assert "extends: base" in text and "includes" not in text and "title" not in text
    assert "worktree: {dir: jj, branch: team/jj}" in text          # у общей роли worktree есть → проекту нужен свой
    assert team.start_mode("jj") == "manual"                       # для наследующей роли start по умолчанию manual
    assert cli.main(["check"]) == 0 and "предупреждение" not in capsys.readouterr().out


def test_role_new_extends_with_overrides(project, lib, capsys):
    assert cli.main(["role", "new", "jj", "--extends", "base", "--title", "Мой: судья", "--model", "sonnet", "--start", "manual"]) == 0
    info = json.loads(capsys.readouterr().out)
    assert info["title"] == "Мой: судья" and info["model"] == "sonnet" and info["start"] == "manual"


@pytest.mark.parametrize("bad,msg", [("nope", "нет в библиотеке"), ("chain", "на один уровень"), ("../x", "extends")])
def test_role_new_extends_errors_leave_no_files(project, lib, capsys, bad, msg):
    assert cli.main(["role", "new", "jj", "--extends", bad]) == 1
    assert msg in capsys.readouterr().err
    team = load_team()
    assert not (team.agents_dir / "roles" / "jj.md").exists() and "jj" not in team.role_names()


def test_role_new_without_title_and_extends_still_fails(project, capsys):
    assert cli.main(["role", "new", "jj"]) == 1
    assert "--title" in capsys.readouterr().err


def test_role_set_extends_sets_and_clears(project, lib, capsys):
    team = load_team()
    path = team.agents_dir / "roles" / "worker.md"
    before = path.read_text(encoding="utf-8")
    assert cli.main(["role", "set", "worker", "--extends", "base"]) == 0
    info = json.loads(capsys.readouterr().out)
    assert info["extends"] == "base" and info["instruction"].startswith("Тело основы.")
    assert "extends: base\n" in path.read_text(encoding="utf-8")
    assert cli.main(["role", "set", "worker", "--extends", ""]) == 0
    info = json.loads(capsys.readouterr().out)
    assert info["extends"] is None
    assert path.read_text(encoding="utf-8") == before            # снятие возвращает файл байт в байт


@pytest.mark.parametrize("bad,msg", [("nope", "нет в библиотеке"), ("chain", "на один уровень")])
def test_role_set_extends_errors_do_not_touch_file(project, lib, capsys, bad, msg):
    team = load_team()
    path = team.agents_dir / "roles" / "worker.md"
    before = path.read_bytes()
    assert cli.main(["role", "set", "worker", "--extends", bad, "--title", "Х"]) == 1
    assert msg in capsys.readouterr().err
    assert path.read_bytes() == before


def test_role_new_extends_same_name_as_library_role_and_json_flag(project, lib, capsys):
    assert cli.main(["role", "new", "base", "--extends", "base", "--json"]) == 0
    info = json.loads(capsys.readouterr().out)
    assert info["role"] == "base" and info["extends"] == "base" and info["source"] == "project" and info["start"] == "manual"
    assert cli.main(["check"]) == 0 and "расходиться" not in capsys.readouterr().out
    assert cli.main(["role", "new", "base", "--extends", "base"]) == 1             # роль уже есть
    assert "уже есть" in capsys.readouterr().err


# --- exclude: наследующая роль убирает элементы общей роли ------------------------------------------------

EXCL = "---\nrole: child\nextends: base\nexclude: {exclude}\nincludes: [rules.md]\nallow: [\"Bash(make *)\", \"Bash(own *)\"]\n---\nx\n"


def test_exclude_removes_base_items_only(project, lib):
    team = load_team()
    write_child(team, EXCL.format(exclude='{includes: [safety.md], allow: ["Bash(ls *)"], add_dirs: ["~/lib"]}'))
    role = load_role(team, "child")
    assert role.includes == ["rules.md"]
    assert role.allow == ["Bash(make *)", "Bash(own *)"]            # Bash(make *) есть и в общей, и в проекте — остаётся
    assert role.add_dirs == ["~/docs"] and role.unmatched_excludes == []
    assert role.exclude == {"includes": ["safety.md"], "allow": ["Bash(ls *)"], "add_dirs": ["~/lib"]}
    text = build.assemble_instruction(team, role)
    assert "Только чтение." not in text and "Не ломать." in text     # исключённый include не подключается


def test_exclude_does_not_remove_own_items(project, lib):
    team = load_team()
    write_child(team, EXCL.format(exclude='{allow: ["Bash(own *)"]}'))
    assert "Bash(own *)" in load_role(team, "child").allow


def test_exclude_everything_inherited_leaves_only_own(project, lib):
    team = load_team()
    write_child(team, "---\nrole: child\nextends: base\nexclude: {includes: [safety.md]}\n---\nx\n")
    assert load_role(team, "child").includes == []


@pytest.mark.parametrize("bad,msg", [("[safety.md]", "словарь"), ("{include: [safety.md]}", "exclude.include"),
                                     ("{includes: safety.md}", "список")])
def test_exclude_bad_shape_is_an_error(project, lib, bad, msg):
    team = load_team()
    write_child(team, EXCL.format(exclude=bad))
    with pytest.raises(TeamError, match=msg):
        load_role(team, "child")


def test_check_warns_about_unmatched_exclude(project, lib, capsys):
    team = load_team()
    write_child(team, EXCL.format(exclude='{includes: [safety.md, nope.md], allow: ["Bash(zz *)"]}'))
    add_child_to_team(team)
    assert cli.main(["check"]) == 0
    out = capsys.readouterr().out
    assert "includes: nope.md" in out and "allow: Bash(zz *)" in out and "includes: safety.md" not in out


def test_check_warns_about_exclude_without_extends(project, lib, capsys):
    team = load_team()
    write_child(team, "---\nrole: child\nexclude: {includes: [a.md]}\n---\nx\n")
    add_child_to_team(team)
    assert cli.main(["check"]) == 0
    assert "exclude без extends" in capsys.readouterr().out


def test_check_errors_on_bad_exclude(project, lib, capsys):
    team = load_team()
    write_child(team, EXCL.format(exclude="[safety.md]"))
    add_child_to_team(team)
    assert cli.main(["check"]) == 1
    assert "exclude" in capsys.readouterr().out


def test_roles_json_exposes_exclude(project, lib, capsys):
    team = load_team()
    write_child(team, EXCL.format(exclude='{includes: [safety.md]}'))
    add_child_to_team(team)
    cli.main(["roles", "--json"])
    roles = json.loads(capsys.readouterr().out)
    assert roles[3]["exclude"] == {"includes": ["safety.md"], "allow": [], "add_dirs": []}
    assert roles[0]["exclude"] == {"includes": [], "allow": [], "add_dirs": []}
