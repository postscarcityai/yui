"""Motion (MOTION-1): the agent's one `motion "<ask>"` line, the film the plugin makes, the sketch an older phone gets.

    ~/.hermes/hermes-agent/venv/bin/python hermes-plugin/tests/test_motion.py
"""

import asyncio
import json
import re
import os
import sys
import time
import unittest
from unittest import mock
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "yui"))
from test_board import _adapter_module  # noqa: E402
import compat  # noqa: E402
import motion  # noqa: E402
import shown  # noqa: E402

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

    def test_a_scene_name_with_spaces_still_harvests(self):
        out, _ = motion.harvest("=== scene Settings redesign 4 ===\napi.look('agent');\n=== end ===\n", 0)
        self.assertEqual([x["name"] for x in out], ["Settingsredesign"])

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


class SplitFilm(unittest.TestCase):
    """Scene 1 from the small model, the rest from the big one, both at once."""

    def _run(self, fast, slow):
        calls = []

        async def fake(ask, model="big", extra="", think=True):
            calls.append((model, think, "ONLY scene 1" in extra))
            for s in (fast if model == motion.OPENER_MODEL else slow):
                yield s

        async def go():
            with mock.patch.object(motion, "claude_cli", fake):
                return [s["name"] async for s in motion.split_film("ask")]
        return asyncio.run(go()), calls

    def test_small_model_opens_without_thinking_then_the_big_one_follows(self):
        names, calls = self._run([{"name": "a"}], [{"name": "s2"}, {"name": "s3"}])
        self.assertEqual(names, ["a", "s2", "s3"])
        self.assertIn((motion.OPENER_MODEL, False, True), calls)

    def test_no_opener_the_film_starts_at_scene_two(self):
        names, _ = self._run([], [{"name": "s2"}])
        self.assertEqual(names, ["s2"])


class Hero(unittest.TestCase):
    """The kit draws the hero (MOTION-14): picked from the ask by words, written into scene 1, kept in later scenes."""

    def setUp(self):  # no test reaches the model for a hero the kit lacks
        import tempfile
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        h = motion.motion_hero
        for patcher in (mock.patch.object(h, "THINGS_ON", False), mock.patch.dict(os.environ, {h.CACHE_ENV: os.path.join(self._tmp.name, "things.json")})):
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_pick_by_words(self):
        pick = motion.motion_hero.pick
        self.assertEqual(pick("How a heart pumps blood"), "heart")
        self.assertEqual(pick("Why a cat purrs"), "cat")
        self.assertEqual(pick("Roast a lemon-garlic chicken: the steps"), "roast")  # a chicken being cooked, the lemon is a side
        self.assertEqual(pick("How a chicken lays an egg"), "chicken")
        self.assertEqual(pick("What the Home screen shows"), None)  # "home screen" is an app, not a house
        self.assertEqual(pick("Show the Earth and Moon in real 3D (api.three)"), None)  # a 3D film draws its own bodies
        self.assertIsNone(motion.motion_hero.pick("A mood: a quiet evening"))
        self.assertIsNone(motion.motion_hero.pick(""))

    def test_put_in_after_the_look_or_at_the_top(self):
        h = motion.motion_hero
        a = h.put_in("api.look('sketch');\napi.say('x');", "dog", True)
        self.assertLess(a.index("api.look"), a.index('api.thing("dog"'))
        self.assertLess(a.index('api.thing("dog"'), a.index("api.say"))
        self.assertIn("if (api.thing)", a)  # an older kit skips it instead of throwing
        self.assertTrue(h.put_in("api.say('x');", "dog", True).startswith("if (api.thing)"))
        own = "api.thing('dog', 1, 2, 3);"
        self.assertEqual(h.put_in(own, "dog", False), own)  # a later scene that already draws it is left alone
        self.assertIn('api.thing("dog"', h.put_in("api.say('x');", "dog", False))

    def test_every_hero_word_names_a_real_kit_thing(self):
        root = Path(os.environ.get("YUIGUI") or Path(__file__).resolve().parents[3] / ".." / "yuigui")
        kit = root / "site" / "public" / "demo" / "motion" / "kit.js"
        if not kit.exists():
            self.skipTest("no sibling yuigui checkout")
        import re
        names = set(re.findall(r"^      ([a-z]+): \[", kit.read_text(), re.M))
        self.assertEqual(sorted((set(motion.motion_hero.WORDS) | {"roast"}) - names), [])

    def test_film_gets_the_hero_in_scene_one_and_the_name_in_the_notes(self):
        notes = []

        async def fake(ask, model="big", extra="", think=True):
            notes.append(extra)
            yield {"name": "a" if model == motion.OPENER_MODEL else "s2", "dur": 3, "code": "api.look('paper');\napi.say('x');"}

        async def go():
            with mock.patch.object(motion, "claude_cli", fake):
                return [s async for s in motion.split_film("How a heart pumps blood")]
        out = asyncio.run(go())
        self.assertIn('api.thing("heart"', out[0]["code"])
        self.assertIn("seg(t, 0, 1.2)", out[0]["code"])   # scene 1 draws it on
        self.assertIn('api.thing("heart"', out[1]["code"])
        self.assertIn("{k: 1}", out[1]["code"])           # later scenes show it already drawn
        self.assertTrue(all("heart" in n for n in notes))

    def test_no_hero_leaves_the_film_as_it_was(self):
        async def fake(ask, model="big", extra="", think=True):
            assert "HERO" not in extra
            yield {"name": "a", "dur": 3, "code": "api.say('x');"}

        async def go():
            with mock.patch.object(motion, "claude_cli", fake):
                return [s async for s in motion.split_film("A calm mood")]
        self.assertEqual(asyncio.run(go())[0]["code"], "api.say('x');")


ELEPHANT = {"noun": "Elephant", "parts": [
    {"s": "ellipse", "x": 5, "y": 8, "rx": 33, "ry": 21, "f": "a2"}, {"s": "circle", "x": -28, "y": -6, "r": 14, "f": "a2"},
    {"s": "rect", "x": -20, "y": 30, "w": 9, "h": 20, "f": "ink"}, {"s": "rect", "x": 24, "y": 30, "w": 9, "h": 20, "f": "ink"},
    {"s": "poly", "p": [[-36, -12], [-52, 0], [-44, 22], [-34, 10]], "f": "accent", "smooth": True},
    {"s": "line", "p": [[-40, 0], [-52, 14], [-48, 30]], "w": 2}, {"s": "circle", "x": -30, "y": -10, "r": 2, "f": "ink"}]}


class SeedThings(unittest.TestCase):
    """MOTION-23: things the kit lacks, shipped drawn in motion_things_seed.json: found by word, no parts call, disk cache wins."""

    def setUp(self):
        import tempfile
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        h = motion.motion_hero
        for patcher in (mock.patch.object(h, "THINGS_ON", True), mock.patch.object(h, "SEED_ON", True),
                        mock.patch.dict(os.environ, {h.CACHE_ENV: os.path.join(self._tmp.name, "things.json")})):
            patcher.start()
            self.addCleanup(patcher.stop)
        self.h = h

    def test_the_seed_has_fifteen_checked_things(self):
        seed = self.h._seed()
        self.assertGreaterEqual(len(seed["things"]), 15)
        self.assertEqual(sorted(seed["words"]), sorted(seed["things"]))
        for name, th in seed["things"].items():
            self.assertRegex(name, r"^[a-z][a-z0-9_]{1,23}$")
            self.assertNotIn(name, self.h.WORDS)  # the kit draws those itself
            self.assertTrue(th["label"])
            self.assertTrue(7 <= len(th["parts"]) and all(len(p) == 4 and p[0].startswith("M") for p in th["parts"]), name)
            self.assertTrue(self.h.define_call(dict(th, name=name)).startswith("if (api.defineThing)"))

    def test_word_forms_find_the_thing(self):
        s = self.h.seeded
        self.assertEqual(s("Why a giraffe has such a long neck")["name"], "giraffe")
        self.assertEqual(s("How do cacti store water?")["name"], "cactus")
        self.assertEqual(s("How a tower crane lifts steel")["name"], "tower_crane")
        self.assertEqual(s("How pianos make sound")["name"], "grand_piano")
        self.assertEqual(s("A wind turbine and its blades")["name"], "windmill")
        self.assertEqual(s("Camels and elephants in the desert")["name"], "camel")  # the earliest word wins
        self.assertEqual(s("Why a giraffe has such a long neck")["label"], "giraffe")

    def test_asks_about_no_seed_thing_miss(self):
        s = self.h.seeded
        for ask in ("Show the plan for Monday", "How a decision tree splits data", "Explain a pyramid scheme", "A balloon payment on a loan",
                    "Show the Earth in real 3D with a tractor (api.three)", ""):
            self.assertIsNone(s(ask), ask)

    def test_motion24_new_things_and_their_word_forms(self):
        s = self.h.seeded
        self.assertGreaterEqual(len(self.h._seed()["things"]), 80)
        for ask, name in (("How penguins huddle in a blizzard", "penguin"), ("How a lightbulb glows", "light_bulb"), ("Why wolves howl", "wolf"),
                          ("Inside a living cell", "cell"), ("How a magnet-free compass points north", "compass"), ("How a solar panel makes power", "solar_panel"),
                          ("How a cargo ship stays afloat", "ship"), ("How the moon pulls the tide", "moon"), ("What a smartphone does", "phone"),
                          ("How DNA copies itself", "dna"), ("A dinosaur and a comet", "dinosaur")):
            self.assertEqual((s(ask) or {}).get("name"), name, ask)

    def test_motion24_generic_words_do_not_hit(self):
        for ask in ("Select a spreadsheet cell range", "Why cloud storage costs more", "We ship the feature on Friday",
                    "Run this python code", "Stock prices rose today", "Show the plan for Monday", "How a decision tree splits data"):
            self.assertIsNone(self.h.seeded(ask), ask)

    def test_the_kit_picks_first_and_the_seed_never_shadows_it(self):
        self.assertEqual(self.h.pick("How a dog sees"), "dog")
        self.assertIsNone(self.h.pick("How a giraffe drinks"))

    def test_disk_cache_wins_over_the_seed(self):
        mine = [["M0 0 L9 9", 0, "fg", 1]]
        self.h._save({"things": {"giraffe": {"label": "tall one", "parts": mine}}})
        got = self.h.seeded("Why a giraffe has such a long neck")
        self.assertEqual((got["label"], got["parts"]), ("tall one", mine))
        self.assertEqual(self.h.seeded("How an octopus hides")["label"], "octopus")

    def test_off_switch(self):
        with mock.patch.object(self.h, "SEED_ON", False):
            self.assertIsNone(self.h.seeded("Why a giraffe has such a long neck"))

    def test_a_seeded_film_makes_no_parts_call(self):
        seen = []

        async def fake(ask, model="big", extra="", think=True):
            seen.append(extra)
            yield {"name": "x", "dur": 3.0, "code": "api.look('dark');\nconst k = 1;"}

        async def boom(*a, **k):
            raise AssertionError("parts call made")

        async def run():
            out = []
            async for s in motion.split_film("Why a giraffe has such a long neck"):
                out.append(s)
            return out

        with mock.patch.object(motion, "claude_cli", fake), mock.patch.object(self.h, "draw_new", boom), mock.patch.object(motion, "HERO", True):
            scenes = asyncio.run(run())
        self.assertTrue(scenes)
        self.assertIn('api.defineThing("giraffe"', scenes[0]["code"])
        self.assertIn('api.thing("giraffe"', scenes[0]["code"])


KAYAK = dict(ELEPHANT, noun="kayak")


class LearnThings(unittest.TestCase):
    """MOTION-25: a noun the film had to draw is drawn again in the background, judged, and kept under narrow words; never inside a turn."""

    def setUp(self):
        import tempfile
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        h = motion.motion_hero
        judge = Path(self._tmp.name) / "learn_judge.py"
        judge.write_text("")
        for patcher in (mock.patch.object(h, "THINGS_ON", True), mock.patch.object(h, "SEED_ON", True), mock.patch.object(h, "LEARN_ON", True),
                        mock.patch.dict(os.environ, {h.CACHE_ENV: os.path.join(self._tmp.name, "things.json"), h.LEARN_JUDGE_ENV: str(judge)})):
            patcher.start()
            self.addCleanup(patcher.stop)
        h._LEARN_INFLIGHT.clear()
        h._LEARN_LOG.clear()
        self.h = h

    def learn(self, name, reply, verdict=(True, "ok")):
        async def parts(ask):
            return json.dumps(reply)

        async def judge(thing):
            return verdict

        async def run():
            ok = self.h.learn_after("How a kayak goes", name)
            while not self.h.learn_idle():
                await asyncio.sleep(0.01)
            return ok

        with mock.patch.object(self.h, "_call_cold", parts), mock.patch.object(self.h, "_judge", judge):
            return asyncio.run(run())

    def test_a_pass_is_kept_and_the_second_ask_is_a_seed_hit(self):
        self.assertTrue(self.learn("kayak", KAYAK))
        self.assertIsNone(self.h.pick("Why do kayaks tip"))
        hit = self.h.seeded("Why do kayaks tip so easily")
        self.assertEqual((hit["name"], hit["label"]), ("kayak", "kayak"))
        self.assertTrue(hit["parts"])
        self.assertTrue(self.h._LEARN_LOG[-1]["ok"])

    def test_a_fail_writes_nothing_and_a_noun_is_tried_twice_at_most(self):
        self.assertTrue(self.learn("kayak", KAYAK, (False, "look:plain")))
        self.assertIsNone(self.h.seeded("Why do kayaks tip so easily"))
        self.assertNotIn("kayak", self.h._load().get("words", {}))
        self.assertTrue(self.learn("kayak", KAYAK, (False, "look:plain")))
        self.assertFalse(self.learn("kayak", KAYAK))
        self.assertEqual(self.h._load()["learn"]["kayak"]["n"], 2)

    def test_parts_naming_another_noun_or_nothing_is_a_fail(self):
        self.learn("kayak", dict(KAYAK, noun="canoe"))
        self.assertFalse(self.h._LEARN_LOG[-1]["ok"])
        self.learn("kayak", {"noun": None})
        self.assertIsNone(self.h.seeded("Why do kayaks tip so easily"))

    def test_off_switch_queues_nothing_and_ignores_learned_words(self):
        self.learn("kayak", KAYAK)
        with mock.patch.object(self.h, "LEARN_ON", False):
            self.assertFalse(self.h.learn_after("a", "kayak"))
            self.assertIsNone(self.h.seeded("Why do kayaks tip so easily"))

    def test_known_and_ambiguous_nouns_are_never_queued(self):
        async def run():
            return [self.h.learn_after("a", n) for n in ("heart", "giraffe", "cell", "cloud", "stapler")]
        with mock.patch.object(self.h, "_learn", lambda k, n, a: asyncio.sleep(0)):
            self.assertEqual(asyncio.run(run()), [False, False, False, False, True])

    def test_a_failed_parts_call_is_named_by_the_job_from_the_ask(self):
        async def parts(ask):
            self.assertIn("kayak", ask)
            return json.dumps(KAYAK)

        async def judge(thing):
            return True, "ok"

        async def run():
            ok = self.h.learn_after("How a kayak goes", None)
            while not self.h.learn_idle():
                await asyncio.sleep(0.01)
            return ok

        with mock.patch.object(self.h, "_call_cold", parts), mock.patch.object(self.h, "_judge", judge):
            self.assertTrue(asyncio.run(run()))
        self.assertEqual(self.h.seeded("Why do kayaks tip so easily")["name"], "kayak")
        self.assertTrue(self.h._LEARN_LOG[-1]["ok"])

    def test_an_ask_the_model_called_bodyless_is_not_learned(self):
        self.h._save({"asks": {self.h._ask_key("Show the plan for Monday"): ""}})
        self.assertFalse(asyncio.run(self._call_after("Show the plan for Monday", None)))

    async def _call_after(self, ask, name):
        return self.h.learn_after(ask, name)

    def test_a_two_word_noun_also_answers_to_its_last_word(self):
        w = lambda label, ask: bool(re.search(r"\b(?:" + self.h.learn_words(label) + r")\b", ask, re.I))
        self.assertTrue(w("snare drum", "What makes a drum loud"))
        self.assertTrue(w("snare drum", "a snare-drums rattle"))
        self.assertFalse(w("kayak paddle", "a kayak glides"))
        self.assertIsNone(self.h.learn_words("cell phone x"))

    def test_narrow_words(self):
        w = lambda label, ask: bool(re.search(r"\b(?:" + self.h.learn_words(label) + r")\b", ask, re.I))
        self.assertTrue(w("kayak", "Why kayaks tip"))
        self.assertTrue(w("stapler", "a stapler jams"))
        self.assertFalse(w("kayak", "a canoe or a boat"))
        self.assertTrue(w("candy", "all the candies"))
        self.assertIsNone(self.h.learn_words("cell"))

    def test_cap_in_flight_and_daily_ceiling(self):
        async def run():
            with mock.patch.object(self.h, "LEARN_MAX_INFLIGHT", 2), mock.patch.object(self.h, "_learn", lambda k, n, a: asyncio.sleep(0.05)):
                got = [self.h.learn_after("a", n) for n in ("kayak", "stapler", "hourglass")]
                await asyncio.sleep(0.2)
                return got
        self.assertEqual(asyncio.run(run()), [True, True, False])
        self.h._LEARN_INFLIGHT.clear()
        self.h._save({"learn_day": {"d": time.strftime("%Y-%m-%d"), "n": 99}})
        self.assertFalse(asyncio.run(self._once("kayak")))

    async def _once(self, n):
        return self.h.learn_after("a", n)

    def test_no_judge_script_no_learning(self):
        with mock.patch.dict(os.environ, {self.h.LEARN_JUDGE_ENV: "/nonexistent/x.py"}), mock.patch.object(self.h.Path, "home", return_value=Path("/nonexistent")):
            self.assertFalse(asyncio.run(self._once("kayak")))

    def test_a_crash_in_the_job_never_reaches_the_film(self):
        async def boom(thing):
            raise RuntimeError("judge died")

        async def parts(ask):
            return json.dumps(KAYAK)

        async def run():
            self.h.learn_after("a", "kayak")
            while not self.h.learn_idle():
                await asyncio.sleep(0.01)

        with mock.patch.object(self.h, "_call_cold", parts), mock.patch.object(self.h, "_judge", boom):
            asyncio.run(run())
        self.assertFalse(self.h._LEARN_LOG[-1]["ok"])
        self.assertIsNone(self.h.seeded("Why do kayaks tip so easily"))

    def test_a_missed_film_queues_the_job_after_it_ends_and_never_waits_on_it(self):
        queued = []

        async def fake(ask, model="big", extra="", think=True):
            yield {"name": "x", "dur": 3.0, "code": "api.look('dark');\nconst k = 1;"}

        async def draw(ask, call=None, on_noun=None, on_text=None):
            self.assertEqual(queued, [])  # nothing queued while the film still draws
            return {"name": "kayak", "label": "kayak", "parts": KAYAK["parts"]}

        async def run():
            return [s async for s in motion.split_film("How a kayak keeps its line")]

        with mock.patch.object(motion, "claude_cli", fake), mock.patch.object(self.h, "draw_new", draw), mock.patch.object(motion, "HERO", True), \
                mock.patch.object(self.h, "learn_after", lambda ask, n: queued.append(n) or True):
            scenes = asyncio.run(run())
        self.assertTrue(scenes)
        self.assertEqual(queued, ["kayak"])

    def test_a_seeded_or_kit_film_queues_nothing(self):
        queued = []

        async def fake(ask, model="big", extra="", think=True):
            yield {"name": "x", "dur": 3.0, "code": "api.look('dark');\nconst k = 1;"}

        async def run(ask):
            return [s async for s in motion.split_film(ask)]

        with mock.patch.object(motion, "claude_cli", fake), mock.patch.object(motion, "HERO", True), \
                mock.patch.object(self.h, "learn_after", lambda ask, n: queued.append(n) or True):
            asyncio.run(run("Why a giraffe has such a long neck"))
            asyncio.run(run("How a heart pumps"))
        self.assertEqual(queued, [])


class NewThing(unittest.TestCase):
    """A hero the kit lacks (MOTION-15): one cheap call returns kit shapes, validated, cached by name."""

    def setUp(self):
        import tempfile
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        h = motion.motion_hero
        for patcher in (mock.patch.object(h, "THINGS_ON", True), mock.patch.object(h, "SEED_ON", False), mock.patch.dict(os.environ, {h.CACHE_ENV: os.path.join(self._tmp.name, "things.json")})):
            patcher.start()
            self.addCleanup(patcher.stop)
        self.h = h
        self.calls = []

    def call(self, reply):
        async def f(ask, on_noun=None, on_text=None):
            self.calls.append(ask)
            return reply if isinstance(reply, str) else json.dumps(reply)
        return f

    def test_a_second_line_after_the_reply_is_ignored(self):
        spec = {"noun": "elephant", "parts": [
            {"s": "ellipse", "x": 5, "y": 8, "rx": 33, "ry": 21, "f": "a2"}, {"s": "circle", "x": -28, "y": -6, "r": 14, "f": "a2"},
            {"s": "rect", "x": -20, "y": 30, "w": 9, "h": 20, "f": "ink"}, {"s": "rect", "x": 10, "y": 30, "w": 9, "h": 20, "f": "ink"},
            {"s": "line", "p": [[-40, -2], [-50, 20]], "w": 2}, {"s": "ellipse", "x": 35, "y": 6, "rx": 8, "ry": 12, "f": "warn"}]}
        hero = self.h.parse_reply(json.dumps(spec) + "\n{\"note\": 1}")
        self.assertEqual(hero["name"], "elephant")

    def test_parts_become_kit_part_lists_and_nothing_else(self):
        hero = asyncio.run(self.h.draw_new("How an elephant keeps cool", self.call("```json\n" + json.dumps(ELEPHANT) + "\n```")))
        self.assertEqual(hero["name"], "elephant")
        self.assertEqual(len(hero["parts"]), 7)
        self.assertTrue(all(len(p) == 4 and p[0].startswith("M") for p in hero["parts"]))
        line = self.h.define_call(hero)
        self.assertTrue(line.startswith('if (api.defineThing) api.defineThing("elephant", [['))

    def test_second_ask_for_the_same_name_hits_the_cache(self):
        asyncio.run(self.h.draw_new("How an elephant keeps cool", self.call(ELEPHANT)))
        again = asyncio.run(self.h.draw_new("How an elephant keeps cool", self.call("not json")))
        self.assertEqual(again["name"], "elephant")
        self.assertEqual(len(self.calls), 1)
        other = asyncio.run(self.h.draw_new("Why elephants never forget", self.call(ELEPHANT)))  # new words, same noun: parts reused
        self.assertEqual(other["parts"], again["parts"])

    def test_no_single_thing_is_remembered_as_none(self):
        self.assertIsNone(asyncio.run(self.h.draw_new("Show the plan for Monday", self.call({"noun": None}))))
        self.assertIsNone(asyncio.run(self.h.draw_new("Show the plan for Monday", self.call(ELEPHANT))))
        self.assertEqual(len(self.calls), 1)

    def test_bad_replies_give_no_hero_and_are_not_remembered(self):
        bad = [{"noun": "elephant", "parts": [{"s": "path", "d": "M0 0 L9 9"}] * 6},      # free-form svg is not in the vocabulary
               {"noun": "elephant", "parts": ELEPHANT["parts"][:3]},                      # too few parts
               {"noun": "elephant", "parts": [dict(p, f="red") if p.get("f") else p for p in ELEPHANT["parts"]]},  # a colour the kit lacks
               {"noun": "elephant", "parts": [{"s": "circle", "x": 0, "y": 0, "r": 4, "f": "ink"}] * 6},           # too small to read
               "sorry, I cannot", ""]
        for r in bad:
            self.assertIsNone(asyncio.run(self.h.draw_new("How an elephant keeps cool", self.call(r))), r)
        self.assertEqual(len(self.calls), len(bad))

    def test_call_that_raises_or_times_out_is_no_hero(self):
        async def boom(ask):
            raise OSError("no claude")
        self.assertIsNone(asyncio.run(self.h.draw_new("How an elephant keeps cool", boom)))

    def test_numbers_are_clamped_and_names_made_safe(self):
        spec = dict(ELEPHANT, noun='Hot-Air "Balloon"; x', parts=[dict(p, x=9999) if "x" in p else p for p in ELEPHANT["parts"]])
        hero = self.h.parse_reply(json.dumps(spec))
        self.assertRegex(hero["name"], r"^[a-z][a-z0-9_]+$")
        self.assertNotIn("9999", self.h.define_call(hero))

    def test_a_noun_the_kit_draws_uses_the_kit_drawing(self):
        hero = asyncio.run(self.h.draw_new("How a goldfish breathes", self.call({"noun": "fish", "parts": []})))
        self.assertEqual(hero["name"], "fish")
        self.assertEqual(self.h.define_call(hero), "")

    def test_film_registers_the_drawn_hero_in_every_scene(self):
        notes = []

        async def fake(ask, model="big", extra="", think=True):
            notes.append(extra)
            yield {"name": "a" if model == motion.OPENER_MODEL else "s2", "dur": 3, "code": "api.say('x');" if model == motion.OPENER_MODEL else "api.thing('elephant', 1, 2, 3);"}

        async def go():
            with mock.patch.object(motion, "claude_cli", fake), mock.patch.object(self.h, "_call_model", self.call(ELEPHANT)):
                return [s async for s in motion.split_film("How an elephant keeps cool")]
        out = asyncio.run(go())
        self.assertIn("api.defineThing", out[0]["code"])
        self.assertLess(out[0]["code"].index("api.defineThing"), out[0]["code"].index('api.thing("elephant"'))
        self.assertIn("api.defineThing", out[1]["code"])  # the model's own api.thing call needs the thing registered too
        self.assertTrue("elephant" in notes[-1])  # the continuation writer is told the hero's name (scene 1's writer started before the noun)

    def test_failed_call_leaves_the_film_as_it_was(self):
        async def fake(ask, model="big", extra="", think=True):
            assert "HERO" not in extra
            yield {"name": "a", "dur": 3, "code": "api.say('x');"}

        async def go():
            with mock.patch.object(motion, "claude_cli", fake), mock.patch.object(self.h, "_call_model", self.call("nope")):
                return [s async for s in motion.split_film("A calm mood")]
        self.assertEqual(asyncio.run(go())[0]["code"], "api.say('x');")

    def streaming(self, reply, noun_after=0.0, done_after=0.2):
        """A parts call that tells on_noun first and finishes later, like the warm process does."""
        async def f(ask, on_noun=None, on_text=None):
            self.calls.append(ask)
            await asyncio.sleep(noun_after)
            if on_noun:
                on_noun(reply.get("noun") if isinstance(reply, dict) else None)
            await asyncio.sleep(done_after)
            return reply if isinstance(reply, str) else json.dumps(reply)
        return f

    def test_writers_start_on_the_noun_before_the_parts_are_whole(self):
        order = []

        async def fake(ask, model="big", extra="", think=True):
            order.append(("start", model, "elephant" in extra))
            yield {"name": "a" if model == motion.OPENER_MODEL else "s2", "dur": 3, "code": "api.say('x');" if model == motion.OPENER_MODEL else "api.say('y');"}

        async def go():
            real = self.streaming(ELEPHANT, 0.0, 0.3)

            async def watched(ask, on_noun=None, on_text=None):
                def heard(n):
                    order.append(("noun", n))
                    on_noun(n)
                r = await real(ask, heard)
                order.append(("parts whole",))
                return r
            with mock.patch.object(motion, "claude_cli", fake), mock.patch.object(self.h, "_call_model", watched):
                return [s async for s in motion.split_film("How an elephant keeps cool")]
        out = asyncio.run(go())
        kinds = [o[0] for o in order]
        self.assertLess(kinds.index("noun"), kinds.index("parts whole"))
        # MOTION-21: the scene 1 writer starts with the parts call (no noun yet), the continuation writer on the noun
        self.assertEqual([o for o in order if o[0] == "start"], [("start", motion.OPENER_MODEL, False), ("start", "big", True)])
        self.assertIn("api.defineThing", out[0]["code"])

    def test_a_noun_whose_parts_then_fail_restarts_the_writers_plain(self):
        starts = []

        async def fake(ask, model="big", extra="", think=True):
            starts.append("HERO" in extra)
            await asyncio.sleep(0.05)
            yield {"name": "a", "dur": 3, "code": "api.say('x');"}

        async def go():
            bad = dict(ELEPHANT, parts=[{"s": "circle", "x": 0, "y": 0, "r": 4}])
            with mock.patch.object(motion, "claude_cli", fake), mock.patch.object(self.h, "_call_model", self.streaming(bad, 0.0, 0.01)):
                return [s async for s in motion.split_film("How an elephant keeps cool")]
        out = asyncio.run(go())
        self.assertEqual(starts, [True, True, False, False])  # the opener and the continuation writer on the noun, then both plain again (MOTION-22: the continuation writer no longer waits to be iterated)
        self.assertEqual(out[0]["code"], "api.say('x');")

    def test_the_continuation_writer_starts_before_scene_1_is_written(self):
        """MOTION-22: scene 2+ is being written while scene 1 is still being written."""
        started = {}

        async def fake(ask, model="big", extra="", think=True):
            started[model] = time.time()
            await asyncio.sleep(0.3 if model == motion.OPENER_MODEL else 0.1)
            yield {"name": "a", "dur": 3, "code": "api.say('x');"}

        async def go():
            with mock.patch.object(motion, "claude_cli", fake), mock.patch.object(motion.motion_hero, "pick", lambda a: "heart"):
                agen = motion.split_film("How a heart pumps")
                first = await agen.__anext__()
                t_first = time.time()
                await agen.aclose()
                return first, t_first
        _, t_first = asyncio.run(go())
        self.assertLess(started["big"], t_first - 0.2)

    def test_a_null_noun_starts_the_writers_plain_at_once(self):
        starts = []

        async def fake(ask, model="big", extra="", think=True):
            starts.append("HERO" in extra)
            yield {"name": "a", "dur": 3, "code": "api.say('x');"}

        async def go():
            with mock.patch.object(motion, "claude_cli", fake), mock.patch.object(self.h, "_call_model", self.streaming({"noun": None}, 0.0, 0.01)):
                return [s async for s in motion.split_film("A calm mood")]
        self.assertEqual(asyncio.run(go())[0]["code"], "api.say('x');")
        self.assertEqual(starts, [True, False, False])  # the speculative scene 1 writer is dropped when the noun is null, then plain writers start

    def test_scene_1_goes_out_on_the_shapes_whole_so_far(self):
        out_at = []

        async def fake(ask, model="big", extra="", think=True):
            yield {"name": "a" if model == motion.OPENER_MODEL else "s2", "dur": 3, "code": "api.say('x');" if model == motion.OPENER_MODEL else "api.say('y');"}

        async def slow_parts(ask, on_noun=None, on_text=None):
            text = '{"noun":"elephant","parts":['
            on_noun("elephant")
            on_text(text)
            for sh in ELEPHANT["parts"]:
                await asyncio.sleep(0.05)
                text += json.dumps(sh) + ","
                on_text(text)
            await asyncio.sleep(0.5)  # the reply is whole only half a second later
            return json.dumps(ELEPHANT)

        async def go():
            t0 = asyncio.get_running_loop().time()
            with mock.patch.object(motion, "claude_cli", fake), mock.patch.object(self.h, "_call_model", slow_parts):
                res = []
                async for s in motion.split_film("How an elephant keeps cool"):
                    out_at.append(asyncio.get_running_loop().time() - t0)
                    res.append(s)
                return res
        out = asyncio.run(go())
        self.assertLess(out_at[0], 0.5)  # scene 1 did not wait for the whole reply
        for s in out:
            self.assertIn("api.defineThing", s["code"])
        self.assertGreaterEqual(out[1]["code"].count('["'), out[0]["code"].count('["'))  # scenes 2+ carry the whole drawing

    def test_shapes_so_far_reads_only_whole_shapes(self):
        txt = '{"noun":"elephant","parts":[{"s":"circle","x":0,"y":0,"r":9,"f":"a2"},{"s":"rect","x":1,"y":2,"w":3'
        self.assertEqual(len(self.h.shapes_so_far(txt)), 1)
        self.assertEqual(self.h.shapes_so_far('{"noun":"elephant"'), [])
        e = self.h.Early()
        e.noun = "elephant"
        e(txt)
        self.assertIsNone(e.hero())  # too few to draw


FAKE_CLAUDE = """#!/usr/bin/env python3
import json, sys, os
print(json.dumps({"type": "system", "subtype": "init"}), flush=True)
for line in sys.stdin:
    q = json.loads(line)["message"]["content"]
    if "DIE" in q:
        os._exit(3)
    out = '{"noun":"ox","parts":[]}' + str(os.getpid())
    for chunk in (out[:12], out[12:]):
        print(json.dumps({"type": "stream_event", "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": chunk}}}), flush=True)
    print(json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": out}]}}), flush=True)
    print(json.dumps({"type": "result", "result": out}), flush=True)
"""


class WarmProcess(unittest.TestCase):
    """The warm claude (MOTION-18): stream-json in and out, one call per process, a fresh one ready, a dead one replaced."""

    def setUp(self):
        import tempfile
        import stat
        import importlib
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        exe = Path(self._tmp.name) / "claude"
        exe.write_text(FAKE_CLAUDE)
        exe.chmod(exe.stat().st_mode | stat.S_IEXEC)
        patcher = mock.patch.dict(os.environ, {"PATH": self._tmp.name + os.pathsep + os.environ["PATH"]})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.warm = importlib.import_module("warm")
        self.warm._slot.clear()
        self.warm.stats.update(spawned=0, calls=0, retries=0)

    def test_twenty_calls_in_a_row_each_on_its_own_process_and_the_noun_streams_early(self):
        heard, pids = [], set()

        async def go():
            for i in range(20):
                if i % 2:
                    await asyncio.sleep(0.15)  # films come minutes apart: the next process is up by then
                nouns = []
                out = await self.warm.ask("q%d" % i, "m", 10, motion.motion_hero.noun_watch(nouns.append))
                heard.append(nouns)
                pids.add(out.rsplit("}", 1)[1])
            self.warm.shutdown()
        asyncio.run(go())
        self.assertEqual(heard, [["ox"]] * 20)
        self.assertEqual(len(pids), 20)  # one ask never sees another ask's chat
        self.assertEqual(self.warm.stats["calls"], 20)
        self.assertEqual(self.warm.stats["retries"], 0)

    def test_a_process_that_dies_is_replaced_and_the_call_goes_through(self):
        async def go():
            await self.warm.ask("first", "m", 10)
            await asyncio.sleep(0.2)
            self.warm._slot["m"].kill()  # the waiting process is killed
            await asyncio.sleep(0.1)
            out = await self.warm.ask("after the kill", "m", 10)
            self.warm.shutdown()
            return out
        self.assertIn('"noun":"ox"', asyncio.run(go()))

    def test_a_process_that_dies_mid_call_is_retried_once_then_raises(self):
        async def go():
            with self.assertRaises(Exception):
                await self.warm.ask("DIE now", "m", 6)
            self.assertEqual(self.warm.stats["retries"], 1)
            self.warm.shutdown()
        asyncio.run(go())


class WarmShutdown(unittest.TestCase):
    def test_shutdown_leaves_no_process_that_was_still_starting(self):
        from unittest import mock
        import importlib
        warm = importlib.import_module("warm")
        warm._slot.clear()

        async def go():
            async def slow(model):
                await asyncio.sleep(5)
            with mock.patch.object(warm, "_spawn", slow):
                warm.prime("m")
                await asyncio.sleep(0.05)
                warm.shutdown()
                await asyncio.sleep(0.05)
            return all(f.cancelled() or f.done() for f in warm._filling.values()), dict(warm._slot)
        ok, slot = asyncio.run(go())
        self.assertTrue(ok)
        self.assertEqual(slot, {})


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

    def test_build_545_is_the_line(self):
        self.assertEqual(compat.MOTION_BUILD, 545)
        self.assertEqual(compat.downgrade(self.FILM, 562), self.FILM)
        self.assertEqual(compat.downgrade(self.FILM, 545), self.FILM)
        self.assertIn("=== scene", compat.downgrade(self.FILM, 562))
        self.assertNotIn("=== scene", compat.downgrade(self.FILM, 538))
        self.assertNotIn("motion", compat.note(562))
        self.assertIn("motion", compat.note(538))

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

    def test_the_working_row_says_which_scene_is_being_drawn(self):
        notes = []
        self.a._doing = type("D", (), {"note": lambda self, k, v: notes.append((k, v))})()
        with mock.patch.object(self.ad.doing, "allowed", lambda *_: True):
            self.send(REPLY)
            self.run_all()
        words = [v if v == "off" else v["text"] for _, v in notes]
        self.assertEqual(words, ["Drawing the first scene", "Drawing scene 2", "Drawing scene 3", "off"])
        self.assertTrue(all(k == "a1" for k, _ in notes))
        self.assertEqual(motion.drawing(1), "Drawing the first scene")

    def test_no_words_for_a_phone_that_cannot_read_them(self):
        self.a._doing = None  # would raise if touched
        self.send(REPLY)
        self.run_all()
        self.assertEqual(len(self.written), 4)

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


    def test_another_take_makes_a_new_film_even_for_the_same_ask(self):
        # YUI-320: the end-of-film tap reaches the agent as a normal turn; its new `motion` line is made again, never
        # deduped against the film already cached for that ask.
        self.send(REPLY)
        self.send(REPLY)
        self.run_all()
        films = {re.search(r"film=(m\w+)", r["body"]).group(1) for r in self.written if "film=" in r["body"]}
        self.assertEqual(len(films), 2)

    def test_the_another_take_tap_is_a_plain_turn(self):
        tap = '[yui] m7 motion again note="make this film again, a different take, same ask" title="How a heart pumps"'
        self.assertFalse(shown.plain(tap))  # a tap, not typed words
        row = {"id": "r1", "kind": "text", "body": tap, "sender": "user"}
        for name in ("_stop", "_key_answer", "_control", "_owner_only", "_board_order", "_need_answer", "_invite_answer",
                     "_need_dismiss", "_need_open", "_talk_tap"):
            self.assertFalse(asyncio.run(getattr(self.a, name)("a1", row)), name)


if __name__ == "__main__":
    unittest.main()
