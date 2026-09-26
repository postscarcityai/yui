"""The working row on the host (YUI-63 step 2): `doing` lines never become
messages, the newest goes onto the running turn's rows about once a second,
only to a phone that draws it, and tool calls turn into plain words.

    ~/.hermes/hermes-agent/venv/bin/python hermes-plugin/tests/test_doing.py

The column and doing_min_build are SQL (migration 20260926010000_yui_doing.sql).
These need only the plugin source.
"""

import asyncio
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

os.environ["HERMES_HOME"] = tempfile.mkdtemp(prefix="yui-doing-")  # turns write talk state (YUI-69): never the real home

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_board import _load, PLUGIN  # noqa: E402
import test_shared  # noqa: E402
from test_shared import AID, CLIENT, OWNER  # noqa: E402

doing = _load("yui_doing", PLUGIN / "yui" / "doing.py")

REPO = PLUGIN.parent
VECTORS = REPO / "Packages" / "YuiLines" / "Tests" / "YuiLinesTests" / "Resources" / "conformance" / "35-doing.json"
MIN = 140


def fence(*lines):
    return "```yui\n" + "\n".join(lines) + "\n```"


def doing_of(text):
    """doingOf over a whole input, the host's way: each doing line in order."""
    now = None
    for ln in text.split("\n"):
        if doing.LINE.match(ln):
            d = doing.parse(ln)
            if d is None:
                continue
            now = None if d == doing.OFF else d
    return now


class Lines(unittest.TestCase):
    def test_matches_the_shared_vectors(self):
        """Every 35-doing.json vector: the host reads the same working row as yl.mjs."""
        vectors = json.loads(VECTORS.read_text())["vectors"]
        self.assertGreater(len(vectors), 20)
        for v in vectors:
            with self.subTest(v["name"]):
                self.assertEqual(doing_of(v["input"]), v["doing"])

    def test_a_message_of_only_doing_is_nothing(self):
        self.assertEqual(doing.split(fence('doing "Reading your calendar" 1/3')),
                         ("", {"text": "Reading your calendar", "step": 1, "of": 3}))
        self.assertEqual(doing.split(fence("doing Reading", "doing off")), ("", doing.OFF))

    def test_doing_leaves_the_rest_alone(self):
        body = "Free at 3.\n" + fence("doing Checking the weather 2/3", "choose \"Book it?\" Yes|No")
        rest, now = doing.split(body)
        self.assertEqual(rest, "Free at 3.\n" + fence('choose "Book it?" Yes|No'))
        self.assertEqual(now, {"text": "Checking the weather", "step": 2, "of": 3})
        self.assertEqual(doing.split("I'm doing fine."), ("I'm doing fine.", None))
        self.assertEqual(doing.split(fence("say doing it")), (fence("say doing it"), None))

    def test_a_bad_doing_line_goes_too(self):
        # An error line would show as an error on the phone: the host drops it.
        self.assertEqual(doing.split(fence("doing Six 6/5", "say Hi")), (fence("say Hi"), None))

    def test_long_words_are_cut(self):
        d = doing.parse("doing " + "word " * 40)
        self.assertLessEqual(len(d["text"]), doing.MAX_TEXT)

    def test_build_gate(self):
        self.assertFalse(doing.allowed(None, MIN))
        self.assertFalse(doing.allowed(MIN - 1, MIN))
        self.assertTrue(doing.allowed(MIN, MIN))
        self.assertFalse(doing.allowed(MIN, None))  # the limit not read yet: too old


class Tools(unittest.TestCase):
    def test_plain_words_never_names(self):
        self.assertEqual(doing.tool_words("web_search"), "Searching the web")
        self.assertEqual(doing.tool_words("browser_click"), "Using the browser")
        self.assertEqual(doing.tool_words("kanban_show"), "Checking the board")
        self.assertIsNone(doing.tool_words("clarify"))
        self.assertIsNone(doing.tool_words("something_new"))
        for w in list(doing.TOOL_WORDS.values()) + [w for _, w in doing.TOOL_PREFIXES]:
            self.assertNotIn("_", w)
            self.assertNotIn("—", w)
            self.assertLessEqual(len(w), 40, w)

    def test_only_yui_sessions(self):
        seen = []

        class A:
            def doing_from_tool(self, user, props):
                seen.append((user, props))
        a = A()
        doing.ADAPTERS.add(a)
        try:
            doing.remember_session(session_id="s-tg", platform="telegram", sender_id="u9")
            doing.on_tool(tool_name="web_search", session_id="s-tg")
            doing.remember_session(session_id="s-yui", platform="yui", sender_id=OWNER)
            doing.on_tool(tool_name="web_search", session_id="s-yui")
            doing.on_tool(tool_name="clarify", session_id="s-yui")
        finally:
            doing.ADAPTERS.discard(a)
        self.assertEqual(seen, [(OWNER, {"text": "Searching the web"})])


class Throttle(unittest.TestCase):
    def test_newest_wins_about_once_a_second(self):
        async def run():
            wrote = []

            async def write(key, value):
                wrote.append((key, value))
            w = doing.Writer(write, every=0.2)
            w.note("k", {"text": "one"})
            await asyncio.sleep(0.01)
            w.note("k", {"text": "two"})
            w.note("k", {"text": "three"})
            await asyncio.sleep(0.05)
            self.assertEqual(wrote, [("k", {"text": "one"})], "a second write went out inside the second")
            await asyncio.sleep(0.25)
            self.assertEqual(wrote, [("k", {"text": "one"}), ("k", {"text": "three"})], "the newest did not win")
            w.note("k", {"text": "three"})
            await asyncio.sleep(0.25)
            self.assertEqual(len(wrote), 2, "the same doing twice is one write")
            w.note("k", doing.OFF)
            await asyncio.sleep(0.25)
            self.assertEqual(wrote[-1], ("k", None))
            w.note("k", {"text": "late"})
            w.end("k")
            await asyncio.sleep(0.25)
            self.assertEqual(wrote[-1], ("k", None), "a write landed after the turn ended")
        asyncio.run(run())


class Turn(unittest.TestCase):
    """The adapter: a doing-only send writes no row and no push; the doing goes on the turn's rows."""

    def make(self, build=MIN, safe=True):
        ad, a = test_shared.Adapter.make(self, safe)
        ad.doing.LIMIT["min_build"] = MIN
        ad.restyle.LIMIT["min_build"] = 10000
        ad.compat.PHONE.update(known=True, build=build)
        a._outbox = type("O", (), {"add": lambda *_: None, "__len__": lambda self: 0})()
        a._client, a._token = object(), "t"
        ad.media.rewrite = lambda body, *_: body
        ad.SendResult = lambda **kw: kw
        a.pushed, a.doings = [], []
        a._spawn = lambda coro: (a.pushed.append(1), coro.close())

        async def write_doing(key, value):
            a.doings.append((key, value))
        a._doing = ad.doing.Writer(write_doing, every=0.05)
        return ad, a

    def put(self, a, key, body, wait=0.1):
        async def go():
            r = await a._insert(key, body)
            await asyncio.sleep(wait)
            return r
        return asyncio.run(go())

    def test_doing_only_mid_turn(self):
        ad, a = self.make()
        a._busy[AID] = (["r1", "r2"], 0)
        r = self.put(a, AID, fence('doing "Reading your calendar" 1/3'))
        self.assertEqual(r, {"success": True, "message_id": None})
        self.assertEqual(a.written, [], "a doing became a message")
        self.assertEqual(a.pushed, [], "a doing pushed the phone")
        self.assertEqual(a.doings, [(AID, {"text": "Reading your calendar", "step": 1, "of": 3})])

    def test_old_phone_keeps_pondering(self):
        ad, a = self.make(build=MIN - 1)
        a._busy[AID] = (["r1"], 0)
        self.put(a, AID, fence("doing Reading 1/3"))
        self.assertEqual((a.written, a.doings), ([], []))
        self.put(a, AID, "Here.\n" + fence("doing Reading 1/3", "say Done."))
        self.assertEqual([w["body"] for w in a.written], ["Here.\n" + fence("say Done.")],
                         "an old phone got a doing line it would show as an Update chip")

    def test_no_turn_no_doing(self):
        ad, a = self.make()
        self.put(a, AID, fence("doing Reading"))
        self.assertEqual((a.written, a.doings), ([], []))

    def test_a_shared_thread_is_its_own(self):
        ad, a = self.make()
        key = f"{AID}~{CLIENT}"
        ad.compat.PHONE.setdefault("users", {})[CLIENT] = MIN
        a._busy[key] = (["c1"], 0)
        self.put(a, key, fence("doing Looking at your week"))
        self.assertEqual(a.doings, [(key, {"text": "Looking at your week"})])

    def test_tool_calls_reach_the_one_running_turn(self):
        ad, a = self.make()

        async def go():
            a._loop = asyncio.get_running_loop()
            a._busy[AID] = (["r1"], 0)
            a.doing_from_tool(OWNER, {"text": "Searching the web"})
            await asyncio.sleep(0.1)
            a.doing_from_tool(CLIENT, {"text": "Reading a file"})  # no turn of theirs runs here
            await asyncio.sleep(0.1)
        asyncio.run(go())
        self.assertEqual(a.doings, [(AID, {"text": "Searching the web"})])


if __name__ == "__main__":
    unittest.main(verbosity=1)
