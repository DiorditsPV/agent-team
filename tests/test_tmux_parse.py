"""Разбор вывода list-panes: битые строки не роняют team, перевод строки в имени окна не рвёт запись."""
import shutil
import time

import pytest

from agent_team import cli, tmuxctl
from agent_team.config import load_team


def row(pane="%1", role="boss#1", widx="0", dead="0", act="100", cmd="claude", pid="42", name="team") -> str:
    return "\t".join([pane, role, widx, dead, act, cmd, pid, name])


def test_parses_ordinary_rows():
    res = tmuxctl.parse_panes(row() + "\n" + row(pane="%2", role="worker", widx="1", name="worker") + "\n")
    assert sorted(res) == ["boss#1", "worker#1"]
    assert res["worker#1"].window == "worker" and res["worker#1"].index == 1 and res["boss#1"].pid == 42


def test_untagged_panes_are_ignored():
    assert tmuxctl.parse_panes(row(role="")) == {}


def test_broken_line_is_skipped_with_warning(capsys):
    res = tmuxctl.parse_panes("garbage\n" + row())
    assert list(res) == ["boss#1"]
    assert "list-panes" in capsys.readouterr().err


def test_empty_line_before_any_row_is_skipped(capsys):
    assert list(tmuxctl.parse_panes("\n" + row())) == ["boss#1"]
    assert "list-panes, которые не разобрать: 1" in capsys.readouterr().err


def test_window_name_with_newlines_stays_in_its_row(capsys):
    out = row(role="boss#1", name="x") + "\n\ny\n" + row(pane="%2", role="worker#1", widx="1", name="w") + "\n"
    res = tmuxctl.parse_panes(out)
    assert res["boss#1"].window == "x\n\ny"
    assert res["worker#1"].window == "w"
    assert capsys.readouterr().err == ""


def test_non_numeric_activity_and_pid_do_not_crash():
    p = tmuxctl.parse_panes(row(act="", pid="?"))["boss#1"]
    assert p.activity == 0 and p.pid == 0


def test_bad_window_index_row_is_skipped(capsys):
    assert tmuxctl.parse_panes(row(widx="x")) == {}
    assert "list-panes" in capsys.readouterr().err


@pytest.mark.skipif(shutil.which("tmux") is None, reason="нет tmux")
def test_status_survives_window_named_with_newlines(project, capsys):
    """Живой tmux: в сессии окно, имя которого — с двумя переводами строки (new-window -n их не экранирует).
    tmux 3.7 и новее отвергают управляющие символы в имени окна, а escape-последовательность и automatic-rename
    их вычищают: такое окно там не создать, и тест пропускается по ответу самого tmux."""
    cli.main(["up"])
    team = load_team()
    res = tmuxctl._run(["new-window", "-d", "-t", f"={team.session}:", "-n", "a\n\nb", "sleep 30"], check=False)
    if res.returncode != 0 and "invalid window name" in res.stderr:
        version = tmuxctl._run(["-V"]).stdout.strip()
        pytest.skip(f"{version} не принимает перевод строки в имени окна — такое окно не создать, проверять нечего")
    assert res.returncode == 0, res.stderr
    raw = tmuxctl._run(["list-panes", "-s", "-t", f"={team.session}", "-F", "#{window_name}"]).stdout
    assert "a\n\nb" in raw                                          # перевод строки дошёл до вывода как есть
    capsys.readouterr()
    assert cli.main(["status", "--json"]) == 0
    assert sorted(tmuxctl.panes(team.session)) == ["boss#1", "worker#1"]
    assert capsys.readouterr().err == ""


@pytest.mark.skipif(shutil.which("tmux") is None, reason="нет tmux")
def test_panes_and_capture_work_without_utf8_locale(project, monkeypatch, capsys):
    """Приложение запускает team из GUI: без LANG и вне tmux. Клиент tmux без -u заменил бы табуляцию и кириллицу
    на «_» (внутри tmux, при заданной TMUX, он считает терминал UTF-8, поэтому из панели это не воспроизводится)."""
    cli.main(["up"])
    team = load_team()
    for var in ("LANG", "LC_CTYPE", "LC_ALL", "TMUX", "TMUX_PANE"):
        monkeypatch.delenv(var, raising=False)
    monkeypatch.setenv("LC_ALL", "C")
    live = tmuxctl.panes(team.session)
    assert sorted(live) == ["boss#1", "worker#1"]
    tmuxctl.send_text(live["worker#1"].id, "привет без локали", enter_delay=0.1)
    end = time.monotonic() + 20
    while "привет без локали" not in tmuxctl.capture(live["worker#1"].id) and time.monotonic() < end:
        time.sleep(0.1)
    assert "привет без локали" in tmuxctl.capture(live["worker#1"].id)
    assert capsys.readouterr().err == ""
