"""Shared agents on the host (YUI-95): the sandbox report, one session per
person, the re-check before a non-owner turn, owner-only taps.

    ~/.hermes/hermes-agent/venv/bin/python hermes-plugin/tests/test_shared.py

Grants, policies and the client-safe mark are SQL and yui-connect, tested
live in supabase/tests/shared_agents_test.py. These need only the plugin
source (and Hermes' toolsets.py for the tool lists).
"""

import asyncio
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_board import AGENT, _adapter_module, _load, PLUGIN  # noqa: E402

sys.path.insert(0, str(AGENT))
sandbox = _load("yui_sandbox", PLUGIN / "yui" / "sandbox.py")

OWNER, CLIENT, AID = "0000aaaa-0000-0000-0000-000000000001", "0000bbbb-0000-0000-0000-000000000002", "a1"
API = {"default": "some-model", "provider": "openrouter", "base_url": "https://openrouter.ai/api/v1"}
SANDBOXED = {"toolsets": ["web", "vision"], "model": API, "memory": {"memory_enabled": False, "user_profile_enabled": False}}


class Report(unittest.TestCase):
    def test_a_sandboxed_profile_passes(self):
        r = sandbox.report(SANDBOXED, "coach", ["OPENROUTER_API_KEY"])
        self.assertEqual(r, {"terminal": "off", "files": "off", "reach": [], "memory": "off", "runner": "api",
                             "profile": "own", "extra_keys": 0})
        self.assertEqual(sandbox.failures(r), [])

    def test_the_default_toolset_is_everything(self):
        r = sandbox.report({"model": API}, "coach")
        f = sandbox.failures(r)
        self.assertIn("terminal: local shell", f)
        self.assertIn("files: the host's files", f)
        self.assertTrue(any(x.startswith("reach: ") and "kanban" in x and "browser" in x for x in f), f)
        self.assertIn("memory: shared between people", f)

    def test_a_container_backend_contains_shell_and_files(self):
        r = sandbox.report({**SANDBOXED, "toolsets": ["terminal", "file"], "terminal": {"backend": "docker"}}, "coach")
        self.assertEqual((r["terminal"], r["files"]), ("container", "sandbox"))
        self.assertEqual(sandbox.failures(r), [])
        r = sandbox.report({**SANDBOXED, "toolsets": ["terminal"], "terminal": {"backend": "ssh"}}, "coach")
        self.assertEqual(r["terminal"], "remote")

    def test_the_yui_platform_toolsets_win(self):
        r = sandbox.report({**SANDBOXED, "toolsets": ["hermes-cli"], "platform_toolsets": {"yui": ["web"]}}, "coach")
        self.assertEqual(sandbox.failures(r), [])

    def test_a_cli_agent_runner_is_not_safe(self):
        cfg = {**SANDBOXED, "model": {"provider": "custom", "base_url": "http://127.0.0.1:8765/v1"}}
        self.assertEqual(sandbox.failures(sandbox.report(cfg, "coach")), ["runner: a local agent with a shell"])

    def test_owner_keys_default_profile_mcp_and_memory(self):
        self.assertIn("keys: 2 in its .env beyond its model key",
                      sandbox.failures(sandbox.report(SANDBOXED, "coach", ["OPENROUTER_API_KEY", "GITHUB_TOKEN", "STRIPE_KEY"])))
        self.assertIn("profile: not its own Hermes profile", sandbox.failures(sandbox.report(SANDBOXED, "default")))
        self.assertIn("reach: mcp servers", sandbox.failures(sandbox.report({**SANDBOXED, "mcp_servers": {"gh": {}}}, "coach")))
        self.assertIn("memory: shared between people",
                      sandbox.failures(sandbox.report({**SANDBOXED, "memory": {}}, "coach")))

    def test_no_report_is_not_safe(self):
        self.assertEqual(sandbox.failures(None), ["no sandbox report from its host yet"])
        self.assertTrue(sandbox.failures({"terminal": "off"}))

    def test_env_keys_are_names_only(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / ".env").write_text("# c\nOPENROUTER_API_KEY=sk-secret\nexport GH=x\n\n")
            self.assertEqual(sandbox.env_keys(Path(d)), ["OPENROUTER_API_KEY", "GH"])


class Event:
    def __init__(self, **kw):
        self.__dict__.update(kw)

    def is_command(self):
        return self.text.lstrip().startswith("/")


class Adapter(unittest.TestCase):
    def make(self, safe=True):
        ad = _adapter_module()
        ad.MessageEvent = Event
        ad.MessageType = type("MT", (), {"TEXT": "text", "PHOTO": "photo"})
        ad.sandbox.current = lambda: sandbox.report(SANDBOXED if safe else {"model": API}, "coach")
        a = ad.YuiAdapter.__new__(ad.YuiAdapter)
        a._user_id, a._remote_ref = OWNER, "coach"
        a._agents = {AID: {"id": AID, "name": "Coach", "handle": "coach", "remote_ref": "coach"}}
        a._all_agents = list(a._agents.values())
        a._notes, a._busy, a._turns, a._last_inbound, a._acks = {AID: ["[yui] note: board"]}, {}, {}, {}, set()
        a._paused_said, a._tasks, a._client = None, [], None
        a.handled, a.written, a.marked, a.beats = [], [], [], []
        a.build_source = lambda **kw: kw

        async def handle(ev):
            a.handled.append(ev)

        async def write(row):
            a.written.append(row)
            return "sent"

        async def mark(ids, col):
            a.marked.append((ids, col))
            return True

        async def notes(*_):
            return ["[yui] note: mention from the owner's thread"]

        async def call(body):
            a.beats.append(body)
            return {}
        a.handle_message, a._write_row, a._mark, a._mention_notes, a._connect_call = handle, write, mark, notes, call
        a._outbox = type("O", (), {"add": lambda *_: None})()
        return ad, a

    def row(self, uid, body="hi", kind="text", rid="r1"):
        return {"id": rid, "user_id": uid, "agent_id": AID, "sender": "user", "body": body, "kind": kind,
                "meta": {}, "created_at": "2026-09-25T01:00:00+00:00"}

    def test_one_session_per_person(self):
        ad, a = self.make()
        self.assertEqual(a._key(self.row(OWNER)), AID)
        self.assertEqual(a._key(self.row(CLIENT)), f"{AID}~{CLIENT}")
        self.assertEqual(a._split(f"{AID}~{CLIENT}"), (AID, CLIENT))
        self.assertEqual(a._split(AID), (AID, OWNER))
        self.assertEqual(a._agent_for(f"{AID}~{CLIENT}"), (f"{AID}~{CLIENT}", None))
        self.assertEqual(a._agent_for("coach"), (AID, None))

    def test_a_client_turn_has_its_own_chat_and_no_owner_notes(self):
        ad, a = self.make()
        asyncio.run(a._dispatch([self.row(CLIENT, "what should I eat")]))
        ev = a.handled[0]
        self.assertEqual(ev.source["chat_id"], f"{AID}~{CLIENT}")
        self.assertEqual(ev.source["user_id"], CLIENT)
        self.assertEqual(ev.text, "what should I eat")  # no board or mention notes from the owner's thread
        self.assertEqual(a._notes[AID], ["[yui] note: board"])

    def test_the_owner_turn_keeps_its_notes(self):
        ad, a = self.make()
        asyncio.run(a._dispatch([self.row(OWNER, "hey")]))
        ev = a.handled[0]
        self.assertEqual(ev.source["chat_id"], AID)
        self.assertTrue(ev.text.startswith("[yui] note: board\n[yui] note: mention"), ev.text)

    def test_a_broken_sandbox_pauses_client_turns_only(self):
        ad, a = self.make(safe=False)

        async def turn():
            await a._dispatch([self.row(CLIENT, "hello?")])
            await asyncio.sleep(0)  # the heartbeat it spawns
        asyncio.run(turn())
        self.assertEqual(a.handled, [])
        to_client = [w for w in a.written if w["user_id"] == CLIENT]
        to_owner = [w for w in a.written if w["user_id"] == OWNER]
        self.assertEqual([w["body"] for w in to_client], [ad.PAUSED_TEXT])
        self.assertEqual(to_client[0]["meta"]["turn"], ["r1"])
        self.assertEqual(len(to_owner), 1)
        self.assertIn("is paused for the people you shared it with", to_owner[0]["body"])
        self.assertIn("terminal: local shell", to_owner[0]["body"])
        self.assertTrue(a.beats and a.beats[0]["action"] == "heartbeat" and a.beats[0]["sandbox"]["coach"]["terminal"] == "local")
        asyncio.run(a._dispatch([self.row(CLIENT, "again?", rid="r2")]))
        self.assertEqual(len([w for w in a.written if w["user_id"] == OWNER]), 1)  # the owner is told once
        asyncio.run(a._dispatch([self.row(OWNER, "me")]))
        self.assertEqual(len(a.handled), 1)  # the owner's own turns still run

    def test_owner_only_taps_from_a_client_are_refused(self):
        ad, a = self.make()
        for body in ("[yui] need-t_123 choose choice=Approve", "[yui] invite-9 choose choice=Approve", "[yui] war tapped"):
            a.written.clear()
            self.assertTrue(asyncio.run(a._owner_only(AID, self.row(CLIENT, body, kind="event"))))
            self.assertEqual([(w["user_id"], w["body"]) for w in a.written], [(CLIENT, "Only the owner can do that.")])
        self.assertFalse(asyncio.run(a._owner_only(AID, self.row(OWNER, "[yui] invite-9 choose", kind="event"))))
        self.assertFalse(asyncio.run(a._owner_only(AID, self.row(CLIENT, "[yui] plan@x submit", kind="event"))))

    def send(self, ad, a, key, body):
        """_insert with the network stubbed: returns (row written, folder each picture went to)."""
        hosted = []
        ad.media.host = lambda token, uid, aid, src: hosted.append(uid) or f"https://x.supabase.co/{uid}/{aid}/agent/p.png"
        ad.media.rewrite = lambda b, hoster, log=None: b.replace("/tmp/p.png", hoster("/tmp/p.png"))
        a._client, a._token = object(), "t"
        a._outbox = type("O", (), {"add": lambda *_: None, "__len__": lambda *_: 0})()
        a._spawn = lambda coro: coro.close()
        ad.SendResult = lambda **kw: kw  # the test harness stubs Hermes' base classes
        asyncio.run(a._insert(key, body))
        return a.written[-1], hosted

    def test_a_clients_picture_goes_to_the_clients_folder(self):
        ad, a = self.make()
        row, hosted = self.send(ad, a, f"{AID}~{CLIENT}", "```yui\nimage /tmp/p.png Your plate\n```")
        self.assertEqual(hosted, [CLIENT])  # YUI-97: the client reads only their own folder
        self.assertEqual(row["user_id"], CLIENT)
        row, hosted = self.send(ad, a, AID, "```yui\nimage /tmp/p.png Mine\n```")
        self.assertEqual(hosted, [OWNER])

    def test_a_clients_own_phone_decides_what_draws(self):
        ad, a = self.make()
        ad.compat.PHONE.update(known=True, build=999, users={CLIENT: 70})
        self.assertEqual(ad.compat.build_for(CLIENT, OWNER), 70)
        self.assertEqual(ad.compat.build_for(OWNER, OWNER), 999)
        self.assertIsNone(ad.compat.build_for("someone-else", OWNER))  # unknown: older than every gated preset
        sketch = "```yui\nsketch Week\nrow Mon\n```"
        row, _ = self.send(ad, a, f"{AID}~{CLIENT}", sketch)
        self.assertNotIn("sketch", row["body"])  # build 70 can't draw a sketch: words instead
        row, _ = self.send(ad, a, AID, sketch)
        self.assertIn("sketch", row["body"])  # the owner's phone can
        ad.compat.seen({"app_build": 120, "app_builds": {CLIENT: 110}})
        self.assertEqual((ad.compat.PHONE["build"], ad.compat.build_for(CLIENT, OWNER)), (120, 110))


if __name__ == "__main__":
    unittest.main(verbosity=2)
