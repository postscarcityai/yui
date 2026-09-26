"""Restyle Yui by asking on the host (YUI-96): `theme app` lines go out only
from the owner's turn to a phone at or above restyle_min_build, the guide's
sentence is taught only there, and the preview card's taps read the spec's way.

    ~/.hermes/hermes-agent/venv/bin/python hermes-plugin/tests/test_restyle.py

restyle_min_build itself is a yui_limits row (migration
20260925100500_yui_restyle_min_build.sql). These need only the plugin source.
"""

import asyncio
import os
import sys
import tempfile
import unittest
from pathlib import Path

os.environ["HERMES_HOME"] = tempfile.mkdtemp(prefix="yui-restyle-")  # turns write talk state (YUI-69): never the real home

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_board import _adapter_module, _load, PLUGIN  # noqa: E402
from test_shared import AID, CLIENT, OWNER, Adapter as SharedAdapter  # noqa: E402

restyle = _load("yui_restyle", PLUGIN / "yui" / "restyle.py")

MIN = 130
OFFER = "Autumn, here's the preview.\n```yui\ntheme app autumn\n```"


def fence(*lines):
    return "```yui\n" + "\n".join(lines) + "\n```"


class Gate(unittest.TestCase):
    def test_owner_on_a_new_build_passes_the_line_through(self):
        self.assertEqual(restyle.gate(OFFER, True, MIN, MIN), (OFFER, None))
        self.assertEqual(restyle.gate(OFFER, True, MIN + 5, MIN), (OFFER, None))

    def test_an_old_build_drops_the_line(self):
        body, why = restyle.gate(OFFER, True, MIN - 1, MIN)
        self.assertEqual((body, why), ("Autumn, here's the preview.", "old"))

    def test_unknown_build_or_limit_counts_as_old(self):
        self.assertEqual(restyle.gate(OFFER, True, None, MIN)[1], "old")
        restyle.LIMIT["min_build"] = None
        self.assertEqual(restyle.gate(OFFER, True, 999)[1], "old")

    def test_a_non_owner_turn_drops_it_on_any_build(self):
        self.assertEqual(restyle.gate(OFFER, False, 999, MIN)[1], "shared")

    def test_only_theme_app_lines_go_and_a_route_prefix_counts(self):
        body = fence("say Here:", ">2 theme app ocean font=serif", "theme autumn", "card Hi")
        out, why = restyle.gate(body, True, 10, MIN)
        self.assertEqual(out, fence("say Here:", "theme autumn", "card Hi"))
        self.assertEqual(why, "old")
        self.assertEqual(restyle.gate("theme app autumn, in words", True, 10, MIN), ("theme app autumn, in words", None))

    def test_the_note_is_one_plain_line(self):
        n = restyle.note(120)
        self.assertTrue(n.startswith("[yui] note: ") and "build 120" in n and "\n" not in n)


class Guide(unittest.TestCase):
    def test_the_bundled_guide_has_the_block_and_the_hint_does_not(self):
        ad = _adapter_module()
        _, body = ad.load_guide()
        fixed, text = restyle.split_guide(body)
        self.assertIn("<!-- restyle:", body)
        self.assertTrue(text.startswith("Yui's own look: ") and "`theme app autumn`" in text, text)
        self.assertNotIn("theme app", fixed)
        self.assertNotIn("theme app", ad.platform_hint())
        self.assertIn("`theme autumn`", ad.platform_hint())  # the agent's own look stays

    def test_restyle_prompt_only_for_the_owner_on_a_new_build(self):
        ad = _adapter_module()
        ad.restyle.LIMIT["min_build"] = MIN
        ad.compat.PHONE.update(known=True, build=MIN)
        self.assertIn("theme app autumn", ad.restyle_prompt(True))
        self.assertEqual(ad.restyle_prompt(False), "")
        ad.compat.PHONE.update(build=MIN - 1)
        self.assertEqual(ad.restyle_prompt(True), "")


class Tap(unittest.TestCase):
    def test_the_app_tap_reads_as_the_spec_writes_it(self):
        self.assertEqual(restyle.tap_text("[yui] restyle theme choice=apply name=autumn scope=app"),
                         "[yui] restyle theme app choice=apply name=autumn")
        self.assertEqual(restyle.tap_text('[yui] restyle theme choice=keep name="this look" scope=app'),
                         '[yui] restyle theme app choice=keep name="this look"')
        self.assertEqual(restyle.tap_text("[yui] n1 choose choice=Legs"), "[yui] n1 choose choice=Legs")


class Turn(SharedAdapter):
    """The adapter: outbound drops, the note on the next turn, the turn's prompt."""

    def make(self, build=MIN, safe=True):
        ad, a = super().make(safe)
        ad.restyle.LIMIT["min_build"] = MIN
        ad.compat.PHONE.update(known=True, build=build)
        a._notes = {}
        a._outbox = type("O", (), {"add": lambda *_: None, "__len__": lambda self: 0})()
        a._client, a._token = object(), "t"

        ad.media.rewrite = lambda body, *_: body
        ad.SendResult = lambda **kw: kw
        a._spawn = lambda coro: coro.close()
        return ad, a

    def send(self, a, key, body):
        return asyncio.run(a._insert(key, body))

    def test_old_build_drops_the_line_and_notes_the_next_turn(self):
        ad, a = self.make(build=MIN - 10)
        self.send(a, AID, OFFER)
        self.assertEqual([w["body"] for w in a.written], ["Autumn, here's the preview."])
        self.assertEqual(len(a._notes[AID]), 1)
        self.send(a, AID, OFFER)
        self.assertEqual(len(a._notes[AID]), 1)  # one note, however many tries
        asyncio.run(a._dispatch([self.row(OWNER, "why not?")]))
        ev = a.handled[0]
        self.assertTrue(ev.text.startswith("[yui] note: this person's Yui app (build 120) cannot restyle"), ev.text)
        self.assertNotIn("theme app", ev.channel_prompt)  # not taught there either

    def test_a_reply_of_only_the_line_sends_nothing(self):
        ad, a = self.make(build=MIN - 10)
        r = self.send(a, AID, fence("theme app autumn"))
        self.assertEqual(a.written, [])
        self.assertEqual(r.get("message_id"), None)

    def test_a_non_owner_turn_drops_it_and_is_not_taught(self):
        ad, a = self.make(build=MIN + 1)
        self.send(a, f"{AID}~{CLIENT}", OFFER)
        self.assertEqual([(w["user_id"], w["body"]) for w in a.written], [(CLIENT, "Autumn, here's the preview.")])
        self.assertEqual(a._notes, {})  # nothing taught to a shared agent
        asyncio.run(a._dispatch([self.row(CLIENT, "make Yui feel like autumn")]))
        self.assertNotIn("theme app", a.handled[0].channel_prompt)

    def test_owner_on_a_new_build_is_taught_and_sends_it(self):
        ad, a = self.make(build=MIN)
        self.send(a, AID, OFFER)
        self.assertEqual([w["body"] for w in a.written], [OFFER])
        asyncio.run(a._dispatch([self.row(OWNER, "make Yui feel like autumn")]))
        prompt = a.handled[0].channel_prompt
        self.assertTrue(prompt.startswith("Your look in Yui: "), prompt)
        self.assertIn("Yui's own look: when the person asks", prompt)

    def test_the_tap_reaches_the_agent_in_the_spec_form(self):
        ad, a = self.make()
        asyncio.run(a._dispatch([self.row(OWNER, "[yui] restyle theme choice=apply name=autumn scope=app", kind="event")]))
        self.assertTrue(a.handled[0].text.endswith("[yui] restyle theme app choice=apply name=autumn"), a.handled[0].text)


# test_shared's cases would run twice under this name.
for _n in [n for n in dir(SharedAdapter) if n.startswith("test_")]:
    setattr(Turn, _n, None)
del SharedAdapter


if __name__ == "__main__":
    unittest.main(verbosity=2)
