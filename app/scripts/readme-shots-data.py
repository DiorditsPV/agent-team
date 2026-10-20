#!/usr/bin/env python3
"""Подставные данные демо-проекта «shop» для снимков README (запускается из readme-shots.sh).

  readme-shots-data.py transcript <роль#n> <session_id> <cwd> <каталог CLAUDE_HOME> <фаза> <каталог сокетов>
  readme-shots-data.py screen     <роль#n> <каталог экранов> <фаза>

Только стандартная библиотека. Тексты английские; личных путей и имён в данных нет.
"""
import json
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

NOW = time.time()
OWNER_ADDR = {}


def slug(cwd):
    return "".join(c if (c.isascii() and c.isalnum()) else "-" for c in cwd)


class Writer:
    def __init__(self, sid, span):
        self.sid, self.rows, self.t, self.n = sid, [], 0.0, 0

    def ts(self, dt=4.0):
        """Время записи — смещение от начала; при записи файла всё сдвигается так, чтобы конец был «только что»."""
        self.t += dt
        return self.t

    def _id(self):
        self.n += 1
        return f"msg_{self.n:04d}"

    def owner(self, text, dt=20):
        self.rows.append({"type": "user", "uuid": str(uuid.uuid4()), "isSidechain": False, "timestamp": self.ts(dt),
                          "sessionId": self.sid, "message": {"role": "user", "content": text}})

    def incoming(self, name, addr, text, dt=20):
        body = f'<cross-session-message from="{addr}" from-name="{name}" from-mode="prompting">\n{text}\n</cross-session-message>'
        self.owner(body, dt)

    def text(self, text, dt=6):
        self._assistant([{"type": "text", "text": text}], dt)

    def tool(self, name, inp, result="ok", dt=3):
        tid = "toolu_" + uuid.uuid4().hex[:12]
        self._assistant([{"type": "tool_use", "id": tid, "name": name, "input": inp}], dt)
        if result is not None:
            self.rows.append({"type": "user", "uuid": str(uuid.uuid4()), "isSidechain": False, "timestamp": self.ts(2),
                              "sessionId": self.sid,
                              "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": tid, "content": result}]}})

    def _assistant(self, blocks, dt):
        self.rows.append({"type": "assistant", "uuid": str(uuid.uuid4()), "isSidechain": False, "timestamp": self.ts(dt),
                          "sessionId": self.sid,
                          "message": {"model": "claude-opus-5-5", "id": self._id(), "role": "assistant", "content": blocks,
                                      "usage": {"input_tokens": 3, "cache_creation_input_tokens": 2000,
                                                "cache_read_input_tokens": 61000, "output_tokens": 300}}})

    def end(self, ms=42000):
        self.rows.append({"type": "system", "subtype": "turn_duration", "uuid": str(uuid.uuid4()), "isSidechain": False,
                          "timestamp": self.ts(1), "sessionId": self.sid, "durationMs": ms})

    def dump(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        shift = NOW - 45 - self.t
        for r in self.rows:
            t = r["timestamp"] + shift
            r["timestamp"] = datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (int((t % 1) * 1000))
        path.write_text("\n".join(json.dumps(r) for r in self.rows) + "\n", encoding="utf-8")


def addr(socks, agent):
    return f"uds:{socks}/{agent.replace('#', '-')}.sock"


TASKS = {
    "developer#1": ("SHOP-14", "Checkout form validation"),
    "developer#2": ("SHOP-15", "Order receipt e-mails"),
    "reviewer#1": ("SHOP-16", "Review of promo-code change"),
    "tester#1": ("SHOP-17", "Cart regression suite"),
}

STATUS_TABLE = """| Lane | Owner | State | Next |
|---|---|---|---|
| Checkout form validation | developer #1 | tests green, waiting for review | merge after verdict |
| Order receipt e-mails | developer #2 | template done, sending untested | staging smoke test |
| Promo-code change review | reviewer #1 | 2 findings sent back | developer #1 fixes |
| Cart regression suite | tester #1 | 41 of 48 cases pass | coupon edge cases |"""

MANAGER_REPLY = f"""Here is where the four lanes stand:

{STATUS_TABLE}

**What blocks the release**

- Receipt e-mails cannot be tried end to end: staging has no SMTP credentials. That is your call.
- One review finding is real: `apply_coupon()` rounds the discount *before* tax, so totals drift by a cent on some carts.

**What I suggest**

1. Let developer #1 fix the rounding first; the fix is small and the tester can re-run the coupon cases right after.
2. Merge validation to the test line once the reviewer accepts it.
3. Hold the e-mail branch until staging has credentials.

Say the word and I will start on 1 and 2."""


def manager_transcript(w, socks, phase):
    d1, d2, rv, ts = (addr(socks, a) for a in ("developer#1", "developer#2", "reviewer#1", "tester#1"))
    w.owner("Start on the checkout form validation and the order receipt e-mails in parallel. Promo codes can wait.", 5400)
    w.tool("Bash", {"command": 'team task developer#1 "Checkout form validation" --id SHOP-14', "description": "Set the task title"},
           "developer#1: task SHOP-14 set", dt=20)
    w.tool("SendMessage", {"to": d1, "summary": "Checkout validation",
                           "message": "SHOP-14 — validate the checkout form: required fields, card number length, ZIP format. Zone: web/checkout. Report when the tests pass."},
           "delivered", dt=8)
    w.tool("SendMessage", {"to": d2, "summary": "Receipt e-mails",
                           "message": "SHOP-15 — send a receipt e-mail after payment. Plain text and HTML parts, order total with tax. Zone: web/mail."},
           "delivered", dt=8)
    w.text("Both lanes are running. developer #1 takes the checkout validation, developer #2 the receipt e-mails; their zones do not overlap.", dt=10)
    w.end(61000)
    w.owner("Good. Ask the reviewer to look at the promo-code change as soon as it lands, and have the tester start the cart regression suite.", 1500)
    w.tool("SendMessage", {"to": rv, "summary": "Review promo codes",
                           "message": "SHOP-16 — review the promo-code branch of developer #1. Look for rounding and for coupons that stack."},
           "delivered", dt=15)
    w.tool("SendMessage", {"to": ts, "summary": "Cart regression",
                           "message": "SHOP-17 — run the cart regression suite against the current test line and list failures by cart type."},
           "delivered", dt=8)
    w.text("The reviewer and the tester are both on their way.", dt=8)
    w.end(38000)
    if phase == "busy":
        w.owner("Where do we stand? A short table, and what is blocking the release.", 600)
        w.tool("Bash", {"command": "team status", "description": "Show agents"}, "manager#1 idle\ndeveloper#1 working\ndeveloper#2 working\nreviewer#1 working\ntester#1 working", dt=15)
        return
    w.incoming("reviewer#1", rv, "Verdict: return. 1. web/cart/coupon.py:88 — discount rounded before tax — totals drift by a cent. 2. tests/test_coupon.py — no case for two stacked coupons.", dt=900)
    w.tool("Bash", {"command": "team status", "description": "Show agents"}, "manager#1 idle\ndeveloper#1 working\ndeveloper#2 working\nreviewer#1 idle\ntester#1 working", dt=12)
    w.text(MANAGER_REPLY, dt=14)
    w.end(52000)
    if phase == "idle":
        return


def agent_transcript(w, agent, socks, phase):
    mgr = addr(socks, "manager#1")
    tid, title = TASKS[agent]
    if agent == "developer#1":
        w.incoming("Manager", mgr, f"{tid} — validate the checkout form: required fields, card number length, ZIP format. Zone: web/checkout. Report when the tests pass.", 5300)
        w.tool("Read", {"file_path": "web/checkout/form.py"}, "class CheckoutForm: ...", dt=6)
        w.tool("Read", {"file_path": "tests/test_checkout.py"}, "def test_required_fields(): ...", dt=5)
        w.tool("Edit", {"file_path": "web/checkout/form.py", "old_string": "def clean(self):", "new_string": "def clean(self):\n        self._check_card_length()"}, "edited", dt=30)
        w.tool("Bash", {"command": "pytest tests/test_checkout.py -q", "description": "Run checkout tests"}, "14 passed in 0.8s", dt=20)
        w.text("Validation is in: required fields, card length 13–19 digits, ZIP by country. 14 tests pass.", dt=8)
        w.tool("SendMessage", {"to": mgr, "summary": "SHOP-14 ready", "message": "SHOP-14 done: branch developer, 14 tests pass, ready for review."}, "delivered", dt=6)
        w.end(180000)
        w.incoming("Manager", mgr, "reviewer #1 sent the promo-code change back: discount is rounded before tax in apply_coupon(). Please fix and add a stacked-coupon test.", 1200)
        w.tool("Read", {"file_path": "web/cart/coupon.py"}, "def apply_coupon(cart, code): ...", dt=6)
    elif agent == "developer#2":
        w.incoming("Manager", mgr, f"{tid} — send a receipt e-mail after payment. Plain text and HTML parts, order total with tax. Zone: web/mail.", 5300)
        w.tool("Read", {"file_path": "web/mail/templates/receipt.html"}, "<h1>Thank you</h1> ...", dt=6)
        w.tool("Edit", {"file_path": "web/mail/receipt.py", "old_string": "def build(order):", "new_string": "def build(order):\n    total = order.total_with_tax()"}, "edited", dt=40)
        w.tool("Bash", {"command": "pytest tests/test_receipt.py -q", "description": "Run receipt tests"}, "9 passed in 0.4s", dt=20)
        w.text("The template renders with tax and shipping. Sending still needs staging SMTP credentials, so I stop at the unit level.", dt=8)
    elif agent == "reviewer#1":
        w.incoming("Manager", mgr, f"{tid} — review the promo-code branch of developer #1. Look for rounding and for coupons that stack.", 3000)
        w.tool("Bash", {"command": "git diff main...HEAD --stat", "description": "Diff of the branch"}, " web/cart/coupon.py | 24 ++++\n tests/test_coupon.py | 18 +++", dt=8)
        w.tool("Read", {"file_path": "web/cart/coupon.py"}, "def apply_coupon(cart, code): ...", dt=6)
        w.text("Two findings: the discount is rounded before tax, and no test covers two stacked coupons. Verdict: return.", dt=12)
        w.tool("SendMessage", {"to": mgr, "summary": "Verdict", "message": "Verdict: return. 1. web/cart/coupon.py:88 — discount rounded before tax. 2. tests/test_coupon.py — no stacked-coupon case."}, "delivered", dt=6)
        w.end(95000)
    elif agent == "tester#1":
        w.incoming("Manager", mgr, f"{tid} — run the cart regression suite against the current test line and list failures by cart type.", 2900)
        w.tool("Bash", {"command": "pytest tests/cart -q", "description": "Run cart suite"}, "41 passed, 7 failed in 12.3s", dt=40)
        w.text("41 of 48 cases pass. The 7 failures are all coupon carts; I am splitting them by coupon type now.", dt=8)


BANNER = [" ▐▛███▛█   Claude Code v2.1.295", "▝▜██████▀  Opus 5.5 · Claude Max", " ▝▝   ▝▝   ~/shop"]


def rule(cols):
    return "─" * cols


def screen(agent, outdir, phase, cols=96):
    out = Path(outdir)
    out.mkdir(parents=True, exist_ok=True)
    name = agent.replace("#", "-")
    top = list(BANNER)
    bottom = [rule(cols), "❯ ", rule(cols), "  [Opus 5.5] shop main 0m ~/shop", "  ⏸ manual mode on"]
    if agent == "manager#1" and phase == "slash":
        menu = [("/agents", "Manage agent configurations"), ("/clear", "Clear conversation history and free up context"),
                ("/compact", "Clear history but keep a summary in context"), ("/config", "Open the settings panel"),
                ("/context", "Show current context usage"), ("/cost", "Show the total cost and duration of this session"),
                ("/help", "Show help and available commands")]
        menu_lines = []
        for i, (c, d) in enumerate(menu):
            menu_lines.append(("  ❯ " if i == 0 else "    ") + c.ljust(22) + d)
        bottom = menu_lines + bottom
        bottom[len(menu_lines) + 1] = "❯ /"
    elif agent == "manager#1" and phase == "busy":
        top += ["", "⏺ Bash(team status)", "  ⎿  manager#1 idle · developer#1 working · developer#2 working", "",
                "⏺ Four lanes are running. The validation branch waits for a verdict, the e-mail branch",
                "  for staging credentials, and the coupon cases are being split by type. The one real",
                "  finding is the rounding of the discount before tax.", "", "✻ Reconciling… (38s · ↓ 1.2k tokens · thinking)"]
    else:
        tid, title = TASKS.get(agent, ("", ""))
        top += ["", f"⏺ {title or 'Ready'}", "", "  Waiting for the next message."]
    (out / f"{name}.top").write_text("\n".join(top) + "\n", encoding="utf-8")
    (out / f"{name}.bottom").write_text("\n".join(bottom) + "\n", encoding="utf-8")


def main():
    a = sys.argv[1:]
    if a[0] == "transcript":
        agent, sid, cwd, home, phase, socks = a[1:7]
        w = Writer(sid, 6000)
        if agent == "manager#1":
            manager_transcript(w, socks, phase)
        else:
            agent_transcript(w, agent, socks, phase)
        w.dump(Path(home) / ".claude/projects" / slug(cwd) / f"{sid}.jsonl")
    elif a[0] == "screen":
        screen(a[1], a[2], a[3])


if __name__ == "__main__":
    main()
