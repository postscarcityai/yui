"""One line and a picture (VIS-1): the gate measures, rewrites and logs counts, never text.

    python3 hermes-plugin/tests/test_oneline.py
"""

import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path

PLUGIN = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("oneline", PLUGIN / "yui" / "oneline.py")
ol = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ol)

WALL = ("You're right, I misread you. You meant the left drawer, not TestFlight.\n\n"
        "The drawer had stopped updating. One card with badly saved text crashed every refresh, so a finished card stayed under Now. "
        "I fixed the crash and the drawer is current again.\n\n"
        "```yui\nsketch \"Left drawer\" frame=phone\nrow \"Daily release  ·  Now\" +hi\n```\n\n"
        "A new card covers the rest. It is on the board and not built yet.")


class Measure(unittest.TestCase):
    def test_counts(self):
        m = ol.measure(WALL)
        self.assertEqual(m["bubbles"], 3)
        self.assertTrue(m["picture"])
        self.assertGreater(m["words"], 50)

    def test_one_line_and_picture_is_fine(self):
        body = "Yes, build 160.\n```yui\nsketch \"Build\" frame=bubble\nrow \"160: newest\" +hi\n```"
        self.assertFalse(ol.violates(ol.measure(body)))
        self.assertIsNone(ol.rewrite(body))

    def test_no_prose_is_fine(self):
        self.assertIsNone(ol.rewrite("```yui\ntimer 5m Plank\n```"))

    def test_code_fence_left_alone(self):
        body = "Run it like this. " * 12 + "\n\n```bash\nls\n```"
        self.assertIsNone(ol.rewrite(body))


class Rewrite(unittest.TestCase):
    def test_wall_becomes_one_line_and_its_picture(self):
        new = ol.rewrite(WALL)
        m = ol.measure(new)
        self.assertEqual(m["bubbles"], 1)
        self.assertLessEqual(m["words"], ol.LINE_WORDS)
        self.assertTrue(m["picture"])
        self.assertTrue(new.startswith("You're right, I misread you."))
        self.assertIn('sketch "Left drawer"', new)

    def test_prose_only_gets_a_sketch(self):
        body = ("The board is fine. Three cards run, two are blocked on a pick, and the site deploy is green. "
                "The blocked ones need your call. Nothing else is waiting on you today.")
        new = ol.rewrite(body)
        self.assertTrue(new.startswith("The board is fine."))
        self.assertIn("```yui\nsketch ", new)
        self.assertTrue(ol.measure(new)["picture"])
        self.assertEqual(ol.measure(new)["bubbles"], 1)

    def test_question_is_kept(self):
        body = "Done with the fix. " + "It touched several files and the tests pass. " * 4 + "Want it in the next build?"
        new = ol.rewrite(body)
        self.assertIn("Want it in the next build?", new.split("\n")[0])

    def test_second_bubble_in_a_turn_is_picture_only(self):
        body = "Here is the rest of it.\n```yui\nstat 12 Cards\n```"
        new = ol.rewrite(body, prior=1)
        self.assertEqual(ol.measure(new)["bubbles"], 0)
        self.assertIn("stat 12 Cards", new)

    def test_filler_lead_goes(self):
        new = ol.rewrite("So, the drawer is fixed. " + "It was a crash in one card. " * 6)
        self.assertTrue(new.startswith("The drawer is fixed."))

    def test_a_got_it_lead_goes_even_on_a_short_reply(self):
        new = ol.rewrite("Got it. Short text plus a drawing.\n```yui\nsketch \"Rule\" frame=bubble\nrow \"Text + drawing\" +hi\n```")
        self.assertTrue(new.startswith("Short text plus a drawing."))

    def test_image_is_not_a_drawing(self):
        self.assertFalse(ol.measure("Here.\n```yui\nimage /tmp/a.png Shot\n```")["picture"])

    def test_clip_never_ellipsis(self):
        c = ol._clip("one two three four five six seven eight nine ten, eleven twelve thirteen", 10)
        self.assertNotIn("…", c)
        self.assertLessEqual(len(c.split()), 10)


class Gate(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        os.environ["YUI_ONELINE_LOG"] = str(Path(self.tmp) / "o.jsonl")

    def tearDown(self):
        os.environ.pop("YUI_ONELINE_LOG", None)

    def test_shadow_sends_untouched_and_logs_counts(self):
        body, drawn = ol.gate(WALL, 0, "shadow", "yui")
        self.assertEqual(body, WALL)
        rows = [json.loads(l) for l in Path(os.environ["YUI_ONELINE_LOG"]).read_text().splitlines()]
        self.assertEqual(rows[0]["action"], "would-rewrite")
        self.assertNotIn("drawer", json.dumps(rows))  # never the text

    def test_on_sends_the_rewrite(self):
        body, drawn = ol.gate(WALL, 0, "on", "yui")
        self.assertNotEqual(body, WALL)
        self.assertEqual(drawn, 1)

    def test_off_and_modes(self):
        self.assertEqual(ol.gate(WALL, 0, "off")[0], WALL)
        self.assertEqual(ol.mode({"one_line": "on"}), "on")
        self.assertEqual(ol.mode({"one_line": "nope"}), "shadow")
        self.assertEqual(ol.mode(None), "shadow")


if __name__ == "__main__":
    unittest.main()
