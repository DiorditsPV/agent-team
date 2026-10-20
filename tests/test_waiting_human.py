"""Признак waiting_human на живых экранах claude 2.1.295 (фикстуры приложения) и на меню владельца."""
from pathlib import Path

import pytest

from agent_team.cli import waiting_human

FIX = Path(__file__).resolve().parent.parent / "app/Tests/AgentTeamCoreTests/Fixtures"


def tail(name: str, n: int = 15) -> str:
    lines = (FIX / name).read_text().rstrip().splitlines()
    return "\n".join(lines[-n:])


def test_permission_prompt_waits():
    assert waiting_human(tail("live-perm.txt"))


def test_ask_form_waits():
    assert waiting_human(tail("live-ask.txt"))


def test_rewind_menu_does_not_wait():
    assert not waiting_human(tail("live-rewind.txt"))


@pytest.mark.parametrize("name", ["live-multi.txt", "live-at.txt", "live-slash.txt", "live-typed.txt"])
def test_idle_input_does_not_wait(name):
    assert not waiting_human(tail(name))


def test_bare_esc_to_cancel_does_not_wait():
    assert not waiting_human("Some menu\nEsc to cancel")


def test_review_answers_screen_waits():
    assert waiting_human("Review your answers\n\nReady to submit your answers?\n❯ 1. Submit answers\n  2. Cancel")


@pytest.mark.parametrize("name", sorted(p.name for p in FIX.glob("live-longform-*.txt")))
def test_ask_form_wrapped_in_narrow_pane_waits(name):
    # подсказка формы в узкой панели перенесена: «… ctrl+g to edit» / «in VS Code · Esc to cancel»
    assert waiting_human(tail(name))


def test_ask_form_hint_split_inside_esc_to_cancel_waits():
    assert waiting_human("  4. Chat about this\n\nEnter to select · ↑/↓ to navigate · Esc\nto cancel")


def test_rewind_hint_wrapped_does_not_wait():
    assert not waiting_human("Restore the code?\nEnter to continue · ↑/↓ to navigate ·\nEsc to cancel")


def test_old_select_hint_far_above_does_not_join_with_cancel():
    assert not waiting_human("Enter to select · ↑/↓ to navigate\nответ принят\nдальше работа\nEsc to cancel")
