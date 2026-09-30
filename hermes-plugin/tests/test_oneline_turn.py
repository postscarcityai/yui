"""One line and a picture in a turn (VIS-1): shadow sends the reply as written, `on` rewrites it,
a second prose bubble in the same turn gets no line.

    ~/.hermes/hermes-agent/venv/bin/python hermes-plugin/tests/test_oneline_turn.py
"""

import asyncio
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_board import _adapter_module  # noqa: E402

WALL = ("You're right, I misread you. You meant the left drawer, not TestFlight.\n\n"
        "The drawer had stopped updating. One card with badly saved text crashed every refresh, so a finished card stayed under Now.\n\n"
        "```yui\nsketch \"Left drawer\" frame=phone\nrow \"Done card gone\" +hi\n```\n\nA new card covers the rest.")


class Turn(unittest.TestCase):
    def setUp(self):
        os.environ["YUI_ONELINE_LOG"] = str(Path(tempfile.mkdtemp()) / "o.jsonl")
        self.addCleanup(os.environ.pop, "YUI_ONELINE_LOG", None)
        os.environ.pop("YUI_ONE_LINE", None)
        self.ad = ad = _adapter_module()
        a = self.a = ad.YuiAdapter.__new__(ad.YuiAdapter)
        a._user_id, a._busy, a._last_inbound, a._tasks = "u1", {"a1": (["row-1"], 0)}, {}, []
        a._outbox, a._client, a._agents = [], object(), {}
        a._notes = {}
        a._agents = {"a1": {"handle": "yui"}}
        a.config = type("C", (), {"extra": {}})()
        self.written = []

        async def write(row):
            self.written.append(row)
            return "sent"
        a._write_row = write
        a._spawn = lambda coro: coro.close()
        ad.flywheel.record = lambda *_: None
        ad.media.rewrite = lambda body, *_: body
        ad.SendResult = lambda **kw: kw
        ad.compat.downgrade = lambda body, build: body  # the phone draws everything

    def send(self, body):
        asyncio.run(self.a._insert("a1", body))
        return self.written[-1]["body"]

    def test_shadow_sends_as_written(self):
        self.assertEqual(self.send(WALL).strip(), WALL.strip())

    def test_on_sends_one_line_and_the_picture(self):
        self.a.config.extra = {"one_line": "on"}
        body = self.send(WALL)
        self.assertTrue(body.startswith("You're right, I misread you."))
        self.assertIn('sketch "Left drawer"', body)
        self.assertNotIn("A new card covers the rest", body)

    def test_second_prose_bubble_in_the_turn_is_picture_only(self):
        self.a.config.extra = {"one_line": "on"}
        self.assertEqual(self.send("Build 392 is out."), "Build 392 is out.")
        second = self.send("One more thing, the drawer is fixed.\n```yui\nstat 12 Cards\n```")
        self.assertNotIn("One more thing", second)
        self.assertIn("stat 12 Cards", second)

    def test_a_new_turn_starts_clean(self):
        self.a.config.extra = {"one_line": "on"}
        self.send("Build 392 is out.")
        self.a._busy = {"a1": (["row-2"], 0)}
        self.assertEqual(self.send("Fresh turn, one line."), "Fresh turn, one line.")

    def test_a_handoff_is_left_alone(self):
        self.a.config.extra = {"one_line": "on"}
        asyncio.run(self.a._insert("a1", WALL, sender="Coach"))
        self.assertEqual(self.written[-1]["body"].strip(), WALL.strip())


if __name__ == "__main__":
    unittest.main()
