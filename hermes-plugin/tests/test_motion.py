"""Motion (MOTION-1): the agent's one `motion "<ask>"` line, the film the plugin makes, the sketch an older phone gets.

    ~/.hermes/hermes-agent/venv/bin/python hermes-plugin/tests/test_motion.py
"""

import asyncio
import os
import sys
import unittest
from unittest import mock
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "yui"))
from test_board import _adapter_module  # noqa: E402
import compat  # noqa: E402
import motion  # noqa: E402

ASK = "How a heart pumps. Blood enters the right side. The left side pushes it out."
REPLY = f'Here is the heart.\n```yui\nmotion "{ASK}"\n```'
SCENES = [{"name": "hook", "dur": 4.0, "code": 'api.say("Blood in");'},
          {"name": "dive", "dur": 6.0, "code": "c.fillRect(0,0,10,10)"}]


async def fake(ask):
    for s in SCENES:
        yield s


async def none(ask):
    return
    yield


class Split(unittest.TestCase):
    def test_line_is_cut_and_ask_kept(self):
        body, ask = motion.split(REPLY)
        self.assertEqual(ask, ASK)
        self.assertEqual(body.strip(), "Here is the heart.")

    def test_bare_words_work_and_our_own_block_is_left(self):
        _, ask = motion.split("```yui\nmotion how a heart pumps\n```")
        self.assertEqual(ask, "how a heart pumps")
        ours = '```yui\nmotion "T" film=m1 part=1\n=== scene a 4 ===\nx\nend\n```'
        self.assertEqual(motion.split(ours), (ours, None))

    def test_only_the_first_line_counts(self):
        body, ask = motion.split('```yui\nmotion "one"\nmotion "two"\n```')
        self.assertEqual(ask, "one")
        self.assertIn('motion "two"', body)

    def test_no_motion_no_change(self):
        b = "```yui\nsay hi\n```"
        self.assertEqual(motion.split(b), (b, None))


class Make(unittest.TestCase):
    def rows(self, src):
        async def go():
            return [r async for r in motion.make(ASK, film="m1", source=src)]
        return asyncio.run(go())

    def test_each_scene_is_a_row_then_a_closing_part(self):
        rows = self.rows(fake)
        self.assertEqual([r[0] for r in rows], [1, 2, 3])
        self.assertTrue(rows[0][2].startswith('```yui\nmotion "How a heart pumps" film=m1 part=1\n=== scene hook 4 ==='))
        self.assertTrue(rows[1][2].startswith("```yui\nmotion film=m1 part=2\n=== scene dive 6 ==="))
        self.assertEqual(rows[2][2], "```yui\nmotion film=m1 part=3 +last\n```")
        self.assertTrue(rows[2][3] and not rows[0][3])

    def test_no_scene_no_rows(self):
        self.assertEqual(self.rows(none), [])

    def test_harvest_waits_for_the_next_header(self):
        text = "=== scene a 4 ===\none\n=== scene b 5 ===\ntwo"
        got, done = motion.harvest(text, 0)
        self.assertEqual([s["name"] for s in got], ["a"])
        got, done = motion.harvest(text + "\n=== end ===\n", done)
        self.assertEqual([s["name"] for s in got], ["b"])

    def test_cap_per_hour(self):
        motion._calls.clear()
        self.assertTrue(all(motion.allowed(1000.0) for _ in range(motion.MAX_FILMS_PER_HOUR)))
        self.assertFalse(motion.allowed(1000.0))
        self.assertTrue(motion.allowed(5000.0))
        motion._calls.clear()


class Compat(unittest.TestCase):
    FILM = '```yui\nmotion "How a heart pumps. Blood enters." film=m1 part=1\n=== scene hook 4 ===\napi.say("Blood in");\nend\n```'

    def test_old_phone_gets_a_sketch_of_the_says(self):
        out = compat.downgrade(self.FILM, 300)
        self.assertIn('sketch "How a heart pumps" frame=bubble', out)
        self.assertIn('row "Blood in"', out)
        self.assertNotIn("=== scene", out)

    def test_old_phone_gets_the_ask_as_rows(self):
        out = compat.downgrade(f'```yui\nmotion "{ASK}"\n```', 300)
        self.assertIn('sketch "How a heart pumps"', out)
        self.assertIn('row "The left side pushes it out."', out)

    def test_later_parts_say_nothing_to_an_old_phone(self):
        self.assertNotIn("motion", compat.downgrade("```yui\nmotion film=m1 part=3 +last\n```", 300))

    def test_a_phone_that_plays_it_gets_it_as_is(self):
        self.assertEqual(compat.downgrade(self.FILM, compat.MOTION_BUILD), self.FILM)

    def test_a_deck_page_is_a_page(self):
        out = compat.downgrade(f'```yui\ndeck "D"\nmotion "{ASK}"\nend\n```', 300)
        self.assertIn('page "How a heart pumps"', out)

    def test_agents_on_old_builds_are_told_to_skip_it(self):
        self.assertIn("motion", compat.note(300))
        self.assertNotIn("motion", compat.note(compat.MOTION_BUILD))


class Turn(unittest.TestCase):
    def setUp(self):
        motion._calls.clear()
        self.ad = ad = _adapter_module()
        a = self.a = ad.YuiAdapter.__new__(ad.YuiAdapter)
        a._user_id, a._busy, a._last_inbound, a._tasks = "u1", {}, {}, []
        a._outbox, a._client, a._agents, a._notes = [], object(), {"a1": {"handle": "yui"}}, {}
        a.config = type("C", (), {"extra": {"motion_maker": fake}})()
        self.written, self.pushed, self.spawned = [], [], []

        async def write(row):
            self.written.append(row)
            return "sent"

        async def notify(mid, sender, handoff):
            pass
        a._write_row, a._notify = write, notify
        def spawn(coro):
            if coro.__name__ == "_film":
                self.spawned.append(coro)
            else:  # a push
                self.pushed.append(coro.cr_frame.f_locals.get("mid"))
                coro.close()
        a._spawn = spawn
        a._poke = lambda: None
        self.build = compat.MOTION_BUILD
        for obj, name, val in ((ad.flywheel, "record", lambda *_: None), (ad.media, "rewrite", lambda body, *_: body),
                               (ad, "SendResult", lambda **kw: kw), (ad.compat, "build_for", lambda *_: self.build)):
            p = mock.patch.object(obj, name, val)
            p.start()
            self.addCleanup(p.stop)

    def run_all(self):
        async def go():
            for c in list(self.spawned):
                self.spawned.remove(c)
                await c
        asyncio.run(go())

    def send(self, body):
        asyncio.run(self.a._insert("a1", body))

    def test_reply_goes_first_then_the_film_streams(self):
        self.send(REPLY)
        self.assertEqual([r["body"] for r in self.written], ["Here is the heart."])
        self.assertEqual(len(self.spawned), 1)
        self.run_all()
        bodies = [r["body"] for r in self.written][1:]
        self.assertEqual(len(bodies), 3)
        self.assertIn("part=1", bodies[0])
        self.assertIn("+last", bodies[2])

    def test_only_the_first_row_pushes(self):
        self.send(REPLY)
        self.run_all()
        self.assertEqual(len(self.pushed), 2)  # the reply, then film part 1

    def test_a_reply_that_is_only_the_line_still_makes_the_film(self):
        self.send(f'```yui\nmotion "{ASK}"\n```')
        self.assertEqual(self.written, [])
        self.run_all()
        self.assertEqual(len(self.written), 3)

    def test_old_phone_gets_a_sketch_and_no_film(self):
        self.build = 300
        self.ad.compat.downgrade = compat.downgrade
        self.send(REPLY)
        self.assertEqual(self.spawned, [])
        self.assertIn("sketch", self.written[0]["body"])
        self.assertNotIn('motion "', self.written[0]["body"])

    def test_off_sends_words_and_tells_the_agent(self):
        self.a.config.extra["motion"] = "off"
        self.send(REPLY)
        self.assertEqual(self.spawned, [])
        self.assertIn("say", self.written[0]["body"])
        self.assertIn("off", self.a._notes["a1"][0])

    def test_a_film_that_never_starts_becomes_a_sketch(self):
        self.a.config.extra["motion_maker"] = none
        self.ad.compat.downgrade = compat.downgrade
        self.send(REPLY)
        self.run_all()
        self.assertIn("sketch", self.written[-1]["body"])
        self.assertIn("did not start", self.a._notes["a1"][0])


if __name__ == "__main__":
    unittest.main()
