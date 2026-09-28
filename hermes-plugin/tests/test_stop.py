"""Stop (YUI-190): the mic's stop square while the agent works.

    ~/.hermes/hermes-agent/venv/bin/python hermes-plugin/tests/test_stop.py

The adapter takes the stop control with no turn: Hermes gets /stop for the running
turn, the rows waiting behind it are dropped, and what the stopped turn still says
is held back. Nothing leaves the machine.
"""

import asyncio
import sys
import time
import types
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_board import _adapter_module  # noqa: E402

ad = _adapter_module()
ad.SendResult = lambda **k: types.SimpleNamespace(**k)  # the gateway's, stubbed
ad.ProcessingOutcome = types.SimpleNamespace(SUCCESS="success")


def stop_row(user="owner", rid="stop-1"):
    return {"id": rid, "user_id": user, "agent_id": "a1", "sender": "user", "kind": "control", "body": "stop",
            "meta": {"op": "stop"}, "created_at": "2026-09-28T12:00:00+00:00"}


def text_row(rid, user="owner"):
    return {"id": rid, "user_id": user, "agent_id": "a1", "sender": "user", "kind": "text", "body": "more",
            "meta": {}, "created_at": "2026-09-28T11:59:00+00:00"}


class Stop(unittest.TestCase):
    def make(self):
        a = ad.YuiAdapter.__new__(ad.YuiAdapter)
        a._remote_ref, a._user_id, a._acks = "yui", "owner", set()
        a._queue, a._busy, a._halted, a._turns = {}, {}, {}, {}
        a.marked, a.written, a.dispatched = [], [], []

        async def mark(ids, column):
            a.marked.append((tuple(ids), column))
            return True

        async def write(row):
            a.written.append(row)
            return "sent"

        async def dispatch(rows):
            a.dispatched.append(rows)
        a._mark, a._write_row, a._dispatch = mark, write, dispatch
        return a

    def test_only_the_persons_stop_control_is_a_stop(self):
        self.assertTrue(ad.is_stop(stop_row()))
        self.assertFalse(ad.is_stop({**stop_row(), "sender": "agent"}))
        self.assertFalse(ad.is_stop({**stop_row(), "kind": "text"}))
        self.assertFalse(ad.is_stop({**stop_row(), "meta": {"op": "list"}}))
        a = self.make()
        self.assertFalse(asyncio.run(a._stop("a1", text_row("r1"))))
        self.assertEqual(a.written, [])

    def test_stop_mid_turn_sends_hermes_stop_and_drops_what_waits(self):
        a = self.make()
        a._busy["a1"] = (["r1"], time.time())
        a._queue["a1"] = [text_row("r2"), text_row("r3")]
        self.assertTrue(asyncio.run(a._stop("a1", stop_row())))
        self.assertEqual(len(a.dispatched), 1)
        self.assertEqual(a.dispatched[0][0]["body"], "/stop", "Hermes interrupts its own run")
        self.assertEqual(a.dispatched[0][0]["kind"], "text")
        self.assertNotIn("a1", a._queue, "the rows behind it never run")
        self.assertEqual(a._acks, {"r1", "r2", "r3", "stop-1"}, "all handled, so a restart replays none")
        self.assertIn((("stop-1",), "delivered_at"), a.marked)
        ans = a.written[0]
        self.assertEqual((ans["kind"], ans["sender"], ans["meta"]["op"], ans["meta"]["for"], ans["meta"]["rows"]),
                         ("control", "agent", "stop", "stop-1", 3))
        self.assertTrue(a._held_back("a1"))

    def test_the_stopped_turns_late_reply_is_held_back_until_it_ends(self):
        a = self.make()
        a._busy["a1"] = (["r1"], time.time())
        asyncio.run(a._stop("a1", stop_row()))
        a._client = object()
        r = asyncio.run(a._insert("a1", "Here is the half-finished plan."))
        self.assertEqual(a.written[1:], [], "nothing written after the stop's own answer")
        self.assertTrue(r.success)
        self.assertIsNone(r.message_id)
        # The stopped turn reports back: the next turn speaks again.
        event = object()
        a._turns[id(event)] = ("a1", ["r1"])
        a._doing = type("D", (), {"end": lambda self, k: None})()
        a._poke = lambda: None
        a._flush_acks = lambda: asyncio.sleep(0)
        a._spawn = lambda c: c.close()
        asyncio.run(a.on_processing_complete(event, "cancelled"))
        self.assertFalse(a._held_back("a1"))

    def test_the_hold_lapses(self):
        a = self.make()
        a._halted["a1"] = (["r1"], time.time() - ad.STOP_HOLD_SECONDS - 1)
        self.assertFalse(a._held_back("a1"))

    def test_nothing_running_still_answers_the_stop(self):
        a = self.make()
        self.assertTrue(asyncio.run(a._stop("a1", stop_row())))
        self.assertEqual(a.dispatched, [])
        self.assertEqual(a.written[0]["meta"]["rows"], 0)
        self.assertFalse(a._held_back("a1"))

    def test_someone_shared_stops_only_their_own_chat(self):
        a = self.make()
        a._busy["a1"] = (["mine"], time.time())
        a._busy["a1~u2"] = (["theirs"], time.time())
        asyncio.run(a._stop("a1", stop_row(user="u2")))
        self.assertTrue(a._held_back("a1~u2"))
        self.assertFalse(a._held_back("a1"), "the owner's turn runs on")
        self.assertNotIn("mine", a._acks)


if __name__ == "__main__":
    unittest.main(verbosity=2)
