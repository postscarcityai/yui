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
        self.assertIn("cannot draw chords, drums, keys, loop, metronome, shapes, sketch, tuner yet", compat.note(96))
        self.assertNotIn("timeline", compat.note(96))
        self.assertEqual(compat.note(compat.SHAPES_BUILD), f"[yui] This person's Yui app (build {compat.SHAPES_BUILD}) cannot draw chords, drums, keys, loop, metronome, tuner yet: don't send those. Say it in words or use another preset.")
        self.assertEqual(compat.note(compat.TUNER_BUILD), "")
        self.assertIn("cannot draw chords, drums, keys, loop, metronome, shapes", compat.note(122))
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

    def test_loop_and_drums_before_build_175(self):
        body = ("Here's a beat.\n\n"
                + fence('loop 96 "Boom bap" p=x...x.x.|....x...|xxxxxxxx +play', "drums 2x2 +record", "save beat"))
        out = compat.downgrade(body, 174)
        self.assertIn("There's a beat here: Boom bap. Update Yui to play it.", out)
        self.assertIn("There are drum pads here. Update Yui to play them.", out)
        self.assertNotIn("p=x", out)
        self.assertDrawable(out, 174)
        self.assertEqual(compat.downgrade(fence("~loop p=x.x.x.x. bpm=94"), 174).strip(), "")
        self.assertEqual(compat.downgrade(body, compat.MUSIC_BUILD), body)

    def test_keys_and_chords_before_build_177(self):
        body = ("Play along.\n\n"
                + fence("keys Am pentatonic +send", "chords G I-V-vi-IV +send", "chords C|G|Am|F"))
        out = compat.downgrade(body, 176)
        self.assertIn("There's a keyboard here in Am pentatonic. Update Yui to play it.", out)
        self.assertIn("There are chord buttons here: G I-V-vi-IV. Update Yui to play them.", out)
        self.assertIn("There are chord buttons here: C G Am F. Update Yui to play them.", out)
        self.assertDrawable(out, 176)
        self.assertIn("cannot draw chords, keys, metronome, tuner yet", compat.note(176))
        self.assertIn("cannot draw metronome, tuner yet", compat.note(compat.KEYS_BUILD))
        self.assertEqual(compat.downgrade(body, compat.KEYS_BUILD), body)

    def test_tuner_and_metronome_before_build_205(self):
        body = ("Tune up, then play.\n\n"
                + fence("tuner guitar +inline", "metronome 80 beats=4", "tuner", "metronome bpm=72"))
        out = compat.downgrade(body, 204)
        self.assertIn("There's a tuner here for guitar. Update Yui to use it.", out)
        self.assertIn("There's a metronome here at 80 bpm. Update Yui to use it.", out)
        self.assertIn("There's a tuner here. Update Yui to use it.", out)
        self.assertIn("There's a metronome here at 72 bpm. Update Yui to use it.", out)
        self.assertDrawable(out, 204)
        self.assertIn("cannot draw metronome, tuner yet", compat.note(204))
        self.assertEqual(compat.note(compat.TUNER_BUILD), "")
        self.assertEqual(compat.downgrade(body, compat.TUNER_BUILD), body)

    def test_placed_shapes_and_a_lone_shape(self):
        body = fence("shapes Parts", "shape box A at=2,2", "shape box B at=8,2", "shape arrow from=a to=b")
        self.assertEqual(compat.downgrade(body, 122), "**Parts**\nA, B")
        self.assertEqual(compat.downgrade(fence('shape circle "Just one"'), 122), "Just one")

    # YUI-113: a lesson as one deck, each piece the picture of its page, calc last.
    LESSON = fence('say "Compound interest in a minute."', ">full", 'deck "Compound interest"',
                   'page "Money on money" body="Interest joins the pile."',
                   "shapes", "shape circle $100", "shape arrow", "shape blob $110",
                   'page "The formula"', "math A = P(1 + r)^t",
                   'page "It bends upward"', "chart line x=Y0|Y10 y=100|259",
                   'stat $673 "After 20 years"',
                   'choose "Fastest lever?" "More time"|"A bigger deposit" answer="More time"',
                   'page "Try it"', 'calc f="A = P*(1+r)^t" P=100-1000@100')

    def test_an_older_build_gets_the_lesson_laid_out_on_the_stage(self):
        out = compat.downgrade(self.LESSON, compat.DECK_PICTURES_BUILD - 1)
        lines = compat.FENCE.findall(out)[0].strip("\n").split("\n")
        deck = lines.index('deck "Compound interest" +inline')
        self.assertEqual(lines[2:deck], ["shapes", "shape circle $100", "shape arrow", "shape blob $110",
                                         "math A = P(1 + r)^t", "chart line x=Y0|Y10 y=100|259",
                                         'stat $673 "After 20 years"'])
        self.assertEqual(lines[-2:], ["end", 'calc f="A = P*(1+r)^t" P=100-1000@100'])
        self.assertEqual([l.split()[0] for l in lines[deck + 1:-2]], ["page", "page", "page", "choose", "page"])
        # What the old parser makes of it: the deck keeps every page and the quiz.
        got = ops(out)
        head = next(o for o in got if o.get("preset") == "deck")["id"]
        self.assertEqual([o["preset"] for o in got if o.get("in") == head], ["page", "page", "page", "choose", "page"])
        self.assertDrawable(out, compat.DECK_PICTURES_BUILD - 1)

    def test_the_deck_pictures_build_gets_the_lesson_untouched(self):
        self.assertEqual(compat.downgrade(self.LESSON, compat.DECK_PICTURES_BUILD), self.LESSON)

    def test_lift_stops_at_end_and_leaves_other_screens_alone(self):
        body = fence("deck D", "page One", "stat Total 3", "end", "stat Out 4", ">2 chart bar x=a y=1")
        self.assertEqual(compat.downgrade(body, 150),
                         fence("stat Total 3", "deck D +inline", "page One", "end", "stat Out 4", ">2 chart bar x=a y=1"))
        plain = fence("deck D", "page One", "page Two")
        self.assertEqual(compat.downgrade(plain, 150), plain)


@unittest.skipUnless(YL.exists() and shutil.which("node"), "yuigui checkout or node not found")
class Flows(unittest.TestCase):
    """YUI-155, feedback AMLn-Gg3: "interview me for a personal brand site" came back
    as a headline and `flow website-intake`, which no build runs yet, so the phone
    drew nothing to tap. A flow now goes out as the plan it walks by default."""

    INTAKE = ("Let's build your personal brand site. A few quick questions first.\n\n"
              + fence("flow website-intake"))
    QUESTIONS = ["biz", "kind", "goal", "pages", "brand", "budget"]

    def plan_of(self, body):
        got = ops(body)
        self.assertFalse([o for o in got if o["op"] == "error"], got)
        self.assertFalse([o for o in got if o.get("preset") == "flow"], got)
        plan = next(o for o in got if o.get("preset") == "plan")
        return plan, [o for o in got if o.get("in") == plan["id"]]

    def test_website_intake_on_build_205_is_a_plan_with_the_intake_questions(self):
        for build in (205, 208, None):
            out = compat.downgrade(self.INTAKE, build)
            self.assertTrue(out.startswith("Let's build your personal brand site."))
            plan, steps = self.plan_of(out)
            self.assertEqual(plan["id"], "intake")
            self.assertEqual(plan["props"]["title"], "Client website intake")
            self.assertEqual(plan["props"]["submit"], "Send the brief")
            self.assertEqual([s["preset"] for s in steps][0], "page")
            self.assertEqual([s["id"] for s in steps if s["preset"] != "page"], self.QUESTIONS)
            self.assertNotIn(compat.FALLBACK, out)

    def test_a_build_that_runs_flows_gets_the_flow(self):
        self.assertEqual(compat.downgrade(self.INTAKE, compat.FLOW_BUILD), self.INTAKE)

    def test_saved_by_title_and_a_starter_variant(self):
        plan, steps = self.plan_of(compat.downgrade(fence('flow "Website intake" submit=Go +inline'), 208))
        self.assertEqual(plan["props"]["submit"], "Go")
        self.assertTrue(plan["props"].get("inline"))
        plan, steps = self.plan_of(compat.downgrade(fence("flow restaurant-intake"), 208))
        self.assertEqual(plan["props"]["title"], "Restaurant intake")
        ids = [s["id"] for s in steps if s["preset"] != "page"]
        self.assertIn("menu", ids)
        self.assertNotIn("pages", ids)

    def test_an_inline_flow_and_its_variant_lines(self):
        body = fence('flow@c "Check-in" submit="Send"', "flowchart TD",
                     '  %% sleep: slide "How did you sleep?" 1-10', "  sleep --> check{Rough?}",
                     "  check -->|sleep<5| easy", "  check --> note",
                     '  %% easy: page "Easy day" body="Go light."', "  easy --> note",
                     "  note[mic Anything else?]", "end", 'card "After the flow"')
        out = compat.downgrade(body, 205)
        plan, steps = self.plan_of(out)
        self.assertEqual(plan["id"], "c")
        self.assertEqual([(s["preset"], s["id"]) for s in steps], [("slide", "sleep"), ("mic", "note")])
        self.assertIn('card "After the flow"', out)
        variant = fence("flow website-intake as=bakery-intake", "drop pages",
                        'add cakes after goal: pick "Which cakes?" Birthday|Wedding', "end")
        plan, steps = self.plan_of(compat.downgrade(variant, 205))
        self.assertEqual(plan["props"]["title"], "Bakery intake")
        self.assertEqual([s["id"] for s in steps if s["preset"] != "page"],
                         ["biz", "kind", "goal", "cakes", "brand", "budget"])

    def test_no_saved_flow_by_that_name_still_leaves_something_to_tap(self):
        out = compat.downgrade("A few questions first.\n\n" + fence("flow no-such-flow"), 205)
        self.assertIn(compat.FALLBACK, out)
        self.assertEqual([o["preset"] for o in ops(out)], ["ask"])

    def test_a_promise_with_nothing_to_tap_gets_the_fallback(self):
        bare = "Let me interview you for the site.\n\n" + fence('card "Your brand site"')
        self.assertIn(compat.FALLBACK, compat.downgrade(bare, 205))
        tap = "A few questions first.\n\n" + fence('choose "Ready?" Yes|No')
        self.assertEqual(compat.downgrade(tap, 205), tap)
        link = "A few questions first.\n\n" + fence('card "Brief" url=https://example.com')
        self.assertEqual(compat.downgrade(link, 205), link)
        plain = "Here is the brief.\n\n" + fence('card "Your brand site"')
        self.assertEqual(compat.downgrade(plain, 205), plain)

    def test_the_turn_note_never_tells_agents_to_skip_flows(self):
        self.assertEqual(compat.note(compat.TUNER_BUILD), "")
        self.assertNotIn("flow", compat.note(100))

    def test_the_saved_flows_match_yuigui(self):
        sync = Path(__file__).resolve().parents[1] / "sync_flows.py"
        r = subprocess.run([sys.executable, str(sync), "--check"], capture_output=True, text=True,
                           env={"YUIGUI": str(YL.parents[3]), "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"})
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
