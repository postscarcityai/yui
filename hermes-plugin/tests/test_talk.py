"""Talk about this (YUI-69, spec yuigui spec/TALK-ABOUT.md): the attach line
is expanded with the redacted item for the owner only, once per rev; the
agent's proposals are checked with the Controls rules, drawn from the host's
file, and applied or kept by a tap with no agent turn.

    ~/.hermes/hermes-agent/venv/bin/python hermes-plugin/tests/test_talk.py

Every test runs on a fresh temp profile home (test_controls sets HERMES_HOME
before hermes-agent is imported), never a real profile, and nothing is sent:
the sender is a stand-in that keeps the rows.
"""

import asyncio
import json
import re
import shutil
import sys
import types
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_controls as tc  # noqa: E402  (sets HERMES_HOME to a temp home first)
from test_board import _adapter_module, PLUGIN  # noqa: E402

HOME, KEY, cron, hconfig = tc.HOME, tc.KEY, tc.cron, tc.hconfig
ad = _adapter_module()
talk, controls = ad.talk, ad.controls
KEYISH = re.compile(r"sk-ant-api03-Q{10}|A{35}")
OWNER, CLIENT = "owner-uid", "client-uid"


class Base(unittest.TestCase):
    def setUp(self):
        tc.fresh_home()
        self.host = controls.Host(HOME, cron=cron, config=hconfig)
        self.t = talk.Talk(self.host)
        self.sent = []
        self.t.turn(agent="a1", user=OWNER, key="a1", owner=True, owner_user=OWNER)

    def send(self, agent, user, body):
        self.sent.append((agent, user, body))
        return f"m{len(self.sent)}"

    def get(self, section, iid):
        ans, _ = self.host.handle({"v": 1, "op": "get", "section": section, "id": iid}, owner=True)
        self.assertTrue(ans["ok"], ans)
        return ans

    def propose(self, section, iid, rev=None, **kw):
        rev = rev or self.get(section, iid)["rev"]
        kw.setdefault("why", "Quieter while you work.")
        return self.t.propose(section, iid, rev, send=self.send, **kw)

    def log(self):
        p = HOME / "yui" / "controls.log"
        return [json.loads(ln) for ln in p.read_text().splitlines()] if p.exists() else []

    def trash(self):
        d = HOME / "yui" / "controls-trash"
        return sorted(p.name for p in d.iterdir()) if d.exists() else []

    def tap(self, pid, choice):
        return self.t.take({"kind": "choose", "pid": pid, "choice": choice}, who=OWNER, agent="a1")


class Attach(Base):
    def test_read_attach_matches_the_reference(self):
        self.assertEqual(talk.read_attach("[yui] attach section=soul id=SOUL.md rev=b41c09\nhi"),
                         {"section": "soul", "id": "SOUL.md", "rev": "b41c09", "words": "hi"})
        for bad in ("[yui] attach section=soul id=../x rev=b\nhi", "[yui] attach section=soul id=SOUL.md rev=\nhi",
                    "[yui] attach section=soul id=SOUL.md rev=b readonly=no\nhi", "hi"):
            self.assertIsNone(talk.read_attach(bad), bad)
        # The vectors the app and yl.mjs pass (yuigui spec/conformance/33-attach.json, copied into the app).
        vec = PLUGIN.parent / "Packages/YuiLines/Tests/YuiLinesTests/Resources/conformance/33-attach.json"
        for v in json.loads(vec.read_text())["vectors"]:
            a, read = v["attach"], talk.read_attach(v["attach"]["body"])
            self.assertEqual(read, None if a["body"] == a["words"] else {**a["item"], "words": a["words"]}, v["name"])

    def test_owner_gets_the_item_once_per_rev(self):
        rev = self.get("soul", "SOUL.md")["rev"]
        msg = talk.attach_body("soul", "SOUL.md", rev, "Less playful.")
        first = self.t.expand(msg, key="a1", owner=True, profile="scout")
        self.assertTrue(first.startswith(f"[yui] attach section=soul id=SOUL.md rev={rev} readonly=no\n--- SOUL.md (current) ---\n# Scout"))
        self.assertIn("hermes -p scout yui propose --section soul --id SOUL.md --rev", first)
        self.assertTrue(first.endswith("\nLess playful."))
        again = self.t.expand(msg, key="a1", owner=True)
        self.assertEqual(again, f"[yui] attach section=soul id=SOUL.md rev={rev} readonly=no\nLess playful.")
        (HOME / "SOUL.md").write_text("# Scout\n\nCalm.\n")  # changed on the host: the new text again
        third = self.t.expand(msg, key="a1", owner=True)
        self.assertIn("Calm.", third)
        self.assertIn(f"rev={self.get('soul', 'SOUL.md')['rev']} ", third)
        # Another thread has not read it yet.
        self.assertIn("--- SOUL.md (current) ---", self.t.expand(msg, key="a2", owner=True))

    def test_redacted_item_is_read_only_and_hides_the_key(self):
        items = {i["title"]: i for i in self.host.handle({"v": 1, "op": "list", "section": "memory"}, owner=True)[0]["items"]}
        secret = next(i for i in items.values() if i["read_only"])
        out = self.t.expand(talk.attach_body("memory", secret["id"], secret["rev"], "Change the key."), key="a1", owner=True)
        self.assertIn("readonly=yes", out)
        self.assertIn(controls.HIDDEN, out)
        self.assertNotRegex(out, KEYISH)
        self.assertIn("Read only", out)
        self.assertNotIn("yui propose", out)

    def test_model_card_is_read_only(self):
        rev = self.get("model", "model")["rev"]
        out = self.t.expand(talk.attach_body("model", "model", rev, "Why this one?"), key="a1", owner=True)
        self.assertIn("readonly=yes", out)
        self.assertIn("model: claude-opus-5-5", out)
        self.assertNotRegex(out, KEYISH)

    def test_anyone_but_the_owner_gets_the_words_only(self):
        rev = self.get("soul", "SOUL.md")["rev"]
        out = self.t.expand(talk.attach_body("soul", "SOUL.md", rev, "What does it say?"), key="a1~c", owner=False)
        self.assertEqual(out, "What does it say?")

    def test_an_item_gone_from_the_host(self):
        out = self.t.expand("[yui] attach section=memory id=mem-0000000000 rev=abc\nForget it.", key="a1", owner=True)
        self.assertIn("missing=yes", out)
        self.assertTrue(out.endswith("Forget it."))


class Propose(Base):
    def test_put_draws_before_and_after_from_the_host_file(self):
        new = "# Scout\n\nCalm and brief while you work.\n\n## Voice\n\nShort sentences.\n"
        out = self.propose("soul", "SOUL.md", value={"text": new})
        self.assertTrue(out["ok"], out)
        self.assertEqual(out["id"], "p-1")
        agent, user, body = self.sent[0]
        self.assertEqual((agent, user), ("a1", OWNER))
        self.assertTrue(body.startswith("Quieter while you work.\n\n```yui\nsketch \"SOUL.md\" frame=window before=Now +inline\n"))
        self.assertIn('row "Warm and quick." +x note="removed"', body)
        self.assertIn('after Proposed', body)
        self.assertIn('row "Calm and brief while you work." +hi note="new"', body)
        self.assertIn('choose@prop-p-1 "Apply this change?" Apply|"Keep it as is" +inline', body)
        self.assertEqual((HOME / "SOUL.md").read_text(), tc.SOUL)  # nothing written yet
        # The picture parses as YL: one sketch with an after, then the choose.
        self.assertEqual(body.count("```"), 2)
        # Apply: the write, its trash copy, the log line.
        res = self.tap("p-1", "Apply")
        self.assertEqual((HOME / "SOUL.md").read_text(), new)
        self.assertEqual(res["applied"], {"section": "soul", "id": "SOUL.md"})
        self.assertIn('card "Personality updated" "Quieter while you work." tag=Applied', res["reply"])
        self.assertEqual(res["note"], "[yui] Applied in Controls: SOUL.md updated (your proposal p-1).")
        self.assertTrue(any(n.endswith("-soul-SOUL.md") for n in self.trash()))
        self.assertEqual(tc.SOUL, (HOME / "yui" / "controls-trash" / self.trash()[0]).read_text())
        line = self.log()[-1]
        self.assertEqual((line["via"], line["proposal"], line["op"], line["section"], line["who"]),
                         ("talk", "p-1", "put", "soul", OWNER))
        self.assertEqual(self.tap("p-1", "Apply"), {"reply": None, "note": None})  # a second tap does nothing

    def test_long_file_folds_unchanged_lines(self):
        long = "# Scout\n" + "".join(f"Line {i}.\n" for i in range(30))
        (HOME / "SOUL.md").write_text(long)
        out = self.propose("soul", "SOUL.md", value={"text": long.replace("Line 15.", "Line fifteen.")})
        body = self.sent[0][2]
        self.assertTrue(out["ok"])
        self.assertIn('row "15 lines unchanged" +dim', body)
        self.assertIn('row "Line 14." +dim', body)
        self.assertIn('row "Line 15." +x note="removed"', body)
        self.assertIn('row "Line fifteen." +hi note="new"', body)
        self.assertLess(body.count("\nrow "), 12)

    def test_act_pauses_a_schedule(self):
        if cron is None:
            self.skipTest("hermes-agent not importable")
        job = cron.create_job(prompt="Morning brief", schedule="0 8 * * 1-5", name="Morning brief")
        out = self.propose("schedules", job["id"], verb="pause", why="You do it yourself now.")
        self.assertTrue(out["ok"], out)
        body = self.sent[0][2]
        self.assertIn('row "Morning brief: runs weekdays 8:00"', body)
        self.assertIn('row "Morning brief: paused" +hi', body)
        self.assertIn(f'choose@prop-{out["id"]} "Pause?" "Pause"|"Keep it as is" +inline', body)
        self.assertNotEqual(cron.get_job(job["id"]).get("state"), "paused")
        self.tap(out["id"], "Pause")
        self.assertEqual(cron.get_job(job["id"]).get("state"), "paused")
        self.assertEqual(self.log()[-1]["via"], "talk")

    def test_schedule_new_time(self):
        if cron is None:
            self.skipTest("hermes-agent not importable")
        job = cron.create_job(prompt="Morning brief", schedule="0 8 * * 1-5", name="Morning brief")
        out = self.propose("schedules", job["id"], value={"schedule": "30 7 * * 1-5"}, why="7:30 on weekdays.")
        self.assertTrue(out["ok"], out)
        body = self.sent[0][2]
        self.assertIn('row "Morning brief: weekdays 8:00" +x', body)
        self.assertIn('row "Morning brief: weekdays 7:30" +hi note="new time"', body)
        self.tap(out["id"], "Apply")
        self.assertEqual(cron.get_job(job["id"])["schedule_display"], "30 7 * * 1-5")

    def test_delete_forgets_a_memory(self):
        mem = next(i for i in self.host.handle({"v": 1, "op": "list", "section": "memory"}, owner=True)[0]["items"]
                   if i["title"].startswith("Deploys"))
        out = self.propose("memory", mem["id"], delete=True, why="Out of date.")
        self.assertTrue(out["ok"], out)
        body = self.sent[0][2]
        self.assertIn('choose@prop-p-1 "Forget this? It won\'t be remembered next time." Forget|"Keep it" +inline', body)
        self.assertIn('+x note="forgotten"', body)
        res = self.tap("p-1", "Forget")
        self.assertIn('card "Memory forgotten"', res["reply"])
        self.assertNotIn("Deploys", (HOME / "memories" / "MEMORY.md").read_text())
        self.assertEqual((self.log()[-1]["op"], self.log()[-1]["via"]), ("delete", "talk"))

    def test_keep_writes_nothing(self):
        out = self.propose("soul", "SOUL.md", value={"text": "# Scout\n\nCalm.\n"})
        res = self.tap(out["id"], "Keep it as is")
        self.assertEqual(res, {"reply": None, "note": f"[yui] Proposal {out['id']} kept as is."})
        self.assertEqual((HOME / "SOUL.md").read_text(), tc.SOUL)
        self.assertEqual(self.log(), [])
        # Answers can change: Apply after Keep still applies.
        self.tap(out["id"], "Apply")
        self.assertEqual((HOME / "SOUL.md").read_text(), "# Scout\n\nCalm.\n")

    def test_stale_rev_at_apply_gets_the_conflict_card_and_ask_again(self):
        out = self.propose("soul", "SOUL.md", value={"text": "# Scout\n\nCalm.\n"})
        (HOME / "SOUL.md").write_text("# Scout\n\nEdited in a terminal.\n")  # mid-proposal
        res = self.tap(out["id"], "Apply")
        self.assertEqual((HOME / "SOUL.md").read_text(), "# Scout\n\nEdited in a terminal.\n")
        self.assertIn('card@again-p-1 "SOUL.md changed on your Mac since this was proposed"', res["reply"])
        self.assertIn('cta="Ask again"', res["reply"])
        self.assertNotIn("applied", res)
        again = self.t.again("p-1")
        self.assertEqual(again, talk.attach_body("soul", "SOUL.md", self.get("soul", "SOUL.md")["rev"],
                                                 "Propose that again against the current file."))
        self.assertEqual(talk.Talk.tap_of({"kind": "event", "meta": {"id": "again-p-1", "preset": "card",
                                                                     "value": {"cta": "Ask again"}}}),
                         {"kind": "again", "pid": "p-1"})

    def test_stale_rev_at_propose_is_refused(self):
        out = self.propose("soul", "SOUL.md", rev="000000000000", value={"text": "# Scout\n"})
        self.assertFalse(out["ok"])
        self.assertIn("changed on the host", out["message"])
        self.assertEqual(self.sent, [])

    def test_read_only_item_refused(self):
        secret = next(i for i in self.host.handle({"v": 1, "op": "list", "section": "memory"}, owner=True)[0]["items"]
                      if i["read_only"])
        out = self.propose("memory", secret["id"], value={"text": "His test key: " + controls.HIDDEN})
        self.assertFalse(out["ok"])
        self.assertEqual(out["message"], controls.MESSAGES["read_only"])
        out = self.propose("memory", secret["id"], delete=True)
        self.assertFalse(out["ok"])
        self.assertEqual(self.sent, [])

    def test_key_shaped_value_refused(self):
        out = self.propose("soul", "SOUL.md", value={"text": f"# Scout\n\nkey: {KEY}\n"})
        self.assertFalse(out["ok"])
        self.assertIn("looks like it holds a key", out["message"])
        out = self.propose("soul", "SOUL.md", value={"text": "# Scout\n"}, why=f"Use {KEY}")
        self.assertFalse(out["ok"])
        self.assertEqual(self.sent, [])

    def test_grantee_refused(self):
        self.t.turn(agent="a1", user=CLIENT, key="a1~" + CLIENT, owner=False, owner_user=OWNER)
        out = self.propose("soul", "SOUL.md", value={"text": "# Scout\n"})
        self.assertFalse(out["ok"])
        self.assertIn("Only the owner", out["message"])
        # The tool knows its session: a shared thread's chat id refuses even after an owner turn.
        self.t.turn(agent="a1", user=OWNER, key="a1", owner=True, owner_user=OWNER)
        out = self.t.propose("soul", "SOUL.md", self.get("soul", "SOUL.md")["rev"], value={"text": "# S\n"},
                             chat="a1~" + CLIENT, send=self.send)
        self.assertFalse(out["ok"])
        self.assertEqual(self.sent, [])

    def test_controls_rules_apply(self):
        out = self.propose("soul", "SOUL.md", value={"text": "   "})
        self.assertEqual((out["ok"], out["message"]), (False, controls.MESSAGES["empty"]))
        out = self.propose("skills", "tan-studio", value={"text": "no frontmatter"})
        self.assertEqual(out["message"], controls.MESSAGES["no_frontmatter"])
        out = self.propose("skills", "apple-notes", delete=True)
        self.assertEqual(out["message"], controls.MESSAGES["bundled"])
        out = self.propose("soul", "SOUL.md", value={"text": "x" * (33 * 1024)})
        self.assertEqual(out["message"], controls.MESSAGES["too_big"])
        out = self.propose("model", "model", rev="abc", value={"text": "gpt"})
        self.assertFalse(out["ok"])
        out = self.propose("soul", "SOUL.md", value={"text": "a"}, verb="pause")
        self.assertIn("exactly one", out["message"])
        self.assertEqual(self.sent, [])

    def test_a_newer_proposal_replaces_the_older(self):
        a = self.propose("soul", "SOUL.md", value={"text": "# Scout\n\nOne.\n"})
        b = self.propose("soul", "SOUL.md", value={"text": "# Scout\n\nTwo.\n"})
        self.assertEqual(self.tap(a["id"], "Apply")["reply"], "Replaced by a newer proposal.")
        self.assertEqual((HOME / "SOUL.md").read_text(), tc.SOUL)
        self.tap(b["id"], "Apply")
        self.assertIn("Two.", (HOME / "SOUL.md").read_text())

    def test_nothing_key_shaped_is_drawn(self):
        """Secrets: a token-shaped memory entry, attached and asked about. The turn shows the
        placeholder, the proposal is refused, and no sent row carries anything key-shaped."""
        secret = next(i for i in self.host.handle({"v": 1, "op": "list", "section": "memory"}, owner=True)[0]["items"]
                      if i["read_only"])
        turn = self.t.expand(talk.attach_body("memory", secret["id"], secret["rev"], "Rotate it."), key="a1", owner=True)
        self.assertIn(controls.HIDDEN, turn)
        self.assertFalse(self.propose("memory", secret["id"], value={"text": f"His test key: {KEY[:-1]}Z"})["ok"])
        self.propose("soul", "SOUL.md", value={"text": "# Scout\n\nCalm.\n"})
        for _, _, body in self.sent:
            self.assertNotRegex(body, KEYISH)
        self.assertNotRegex((HOME / "yui" / "talk.json").read_text(), KEYISH)


class AdapterPath(Base):
    """The adapter takes the taps with no turn, owner only, and expands the line in the turn."""

    def make(self, user_id=OWNER):
        a = ad.YuiAdapter.__new__(ad.YuiAdapter)
        a._remote_ref, a._user_id, a._notes, a._acks = "scout", user_id, {}, set()
        a._controls, a._talk = self.host, self.t
        a.marked, a.written = [], []

        async def mark(ids, column):
            a.marked.append((tuple(ids), column))
            return True

        async def write(row):
            a.written.append(row)
            return "sent"
        a._mark, a._write_row = mark, write
        return a

    def event(self, eid, preset, value, user_id=OWNER):
        return {"id": "row-9", "kind": "event", "sender": "user", "user_id": user_id, "agent_id": "a1",
                "body": f"[yui] {eid} {preset}", "meta": {"id": eid, "preset": preset, "value": value}}

    def test_apply_tap_writes_with_no_turn(self):
        out = self.propose("soul", "SOUL.md", value={"text": "# Scout\n\nCalm.\n"})
        a = self.make()
        self.assertTrue(asyncio.run(a._talk_tap("a1", self.event(f"prop-{out['id']}", "choose", {"choice": "Apply"}))))
        self.assertIn("Calm.", (HOME / "SOUL.md").read_text())
        reply = a.written[0]
        self.assertEqual(reply["meta"]["talk"], {"applied": {"section": "soul", "id": "SOUL.md"}})
        self.assertEqual(reply["meta"]["turn"], ["row-9"])
        self.assertIn("tag=Applied", reply["body"])
        self.assertEqual(a._notes["a1"], ["[yui] Applied in Controls: SOUL.md updated (your proposal p-1)."])
        self.assertIn("row-9", a._acks)

    def test_keep_tap_acks_quietly(self):
        out = self.propose("soul", "SOUL.md", value={"text": "# Scout\n\nCalm.\n"})
        a = self.make()
        asyncio.run(a._talk_tap("a1", self.event(f"prop-{out['id']}", "choose", {"choice": "Keep it as is"})))
        self.assertEqual(a.written, [])
        self.assertEqual(a._notes["a1"], ["[yui] Proposal p-1 kept as is."])
        self.assertIn("row-9", a._acks)

    def test_grantee_tap_does_nothing(self):
        out = self.propose("soul", "SOUL.md", value={"text": "# Scout\n\nCalm.\n"})
        a = self.make()
        ev = self.event(f"prop-{out['id']}", "choose", {"choice": "Apply"}, user_id=CLIENT)
        self.assertTrue(asyncio.run(a._talk_tap("a1", ev)))
        self.assertEqual((HOME / "SOUL.md").read_text(), tc.SOUL)
        self.assertEqual(a.written[0]["body"], "Only the owner can do that.")

    def test_ask_again_becomes_the_persons_message(self):
        out = self.propose("soul", "SOUL.md", value={"text": "# Scout\n\nCalm.\n"})
        (HOME / "SOUL.md").write_text("# Scout\n\nEdited.\n")
        a = self.make()
        asyncio.run(a._talk_tap("a1", self.event(f"prop-{out['id']}", "choose", {"choice": "Apply"})))
        self.assertIn("card@again-p-1", a.written[0]["body"])
        ev = self.event("again-p-1", "card", {"cta": "Ask again"})
        self.assertFalse(asyncio.run(a._talk_tap("a1", ev)))  # goes on to the agent
        self.assertEqual(ev["kind"], "text")
        self.assertEqual(talk.read_attach(ev["body"])["rev"], self.get("soul", "SOUL.md")["rev"])

    def test_other_rows_pass(self):
        a = self.make()
        self.assertFalse(asyncio.run(a._talk_tap("a1", self.event("need-t_1234", "choose", {"choice": "x"}))))
        self.assertFalse(asyncio.run(a._talk_tap("a1", {"id": "r", "kind": "text", "body": "hi"})))

    def test_dispatch_expands_for_the_owner_and_strips_for_a_group(self):
        a = self.make()
        a._agents = {"a1": {"name": "Scout"}}
        a._last_inbound, a._turns, a._token, a.got = {}, {}, None, []
        a.build_source = lambda **kw: kw
        ad.MessageEvent = type("E", (), {"__init__": lambda s, **kw: s.__dict__.update(kw),
                                         "is_command": lambda s: False})
        ad.MessageType = types.SimpleNamespace(PHOTO="photo", TEXT="text")

        async def no_notes(*_):
            return []

        async def handle(event):
            a.got.append(event)
        a._mention_notes, a._group_notes, a.handle_message = no_notes, no_notes, handle
        rev = self.get("soul", "SOUL.md")["rev"]
        row = {"id": "r1", "agent_id": "a1", "user_id": OWNER, "kind": "text", "created_at": "2026-09-26T00:00:00Z",
               "body": talk.attach_body("soul", "SOUL.md", rev, "Calmer please.")}
        asyncio.run(a._dispatch([row]))
        self.assertIn("--- SOUL.md (current) ---", a.got[0].text)
        grow = {**row, "id": "r2", "meta": {"group": {"thread": "g1"}}}
        asyncio.run(a._dispatch([grow]))
        self.assertEqual(a.got[1].text, "Calmer please.")
        st = json.loads((HOME / "yui" / "talk.json").read_text())
        self.assertEqual((st["turn"]["owner"], st["owner_user"]), (True, OWNER))

    def test_cli_has_propose(self):
        import argparse
        p = argparse.ArgumentParser()
        ad.connector.build_parser(p, with_profile=False)
        args = p.parse_args(["propose", "--section", "soul", "--id", "SOUL.md", "--rev", "abc", "--text", "x",
                             "--why", "y"])
        self.assertIs(args.fn, ad.talk.cmd_propose)


if __name__ == "__main__":
    try:
        unittest.main(verbosity=2)
    finally:
        shutil.rmtree(HOME, ignore_errors=True)
