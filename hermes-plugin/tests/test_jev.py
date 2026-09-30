"""Jev at the reply-shape decision (YUI-215): the hint rules, the shape a reply had, and that nothing blocks.

    python3 hermes-plugin/tests/test_jev.py

No network, no key: `jev.call` is replaced with a fake. The live numbers are in
yuigui docs/research/jev-results.md (hermes-plugin/jev_eval/run_shape.py).
"""

import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path

PLUGIN = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("yui_jev", PLUGIN / "yui" / "jev.py")
jev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(jev)


def dec(shape="line", conf=0.9, things=1.0, map_=0.02, camera=0.02, kind="none"):
    return {"shape": shape, "conf": conf, "things": things, "map": map_, "camera": camera, "camera_kind": kind}


def fake(shape="line", conf=0.9, cost=0.00002):
    return {"answers": {
        "shape": {"type": "choice", "choice": shape, "confidence": conf, "probabilities": {shape: conf}},
        "things": {"type": "score", "score": 1.0, "confidence": 0.9},
        "map": {"type": "noul", "noul": 0.02}, "camera": {"type": "noul", "noul": 0.01},
        "camera_kind": {"type": "choice", "choice": "none", "confidence": 0.9}},
        "cost": cost, "ms": 120, "input_tokens": 800}


class Hint(unittest.TestCase):
    def test_says_one_line_above_the_cut(self):
        h = jev.hint(dec("card", 0.91))
        self.assertTrue(h.startswith("[yui] hint: shape=card (0.91)."))
        self.assertNotIn("\n", h)

    def test_a_line_or_yes_no_stays_shadow_only_unless_asked_for(self):
        self.assertEqual(jev.hint(dec("line", 0.97)), "")  # the eval got worse with a line hint
        self.assertEqual(jev.hint(dec("yesno", 0.97)), "")
        self.assertTrue(jev.hint(dec("line", 0.97), shapes=("line", "card")).startswith("[yui] hint: shape=line"))
        self.assertEqual(jev.hint_shapes({}), ("card", "pages", "full"))
        self.assertEqual(jev.hint_shapes({"jev_hint_shapes": ["line", "card", "nonsense"]}), ("line", "card"))
        self.assertEqual(jev.hint_shapes({"jev_hint_shapes": "pages"}), ("pages",))
        self.assertEqual(jev.hint_shapes({"jev_hint_shapes": ["nonsense"]}), ("card", "pages", "full"))

    def test_silent_below_the_cut_or_without_a_shape(self):
        self.assertEqual(jev.hint(dec("card", 0.79)), "")
        self.assertEqual(jev.hint(None), "")
        self.assertEqual(jev.hint(dec(None, 0.99)), "")

    def test_clashing_hints_drop_both(self):
        self.assertEqual(jev.hint(dec("line", 0.95, things=4.0), shapes=jev.SHAPES), "")
        self.assertEqual(jev.hint(dec("pages", 0.95, things=1.0)), "")

    def test_map_and_camera_only_when_sure(self):
        self.assertNotIn("map", jev.hint(dec("card", 0.9, map_=0.9)))  # off by default: it made a plain fact a map
        self.assertIn("map", jev.hint(dec("card", 0.9, map_=0.9), map_hint=True))
        self.assertNotIn("map", jev.hint(dec("card", 0.9, map_=0.6), map_hint=True))  # the middle says nothing
        self.assertIn("camera=meal", jev.hint(dec("card", 0.9, camera=0.95, kind="meal")))
        self.assertNotIn("camera", jev.hint(dec("card", 0.9, camera=0.95, kind="barcode")))  # the app cannot draw it

    def test_flag_is_off_by_default(self):
        os.environ.pop("YUI_JEV_HINT", None)
        self.assertFalse(jev.hint_on({}))
        self.assertFalse(jev.hint_on(None))
        self.assertTrue(jev.hint_on({"jev_hint": True}))


class Plain(unittest.TestCase):
    def test_taps_events_and_commands_get_no_call(self):
        self.assertTrue(jev.plain("Am I on the latest build?"))
        for b in ("[yui] n1 choose choice=Legs", "/stop", "   "):
            self.assertFalse(jev.plain(b))

    def test_message_is_cut_before_it_leaves(self):
        self.assertEqual(len(jev.state_for("x" * 900)["message"]), jev.MESSAGE_CAP)
        self.assertEqual(set(jev.state_for("hi")), {"message", "agent", "has_photo", "last_agent_shape"})


class SentShape(unittest.TestCase):
    def test_shapes(self):
        self.assertEqual(jev.sent_shape("Yes, build 160 is the newest."), "yesno")
        self.assertEqual(jev.sent_shape("Build 160 is the newest."), "line")
        self.assertEqual(jev.sent_shape("Here.\n```yui\ncard \"Build 160\" body=\"Newest.\"\n```"), "card")
        deck = "```yui\ndeck +inline\npage \"A\"\npage \"B\"\npage \"C\"\n```"
        self.assertEqual(jev.sent_shape(deck), "pages")
        self.assertEqual(jev.sent_shape("```yui\nflow website-intake\n```"), "full")


class Decide(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        os.environ["YUI_JEV_LOG"] = str(Path(self.tmp) / "jev.jsonl")
        os.environ["OPENROUTER_API_KEY"] = "test"
        jev._spend.update(day="", usd=0.0)
        self._call = jev.call

    def tearDown(self):
        jev.call = self._call
        os.environ.pop("OPENROUTER_API_KEY", None)
        os.environ.pop("YUI_JEV_LOG", None)
        os.environ.pop("JEV_SPEND_CAP", None)

    def test_reads_the_answers(self):
        jev.call = lambda *a, **k: fake("yesno", 0.71)
        d = jev.decide("Am I on the latest build?")
        self.assertEqual((d["shape"], d["conf"], d["ms"]), ("yesno", 0.71, 120))

    def test_failure_is_no_decision_never_an_error(self):
        jev.call = lambda *a, **k: None
        self.assertIsNone(jev.decide("hi"))

    def test_no_key_no_call(self):
        os.environ.pop("OPENROUTER_API_KEY")
        os.environ.pop("YUI_JEV_KEY", None)
        jev.call = lambda *a, **k: self.fail("called without a key")
        self.assertIsNone(jev.decide("hi"))

    def test_daily_spend_cap_stops_calls(self):
        os.environ["JEV_SPEND_CAP"] = "0.00003"
        jev.call = lambda *a, **k: fake(cost=0.00002)
        self.assertIsNotNone(jev.decide("one"))
        self.assertIsNotNone(jev.decide("two"))   # 0.00002 spent, under the cap when asked
        jev.call = lambda *a, **k: self.fail("called past the cap")
        self.assertIsNone(jev.decide("three"))    # 0.00004 spent

    def test_record_writes_numbers_never_words(self):
        d = dec("card", 0.9)
        d.update(ms=200, cost=0.00002)
        jev.record(d, "line", "yui", "Penny")
        row = json.loads(Path(os.environ["YUI_JEV_LOG"]).read_text())
        self.assertEqual((row["shape"], row["sent"], row["agent"]), ("card", "line", "Penny"))
        self.assertNotIn("message", row)
        self.assertNotIn("text", row)


if __name__ == "__main__":
    unittest.main()
