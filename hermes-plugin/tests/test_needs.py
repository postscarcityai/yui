"""One-tap answers from the war room (YUI-73): a `choose@need-<task id>` answer
lands on the kanban card as a comment and unblocks it, with no agent turn, and
only for the paired owner.

    ~/.hermes/hermes-agent/venv/bin/python hermes-plugin/tests/test_needs.py

The parse tests need nothing. The DB and adapter tests need hermes-agent on the
path (HERMES_AGENT, default ~/.hermes/hermes-agent); they skip without it.
Every DB here is a fresh temp file, never the real board.
"""

import asyncio
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_board import _adapter_module, _load, PLUGIN, kb  # noqa: E402

needs = _load("yui_needs", PLUGIN / "yui" / "needs.py")


def event(task="t_0a0b0c", choice="a: board kit", **extra):
    return {"id": "row-1", "kind": "event", "user_id": "owner", "agent_id": "a1",
            "body": f"[yui] need-{task} choose choice=\"{choice}\"",
            "meta": {"id": f"need-{task}", "preset": "choose", "value": {"choice": choice, **extra}}}


class Parse(unittest.TestCase):
    def test_answer_of(self):
        self.assertEqual(needs.answer_of(event()),
                         {"task": "t_0a0b0c", "choice": "a: board kit", "typed": False, "changed": False})
        typed = needs.answer_of(event(choice="  me@example.com ", other=True, changed=True, saved="war room"))
        self.assertEqual((typed["choice"], typed["typed"], typed["changed"]), ("me@example.com", True, True))

    def test_a_typed_answer_form(self):
        e = event()
        e["meta"]["preset"], e["meta"]["value"] = "form", {"form": {"answer": "me@example.com"}}
        self.assertEqual(needs.answer_of(e), {"task": "t_0a0b0c", "choice": "me@example.com", "typed": True, "changed": False})
        e["meta"]["value"] = {"form": {"other": "x"}}
        self.assertIsNone(needs.answer_of(e), "a form with no answer field is not an answer")

    def test_other_events_are_not_answers(self):
        self.assertIsNone(needs.answer_of({**event(), "kind": "text"}))
        e = event()
        e["meta"]["preset"] = "ask"
        self.assertIsNone(needs.answer_of(e), "only choose and form rows")
        for bad in ("n1", "need-", "need-YUI-60", "need-t_0a0b0c extra", "xneed-t_0a0b0c"):
            e = event()
            e["meta"]["id"] = bad
            self.assertIsNone(needs.answer_of(e), bad)
        self.assertIsNone(needs.answer_of(event(choice="  ")))

    def test_reply_and_note(self):
        ok = {"ok": True, "card": "YUI-60", "task": "t_1", "choice": "Park it", "unblocked": True, "status": "ready"}
        self.assertEqual(needs.reply(ok), "Sent to YUI-60: Park it. It's back in the queue.")
        self.assertEqual(needs.reply({**ok, "status": "todo"}), "Sent to YUI-60: Park it. It's waiting on its parent card.")
        self.assertEqual(needs.reply({**ok, "unblocked": False}), "Noted on YUI-60: Park it.")
        self.assertEqual(needs.reply({"ok": False, "card": "YUI-9", "why": "done"}), "Couldn't answer YUI-9: done.")
        self.assertIn("no reply needed", needs.note(ok))


BOARD = [
    ("t_aa01", "YUI-60 (backlog): games in lines", "blocked", "yui"),
    ("t_aa02", "YUI-56: invites end to end", "blocked", None),
    ("t_aa03", "AMC-4: docket", "blocked", "r0ss"),
    ("t_aa04", "YUI-65: timeline", "done", "yui"),
    ("t_aa05", "YUI-73: war room panels", "running", "yui"),
    ("t_aa06", "YUI-70: agent controls", "blocked", "yui"),
]


@unittest.skipIf(kb is None, "hermes-agent not importable")
class RealBoard(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.db = Path(self.dir.name) / "kanban.db"
        with kb.connect_closing(self.db) as conn:
            now = int(time.time())
            for i, (tid, title, status, who) in enumerate(BOARD):
                conn.execute("INSERT INTO tasks (id, title, assignee, status, created_at) VALUES (?, ?, ?, ?, ?)",
                             (tid, title, who, status, now + i))
            # YUI-70 waits on the running YUI-73: an answer unblocks it to todo, not ready.
            conn.execute("INSERT INTO task_links (parent_id, child_id) VALUES ('t_aa05', 't_aa06')")
            conn.commit()

    def tearDown(self):
        self.dir.cleanup()

    def rows(self, sql, *args):
        with kb.connect_closing(self.db) as conn:
            return [tuple(r) for r in conn.execute(sql, args).fetchall()]

    def answer(self, task, choice="a: board kit", **extra):
        return needs.apply("yui", needs.answer_of(event(task, choice, **extra)), self.db)

    def test_answer_comments_and_unblocks(self):
        r = self.answer("t_aa01")
        self.assertEqual((r["ok"], r["card"], r["unblocked"], r["status"]), (True, "YUI-60", True, "ready"))
        c = self.rows("SELECT author, body FROM task_comments WHERE task_id = 't_aa01'")
        self.assertEqual(c, [("chris (yui-app)", "ANSWER (Chris, tapped in the Yui war room): a: board kit")])
        self.assertEqual(self.rows("SELECT status FROM tasks WHERE id = 't_aa01'")[0][0], "ready")
        # Chris changes his mind: a second comment, the card stays queued.
        r2 = self.answer("t_aa01", "Park it", changed=True)
        self.assertEqual((r2["ok"], r2["unblocked"], r2["was"]), (True, False, "ready"))
        self.assertEqual(needs.reply(r2), "Noted on YUI-60: Park it.")
        self.assertEqual(self.rows("SELECT body FROM task_comments WHERE task_id = 't_aa01' ORDER BY id")[-1][0],
                         "ANSWER CHANGED (Chris, tapped in the Yui war room): Park it")

    def test_unassigned_card_and_typed_answer(self):
        r = self.answer("t_aa02", "me@example.com", other=True)
        self.assertTrue(r["ok"] and r["unblocked"])
        self.assertIn("typed in the Yui war room): me@example.com",
                      self.rows("SELECT body FROM task_comments WHERE task_id = 't_aa02'")[0][0])

    def test_a_card_with_an_open_parent_goes_to_todo(self):
        r = self.answer("t_aa06", "Build it")
        self.assertEqual((r["unblocked"], r["status"]), (True, "todo"))
        self.assertTrue(needs.reply(r).endswith("waiting on its parent card."))

    def test_other_agents_done_and_missing_cards_are_left_alone(self):
        self.assertEqual(self.answer("t_aa03")["why"], "r0ss's card")
        self.assertEqual(self.answer("t_aa04")["why"], "done")
        self.assertEqual(self.answer("t_ffff")["why"], "not on the board")
        self.assertEqual(self.rows("SELECT count(*) FROM task_comments")[0][0], 0)
        self.assertEqual(self.rows("SELECT status FROM tasks WHERE id = 't_aa03'")[0][0], "blocked")


@unittest.skipIf(kb is None, "hermes-agent not importable")
class AdapterPath(RealBoard):
    """The adapter takes the row, applies it, answers without a turn, and queues no turn."""

    def make(self, user_id="owner"):
        ad = _adapter_module()
        a = ad.YuiAdapter.__new__(ad.YuiAdapter)
        a._remote_ref, a._user_id, a._notes, a._acks = "yui", user_id, {}, set()
        a.marked, a.written = [], []

        async def mark(ids, column):
            a.marked.append((tuple(ids), column))
            return True

        async def write(row):
            a.written.append(row)
            return "sent"
        a._mark, a._write_row = mark, write
        db, orig = self.db, needs.apply
        ad.needs.apply = lambda board, ans: orig(board, ans, db)
        return a

    def test_owner_answers_without_a_turn(self):
        a = self.make()
        self.assertTrue(asyncio.run(a._need_answer("a1", event("t_aa01", "Park it"))))
        self.assertEqual(a.written[0]["body"], "Sent to YUI-60: Park it. It's back in the queue.")
        self.assertEqual(a.written[0]["meta"]["turn"], ["row-1"], "the reply names the row, so a restart never replays it")
        self.assertIn("row-1", a._acks)
        self.assertIn("YUI-60", a._notes["a1"][0])
        self.assertEqual(self.rows("SELECT status FROM tasks WHERE id = 't_aa01'")[0][0], "ready")

    def test_someone_else_cannot_answer(self):
        a = self.make(user_id="someone-else")
        self.assertTrue(asyncio.run(a._need_answer("a1", event("t_aa01"))))
        self.assertEqual(a.written[0]["body"], "Only the owner can answer these cards.")
        self.assertEqual(self.rows("SELECT status FROM tasks WHERE id = 't_aa01'")[0][0], "blocked")
        self.assertEqual(self.rows("SELECT count(*) FROM task_comments")[0][0], 0)

    def test_ordinary_choose_goes_to_the_agent(self):
        a = self.make()
        plain = event()
        plain["meta"]["id"] = "n3"
        self.assertFalse(asyncio.run(a._need_answer("a1", plain)))
        self.assertEqual(a.written, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
