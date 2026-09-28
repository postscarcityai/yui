"""Tables in the reply (YUI-171 step 3, yuigui spec/TABLES.md section 8): table
words in a Hermes agent's ```yui block come out before the reply is saved. The
adapter hands the reply to yui-connect /tables (reply=) and saves the text the
server gives back; a reply of query lines alone is a read, and the rows go back
to the agent as its next turn. After a hand over, the turn opens with the
[yui] tables line the server put on the person's message (meta.tables).

    python3 hermes-plugin/tests/test_tables_reply.py

Nothing leaves the machine: tables.call is a stand-in that keeps the calls.
The live round trip is supabase/tests/tables_reply_e2e.py.
"""
import asyncio
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_restyle  # noqa: E402
from test_shared import AID, CLIENT, OWNER  # noqa: E402

PUT = "Logged.\n```yui\nput meals Food=Oats Cal=300\nquery meals as table\n```"
DRAWN = "Logged.\n```yui\ntable Meals Food|Cal \"Oats|300\"\n```"
READ = "```yui\nquery meals where=Day=today\n```"
NOTE = "[yui] Your tables:\n\nmeals\nFood | Cal\nOats | 300\n\n[yui] Answer the person now."


class ReplyPath(test_restyle.Turn):
    def make(self, answers=None):
        ad, a = super().make(build=test_restyle.MIN + 1)
        a._queue, a.poked, self.calls = {}, [], []
        a._poke = lambda: a.poked.append(1)
        answers = list(answers or [])

        def call(lines="", agent=None, reply=None):
            self.calls.append({"lines": lines, "agent": agent, "reply": reply})
            return answers.pop(0) if answers else (200, {"text": reply, "failed": []})
        ad.tables.call = call
        return ad, a

    def test_table_words_come_out_and_the_server_text_is_saved(self):
        ad, a = self.make([(200, {"text": DRAWN, "wrote": 1, "failed": []})])
        self.send(a, AID, PUT)
        self.assertEqual(self.calls, [{"lines": "", "agent": AID, "reply": PUT}])
        self.assertEqual([w["body"] for w in a.written], [DRAWN])

    def test_a_reply_without_table_words_makes_no_call(self):
        ad, a = self.make()
        self.send(a, AID, "Morning.\n```yui\ncard \"Hi\"\n```")
        self.assertEqual(self.calls, [])
        self.assertEqual(len(a.written), 1)

    def test_a_read_saves_nothing_and_the_rows_are_the_next_turn(self):
        ad, a = self.make([(200, {"read": True, "text": "", "note": NOTE, "results": []})])
        r = self.send(a, AID, READ)
        self.assertEqual(a.written, [])
        self.assertIsNone(r.get("message_id"))
        queued = a._queue[AID]
        self.assertEqual([q["body"] for q in queued], [NOTE])
        self.assertEqual((queued[0]["user_id"], queued[0]["agent_id"], queued[0]["sender"]), (OWNER, AID, "user"))
        self.assertEqual(a.poked, [1])
        asyncio.run(a._dispatch(queued))
        self.assertTrue(a.handled[-1].text.endswith(NOTE), a.handled[-1].text)

    def test_the_third_read_in_a_row_is_drawn_for_the_person(self):
        read = (200, {"read": True, "text": "", "note": NOTE})
        drawn = (200, {"text": "Here they are.\n```yui\ntable Meals Food|Cal \"Oats|300\"\n```", "failed": []})
        ad, a = self.make([read, read, read, drawn])
        for _ in range(3):
            self.send(a, AID, READ)
        self.assertEqual(len(a._queue[AID]), 2)
        self.assertTrue(self.calls[-1]["reply"].startswith("Here they are.\n"))
        self.assertEqual([w["body"] for w in a.written], [drawn[1]["text"]])
        self.assertEqual(a._reads, {})  # a saved reply starts the count again

    def test_yui_unreachable_saves_the_reply_as_is(self):
        ad, a = self.make([(503, {"error": "unreachable"})])
        self.send(a, AID, PUT)
        self.assertEqual([w["body"] for w in a.written], [PUT])

    def test_a_refused_write_is_told_on_the_next_turn(self):
        ad, a = self.make([(200, {"text": "Hm.", "wrote": 0, "failed": [{"line": "", "error": "Cal: \"lots\" is not a number"}]})])
        a._notes = {}
        self.send(a, AID, "Hm.\n```yui\nput meals Cal=lots\n```")
        self.assertEqual(a._notes[AID], ['[yui] Table writes in your last reply were refused: Cal: "lots" is not a number.'])

    def test_only_writes_left_nothing_saves_nothing(self):
        ad, a = self.make([(200, {"text": "", "wrote": 0, "failed": []})])
        self.send(a, AID, "```yui\ntable create meals Food:text\n```")
        self.assertEqual(a.written, [])

    def test_a_shared_thread_never_touches_the_owners_tables(self):
        ad, a = self.make()
        self.send(a, f"{AID}~{CLIENT}", PUT)
        self.assertEqual(self.calls, [])

    def test_a_hand_over_line_opens_the_turn(self):
        ad, a = self.make()
        row = self.row(OWNER, "what did I eat?")
        row["meta"] = {"tables": "[yui] tables foods(3 rows: Food, Cal) meals(1 row: Day, Food)"}
        asyncio.run(a._dispatch([row]))
        text = a.handled[-1].text
        self.assertIn("[yui] tables foods(3 rows: Food, Cal) meals(1 row: Day, Food)\nwhat did I eat?", text)
        client = self.row(CLIENT, "hi")
        client["meta"] = {"tables": "[yui] tables foods(3 rows: Food)"}
        asyncio.run(a._dispatch([client]))
        self.assertNotIn("[yui] tables", a.handled[-1].text)

    def test_a_delete_tap_settles_now_and_says_so(self):
        ad, a = self.make([(200, {"settled": [{"id": "del-ab12", "choice": "Delete", "deleted": 1}], "tables": []})])
        asyncio.run(a._dispatch([self.row(OWNER, "[yui] del-ab12 choose choice=Delete", kind="event")]))
        self.assertEqual(self.calls, [{"lines": "", "agent": AID, "reply": None}])
        self.assertIn("[yui] The person tapped Delete on del-ab12: 1 gone.", a.handled[-1].text)


def load_tests(loader, tests, pattern):
    """Only this file's tests, not the ones the harness classes carry."""
    return unittest.TestSuite(ReplyPath(n) for n in vars(ReplyPath) if n.startswith("test_"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
