"""Key vault, host side (YUI-34 step 2, yuigui spec/VAULT.md sections 3 and 4).

    python3 -m pytest hermes-plugin/tests/test_vault.py

yui_key_ask writes one control row for the app's own sheet; the person's key_answer
becomes the one `[yui] Key access` line; vault_call posts the connector with the
agent's own token. Nothing leaves the machine: urlopen and the row sender are
stand-ins, and every key here is key-shaped, not real.
"""
import asyncio
import io
import json
import os
import sys
import tempfile
import time
import types
import unittest
import urllib.error
from pathlib import Path

HOME = Path(tempfile.mkdtemp(prefix="yui-vault-"))
os.environ["HERMES_HOME"] = str(HOME)
os.environ["YUI_CONNECTOR_FILE"] = str(HOME / "connector.json")
os.environ.pop("YUI_VAULT_BASE", None)

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "yui"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import connector  # noqa: E402
import controls  # noqa: E402
import talk  # noqa: E402
import vault  # noqa: E402

FAL_KEY = "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0:" + "ab12" * 8  # shape of a fal key, not one
CT = "yui_ct_" + "Z" * 24


def fresh(owner=True, age=0):
    import shutil
    for p in HOME.iterdir():
        if p.name != "connector.json":
            shutil.rmtree(p) if p.is_dir() else p.unlink()
    connector.save({"token": CT})
    t = talk.Talk(controls.Host(HOME))
    t.turn(agent="a1", user="owner-uid", key="a1", owner=owner, owner_user="owner-uid")
    if age:
        with t._state() as st:
            st["turn"]["at"] -= age


class Sender:
    def __init__(self):
        self.rows = []

    def __call__(self, agent, user, meta):
        self.rows.append((agent, user, meta))
        return "row-1"


class Ask(unittest.TestCase):
    def setUp(self):
        fresh()
        self.send = Sender()

    def ask(self, provider="fal", for_="Draw your agent avatars", **kw):
        return vault.ask(provider, for_, send=self.send, **kw)

    def test_the_row_is_exactly_the_spec_payload(self):
        r = self.ask(est="about 4 images a week", cap=5)
        self.assertTrue(r["ok"], r)
        agent, user, meta = self.send.rows[0]
        self.assertEqual((agent, user), ("a1", "owner-uid"))
        self.assertEqual(meta, {"v": 1, "req": r["req"], "op": "key_ask", "provider": "fal",
                                "for": "Draw your agent avatars", "est": "about 4 images a week", "cap": 5})
        self.assertRegex(r["req"], r"^k-[0-9a-f]{4}$")

    def test_est_and_cap_are_optional(self):
        self.assertTrue(self.ask()["ok"])
        self.assertEqual(set(self.send.rows[0][2]), {"v", "req", "op", "provider", "for"})

    def test_every_provider_of_the_six_but_openrouter(self):
        for i, p in enumerate(vault.PROVIDERS):
            fresh()
            self.assertTrue(vault.ask(p, "x", send=self.send)["ok"], p)
        for bad in ("openrouter", "google", "", None):
            fresh()
            r = vault.ask(bad, "x", send=self.send)
            self.assertFalse(r["ok"], bad)
            self.assertIn("provider is one of", r["message"])

    def test_for_is_one_line_of_80_at_most(self):
        self.assertTrue(self.ask(for_="x" * 80)["ok"])
        fresh()
        self.assertFalse(self.ask(for_="x" * 81)["ok"])
        self.assertFalse(self.ask(for_="   ")["ok"])
        self.assertFalse(self.ask(for_="")["ok"])
        fresh()
        self.assertTrue(self.ask(for_="two\nlines here")["ok"])
        self.assertEqual(self.send.rows[-1][2]["for"], "two lines here")

    def test_key_shaped_text_is_refused_in_every_field(self):
        shapes = ["sk-ant-api03-" + "Q" * 30, "sk-" + "a" * 32, "r8_" + "B" * 30, "sk-or-v1-" + "c" * 30, FAL_KEY,
                  "yui_ct_" + "Z" * 20, "api_key=abcdefabcdef1234"]
        for s in shapes:
            for field in ("for_", "est"):
                fresh()
                kw = {field: f"use {s} please"}
                r = self.ask(**kw)
                self.assertFalse(r["ok"], (field, s))
                self.assertIn("looks like it holds a key", r["message"])
        self.assertEqual(self.send.rows, [], "nothing was sent")

    def test_cap_is_a_whole_dollar_amount(self):
        for bad in (0, -1, 1001, "lots", 2.5, True):
            fresh()
            self.assertFalse(self.ask(cap=bad)["ok"], bad)
        fresh()
        self.assertTrue(self.ask(cap="5")["ok"])
        self.assertEqual(self.send.rows[-1][2]["cap"], 5)

    def test_only_the_owners_recent_turn_may_ask(self):
        fresh(owner=False)
        r = self.ask()
        self.assertFalse(r["ok"])
        self.assertIn("Only the owner", r["message"])
        fresh(age=3 * 3600)
        self.assertFalse(self.ask()["ok"])
        fresh()
        self.assertFalse(vault.ask("fal", "x", chat="a1~someone:c1", send=self.send)["ok"], "a shared thread")
        self.assertEqual(self.send.rows, [])

    def test_one_open_ask_per_provider(self):
        self.assertTrue(self.ask()["ok"])
        r = self.ask()
        self.assertFalse(r["ok"])
        self.assertIn("still waiting", r["message"])
        self.assertTrue(self.ask("replicate")["ok"], "another provider is its own ask")
        self.assertEqual(len(self.send.rows), 2)

    def test_a_send_that_fails_leaves_no_open_ask(self):
        def boom(*a):
            raise OSError("down")
        r = vault.ask("fal", "x", send=boom)
        self.assertFalse(r["ok"])
        self.assertIn("Couldn't reach Yui", r["message"])
        self.assertTrue(self.ask()["ok"], "the agent can try again")

    def test_a_decline_blocks_a_repeat_for_24_hours(self):
        r = self.ask()
        vault.take({"req": r["req"], "decision": "deny", "provider": "fal", "handle": None, "cap": None})
        again = self.ask()
        self.assertFalse(again["ok"])
        self.assertEqual(again["error"], "declined_today")
        self.assertEqual(again["message"], "[yui] Key access: fal was declined today. Ask again tomorrow, or let them bring it up.")
        self.assertTrue(self.ask("openai")["ok"], "only that provider")
        sp = vault.state_path()
        st = json.loads(sp.read_text())
        st["declined"]["fal"] -= 25 * 3600
        sp.write_text(json.dumps(st))
        self.assertTrue(self.ask()["ok"], "a day later")
        self.assertEqual(len(self.send.rows), 3)

    def test_state_file_is_private_and_holds_no_key(self):
        self.ask()
        p = vault.state_path()
        self.assertEqual(oct(p.stat().st_mode & 0o777), "0o600")
        self.assertNotIn("sk-", p.read_text())


class Answer(unittest.TestCase):
    def setUp(self):
        fresh()

    def row(self, **meta):
        m = {"v": 1, "req": "k-19c4", "op": "key_answer", "decision": "allow", "provider": "fal",
             "handle": "vk_fal_3f9a", "cap": 5}
        m.update(meta)
        return {"id": "r1", "user_id": "owner-uid", "agent_id": "a1", "sender": "user", "kind": "control",
                "body": "key", "meta": {k: v for k, v in m.items() if v is not ...}}

    def test_allow_line_is_the_specs(self):
        vault.ask("fal", "Draw your agent avatars", send=Sender())
        ans = vault.answer_of(self.row(req=next(iter(json.loads(vault.state_path().read_text())["asks"]))))
        self.assertEqual(vault.take(ans), '[yui] Key access: fal allowed for "Draw your agent avatars", cap $5 a month, handle vk_fal_3f9a.')

    def test_once_deny_and_a_fractional_cap(self):
        a = vault.answer_of(self.row(decision="once"))
        self.assertEqual(vault.answer_line(a, "logos"), '[yui] Key access: fal allowed once for "logos", one call, handle vk_fal_3f9a.')
        d = vault.answer_of(self.row(decision="deny", handle=...))
        self.assertEqual(vault.answer_line(d), "[yui] Key access: fal not allowed.")
        self.assertEqual(vault.answer_line(vault.answer_of(self.row(cap=7.5))), '[yui] Key access: fal allowed, cap $7.50 a month, handle vk_fal_3f9a.')
        self.assertEqual(vault.answer_line(vault.answer_of(self.row(cap=None))), "[yui] Key access: fal allowed, handle vk_fal_3f9a.")

    def test_malformed_answers_are_not_answers(self):
        for bad in (dict(decision="maybe"), dict(provider="openrouter"), dict(handle="vk_fal_zzzz"), dict(handle=...),
                    dict(handle="vk_openai_3f9a"), dict(req="x"), dict(v=2), dict(cap=-1), dict(cap="5")):
            self.assertIsNone(vault.answer_of(self.row(**bad)), bad)
        self.assertIsNone(vault.answer_of({**self.row(), "sender": "agent"}), "an agent cannot answer itself")
        self.assertIsNone(vault.answer_of({**self.row(), "kind": "text"}))
        self.assertIsNone(vault.answer_of({**self.row(), "meta": {"op": "list"}}))

    def test_a_handle_is_not_a_key(self):
        self.assertFalse(vault.keyish("vk_fal_3f9a"))

    def test_deny_starts_the_no_nag_and_allow_clears_it(self):
        vault.take(vault.answer_of(self.row(decision="deny", handle=...)))
        self.assertIn("fal", json.loads(vault.state_path().read_text())["declined"])
        vault.take(vault.answer_of(self.row()))
        self.assertNotIn("fal", json.loads(vault.state_path().read_text())["declined"])


class Gateway(unittest.TestCase):
    """The adapter takes the answer with no turn and hands the agent the line."""

    @classmethod
    def setUpClass(cls):
        from test_board import _adapter_module
        cls.ad = _adapter_module()

    def make(self):
        a = self.ad.YuiAdapter.__new__(self.ad.YuiAdapter)
        a._remote_ref, a._user_id, a._acks, a._notes = "yui", "owner-uid", set(), {}
        a.marked = []

        async def mark(ids, column):
            a.marked.append((tuple(ids), column))
            return True
        a._mark = mark
        return a

    def answer(self, user="owner-uid", **meta):
        return {"id": "r9", "user_id": user, "agent_id": "a1", "sender": "user", "kind": "control", "body": "k",
                "meta": {"v": 1, "req": "k-19c4", "op": "key_answer", "decision": "allow", "provider": "fal",
                         "handle": "vk_fal_3f9a", "cap": 5, **meta}}

    def test_owner_answer_becomes_a_note_and_no_turn(self):
        fresh()
        a = self.make()
        self.assertTrue(asyncio.run(a._key_answer("a1", self.answer())))
        self.assertEqual(a._notes["a1"], ["[yui] Key access: fal allowed, cap $5 a month, handle vk_fal_3f9a."])
        self.assertEqual(a._acks, {"r9"})
        self.assertIn((("r9",), "delivered_at"), a.marked)

    def test_someone_elses_answer_is_dropped(self):
        fresh()
        a = self.make()
        self.assertTrue(asyncio.run(a._key_answer("a1~other", self.answer(user="other"))))
        self.assertEqual(a._notes, {})
        self.assertEqual(a._acks, {"r9"})

    def test_other_rows_fall_through(self):
        a = self.make()
        row = {**self.answer(), "meta": {"op": "list", "section": "soul"}}
        self.assertFalse(asyncio.run(a._key_answer("a1", row)))
        self.assertFalse(asyncio.run(a._key_answer("a1", {**self.answer(), "kind": "text"})))

    def test_tools_are_registered(self):
        seen = {}
        ctx = types.SimpleNamespace(register_platform=lambda **k: None, register_hook=lambda *a: None,
                                    register_tool=lambda **k: seen.setdefault(k["name"], k),
                                    register_command=lambda *a, **k: None, register_cli_command=lambda **k: None)
        self.ad.register(ctx)
        self.assertIn("yui_key_ask", seen)
        self.assertIn("vault_call", seen)
        self.assertEqual(seen["vault_call"]["schema"]["parameters"]["required"], ["handle", "path"])


class Fake:
    def __init__(self, status=200, body=None, ctype="application/json", raw=None):
        self.status, self.body, self.ctype, self.raw, self.sent = status, body, ctype, raw, []

    def __call__(self, req, timeout=None):
        self.sent.append({"url": req.full_url, "method": req.get_method(),
                          "headers": {k.lower(): v for k, v in req.header_items()}, "data": req.data})
        raw = self.raw if self.raw is not None else json.dumps(self.body if self.body is not None else {}).encode()
        if self.status >= 400:
            raise urllib.error.HTTPError(req.full_url, self.status, "x", {}, io.BytesIO(raw))
        outer = self

        class R:
            status = outer.status
            headers = {"content-type": outer.ctype}
            def read(self): return raw
            def __enter__(self): return self
            def __exit__(self, *a): return False
        return R()


class Call(unittest.TestCase):
    def setUp(self):
        fresh()

    def test_posts_the_connector_route_with_the_agents_own_token(self):
        f = Fake(body={"images": [{"url": "https://cdn/x.png"}]})
        r = vault.result("vk_fal_3f9a", "fal-ai/flux/dev", {"prompt": "a rabbit"}, opener=f)
        self.assertEqual(r, {"ok": True, "status": 200, "body": {"images": [{"url": "https://cdn/x.png"}]}})
        s = f.sent[0]
        self.assertEqual(s["method"], "POST")
        self.assertEqual(s["url"], f"{connector.SUPABASE_URL}/functions/v1/yui-vault/vault/v1/vk_fal_3f9a/fal-ai/flux/dev")
        self.assertEqual(s["headers"]["authorization"], f"Bearer {CT}")
        self.assertEqual(json.loads(s["data"]), {"prompt": "a rabbit"})

    def test_the_request_never_carries_a_provider_key(self):
        f = Fake(body={})
        vault.result("vk_fal_3f9a", "fal-ai/flux/dev", {"prompt": "x"}, opener=f)
        blob = json.dumps(f.sent[0]["headers"]) + f.sent[0]["url"]
        self.assertNotIn("Bearer sk", blob)
        self.assertEqual(set(f.sent[0]["headers"]) - {"content-type", "apikey", "user-agent", "authorization"}, set())

    def test_base_url_can_be_overridden(self):
        os.environ["YUI_VAULT_BASE"] = "http://127.0.0.1:9/"
        try:
            f = Fake()
            vault.result("vk_fal_3f9a", "a/b", {}, opener=f)
            self.assertEqual(f.sent[0]["url"], "http://127.0.0.1:9/vault/v1/vk_fal_3f9a/a/b")
        finally:
            os.environ.pop("YUI_VAULT_BASE")

    def test_each_refusal_says_what_to_do(self):
        for code, status, word in (("not_granted", 403, "yui_key_ask"), ("cap_reached", 402, "1st"),
                                   ("path_not_allowed", 403, "fix the path"), ("key_rejected", 402, "Settings > Keys"),
                                   ("once_used", 403, "Ask again")):
            r = vault.result("vk_fal_3f9a", "p", {}, opener=Fake(status, {"error": code}))
            self.assertFalse(r["ok"])
            self.assertEqual(r["error"], code)
            self.assertIn(word, r["say"])

    def test_unknown_error_and_unreachable(self):
        r = vault.result("vk_fal_3f9a", "p", {}, opener=Fake(500, {"error": "boom"}))
        self.assertIn("500", r["say"])
        def down(req, timeout=None):
            raise urllib.error.URLError("no route to sk-ant-api03-" + "Q" * 30)
        r = vault.result("vk_fal_3f9a", "p", {}, opener=down)
        self.assertEqual(r["error"], "unreachable")
        self.assertNotIn("sk-ant", json.dumps(r))

    def test_bad_handle_and_bad_paths_never_call(self):
        f = Fake()
        for h in ("sk-ant-api03-" + "Q" * 30, "vk_fal", "vk_fal_3f9a/../x", "", None, "vk_FAL_3f9a"):
            self.assertEqual(vault.result(h, "p", {}, opener=f)["error"], "refused", h)
        for p in ("", "https://evil.example/x", "//evil.example/x", "../x", "a/../b", "a b", "a%2e%2e/b", "a@evil/x",
                  "a\\b", "a#b", "x" * 400):
            self.assertEqual(vault.result("vk_fal_3f9a", p, {}, opener=f).get("error"), "refused", repr(p))
        self.assertEqual(f.sent, [], "no call was made")

    def test_leading_slash_and_query_are_fine(self):
        f = Fake()
        self.assertTrue(vault.result("vk_replicate_00ab", "/v1/predictions?wait=1", {}, opener=f)["ok"])
        self.assertTrue(f.sent[0]["url"].endswith("/vault/v1/vk_replicate_00ab/v1/predictions?wait=1"))

    def test_unpaired_machine_never_calls(self):
        connector.save({})
        f = Fake()
        r = vault.result("vk_fal_3f9a", "p", {}, opener=f)
        self.assertEqual(r["message"], "This machine is not paired with Yui.")
        self.assertEqual(f.sent, [])

    def test_a_key_in_the_answer_is_scrubbed(self):
        leak = "sk-ant-api03-" + "Q" * 40
        r = vault.result("vk_fal_3f9a", "p", {}, opener=Fake(body={"echo": leak, "ok": 1}))
        self.assertTrue(r["ok"])
        self.assertNotIn(leak, json.dumps(r))
        self.assertEqual(r["body"]["ok"], 1, "the rest of the answer survives")
        r = vault.result("vk_fal_3f9a", "p", {}, opener=Fake(ctype="text/plain", raw=("here " + leak).encode()))
        self.assertNotIn(leak, json.dumps(r))

    def test_binary_answers_go_to_a_private_file(self):
        r = vault.result("vk_elevenlabs_0abc", "v1/text-to-speech/x", {"text": "hi"},
                         opener=Fake(ctype="audio/mpeg", raw=b"\xff\xfb\x90\x00" * 100))
        self.assertTrue(r["ok"])
        self.assertEqual(r["bytes"], 400)
        self.assertEqual(oct(Path(r["file"]).stat().st_mode & 0o777), "0o600")
        self.assertNotIn("body", r)

    def test_tool_handlers_return_json(self):
        self.assertFalse(json.loads(vault.call_handler({"handle": "nope", "path": "p"}))["ok"])
        out = json.loads(vault.tool_handler({"provider": "fal", "for": "x " + FAL_KEY}))
        self.assertEqual(out["error"], "refused")
        self.assertNotIn(FAL_KEY, json.dumps(out))


if __name__ == "__main__":
    unittest.main()
