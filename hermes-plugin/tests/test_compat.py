"""Presets the phone can't draw go out as words (beta feedback ANJPrtB7CHynwGR5mqNVPSM).

    ~/.hermes/hermes-agent/venv/bin/python hermes-plugin/tests/test_compat.py

Build 96 got a `sketch` (frame=phone, row/after/row) and drew every line as a
red "unknown preset" with the raw Yui Lines under it. compat.downgrade turns
each preset the phone's build cannot draw into plain words in the chat, or a
page of points inside a deck or plan; newer builds get the reply untouched.
Every result is parsed with yl.mjs (from ../yuigui when it sits next to this
repo) to prove no gated preset and no parse error is left in it.
"""

import json
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "yui"))
import compat  # noqa: E402

YL = Path(__file__).resolve().parents[3] / "yuigui" / "site" / "lib" / "yl" / "yl.mjs"


def fence(*lines):
    return "```yui\n" + "\n".join(lines) + "\n```"


# The reply in the screenshot, as Yui sent it.
INT7 = ("Your feedback on the INT-7 and INT-8 asks is live.\n\n"
        + fence('card "Not yet + You decide" body="Every Needs you ask now ends with both."',
                'sketch "INT-7 ask" frame=phone',
                'row "Works | Phone only | Connector failed" +x note="assumed you\'d tested"',
                "after",
                'row "Works | Phone only | Connector failed"',
                'row "Not yet | You decide" +hi note="new, on every ask"')
        + "\n\nBuild 97 is still your call.")


def ops(body):
    """yl.mjs ops for every ```yui fence in body."""
    out = []
    for block in compat.FENCE.findall(body):
        js = ("import('" + YL.as_uri() + "').then(m => process.stdout.write("
              "JSON.stringify(m.parse(require('fs').readFileSync(0, 'utf8')))))")
        r = subprocess.run(["node", "-e", js], input=block, capture_output=True, text=True, check=True)
        out += json.loads(r.stdout)
    return out


@unittest.skipUnless(YL.exists() and shutil.which("node"), "yuigui checkout or node not found")
class Downgrade(unittest.TestCase):
    def assertDrawable(self, body, build):
        gated = compat.too_new(build)
        for op in ops(body):
            self.assertNotEqual(op["op"], "error", op)
            self.assertNotIn(op.get("preset"), gated, op)

    def test_build_96_gets_the_sketch_as_words(self):
        out = compat.downgrade(INT7, 96)
        self.assertNotIn("sketch", out)
        self.assertNotIn("frame=phone", out)
        self.assertIn("**INT-7 ask**", out)
        self.assertIn("Before:", out)
        self.assertIn("- ~~Works | Phone only | Connector failed~~ (assumed you'd tested)", out)
        self.assertIn("After:", out)
        self.assertIn("- **Not yet | You decide** (new, on every ask)", out)
        # What was drawable stays drawn, in order, and the words around it stay.
        self.assertTrue(out.startswith("Your feedback on the INT-7"))
        self.assertLess(out.index('card "Not yet + You decide"'), out.index("**INT-7 ask**"))
        self.assertTrue(out.endswith("Build 97 is still your call."))
        self.assertDrawable(out, 96)

    def test_new_builds_get_it_untouched(self):
        self.assertEqual(compat.downgrade(INT7, 104), INT7)
        self.assertEqual(compat.downgrade(INT7, 112), INT7)

    def test_unknown_build_counts_as_old(self):
        out = compat.downgrade(INT7, None)
        self.assertNotIn("sketch", out)
        self.assertDrawable(out, None)

    def test_a_sketch_in_a_deck_becomes_a_page_of_points(self):
        body = fence('deck "Card ids" +inline',
                     'page "Ids" body="Plain words read better."',
                     'sketch "Card ids" frame=bubble',
                     'row "Parked YUI-83 in the backlog" +x note="an id means nothing"',
                     "after",
                     'row "Parked the drawing card in the backlog" +hi',
                     'page "Next" body="More soon."',
                     "end",
                     'ask "Keep going?" Yes|No')
        out = compat.downgrade(body, 96)
        self.assertEqual(out.count("```yui"), 1, out)  # the deck stays one screen
        self.assertIn('page "Card ids" points="Out: Parked YUI-83 in the backlog (an id means nothing)"'
                      '|"New: Parked the drawing card in the backlog"', out)
        self.assertDrawable(out, 96)
        titles = [o["props"].get("title") for o in ops(out) if o.get("preset") == "page"]
        self.assertEqual(titles, ["Ids", "Card ids", "Next"])

    def test_a_timeline_before_build_69(self):
        body = fence('timeline "This week"', 'done "Hero shipped" at=Mon', 'now "Blog"', 'next "Contact form"')
        out = compat.downgrade(body, 60)
        self.assertEqual(out, "**This week**\n- Done: Hero shipped (Mon)\n- Now: Blog\n- Next: Contact form")
        self.assertEqual(compat.downgrade(body, 96), body)

    def test_a_lone_row_and_a_stray_patch(self):
        out = compat.downgrade(fence('say Look:', 'row "Just this" +hi', '~sketch title="x"'), 96)
        self.assertEqual(out, fence("say Look:") + "\n\n- **Just this**")
        self.assertDrawable(out, 96)

    def test_screen_prefix_and_other_fences_survive(self):
        body = fence(">2 timer 25m Focus") + "\n\n" + fence('>3 sketch "S" frame=window', '>3 row "A"')
        out = compat.downgrade(body, 96)
        self.assertIn(">2 timer 25m Focus", out)
        self.assertIn("**S**\n- A", out)
        self.assertDrawable(out, 96)

    def test_note_names_what_to_skip(self):
        self.assertIn("cannot draw shapes, sketch yet", compat.note(96))
        self.assertNotIn("timeline", compat.note(96))
        self.assertEqual(compat.note(compat.SHAPES_BUILD), "")
        self.assertIn("cannot draw shapes", compat.note(122))
        self.assertIn("an older build", compat.note(None))

    def test_menu_lines_go_quietly_before_the_drawer(self):
        body = fence("say Drafted.", 'menu backlog@deload "Deload week plan" sub=drafting', "menu done dana")
        self.assertEqual(compat.downgrade(body, 106), fence("say Drafted."))
        self.assertEqual(compat.downgrade(body, 115), body)
        self.assertNotIn("menu", compat.note(106))

    def test_build_122_gets_shapes_as_words(self):
        body = ("Here's the flow.\n\n"
                + fence('shapes "How an ask ships" caption="You ask, a lane builds it."',
                        "shape@you circle You +grow", "shape arrow", 'shape box "The board" +fill',
                        "shape arrow label=pulls", "shape pill Lane +pulse", "shape dot at=5,5",
                        "shape path pts=1,1|2,2", "say Want the long version?"))
        out = compat.downgrade(body, 122)
        self.assertNotIn("shape", out.replace("shapes", "").replace("How an ask ships", ""))
        self.assertIn("**How an ask ships**\nYou → The board → Lane\nYou ask, a lane builds it.", out)
        self.assertIn(fence("say Want the long version?"), out)
        self.assertDrawable(out, 122)
        self.assertEqual(compat.downgrade(body, compat.SHAPES_BUILD), body)

    def test_placed_shapes_and_a_lone_shape(self):
        body = fence("shapes Parts", "shape box A at=2,2", "shape box B at=8,2", "shape arrow from=a to=b")
        self.assertEqual(compat.downgrade(body, 122), "**Parts**\nA, B")
        self.assertEqual(compat.downgrade(fence('shape circle "Just one"'), 122), "Just one")


if __name__ == "__main__":
    unittest.main(verbosity=2)
