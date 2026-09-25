"""Text bombs (YUI-79): the guard logs counts, never text; reports come out as screens.

    python3 hermes-plugin/tests/test_textbomb.py

No Hermes needed: textbomb.py and yui_report.py load on their own. The Yui
Lines check parses the report with yuigui's yl.mjs when node and ../yuigui
are there (YUI_HUB overrides); it skips without them.
"""

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

PLUGIN = Path(__file__).resolve().parent.parent
HUB = Path(os.environ.get("YUI_HUB") or PLUGIN.parent.parent / "yuigui")


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


textbomb = _load("yui_textbomb", PLUGIN / "yui" / "textbomb.py")
report = _load("yui_report", PLUGIN / "yui_report.py")

# The INT-18 build ping Chris got as one wall (TestFlight feedback, build 82).
INT18 = (
    "A2A bridge: add any A2A agent to Yui by its Agent Card. node adapters/a2a/yui-a2a.ts pair <code> --card <url>, "
    "then run; add --card <url> puts more agents on the same machine. Runtime-neutral TypeScript client (src/a2a.ts + "
    "src/sse.ts, fetch and an SSE parser only, so the hosted step runs the same code in a Durable Object): A2A 1.0 "
    "SendMessage / SendStreamingMessage / SubscribeToTask / GetTask / CancelTask and 0.3 message/send, message/stream, "
    "tasks/resubscribe, tasks/get, one version-free shape for callers; 1.0 wins when a card lists both. The bridge keeps "
    "the relay's rules (delivered on pickup, handled after the answer, meta.turn, outbox on disk, one turn at a time per "
    "agent, a clean stop reads offline): contextId = the Yui agent, the channel guide rides as a context part on each new "
    "task. Tests: client.test.ts 42/42; sdk_interop.test.ts 4/4 against the official a2a-sdk servers (1.1.5 and 0.3.26); "
    "a2a_e2e.py 66/66 live on throwaway accounts. No app binary change (INT-18)"
)


class Guard(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        os.environ["YUI_TEXTBOMB_LOG"] = str(Path(self.dir) / "tb.jsonl")
        os.environ.pop("HERMES_CRON_SESSION", None)

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)
        os.environ.pop("YUI_TEXTBOMB_LOG", None)

    def rows(self):
        p = Path(os.environ["YUI_TEXTBOMB_LOG"])
        return [json.loads(x) for x in p.read_text().splitlines()] if p.exists() else []

    def test_short_text_is_not_logged(self):
        self.assertEqual(textbomb.record("Leg day. Pick your gear.", "yui"), 0)
        self.assertEqual(self.rows(), [])

    def test_screens_do_not_count(self):
        big = "```yui\n" + "\n".join(f'page "P{i}" body="{"word " * 40}"' for i in range(8)) + "\n```"
        self.assertEqual(textbomb.chat_words("Here it is.\n" + big), 3)
        self.assertEqual(textbomb.record("Here it is.\n" + big, "yui"), 0)
        self.assertEqual(textbomb.chat_words("MEDIA:/tmp/a.png\nhi"), 1)

    def test_a_wall_is_logged_without_its_text(self):
        n = textbomb.record(INT18, "yui", "handoff")
        self.assertGreater(n, textbomb.CAP)
        [r] = self.rows()
        self.assertEqual((r["profile"], r["source"], r["words"], r["screen"]), ("yui", "handoff", n, False))
        raw = Path(os.environ["YUI_TEXTBOMB_LOG"]).read_text()
        for leak in ("A2A", "bridge", "INT-18", "42/42"):
            self.assertNotIn(leak, raw)

    def test_cron_is_named(self):
        os.environ["HERMES_CRON_SESSION"] = "1"
        try:
            textbomb.record(INT18, "yui", "out-of-process")
        finally:
            os.environ.pop("HERMES_CRON_SESSION")
        self.assertEqual(self.rows()[0]["source"], "cron")

    def test_never_raises(self):
        os.environ["YUI_TEXTBOMB_LOG"] = "/dev/null/nope/tb.jsonl"
        self.assertEqual(textbomb.record(INT18, "yui"), 0)
        self.assertEqual(textbomb.record(None), 0)

    def test_report(self):
        self.assertIn("No text bombs", textbomb.report(7))
        textbomb.record(INT18, "yui", "reply")
        textbomb.record(INT18, "yui", "reply")
        out = textbomb.report(7)
        self.assertIn("yui reply: 2", out)


class Report(unittest.TestCase):
    def ping(self):
        return report.render({
            "line": "📱 Build 82 is ready in TestFlight.",
            "card": {"title": "Build 82", "body": "INT-18: " + INT18, "cta": "Open TestFlight",
                     "url": "https://testflight.apple.com/join/ykrYHwet"},
            "deck": "What's in build 82",
            "pages": [{"title": "INT-18", "body": INT18},
                      {"title": "Tests", "points": ["client.test.ts 42/42", "a2a_e2e.py 66/66 | live"]}],
        })

    def test_no_wall_in_chat(self):
        msg = self.ping()
        self.assertLessEqual(textbomb.chat_words(msg), report.LINE_WORDS)
        self.assertEqual(textbomb.record(msg, "yui"), 0)

    def test_pages_are_short_and_whole(self):
        ps = report.pages([{"title": "INT-18", "body": INT18}])
        self.assertGreater(len(ps), 1)
        self.assertEqual(ps[0]["title"], "INT-18")                     # said once, no (1/3) counters
        self.assertTrue(all(p["title"] == "" for p in ps[1:]))
        for p in ps:
            self.assertLessEqual(report.words(p["body"]), report.PAGE_WORDS * 3 // 2)
        self.assertEqual(" ".join(p["body"] for p in ps).split(), INT18.split())   # nothing lost

    def test_giant_sentence_splits(self):
        ps = report.chunks("word " * 400)
        self.assertTrue(all(report.words(c) <= report.PAGE_WORDS * 3 // 2 for c in ps))
        self.assertEqual(sum(report.words(c) for c in ps), 400)

    def test_clip_stops_after_a_clause(self):
        s = "I've carded it as YUI-81 (backlog), with the other Yui app cards, next to YUI-79 (no text bombs)"
        self.assertEqual(report.clip(s, 8), "I've carded it as YUI-81 (backlog)…")
        self.assertEqual(report.clip("one two three four five six", 3), "one two three…")

    def test_quotes_escape(self):
        self.assertEqual(report.q('say "hi" \\ there\n now'), '"say \\"hi\\" \\\\ there now"')

    def test_fold(self):
        self.assertEqual(report.fold("Note", "Short and sweet."), "Short and sweet.")
        msg = report.fold("Report", INT18)
        self.assertIn("```yui\ndeck", msg)
        self.assertLessEqual(textbomb.chat_words(msg), report.LINE_WORDS)

    @unittest.skipUnless(shutil.which("node") and (HUB / "site/lib/yl/yl.mjs").exists(), "needs node and ../yuigui")
    def test_parses_as_yui_lines(self):
        msg = self.ping()
        body = msg.split("```yui\n", 1)[1].rsplit("```", 1)[0]
        js = ("import {parse} from %s; const ops = parse(process.argv[1]);"
              "console.log(JSON.stringify(ops.map(o => [o.op, o.preset || null, o.props || {}, o.in || null])))"
              % json.dumps(str(HUB / "site/lib/yl/yl.mjs")))
        out = subprocess.run(["node", "--input-type=module", "-e", js, body], capture_output=True, text=True)
        self.assertEqual(out.returncode, 0, out.stderr)
        ops = json.loads(out.stdout)
        self.assertFalse([o for o in ops if o[0] == "error"], ops)
        presets = [o[1] for o in ops if o[0] == "add"]
        self.assertEqual(presets[:2], ["card", "deck"])
        self.assertTrue(all(p == "page" for p in presets[2:]))
        card, deck = ops[0][2], ops[1][2]
        self.assertEqual((card["cta"], card["url"]), ("Open TestFlight", "https://testflight.apple.com/join/ykrYHwet"))
        self.assertEqual((deck["title"], deck["inline"]), ("What's in build 82", True))
        tests = [o[2] for o in ops if o[1] == "page"][-1]
        self.assertEqual(tests["points"], ["client.test.ts 42/42", "a2a_e2e.py 66/66 / live"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
