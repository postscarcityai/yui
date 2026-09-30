"""Jev in a turn (YUI-215): shadow by default, one hint line behind the flag, never blocks.

    ~/.hermes/hermes-agent/venv/bin/python hermes-plugin/tests/test_jev_turn.py
"""

import asyncio
import os
import sys
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_chats as tc  # noqa: E402  (the same adapter stubs)

AID, ad, row = tc.AID, tc.ad, tc.row

jev = ad.jev


def decision(shape="card", conf=0.93):
    return {"shape": shape, "conf": conf, "things": 1.0, "map": 0.01, "camera": 0.01, "camera_kind": "none",
            "ms": 210, "cost": 0.00002}


class Turn(unittest.TestCase):
    make = tc.Chats.make
    patch = tc.Chats.patch

    def setUp(self):
        self.calls = []
        os.environ["OPENROUTER_API_KEY"] = "test"
        os.environ.pop("YUI_JEV_HINT", None)
        self.addCleanup(os.environ.pop, "OPENROUTER_API_KEY", None)
        self.addCleanup(os.environ.pop, "YUI_JEV_HINT", None)

        def fake(message, agent="", has_photo=False, last_shape="none", **kw):
            self.calls.append(message)
            return dict(decision())
        self.patch(jev, "decide", fake)
        self.a = self.make()
        self.a.config = type("C", (), {"extra": {}})()

    def run_turn(self, body="Am I on the latest build?", **kw):
        asyncio.run(self.a._dispatch([row(body=body, **kw)]))
        return self.a.handled[-1]

    def test_shadow_by_default_adds_nothing_to_the_turn(self):
        ev = self.run_turn()
        self.assertEqual(self.calls, ["Am I on the latest build?"])
        self.assertNotIn("hint", ev.channel_prompt)
        d, name = self.a._jev_pending[AID]
        self.assertEqual((d["shape"], d["hinted"], name), ("card", False, "Coach"))

    def test_flag_on_adds_one_hint_line(self):
        self.a.config.extra = {"jev_hint": True}
        ev = self.run_turn()
        hints = [ln for ln in ev.channel_prompt.split("\n") if ln.startswith("[yui] hint:")]
        self.assertEqual(len(hints), 1)
        self.assertIn("shape=card (0.93)", hints[0])
        self.assertTrue(self.a._jev_pending[AID][0]["hinted"])

    def test_below_the_line_says_nothing_even_with_the_flag(self):
        self.a.config.extra = {"jev_hint": True}
        self.patch(jev, "decide", lambda *a, **k: decision(conf=0.6))
        ev = self.run_turn()
        self.assertNotIn("hint", ev.channel_prompt)

    def test_a_line_answer_is_logged_but_never_hinted(self):
        self.a.config.extra = {"jev_hint": True}
        self.patch(jev, "decide", lambda *a, **k: decision("line", 0.97))
        ev = self.run_turn()
        self.assertNotIn("hint", ev.channel_prompt)
        d, _ = self.a._jev_pending[AID]
        self.assertEqual((d["shape"], d["hinted"]), ("line", False))

    def test_taps_and_commands_make_no_call(self):
        self.run_turn(body="[yui] n1 choose choice=Legs", kind="event")
        self.run_turn(body="/stop")
        self.assertEqual(self.calls, [])

    def test_a_shared_agents_turn_makes_no_call(self):
        self.a._user_id = "someone-else"  # not the owner of this agent's thread
        self.run_turn()
        self.assertEqual(self.calls, [])

    def test_no_key_no_call(self):
        os.environ.pop("OPENROUTER_API_KEY")
        self.run_turn()
        self.assertEqual(self.calls, [])

    def test_a_failed_call_still_runs_the_turn(self):
        self.patch(jev, "decide", lambda *a, **k: None)
        ev = self.run_turn()
        self.assertEqual(ev.text, "Am I on the latest build?")
        self.assertNotIn(AID, self.a.__dict__.get("_jev_pending", {}))

    def test_a_slow_jev_never_holds_the_turn(self):
        def slow(*a, **k):
            time.sleep(2.0)
            return decision()
        self.patch(jev, "decide", slow)
        took = []

        async def timed():
            t = time.perf_counter()
            await self.a._dispatch([row(body="Am I on the latest build?")])
            took.append(time.perf_counter() - t)
        asyncio.run(timed())
        ev = self.a.handled[-1]
        self.assertLess(took[0], 0.9)  # the timeout is 0.6 s; the thread is left to finish on its own
        self.assertEqual(ev.text, "Am I on the latest build?")
        self.assertNotIn(AID, self.a.__dict__.get("_jev_pending", {}))


if __name__ == "__main__":
    unittest.main()
