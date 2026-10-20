"""role set / role new: байт-в-байт сохранение тела и комментариев."""
import json

import pytest

from agent_team import cli
from agent_team.config import load_role, load_team


def out_json(capsys):
    return json.loads(capsys.readouterr().out)


def test_role_set_rewrites_only_named_frontmatter_fields(project, capsys):
    team = load_team()
    path = team.agents_dir / "roles" / "worker.md"
    path.write_text("---\nrole: worker\ntitle: Исполнитель   # имя\nkind: executor\nworktree: {dir: worker, branch: worker}\n"
                    "includes: [rules.md]\n---\nТело: с «двоеточием»\r\n\n  хвост без перевода строки", encoding="utf-8", newline="")
    before = path.read_bytes()
    assert cli.main(["role", "set", "worker", "--title", "Новый: заголовок", "--model", "opus", "--description", "Делает X"]) == 0
    info = out_json(capsys)
    assert info["title"] == "Новый: заголовок" and info["model"] == "opus" and info["description"] == "Делает X"
    after = path.read_bytes()
    body = "Тело: с «двоеточием»\r\n\n  хвост без перевода строки".encode()
    assert after.endswith(b"---\n" + body)                       # тело не тронуто
    assert b"worktree: {dir: worker, branch: worker}\n" in after and b"includes: [rules.md]\n" in after
    assert b"kind: executor\n" in after and before.count(b"\n") < after.count(b"\n")     # добавлены model и description
    assert load_role(load_team(), "worker").title == "Новый: заголовок"


TEAM_YAML_WITH_COMMENTS = ("# шапка\nproject: %s\nrepo: %s\nworktree_root: ../wt\nmanager: boss\n\nroles:\n"
                           "  - {role: boss, start: manual}   # ведущая\n"
                           "  # про worker\n"
                           "  - role: worker   # исполнитель\n    start: always   # поднимается сразу\n    extra: 1\n"
                           "  - idle   # запасная\n# конец\n")


def test_role_set_start_drops_comment_of_changed_line(project, capsys):
    """Комментарий строки, где стоит start, мог описывать прежний режим — при смене значения он убирается.
    Комментарии на других строках (шапка, строка «- role:», отдельные строки) остаются."""
    team = load_team()
    yp = team.agents_dir / "team.yaml"
    yp.write_text(TEAM_YAML_WITH_COMMENTS % (team.project, team.home), encoding="utf-8")
    assert cli.main(["role", "set", "boss", "--start", "always"]) == 0
    assert cli.main(["role", "set", "worker", "--start", "on_demand"]) == 0
    assert cli.main(["role", "set", "idle", "--start", "manual"]) == 0
    capsys.readouterr()
    text = yp.read_text(encoding="utf-8")
    assert text == ("# шапка\nproject: %s\nrepo: %s\nworktree_root: ../wt\nmanager: boss\n\nroles:\n"
                    "  - {role: boss, start: always}\n"
                    "  # про worker\n"
                    "  - role: worker   # исполнитель\n    start: on_demand\n    extra: 1\n"
                    "  - {role: idle, start: manual}\n# конец\n" % (team.project, team.home))
    t = load_team()
    assert [t.start_mode(n) for n in ("boss", "worker", "idle")] == ["always", "on_demand", "manual"]


def test_role_set_same_start_keeps_team_yaml(project, capsys):
    """Режим не меняется — team.yaml не переписывается, комментарии строк остаются."""
    team = load_team()
    yp = team.agents_dir / "team.yaml"
    yp.write_text(TEAM_YAML_WITH_COMMENTS % (team.project, team.home), encoding="utf-8")
    before = yp.read_bytes()
    assert cli.main(["role", "set", "boss", "--start", "manual"]) == 0
    assert cli.main(["role", "set", "worker", "--start", "always"]) == 0
    assert cli.main(["role", "set", "idle", "--start", "on_demand"]) == 0      # режим по умолчанию
    capsys.readouterr()
    assert yp.read_bytes() == before


def test_role_set_start_keeps_crlf_of_block_line(project, capsys):
    team = load_team()
    yp = team.agents_dir / "team.yaml"
    text = (TEAM_YAML_WITH_COMMENTS % (team.project, team.home)).replace("\n", "\r\n")
    yp.write_text(text, encoding="utf-8", newline="")
    assert cli.main(["role", "set", "worker", "--start", "manual"]) == 0
    capsys.readouterr()
    assert b"    start: manual\r\n    extra: 1\r\n" in yp.read_bytes()


def test_role_set_adds_missing_start(project):
    team = load_team()
    yp = team.agents_dir / "team.yaml"
    yp.write_text(yp.read_text(encoding="utf-8").replace("{role: idle, start: on_demand}", "{role: idle}"), encoding="utf-8")
    assert cli.main(["role", "set", "idle", "--start", "always"]) == 0
    assert "{role: idle, start: always}" in yp.read_text(encoding="utf-8")


def test_role_set_errors(project, capsys):
    assert cli.main(["role", "set", "ghost", "--title", "x"]) == 1
    assert cli.main(["role", "set", "worker"]) == 1                 # нечего менять
    capsys.readouterr()
    with pytest.raises(SystemExit):
        cli.main(["role", "set", "worker", "--model", "gpt"])


def test_role_new_creates_file_and_team_yaml_line(project, capsys):
    team = load_team()
    yp = team.agents_dir / "team.yaml"
    before = yp.read_text(encoding="utf-8")
    assert cli.main(["role", "new", "writer", "--title", "Писатель", "--model", "haiku", "--description", "Пишет тексты",
                     "--start", "always"]) == 0
    info = out_json(capsys)
    assert info["role"] == "writer" and info["kind"] == "executor" and info["start"] == "always"
    assert info["worktree"] == {"dir": "writer", "branch": "team/writer", "repo": None}
    assert info["zone"] == [] and info["includes"] == ["rules.md"]           # как у первой роли-исполнителя (worker)
    assert info["model"] == "haiku" and info["title"] == "Писатель" and info["description"] == "Пишет тексты"
    assert yp.read_text(encoding="utf-8") == before + "  - {role: writer, start: always}\n"
    assert load_team().role_names()[-1] == "writer"
    assert cli.main(["role", "new", "writer", "--title", "x"]) == 1          # повтор отклонён
    assert cli.main(["role", "new", "Bad Name", "--title", "x"]) == 1


def test_role_new_defaults(project, capsys):
    assert cli.main(["role", "new", "helper", "--title", "Помощник"]) == 0
    info = out_json(capsys)
    assert info["start"] == "on_demand" and info["model"] == "inherit" and info["description"] == ""
