"""team set: правка ключа верхнего уровня team.yaml."""
import json

import pytest

from agent_team import cli
from agent_team.config import load_team


def yaml_path():
    return load_team().root / "agents" / "team.yaml"


def test_inserts_missing_key_before_roles(project, capsys):
    before = yaml_path().read_text(encoding="utf-8")
    assert cli.main(["set", "idle_stop_minutes", "10", "--json"]) == 0
    assert json.loads(capsys.readouterr().out) == {"key": "idle_stop_minutes", "value": 10}
    after = yaml_path().read_text(encoding="utf-8")
    assert after == before.replace("roles:\n", "idle_stop_minutes: 10\nroles:\n")
    assert load_team().idle_stop_minutes == 10


def test_replaces_value_and_keeps_comment_and_other_lines(project, capsys):
    path = yaml_path()
    text = path.read_text(encoding="utf-8").replace("roles:\n", "idle_stop_minutes: 5   # гасить через пять\n# про роли\nroles:\n")
    path.write_text(text, encoding="utf-8")
    assert cli.main(["set", "idle_stop_minutes", "30"]) == 0
    assert capsys.readouterr().out.strip() == "idle_stop_minutes: 30"
    assert path.read_text(encoding="utf-8") == text.replace("5   # гасить", "30   # гасить")


def test_off_writes_off_and_is_idempotent(project, capsys):
    cli.main(["set", "idle_stop_minutes", "7"])
    capsys.readouterr()
    assert cli.main(["set", "idle_stop_minutes", "off", "--json"]) == 0
    assert json.loads(capsys.readouterr().out) == {"key": "idle_stop_minutes", "value": None}
    assert "idle_stop_minutes: off\n" in yaml_path().read_text(encoding="utf-8")
    assert load_team().idle_stop_minutes is None
    assert cli.main(["set", "idle_stop_minutes", "off"]) == 0
    assert yaml_path().read_text(encoding="utf-8").count("idle_stop_minutes") == 1
    assert load_team().idle_stop_minutes is None


def test_off_without_key_writes_off(project):
    assert cli.main(["set", "idle_stop_minutes", "off"]) == 0
    assert "idle_stop_minutes: off\nroles:" in yaml_path().read_text(encoding="utf-8")
    assert load_team().idle_stop_minutes is None


def test_set_number_after_off(project):
    cli.main(["set", "idle_stop_minutes", "off"])
    assert cli.main(["set", "idle_stop_minutes", "20"]) == 0
    assert load_team().idle_stop_minutes == 20


@pytest.mark.parametrize("bad", ["0", "abc"])
def test_invalid_value_is_error_without_write(project, capsys, bad):
    before = yaml_path().read_text(encoding="utf-8")
    assert cli.main(["set", "idle_stop_minutes", bad]) == 1
    assert "idle_stop_minutes" in capsys.readouterr().err
    assert yaml_path().read_text(encoding="utf-8") == before


def test_unknown_key_lists_supported(project, capsys):
    before = yaml_path().read_text(encoding="utf-8")
    assert cli.main(["set", "layout", "panes"]) == 1
    assert "idle_stop_minutes" in capsys.readouterr().err
    assert yaml_path().read_text(encoding="utf-8") == before


def test_unclear_line_form_is_error_without_write(project, capsys):
    path = yaml_path()
    text = path.read_text(encoding="utf-8").replace("roles:\n", "idle_stop_minutes: &a 5\nroles:\n")
    path.write_text(text, encoding="utf-8")
    assert cli.main(["set", "idle_stop_minutes", "5"]) == 1
    assert "вручную" in capsys.readouterr().err
    assert path.read_text(encoding="utf-8") == text


def test_plain_output_in_words(project, capsys):
    cli.main(["set", "idle_stop_minutes", "12"])
    assert capsys.readouterr().out.strip() == "idle_stop_minutes: 12"
    cli.main(["set", "idle_stop_minutes", "off"])
    assert capsys.readouterr().out.strip() == "idle_stop_minutes: off (выключено)"
