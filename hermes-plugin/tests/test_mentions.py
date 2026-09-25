"""@mentions on the host (YUI-44): @handles out in a reply, notes in on the next turn.

    ~/.hermes/hermes-agent/venv/bin/python hermes-plugin/tests/test_mentions.py

The routing itself is SQL, tested live in supabase/tests/mention_test.py.
These need nothing but the plugin source.
"""

import asyncio
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_board import _adapter_module, _load, PLUGIN  # noqa: E402

mentions = _load("yui_mentions", PLUGIN / "yui" / "mentions.py")


class Handles(unittest.TestCase):
    def test_finds_handles_in_order(self):
        self.assertEqual(mentions.handles_in("Asking @Coach and @pilot now. @coach again"), ["coach", "pilot"])

    def test_at_most_three_never_its_own(self):
        self.assertEqual(mentions.handles_in("@a @b @yui @c @d", own=["yui"]), ["a", "b", "c"])

    def test_emails_and_screens_and_code_do_not_count(self):
        text = "Mail me@example.com\n```yui\nask a1 \"@coach?\" Yes|No\n```\nRun `hermes @nova` or ask @scout-2."
        self.assertEqual(mentions.handles_in(text), ["scout-2"])

    def test_unclosed_fence_hides_the_rest(self):
        self.assertEqual(mentions.handles_in("hi @a\n```yui\nnote @b"), ["a"])

    def test_nothing(self):
        self.assertEqual(mentions.handles_in(""), [])
        self.assertEqual(mentions.handles_in("@ alone, @-dash, @_under"), [])


class Notes(unittest.TestCase):
    def test_person_mention_then_answer(self):
        rows = [
            {"sender": "user", "body": "[yui] mention to=coach\n@Coach does this fit my knee?",
             "meta": {"mention": {"to": "b", "handle": "coach", "name": "Coach"}}},
            {"sender": "agent", "body": "Coach is asleep. It gets this when its computer wakes.",
             "meta": {"mention_reply": {"agent": "b", "name": "Coach", "status": "asleep"}}},
            {"sender": "agent", "body": "Swap squats for box squats.\n```yui\nask b1 \"Swap?\" Yes|No\n```",
             "meta": {"mention_reply": {"agent": "b", "name": "Coach", "msg": "m2"}}},
        ]
        self.assertEqual(mentions.notes(rows), [
            "[yui] note: in this thread the person asked Coach, not you: @Coach does this fit my knee?",
            "[yui] note: Coach answered here: Swap squats for box squats. [screen]",
        ])

    def test_long_answers_are_cut(self):
        n = mentions.notes([{"sender": "agent", "body": "x" * 2000, "meta": {"mention_reply": {"name": "Coach"}}}])
        self.assertLess(len(n[0]), 700)
        self.assertTrue(n[0].endswith("…"))

    def test_other_rows_say_nothing(self):
        self.assertEqual(mentions.notes([{"sender": "user", "body": "hi", "meta": {}}]), [])


class FakeResponse:
    def __init__(self, rows, status=200):
        self.rows, self.status_code, self.text = rows, status, ""

    def json(self):
        return self.rows


class FakeClient:
    def __init__(self, rows):
        self.rows, self.calls = rows, []

    async def get(self, url, headers=None, params=None):
        self.calls.append(params)
        return FakeResponse(self.rows)


class AdapterPath(unittest.TestCase):
    def make(self, rows=()):
        ad = _adapter_module()
        a = ad.YuiAdapter.__new__(ad.YuiAdapter)
        a._cursor, a._agents, a._client = {"a1": "2026-09-25T00:00:00+00:00"}, {"a1": {"handle": "yui"}}, FakeClient(list(rows))
        a._rest_headers = lambda: {}
        a.saved = 0

        def save():
            a.saved += 1
        a._save_cursor = save
        return ad, a

    def test_notes_since_last_turn_move_the_floor(self):
        rows = [{"id": "m1", "sender": "agent", "created_at": "2026-09-25T01:00:00+00:00", "body": "Box squats.",
                 "meta": {"mention_reply": {"name": "Coach"}}}]
        ad, a = self.make(rows)
        got = asyncio.run(a._mention_notes("a1", "2026-09-25T02:00:00+00:00"))
        self.assertEqual(got, ["[yui] note: Coach answered here: Box squats."])
        p = a._client.calls[0]
        self.assertEqual((p["agent_id"], p["created_at"]), ("eq.a1", "gt.2026-09-25T00:00:00+00:00"))
        self.assertIn("meta->mention_reply", p["or"])
        self.assertEqual(p["and"], '(created_at.lte."2026-09-25T02:00:00+00:00")')
        self.assertEqual(a._cursor["mention:a1"], "2026-09-25T01:00:00+00:00")
        self.assertEqual(a.saved, 1)
        a._client.rows = []
        asyncio.run(a._mention_notes("a1", None))
        self.assertEqual(a._client.calls[1]["created_at"], "gt.2026-09-25T01:00:00+00:00")

    def test_a_failure_is_no_notes(self):
        ad, a = self.make()

        async def boom(*_, **__):
            raise OSError("network down")
        a._client.get = boom
        self.assertEqual(asyncio.run(a._mention_notes("a1", None)), [])
        self.assertNotIn("mention:a1", a._cursor)

    def test_reply_to_the_person_carries_its_mentions(self):
        ad, a = self.make()
        a._user_id, a._busy, a._last_inbound, a._tasks = "u1", {"a1": (["row-1"], 0)}, {}, []
        a._outbox = []
        written = []

        async def write(row):
            written.append(row)
            return "sent"
        a._write_row = write
        a._spawn = lambda coro: coro.close()
        ad.flywheel.record = lambda *_: None
        ad.media.rewrite = lambda body, *_: body
        ad.SendResult = lambda **kw: kw
        asyncio.run(a._insert("a1", "Asking @coach now, @yui is me."))
        self.assertEqual(written[0]["meta"], {"turn": ["row-1"], "mentions": ["coach"]})
        asyncio.run(a._insert("a1", "No one to ask."))
        self.assertEqual(written[1]["meta"], {"turn": ["row-1"]})
        asyncio.run(a._insert("a1", "Handoff for @coach", sender="Coach"))
        self.assertNotIn("meta", written[2])


if __name__ == "__main__":
    unittest.main(verbosity=2)
