"""Agent controls from the drawer (YUI-70, spec yuigui spec/CONTROLS.md): a
kind='control' row is served by the host with no agent turn, only for the
owner, and answered with one kind='control' row.

    ~/.hermes/hermes-agent/venv/bin/python hermes-plugin/tests/test_controls.py

Every test runs on a fresh temp profile home (HERMES_HOME is pointed at it
before hermes-agent is imported, so cron and config read and write there),
never a real profile. The schedule and config tests need hermes-agent on the
path (HERMES_AGENT, default ~/.hermes/hermes-agent); they skip without it.
"""

import asyncio
import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

HOME = Path(tempfile.mkdtemp(prefix="yui-controls-"))
os.environ["HERMES_HOME"] = str(HOME)  # before any hermes import: cron binds its paths at import

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_board import _adapter_module, _load, PLUGIN, AGENT  # noqa: E402

controls = _load("yui_controls", PLUGIN / "yui" / "controls.py")

try:
    sys.path.insert(0, str(AGENT))
    from cron import jobs as cron  # noqa: E402
    from hermes_cli import config as hconfig  # noqa: E402
except Exception:  # pragma: no cover
    cron = hconfig = None

KEY = "sk-ant-api03-" + "Q" * 40  # token-shaped, not a real key
SOUL = "# Scout\n\nWarm and quick.\n\n## Voice\n\nShort sentences.\n"
SKILL = "---\nname: tan-studio\ndescription: Book a tan.\n---\n\n# Tan studio\n\nSteps.\n"
BUNDLED = "---\nname: apple-notes\ndescription: Notes via memo.\n---\n\nBody.\n"


def fresh_home():
    for p in HOME.iterdir():
        shutil.rmtree(p) if p.is_dir() else p.unlink()
    (HOME / "SOUL.md").write_text(SOUL)
    (HOME / "memories").mkdir()
    (HOME / "memories" / "MEMORY.md").write_text("Mac mini is the host.\n§\nDeploys go through Vercel.")
    (HOME / "memories" / "USER.md").write_text(f"Chris likes short answers.\n§\nHis test key: {KEY}")
    for rel, text in (("productivity/tan-studio", SKILL), ("apple/apple-notes", BUNDLED)):
        (HOME / "skills" / rel).mkdir(parents=True)
        (HOME / "skills" / rel / "SKILL.md").write_text(text)
    (HOME / "skills" / ".bundled_manifest").write_text("apple-notes:abc123\n")
    (HOME / ".env").write_text(f"ANTHROPIC_API_KEY={KEY}\nTELEGRAM_BOT_TOKEN=123456789:{'A' * 35}\n")
    (HOME / "config.yaml").write_text(
        "model:\n  default: claude-opus-5-5\n  provider: custom\n  base_url: http://127.0.0.1:8765/v1\n"
        f"  api_key: {KEY}\ntoolsets:\n- hermes-cli\n- kanban\nplatforms:\n  yui:\n    enabled: true\n")
    (HOME / "gateway_state.json").write_text(json.dumps(
        {"platforms": {"yui": {"state": "connected"}, "telegram": {"state": "connected", "token": KEY}}}))


def req(op, section, id=None, **kw):
    r = {"v": 1, "req": "c-1", "op": op, "section": section, **kw}
    if id is not None:
        r["id"] = id
    return r


class Base(unittest.TestCase):
    def setUp(self):
        fresh_home()
        self.host = controls.Host(HOME, cron=cron, config=hconfig)

    def ask(self, *a, owner=True, **kw):
        ans, change = self.host.handle(req(*a, **kw), owner=owner, who="owner-uid", agent="a1")
        self.change = change
        return ans

    def ok(self, *a, **kw):
        ans = self.ask(*a, **kw)
        self.assertTrue(ans["ok"], ans)
        self.assertEqual(ans["req"], "c-1")
        return ans

    def log(self):
        p = HOME / "yui" / "controls.log"
        return [json.loads(ln) for ln in p.read_text().splitlines()] if p.exists() else []

    def trash(self):
        p = HOME / "yui" / "controls-trash"
        return sorted(x.name for x in p.iterdir()) if p.exists() else []


class Protocol(Base):
    def test_report(self):
        self.assertEqual(controls.report(), {"v": 1, "sections": {
            "soul": "rw", "memory": "rwd", "skills": "rwd", "schedules": "rwd", "model": "r", "channels": "r"}})

    def test_request_of(self):
        self.assertEqual(controls.request_of({"kind": "control", "sender": "user", "meta": {"op": "list"}}), {"op": "list"})
        self.assertIsNone(controls.request_of({"kind": "event", "meta": {"op": "list"}}))
        self.assertIsNone(controls.request_of({"kind": "control", "sender": "agent", "meta": {}}))

    def test_unknown_version_op_section_verb(self):
        self.assertEqual(self.host.handle({"v": 2, "req": "x", "op": "list", "section": "soul"}, owner=True)[0]["error"], "version")
        self.assertEqual(self.ask("drop", "soul")["error"], "bad_op")
        self.assertEqual(self.ask("list", "secrets")["error"], "bad_section")
        self.assertEqual(self.ask("act", "skills", "tan-studio", verb="explode")["error"], "bad_verb")
        self.assertEqual(self.ask("put", "model", "model", rev="x", value={"text": "gpt"})["error"], "not_allowed")
        self.assertEqual(self.ask("delete", "soul", "SOUL.md", rev="x", confirmed=True)["error"], "keep_soul")

    def test_grantee_refused(self):
        ans = self.ask("list", "memory", owner=False)
        self.assertEqual((ans["ok"], ans["error"]), (False, "not_owner"))
        self.assertNotIn("items", ans)
        rev = self.ok("get", "soul", "SOUL.md")["rev"]
        self.assertEqual(self.ask("put", "soul", "SOUL.md", rev=rev, value={"text": "# Pwned"}, owner=False)["error"], "not_owner")
        self.assertEqual((HOME / "SOUL.md").read_text(), SOUL)

    def test_path_ids_refused(self):
        for bad in ("../SOUL.md", "../../.env", "/etc/passwd", "skills/../x", ".env", "a/b"):
            self.assertEqual(self.ask("get", "skills", bad)["error"], "bad_id", bad)
        self.assertEqual(self.ask("get", "soul", "USER.md")["error"], "bad_id")
        self.assertEqual(self.ask("get", "skills", "not-listed")["error"], "bad_id")
        self.assertEqual(self.ask("get", "memory", "mem-0000000000")["error"], "not_found")

    def test_rate_limit(self):
        rev = self.ok("get", "soul", "SOUL.md")["rev"]
        for i in range(controls.WRITES_PER_MINUTE):
            rev = self.ok("put", "soul", "SOUL.md", rev=rev, value={"text": f"# Scout {i}"})["rev"]
        self.assertEqual(self.ask("put", "soul", "SOUL.md", rev=rev, value={"text": "# more"})["error"], "too_fast")
        self.host.clock = lambda: __import__("time").time() + 61
        self.ok("put", "soul", "SOUL.md", rev=rev, value={"text": "# later"})

    def test_body_has_no_values(self):
        ans = self.ok("get", "memory", self.ok("list", "memory")["items"][0]["id"])
        body = controls.body_of(req("get", "memory"), ans)
        self.assertTrue(body.startswith("controls: get memory "))
        self.assertNotIn("Chris", body)

    def test_note(self):
        self.assertEqual(controls.note(["one memory forgotten", "one memory forgotten", '"morning brief" paused']),
                         '[yui] Your settings changed in Controls: 2 memories forgotten, "morning brief" paused. '
                         "(Already applied on the host; no reply needed.)")

    def test_when_in_words(self):
        self.assertEqual(controls.when_in_words("0 8 * * 1-5"), "weekdays 8:00")
        self.assertEqual(controls.when_in_words("30 17 * * *"), "daily 17:30")
        self.assertEqual(controls.when_in_words("*/30 * * * *"), "every 30 minutes")
        self.assertEqual(controls.when_in_words("every 10m"), "every 10 minutes")
        self.assertEqual(controls.when_in_words("0 9 1 * *"), "0 9 1 * *")


class Soul(Base):
    def test_list_get_put_conflict_trash_log(self):
        items = self.ok("list", "soul")["items"]
        self.assertEqual([i["id"] for i in items], ["SOUL.md"])
        got = self.ok("get", "soul", "SOUL.md")
        self.assertEqual(got["item"]["text"], SOUL)
        self.assertEqual(got["item"]["outline"], ["Scout", "Voice"])
        put = self.ok("put", "soul", "SOUL.md", rev=got["rev"], value={"text": "# Scout\n\nPlayful now."})
        self.assertEqual((HOME / "SOUL.md").read_text(), "# Scout\n\nPlayful now.")
        self.assertEqual(self.change, "personality edited")
        self.assertNotEqual(put["rev"], got["rev"])
        # the old copy is in the trash, and the log has one line with old and new rev
        t = self.trash()
        self.assertEqual(len(t), 1)
        self.assertTrue(t[0].endswith("-soul-SOUL.md"))
        self.assertEqual((HOME / "yui" / "controls-trash" / t[0]).read_text(), SOUL)
        log = self.log()
        self.assertEqual(len(log), 1)
        self.assertEqual({k: log[0][k] for k in ("who", "op", "section", "id", "old", "new")},
                         {"who": "owner-uid", "op": "put", "section": "soul", "id": "SOUL.md",
                          "old": got["rev"], "new": put["rev"]})
        # the phone still holds the first rev: a stale save is refused with the current item
        stale = self.ask("put", "soul", "SOUL.md", rev=got["rev"], value={"text": "# Clobber"})
        self.assertEqual(stale["error"], "conflict")
        self.assertEqual(stale["rev"], put["rev"])
        self.assertEqual(stale["item"]["text"], "# Scout\n\nPlayful now.")
        self.assertEqual((HOME / "SOUL.md").read_text(), "# Scout\n\nPlayful now.")
        self.assertEqual(len(self.log()), 1)

    def test_empty_and_too_big(self):
        rev = self.ok("get", "soul", "SOUL.md")["rev"]
        self.assertEqual(self.ask("put", "soul", "SOUL.md", rev=rev, value={"text": "  \n"})["error"], "empty")
        self.assertEqual(self.ask("put", "soul", "SOUL.md", rev=rev, value={"text": "x" * 40000})["error"], "too_big")
        self.assertEqual((HOME / "SOUL.md").read_text(), SOUL)


class Memory(Base):
    def test_list_newest_first_by_group(self):
        items = self.ok("list", "memory")["items"]
        self.assertEqual([(i["group"], i["title"]) for i in items], [
            ("remembers", "Deploys go through Vercel."), ("remembers", "Mac mini is the host."),
            ("you", controls.HIDDEN), ("you", "Chris likes short answers.")])

    def test_secret_redacted_and_read_only(self):
        items = self.ok("list", "memory")["items"]
        keyed = [i for i in items if i["read_only"]]
        self.assertEqual(len(keyed), 1)
        got = self.ok("get", "memory", keyed[0]["id"])
        self.assertEqual(got["item"]["text"], controls.HIDDEN)
        self.assertTrue(got["item"]["read_only"])
        self.assertNotIn("sk-ant", json.dumps(self.ok("list", "memory")))
        # a save over it is refused, so the placeholder never lands on the real value
        ans = self.ask("put", "memory", keyed[0]["id"], rev=got["rev"], value={"text": controls.HIDDEN})
        self.assertEqual(ans["error"], "read_only")
        self.assertIn(KEY, (HOME / "memories" / "USER.md").read_text())
        # the placeholder cannot be written into another entry either
        plain = [i for i in items if not i["read_only"]][0]
        rev = self.ok("get", "memory", plain["id"])["rev"]
        self.assertEqual(self.ask("put", "memory", plain["id"], rev=rev,
                                  value={"text": "x " + controls.HIDDEN})["error"], "read_only")

    def test_edit_forget_conflict(self):
        items = self.ok("list", "memory")["items"]
        vercel = next(i for i in items if i["title"].startswith("Deploys"))
        got = self.ok("get", "memory", vercel["id"])
        put = self.ok("put", "memory", vercel["id"], rev=got["rev"], value={"text": "Deploys go through Vercel CLI."})
        self.assertNotEqual(put["id"], vercel["id"], "an entry's id follows its text")
        self.assertIn("Deploys go through Vercel CLI.", (HOME / "memories" / "MEMORY.md").read_text())
        self.assertEqual(self.change, "one memory edited")
        # forget without confirmed is refused
        self.assertEqual(self.ask("delete", "memory", put["id"], rev=put["rev"])["error"], "confirm")
        # a stale rev on delete is a conflict
        self.assertEqual(self.ask("delete", "memory", put["id"], rev=got["rev"], confirmed=True)["error"], "conflict")
        gone = self.ok("delete", "memory", put["id"], rev=put["rev"], confirmed=True)
        self.assertTrue(gone["deleted"])
        self.assertEqual(self.change, "one memory forgotten")
        self.assertEqual((HOME / "memories" / "MEMORY.md").read_text(), "Mac mini is the host.")
        self.assertEqual(len(self.trash()), 2)
        self.assertEqual([ln["op"] for ln in self.log()], ["put", "delete"])
        self.assertEqual(self.ask("get", "memory", put["id"])["error"], "not_found")


class Skills(Base):
    def test_list_get_put(self):
        items = {i["id"]: i for i in self.ok("list", "skills")["items"]}
        self.assertEqual(set(items), {"tan-studio", "apple-notes"})
        self.assertEqual(items["tan-studio"]["description"], "Book a tan.")
        self.assertTrue(items["apple-notes"]["bundled"])
        self.assertFalse(items["tan-studio"]["bundled"])
        got = self.ok("get", "skills", "tan-studio")
        self.assertEqual(got["item"]["text"], SKILL)
        bad = self.ask("put", "skills", "tan-studio", rev=got["rev"], value={"text": "# no frontmatter"})
        self.assertEqual(bad["error"], "no_frontmatter")
        new = SKILL.replace("Steps.", "Call first.")
        self.ok("put", "skills", "tan-studio", rev=got["rev"], value={"text": new})
        self.assertEqual((HOME / "skills/productivity/tan-studio/SKILL.md").read_text(), new)

    @unittest.skipIf(hconfig is None, "hermes-agent not importable")
    def test_switch_off_and_on(self):
        self.ok("act", "skills", "apple-notes", verb="disable")
        self.assertEqual(self.change, 'skill "apple-notes" switched off')
        self.assertIn("apple-notes", hconfig.load_config()["skills"]["disabled"])
        self.assertFalse({i["id"]: i for i in self.ok("list", "skills")["items"]}["apple-notes"]["enabled"])
        self.ok("act", "skills", "apple-notes", verb="enable")
        self.assertNotIn("apple-notes", hconfig.load_config()["skills"].get("disabled") or [])
        self.assertIn("api_key", (HOME / "config.yaml").read_text(), "the rest of the config is kept")

    def test_bundled_refused_added_deleted(self):
        rev = self.ok("get", "skills", "apple-notes")["rev"]
        self.assertEqual(self.ask("delete", "skills", "apple-notes", rev=rev, confirmed=True)["error"], "bundled")
        self.assertTrue((HOME / "skills/apple/apple-notes/SKILL.md").exists())
        rev = self.ok("get", "skills", "tan-studio")["rev"]
        self.ok("delete", "skills", "tan-studio", rev=rev, confirmed=True)
        self.assertFalse((HOME / "skills/productivity/tan-studio").exists())
        kept = [t for t in self.trash() if t.endswith("-skills-tan-studio")]
        self.assertEqual(len(kept), 1)
        self.assertTrue((HOME / "yui/controls-trash" / kept[0] / "SKILL.md").exists(), "the whole folder is kept")

    def test_symlink_out_of_the_folder_is_not_listed(self):
        outside = Path(tempfile.mkdtemp()) / "evil"
        outside.mkdir()
        (outside / "SKILL.md").write_text(SKILL)
        (HOME / "skills" / "evil").symlink_to(outside)
        self.assertNotIn("evil", [i["id"] for i in self.ok("list", "skills")["items"]])
        self.assertEqual(self.ask("get", "skills", "evil")["error"], "bad_id")


@unittest.skipIf(cron is None, "hermes-agent not importable")
class Schedules(Base):
    def setUp(self):
        super().setUp()
        self.job = cron.create_job(prompt="Send the morning brief.", schedule="0 8 * * 1-5", name="morning brief")["id"]

    def test_list_get(self):
        items = self.ok("list", "schedules")["items"]
        self.assertEqual(len(items), 1)
        self.assertEqual((items[0]["title"], items[0]["when"], items[0]["paused"]), ("morning brief", "weekdays 8:00", False))
        got = self.ok("get", "schedules", self.job)
        self.assertEqual(got["item"]["text"], "Send the morning brief.")

    def test_pause_resume_run(self):
        self.ok("act", "schedules", self.job, verb="pause")
        self.assertEqual(self.change, '"morning brief" paused')
        self.assertEqual(cron.get_job(self.job)["state"], "paused")
        self.assertTrue(self.ok("list", "schedules")["items"][0]["paused"])
        self.ok("act", "schedules", self.job, verb="resume")
        self.assertEqual(cron.get_job(self.job)["state"], "scheduled")
        ran = self.ok("act", "schedules", self.job, verb="run")
        self.assertTrue(ran["item"]["running_soon"])
        self.assertEqual(self.change, '"morning brief" run now')
        self.assertEqual([ln["op"] for ln in self.log()], ["act", "act", "act"])

    def test_edit_time_and_prompt(self):
        got = self.ok("get", "schedules", self.job)
        bad = self.ask("put", "schedules", self.job, rev=got["rev"], value={"schedule": "whenever you like"})
        self.assertEqual(bad["error"], "bad_schedule")
        put = self.ok("put", "schedules", self.job, rev=got["rev"],
                      value={"text": "Send the brief with weather.", "schedule": "30 7 * * *"})
        self.assertEqual(put["item"]["when"], "daily 7:30")
        self.assertEqual(cron.get_job(self.job)["prompt"], "Send the brief with weather.")
        self.assertEqual(self.ask("put", "schedules", self.job, rev=got["rev"], value={"text": "x"})["error"], "conflict")

    def test_delete(self):
        rev = self.ok("get", "schedules", self.job)["rev"]
        self.ok("delete", "schedules", self.job, rev=rev, confirmed=True)
        self.assertIsNone(cron.get_job(self.job))
        self.assertEqual(self.change, '"morning brief" deleted')
        self.assertTrue(any(t.endswith(f"-schedules-{self.job}") for t in self.trash()))

    def test_secret_in_prompt_is_hidden(self):
        job = cron.create_job(prompt=f"Use key {KEY} to post.", schedule="every 30m", name="poster")["id"]
        got = self.ok("get", "schedules", job)
        self.assertNotIn("sk-ant", json.dumps(got))
        self.assertTrue(got["item"]["read_only"])
        self.assertEqual(self.ask("put", "schedules", job, rev=got["rev"], value={"text": "x"})["error"], "read_only")


class ModelChannels(Base):
    def test_model_read_only_no_key(self):
        got = self.ok("get", "model", "model")
        self.assertEqual(got["item"]["model"], "claude-opus-5-5")
        self.assertEqual(got["item"]["provider"], "Claude on this Mac")
        self.assertEqual([t["name"] for t in got["item"]["toolsets"]], ["hermes-cli", "kanban"])
        blob = json.dumps([got, self.ok("list", "model")])
        self.assertNotIn("sk-ant", blob)
        self.assertNotIn("127.0.0.1", blob)

    def test_channels_names_only(self):
        items = self.ok("list", "channels")["items"]
        self.assertEqual([(i["id"], i["title"]) for i in items], [("telegram", "Telegram"), ("yui", "Yui")])
        self.assertNotIn("sk-ant", json.dumps(items))

    def test_nothing_key_shaped_in_any_answer(self):
        blob = []
        for s in controls.SECTIONS:
            lst = self.ok("list", s)
            blob.append(lst)
            for i in lst["items"]:
                blob.append(self.ok("get", s, i["id"]))
        text = json.dumps(blob)
        self.assertIsNone(controls.KEYISH.search(text), controls.KEYISH.search(text))
        self.assertNotIn("A" * 35, text)


class AdapterPath(Base):
    """The adapter serves the row, answers with one control row, queues no turn, and notes the change."""

    def make(self, user_id="owner"):
        ad = _adapter_module()
        a = ad.YuiAdapter.__new__(ad.YuiAdapter)
        a._remote_ref, a._user_id, a._notes, a._acks = "yui", user_id, {}, set()
        a._controls, a._control_changes = controls.Host(HOME, cron=cron, config=hconfig), {}
        ad.controls = controls
        a.marked, a.written = [], []

        async def mark(ids, column):
            a.marked.append((tuple(ids), column))
            return True

        async def write(row):
            a.written.append(row)
            return "sent"
        a._mark, a._write_row = mark, write
        return a

    def row(self, meta, user_id="owner"):
        return {"id": "row-1", "kind": "control", "sender": "user", "user_id": user_id, "agent_id": "a1",
                "body": "controls", "meta": meta}

    def test_owner_served_without_a_turn(self):
        a = self.make()
        rev = self.ok("get", "soul", "SOUL.md")["rev"]
        self.assertTrue(asyncio.run(a._control("a1", self.row(req("put", "soul", "SOUL.md", rev=rev,
                                                                    value={"text": "# New"})))))
        out = a.written[0]
        self.assertEqual((out["kind"], out["sender"], out["body"]), ("control", "agent", "controls: put soul SOUL.md"))
        self.assertTrue(out["meta"]["ok"])
        self.assertEqual(out["meta"]["for"], "row-1")
        self.assertNotIn("turn", out["meta"])
        self.assertEqual(a._control_changes, {"a1": ["personality edited"]})
        self.assertIn("row-1", a._acks)
        self.assertEqual(a.marked, [(("row-1",), "delivered_at")])

    def test_grantee_refused_by_the_host(self):
        a = self.make()
        asyncio.run(a._control("a1", self.row(req("list", "memory"), user_id="client")))
        self.assertEqual(a.written[0]["meta"]["error"], "not_owner")
        self.assertEqual(a._control_changes, {})

    def test_other_rows_pass(self):
        a = self.make()
        self.assertFalse(asyncio.run(a._control("a1", {**self.row({}), "kind": "event"})))
        self.assertEqual(a.written, [])


if __name__ == "__main__":
    try:
        unittest.main(verbosity=2)
    finally:
        shutil.rmtree(HOME, ignore_errors=True)
