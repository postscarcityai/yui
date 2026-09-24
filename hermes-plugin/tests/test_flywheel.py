"""Preset flywheel (YUI-42): the log holds shapes, never values.

    python3 hermes-plugin/tests/test_flywheel.py

No Hermes needed: flywheel.py and flywheel_report.py load on their own. The
conformance vectors and yl.mjs are read from ../yuigui when it sits next to
this repo (YUI_HUB overrides); those tests skip without it.
"""

import importlib.util
import json
import os
import random
import re
import string
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


flywheel = _load("yui_flywheel", PLUGIN / "yui" / "flywheel.py")
report = _load("yui_flywheel_report", PLUGIN / "flywheel_report.py")

# Custom lines from YL.md section 6 and the channel guide, plus the kind of
# thing an agent really sends: names, prices, links, ids, emails.
REAL = [
    'custom {"type":"text","text":"hi","size":"lg"}',
    'custom@countdown {"type":"stat","value":"3","label":"days"}',
    'custom {"type":"stack","children":[{"type":"badge","text":"PR"},{"type":"divider"},'
    '{"type":"stat","value":1.5,"label":"km"}]}',
    'custom {"type":"row","children":[{"type":"image","src":"https://cdn.example.com/p/8f3a.jpg?sig=Zq9Xk",'
    '"alt":"Chris at the beach"},{"type":"button","text":"Book 4:30 with Dr. Alvarez","action":"book-4-30"}]}',
    'custom {"type":"ticket","seat":"14C","gate":"B22","flight":"DL 1182","pnr":"QX7Z2M",'
    '"passenger":"Mick Johnston","boarding":"2026-09-25T16:40:00-04:00"}',
    'custom {"type":"receipt","total":41.87,"items":[{"name":"Oat latte","price":6.25},'
    '{"name":"Croissant","price":4.5}],"email":"someone@example.org"}',
    'custom {"scores":{"Alice":3,"Bob Smith":7,"555-0142":1},"type":"leaderboard"}',
    'custom {"type":"Private Label","note":"call 305-555-0199"}',
    'custom 42',
    'custom "just a string with a secret sk-live-abc123"',
    'custom [1,2,{"type":"text","text":"Meet at 5 Main St"}]',
    'custom {"type":"text","text":"bad json" # comment}',
]


def leaves(v):
    """Every string and number in a JSON value, plus the names allowed to survive."""
    vals, names = [], set()
    if isinstance(v, dict):
        for k, x in v.items():
            names.add(k)
            if k == "type" and isinstance(x, str):
                names.add(x)
            a, b = leaves(x)
            vals += a
            names |= b
    elif isinstance(v, list):
        for x in v:
            a, b = leaves(x)
            vals += a
            names |= b
    elif isinstance(v, bool) or v is None:
        pass
    elif isinstance(v, (int, float, str)):
        vals.append(v)
    return vals, names


def fence(*lines) -> str:
    return "Here you go.\n\n```yui\n" + "\n".join(lines) + "\n```\n"


class Env(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        self._env = {k: os.environ.get(k) for k in ("HERMES_HOME", "YUI_FLYWHEEL_LOG")}
        os.environ["HERMES_HOME"] = str(self.home)
        os.environ.pop("YUI_FLYWHEEL_LOG", None)
        flywheel._enabled_cache = (None, False)

    def tearDown(self):
        for k, v in self._env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self.tmp.cleanup()

    def turn_on(self, on=True):
        (self.home / "config.yaml").write_text(f"model: x\nyui:\n  flywheel: {'true' if on else 'false'}\n")
        flywheel._enabled_cache = (None, False)

    def log(self) -> str:
        p = self.home / "yui" / "flywheel.jsonl"
        return p.read_text() if p.exists() else ""

    def assert_no_values(self, line: str, text: str):
        """No value from the custom line's JSON appears in `text` (the log)."""
        try:
            value = json.loads(line.split(None, 1)[1])
        except (ValueError, IndexError):
            return
        vals, names = leaves(value)
        tokens = set(re.findall(r"[A-Za-z0-9_.:@/-]+", text))
        for v in vals:
            s = str(v)
            if s in names:
                continue  # a value that is also a key or type name in the same JSON
            self.assertNotIn(s, tokens, f"value {s!r} leaked from {line!r}")
            if len(s) >= 4:
                self.assertNotIn(s, text, f"value {s!r} leaked from {line!r}")
        for bad in ("http", "://", "@example", "sk-live", "Johnston", "Alice", "Bob", "Private"):
            self.assertNotIn(bad, text)


class Logging(Env):
    def test_off_by_default(self):
        self.assertEqual(flywheel.record(fence(REAL[0]), "yui"), 0)
        self.assertEqual(self.log(), "")
        self.turn_on(False)
        self.assertEqual(flywheel.record(fence(REAL[0]), "yui"), 0)
        self.assertEqual(self.log(), "")

    def test_real_lines_log_shapes_only(self):
        self.turn_on()
        n = flywheel.record(fence(*REAL), "yui")
        self.assertEqual(n, len(REAL))
        text = self.log()
        rows = [json.loads(x) for x in text.splitlines()]
        self.assertEqual({r["kind"] for r in rows}, {"custom"})
        self.assertEqual(set(rows[0]), {"date", "profile", "kind", "hash", "shape"})
        for line in REAL:
            self.assert_no_values(line, text)
        shapes = [r["shape"] for r in rows]
        self.assertEqual(shapes[0], "text{size:s,text:s}")
        self.assertEqual(shapes[2], "stack{children:[badge{text:s}|divider{}|stat{label:s,value:n}]}")
        self.assertEqual(shapes[6], "leaderboard{scores:{*:n}}")   # data keys collapse to *
        self.assertEqual(shapes[7], "?{note:s}")                     # a type name that reads as data
        self.assertEqual(shapes[8], "n")
        self.assertEqual(shapes[11], "!json")

    def test_same_shape_same_hash(self):
        self.turn_on()
        flywheel.record(fence('custom {"type":"stat","value":"3","label":"days"}',
                              'custom {"label":"kg lost","type":"stat","value":"12"}'), "yui")
        a, b = [json.loads(x) for x in self.log().splitlines()]
        self.assertEqual(a["hash"], b["hash"])

    def test_unknown_words_keep_the_word_only(self):
        self.turn_on()
        flywheel.record(fence("poll@lunch \"Where to, Mick?\" Tacos|Sushi", ">2 confetti 3s gold",
                              "timer 40/20x8 Tabata", "Timer 60", "~hiit rounds=10", ">full",
                              "# poll comment", "save leg day"), "yui")
        rows = [json.loads(x) for x in self.log().splitlines()]
        self.assertEqual([r["word"] for r in rows], ["poll", "confetti"])
        for leak in ("Mick", "Tacos", "Sushi", "gold", "lunch", "Tabata"):
            self.assertNotIn(leak, self.log())

    def test_text_outside_fences_is_ignored(self):
        self.turn_on()
        self.assertEqual(flywheel.record('custom {"type":"text","text":"x"}\nplain reply', "yui"), 0)
        self.assertEqual(self.log(), "")

    def test_random_fuzz_never_leaks_a_sentinel(self):
        self.turn_on()
        rnd = random.Random(42)

        def word():
            return "".join(rnd.choice(string.ascii_lowercase) for _ in range(rnd.randint(3, 8)))

        def sentinel():
            kind = rnd.choice(["url", "text", "email", "num", "id"])
            tag = "".join(rnd.choice(string.ascii_uppercase) for _ in range(6))
            return {"url": f"https://leak-{tag}.example/{tag}", "text": f"LEAK {tag} said hi",
                    "email": f"LEAK{tag}@mail.test", "num": f"LEAK{tag}",
                    "id": f"LEAK-{tag}-{rnd.randint(0, 99999)}"}[kind]

        def value(depth=0):
            r = rnd.random()
            if depth > 7 or r < 0.35:
                return rnd.choice([sentinel(), rnd.randint(-99999, 99999), rnd.random() * 1e6, True, None])
            if r < 0.55:
                return [value(depth + 1) for _ in range(rnd.randint(0, 4))]
            obj = {word(): value(depth + 1) for _ in range(rnd.randint(0, 5))}
            if rnd.random() < 0.4:
                obj["LEAK" + word().upper()] = value(depth + 1)   # a data-shaped key
            if rnd.random() < 0.6:
                obj["type"] = rnd.choice([word(), sentinel()])
            if rnd.random() < 0.1:
                obj.update({f"k{i}": sentinel() for i in range(20)})  # a big map
            return obj

        lines = [f"custom {json.dumps(value())}" for _ in range(400)]
        flywheel.record(fence(*lines), "yui")
        text = self.log()
        self.assertEqual(len(text.splitlines()), 400)
        self.assertNotIn("LEAK", text.upper())
        self.assertNotIn("http", text)
        for n in re.findall(r'"shape": "([^"]*)"', text):
            self.assertLessEqual(len(n), flywheel.MAX_SHAPE)

    @unittest.skipUnless((HUB / "spec" / "conformance").is_dir(), "yuigui checkout not found")
    def test_conformance_vectors(self):
        self.turn_on()
        customs = []
        for f in sorted((HUB / "spec" / "conformance").glob("*.json")):
            for v in json.loads(f.read_text()).get("vectors", []):
                flywheel.record(fence(v["input"]), "yui")
                customs += [ln.strip() for ln in v["input"].split("\n") if re.match(r"\s*(>\S+\s+)?custom\b", ln)]
        self.assertGreater(len(customs), 3)
        text = self.log()
        for line in customs:
            self.assert_no_values(re.sub(r"^>\S+\s+", "", line), text)

    def test_never_raises(self):
        os.environ["YUI_FLYWHEEL_LOG"] = "/dev/null/not/a/dir/flywheel.jsonl"
        self.turn_on()
        self.assertEqual(flywheel.record(fence(REAL[0]), "yui"), 0)


class Vocabulary(unittest.TestCase):
    @unittest.skipUnless((HUB / "site" / "lib" / "yl" / "yl.mjs").exists(), "yuigui checkout not found")
    def test_matches_yl_mjs(self):
        src = (HUB / "site" / "lib" / "yl" / "yl.mjs").read_text()
        presets = set(re.findall(r'"(\w+)"', re.search(r"export const PRESETS = \[(.*?)\];", src, re.S).group(1)))
        core = set(re.findall(r'"(\w+)"', re.search(r"export const CORE = \[(.*?)\];", src, re.S).group(1)))
        self.assertEqual(flywheel.PRESETS, presets)
        self.assertEqual(flywheel.CORE, core)

    def test_adapter_records_before_media_rewrite(self):
        src = (PLUGIN / "yui" / "adapter.py").read_text()
        self.assertEqual(src.count("flywheel.record("), 2)
        for m in re.finditer(r"flywheel\.record\(", src):
            self.assertIn("media.rewrite", src[m.end():m.end() + 300])


class Report(unittest.TestCase):
    def rows(self):
        out = []
        for d in range(1, 5):   # 4 days, 2 a day: 8 uses
            out += [{"date": f"2026-09-0{d}", "profile": "yui", "kind": "custom", "hash": "aaa", "shape": "ticket{seat:s}"}] * 2
        out += [{"date": "2026-09-01", "profile": "yui", "kind": "custom", "hash": "bbb", "shape": "text{text:s}"}] * 9
        out += [{"date": f"2026-09-0{d}", "profile": "yui", "kind": "custom", "hash": "ccc", "shape": "!json"} for d in range(1, 7)]
        out += [{"date": "2026-09-02", "profile": "yui", "kind": "word", "word": "poll"}] * 3
        return out

    def test_bar(self):
        md = report.report(self.rows(), min_uses=5, min_days=3, top=10, source="x")
        ready = md.split("## Ready to promote")[1].split("##")[0]
        self.assertIn("aaa", ready)
        self.assertNotIn("bbb", ready)   # 9 uses, one day
        self.assertNotIn("ccc", ready)   # bad JSON never qualifies
        self.assertIn("| `poll` | 3 | 1 |", md)
        self.assertIn("`ticket{seat:s}`", md)

    def test_nudge_is_silent_below_the_bar(self):
        self.assertEqual(report.nudge(self.rows()[8:], min_uses=5, min_days=3), "")
        self.assertIn("aaa: 8 uses on 4 days", report.nudge(self.rows(), min_uses=5, min_days=3))

    def test_cli_on_a_file(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "f.jsonl"
            p.write_text("".join(json.dumps(r) + "\n" for r in self.rows()) + "not json\n")
            import io
            from contextlib import redirect_stdout
            buf = io.StringIO()
            with redirect_stdout(buf):
                report.main(["--log", str(p), "--only-qualified"])
            self.assertIn("aaa", buf.getvalue())
            buf = io.StringIO()
            with redirect_stdout(buf):
                report.main(["--log", str(Path(d) / "missing.jsonl"), "--only-qualified"])
            self.assertEqual(buf.getvalue(), "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
