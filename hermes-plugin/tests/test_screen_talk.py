"""Chat with a screen (YUI-62): words typed on a page reach the agent tagged.

    ~/.hermes/hermes-agent/venv/bin/python hermes-plugin/tests/test_screen_talk.py

The app writes the person's row as `[yui] screen=2` then the words, with
meta {"screen": "2"} (spec yuigui/spec/YL.md section 7). The adapter passes the
body through untouched, so the agent reads which screen the words are about.
Needs nothing but the plugin source.
"""

import asyncio
import sys
import types
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_board import _adapter_module  # noqa: E402


class Event:
    def __init__(self, **kw):
        self.__dict__.update(kw)

    def is_command(self):
        return self.text.lstrip().startswith("/")


def adapter():
    ad = _adapter_module()
    ad.MessageEvent = Event
    ad.MessageType = types.SimpleNamespace(PHOTO="photo", TEXT="text")
    a = ad.YuiAdapter.__new__(ad.YuiAdapter)
    a._user_id = "u1"  # the owner's thread (YUI-95)
    a._agents = {"a1": {"name": "Arnold"}}
    a._notes, a._last_inbound, a._turns, a._token = {}, {}, {}, None
    a.got = []
    a.build_source = lambda **kw: kw

    async def no_notes(aid, upto):
        return []

    async def handle(event):
        a.got.append(event)
    a._mention_notes, a.handle_message = no_notes, handle
    return a


def row(body, meta=None, rid="row-1"):
    return {"id": rid, "agent_id": "a1", "user_id": "u1", "kind": "text", "body": body, "meta": meta,
            "created_at": "2026-09-25T14:00:00Z"}


class TypedOnAScreen(unittest.TestCase):
    def test_the_tag_reaches_the_agent(self):
        a = adapter()
        asyncio.run(a._dispatch([row("[yui] screen=2\nMake Thursday a swim instead.", {"screen": "2"})]))
        self.assertEqual(len(a.got), 1)
        self.assertEqual(a.got[0].text, "[yui] screen=2\nMake Thursday a swim instead.")
        self.assertEqual(a._turns[id(a.got[0])], ("a1", ["row-1"]), "it is a normal turn the agent answers")

    def test_a_backlog_keeps_each_tag_on_its_own_line(self):
        a = adapter()
        asyncio.run(a._dispatch([row("hello", rid="r1"),
                                 row("[yui] screen=3\nAdd sunscreen", {"screen": "3"}, rid="r2")]))
        self.assertEqual(a.got[0].text, "hello\n[yui] screen=3\nAdd sunscreen")


if __name__ == "__main__":
    unittest.main()
