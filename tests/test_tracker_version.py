"""tracker в status --json (строка или объект) и team --version."""
import importlib.metadata
import json
import subprocess
import sys

import pytest

from agent_team import cli
from agent_team.config import load_team


def status(capsys):
    capsys.readouterr()
    assert cli.main(["status", "--json"]) == 0
    return json.loads(capsys.readouterr().out)


def add_tracker(project, text):
    yp = load_team().root / "agents" / "team.yaml"
    yp.write_text(yp.read_text(encoding="utf-8") + text, encoding="utf-8")


def test_tracker_string_stays_string(project, capsys):
    add_tracker(project, "tracker: Linear DEMO\n")
    assert status(capsys)["tracker"] == "Linear DEMO"


def test_tracker_mapping_is_an_object(project, capsys):
    add_tracker(project, "tracker:\n  kind: linear\n  project: DEMO\n  team: 3\n")
    assert status(capsys)["tracker"] == {"kind": "linear", "project": "DEMO", "team": 3}


def test_tracker_mapping_with_non_json_values_does_not_break_status(project, capsys):
    add_tracker(project, "tracker:\n  kind: linear\n  since: 2026-10-17\n")
    t = status(capsys)["tracker"]
    assert t["kind"] == "linear" and t["since"] == "2026-10-17"


def test_tracker_absent_or_empty_is_null(project, capsys):
    assert status(capsys)["tracker"] is None
    add_tracker(project, "tracker: {}\n")
    assert status(capsys)["tracker"] is None


def test_version_flag_prints_package_version(capsys):
    with pytest.raises(SystemExit) as e:
        cli.main(["--version"])
    assert e.value.code == 0
    assert capsys.readouterr().out.strip() == f"team {importlib.metadata.version('agent-team')}"


def test_version_via_entry_point_module():
    out = subprocess.run([sys.executable, "-m", "agent_team.cli", "--version"], capture_output=True, text=True)
    assert out.returncode == 0 and out.stdout.startswith("team ") and out.stdout.split()[1][0].isdigit()
