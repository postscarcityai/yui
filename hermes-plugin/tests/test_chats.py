"""Several chats per agent (YUI-169).

    ~/.hermes/hermes-agent/venv/bin/python hermes-plugin/tests/test_chats.py

Each chat is its own Hermes session: `<base key>` for the first chat (and an old
row with no meta.chat), `<base key>:<chat id>` for every other. Ownership and the
notes still go by the base key and the agent id.
"""

import asyncio
import sys
import time
import types
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_board import _adapter_module  # noqa: E402

ad = _adapter_module()
ad.SendResult = lambda **k: types.SimpleNamespace(**k)  # same stubs as test_stop.py
ad.ProcessingOutcome = types.SimpleNamespace(SUCCESS="success")

AID = "11111111-1111-1111-1111-111111111111"
OWNER = "22222222-2222-2222-2222-222222222222"
CLIENT = "33333333-3333-3333-3333-333333333333"
C1 = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"  # first chat
C2 = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
C3 = "cccccccc-cccc-cccc-cccc-cccccccccccc"


class Event:
    def __init__(self, **kw):
        self.__dict__.update(kw)

    def is_command(self):
        return self.text.lstrip().startswith("/")


def row(rid="r1", chat=None, first=False, new=False, user=OWNER, kind="text", body="hi", meta=None):
    m = dict(meta or {})
    if chat:
        m["chat"] = {"id": chat, "first": first, "new": new}
    return {"id": rid, "user_id": user, "agent_id": AID, "sender": "user", "kind": kind, "body": body,
            "meta": m, "created_at": "2026-09-29T12:00:00+00:00"}


class Chats(unittest.TestCase):
    def patch(self, obj, name, value):
        """Module stubs are undone after each test: the other files share the adapter module."""
        old = getattr(obj, name)
        setattr(obj, name, value)
        self.addCleanup(setattr, obj, name, old)

    def make(self):
        self.patch(ad, "MessageEvent", Event)
        self.patch(ad, "MessageType", type("MT", (), {"TEXT": "text", "PHOTO": "photo"}))
        self.patch(ad.sandbox, "current", lambda: {})
        self.patch(ad.sandbox, "failures", lambda r: [])
        self.patch(ad.media, "rewrite", lambda b, h, log=None: b)
        a = ad.YuiAdapter.__new__(ad.YuiAdapter)
        a._user_id, a._remote_ref = OWNER, "coach"
        a._agents = {AID: {"id": AID, "name": "Coach", "handle": "coach", "remote_ref": "coach"}}
        a._all_agents = list(a._agents.values())
        a._notes, a._busy, a._turns, a._last_inbound, a._acks = {}, {}, {}, {}, set()
        a._queue, a._halted, a._control_changes = {}, {}, {}
        a._paused_said, a._tasks, a._client = None, [], None
        a.handled, a.written, a.marked = [], [], []
        a.build_source = lambda **kw: kw

        async def handle(ev):
            a.handled.append(ev)

        async def write(r):
            a.written.append(r)
            return "sent"

        async def mark(ids, col):
            a.marked.append((tuple(ids), col))
            return True

        async def notes(*_):
            return []
        a.handle_message, a._write_row, a._mark, a._mention_notes = handle, write, mark, notes
        a._outbox = type("O", (), {"add": lambda *_: None, "__len__": lambda *_: 0})()
        return a

    # -- keys ---------------------------------------------------------------

    def test_first_chat_key_is_the_agent_id(self):
        a = self.make()
        self.assertEqual(a._key(row(chat=C1, first=True)), AID)
        self.assertEqual(a._key(row(chat=C1, first=True, new=True)), AID)

    def test_second_chat_key_has_the_chat_suffix(self):
        a = self.make()
        self.assertEqual(a._key(row(chat=C2)), f"{AID}:{C2}")
        self.assertEqual(a._base_key(row(chat=C2)), AID)

    def test_shared_agent_key(self):
        a = self.make()
        self.assertEqual(a._key(row(chat=C2, user=CLIENT)), f"{AID}~{CLIENT}:{C2}")
        self.assertEqual(a._key(row(chat=C1, first=True, user=CLIENT)), f"{AID}~{CLIENT}")
        self.assertEqual(a._base_key(row(chat=C2, user=CLIENT)), f"{AID}~{CLIENT}")

    def test_an_old_row_behaves_as_before(self):
        a = self.make()
        self.assertEqual(a._key(row()), AID)
        self.assertEqual(a._key(row(user=CLIENT)), f"{AID}~{CLIENT}")
        asyncio.run(a._dispatch([row(body="old")]))
        ev = a.handled[0]
        self.assertEqual((ev.source["chat_id"], ev.text), (AID, "old"))
        self.assertNotIn(AID, a._chats if hasattr(a, "_chats") else {})

    def test_agent_for_resolves_every_key_shape(self):
        a = self.make()
        self.assertEqual(a._agent_for(AID), (AID, None))
        self.assertEqual(a._agent_for(f"{AID}~{CLIENT}"), (f"{AID}~{CLIENT}", None))
        self.assertEqual(a._agent_for(f"{AID}:{C2}"), (f"{AID}:{C2}", None))
        self.assertEqual(a._agent_for(f"{AID}~{CLIENT}:{C2}"), (f"{AID}~{CLIENT}:{C2}", None))
        self.assertEqual(a._agent_for("coach"), (AID, None))
        self.assertEqual(a._agent_for(f"coach:{C2}"), (f"{AID}:{C2}", None))
        self.assertEqual(a._agent_for("nobody"), (None, None))
        self.assertEqual(a._split(f"{AID}~{CLIENT}:{C2}"), (AID, CLIENT))
        self.assertEqual(a._split(f"{AID}:{C2}"), (AID, OWNER))
        self.assertEqual(a._key_chat(f"{AID}:{C2}"), C2)
        self.assertIsNone(a._key_chat(AID))
        self.assertEqual(asyncio.run(a.get_chat_info(f"{AID}:{C2}"))["name"], "Yui: Coach")

    def test_split_chat(self):
        self.assertEqual(ad.split_chat(f"{AID}~{CLIENT}:{C2}"), (f"{AID}~{CLIENT}", C2))
        self.assertEqual(ad.split_chat("coach"), ("coach", None))
        self.assertEqual(ad.split_chat("coach:notauuid"), ("coach:notauuid", None))

    # -- two sessions -------------------------------------------------------

    def test_two_chats_are_two_sessions_with_two_busy_states(self):
        a = self.make()
        a._queue = {AID: [row("r1", C1, True)], f"{AID}:{C2}": [row("r2", C2)]}
        asyncio.run(a._pump(AID))
        asyncio.run(a._pump(f"{AID}:{C2}"))
        self.assertEqual([e.source["chat_id"] for e in a.handled], [AID, f"{AID}:{C2}"])
        self.assertEqual(a._busy[AID][0], ["r1"])
        self.assertEqual(a._busy[f"{AID}:{C2}"][0], ["r2"])
        # a third row in chat 2 waits behind chat 2's turn only
        a._queue[f"{AID}:{C2}"] = [row("r3", C2)]
        asyncio.run(a._pump(f"{AID}:{C2}"))
        self.assertEqual(len(a.handled), 2)
        a._busy.pop(AID)
        a._queue[AID] = [row("r4", C1, True)]
        asyncio.run(a._pump(AID))
        self.assertEqual(len(a.handled), 3)

    def test_fetch_pumps_every_chat_of_the_agent(self):
        a = self.make()
        a._queue = {f"{AID}:{C2}": [], AID: []}
        seen = []

        async def pump(key):
            seen.append(key)
        a._pump = pump
        a._agents = {AID: {}}
        a._cursor, a._dispatched, a._realtime_ok = {}, set(), True
        a._fetch_lock = asyncio.Lock()

        async def flush():
            return None

        class R:
            status_code = 200

            def raise_for_status(self):
                pass

            def json(self):
                return [row("r9", C2)]

        class C:
            async def get(self, *a, **k):
                return R()
        a._token = "t"
        a._client, a._flush_acks = C(), flush
        a._stop = a._control = a._owner_only = a._board_order = a._need_answer = a._need_open = a._talk_tap = \
            lambda *x: asyncio.sleep(0, result=False)
        asyncio.run(a._fetch_new())
        self.assertEqual(sorted(seen), sorted([AID, f"{AID}:{C2}"]))
        self.assertEqual(a._queue[f"{AID}:{C2}"][0]["id"], "r9")

    def stop_row(self, chat, first=False, rid="stop-1"):
        return row(rid, chat, first, kind="control", body="stop", meta={"op": "stop"})

    def test_stop_in_one_chat_does_not_halt_the_other(self):
        a = self.make()
        k2 = f"{AID}:{C2}"
        a._busy[AID] = (["r1"], time.time())
        a._busy[k2] = (["r2"], time.time())
        a._queue[k2] = [row("r5", C2)]
        self.assertTrue(asyncio.run(a._stop(AID, self.stop_row(C2))))
        self.assertTrue(a._held_back(k2))
        self.assertFalse(a._held_back(AID))
        self.assertNotIn(k2, a._queue)
        self.assertNotIn("r1", a._acks)
        self.assertEqual(a.handled[0].source["chat_id"], k2, "Hermes /stop goes to that chat's session")
        self.assertEqual(a.written[0]["meta"]["chat"], C2, "the answer lands in the chat that stopped")
        # and the other way round
        a2 = self.make()
        a2._busy[AID] = (["r1"], time.time())
        a2._busy[k2] = (["r2"], time.time())
        asyncio.run(a2._stop(AID, self.stop_row(C1, True)))
        self.assertTrue(a2._held_back(AID))
        self.assertFalse(a2._held_back(k2))
        self.assertEqual(a2.written[0]["meta"]["chat"], C1)

    def test_a_stopped_chats_late_reply_is_held_but_the_other_speaks(self):
        a = self.make()
        k2 = f"{AID}:{C2}"
        a._busy[k2] = (["r2"], time.time())
        a._busy[AID] = (["r1"], time.time())
        asyncio.run(a._stop(AID, self.stop_row(C2)))
        a.written.clear()
        a._client, a._token = object(), "t"
        a._spawn = lambda c: c.close()
        asyncio.run(a._insert(k2, "half a plan"))
        self.assertEqual(a.written, [])
        asyncio.run(a._insert(AID, "still going"))
        self.assertEqual(a.written[0]["meta"]["turn"], ["r1"])

    # -- chat new -----------------------------------------------------------

    def test_chat_new_only_on_a_new_non_first_chat(self):
        a = self.make()
        asyncio.run(a._dispatch([row("r1", C2, new=True, body="hello there")]))
        self.assertEqual(a.handled[-1].text, "[yui] chat new\nhello there")
        asyncio.run(a._dispatch([row("r2", C1, first=True, new=True, body="first")]))
        self.assertEqual(a.handled[-1].text, "first")
        asyncio.run(a._dispatch([row("r3", C2, new=False, body="later")]))
        self.assertEqual(a.handled[-1].text, "later")
        asyncio.run(a._dispatch([row("r4", body="old app")]))
        self.assertEqual(a.handled[-1].text, "old app")

    def test_chat_new_comes_before_the_notes(self):
        a = self.make()
        a._notes[AID] = ["[yui] note: board"]
        asyncio.run(a._dispatch([row("r1", C2, new=True, body="hi")]))
        self.assertEqual(a.handled[-1].text, "[yui] chat new\n[yui] note: board\nhi")

    def test_a_backlog_that_starts_with_the_new_row_gets_the_line_once(self):
        a = self.make()
        asyncio.run(a._dispatch([row("r1", C2, new=True, body="one"), row("r2", C2, body="two")]))
        self.assertEqual(a.handled[-1].text, "[yui] chat new\none\ntwo")

    # -- notes and ownership ------------------------------------------------

    def test_notes_are_the_agents_so_a_second_chat_reads_them(self):
        a = self.make()
        a._notes[AID] = ["[yui] note: board"]
        asyncio.run(a._dispatch([row("r1", C2, body="hey")]))
        self.assertTrue(a.handled[-1].text.startswith("[yui] note: board"))
        self.assertEqual(a._notes[AID] if AID in a._notes else [], [])

    def test_a_shared_chat_gets_no_owner_notes(self):
        a = self.make()
        a._notes[AID] = ["[yui] note: board"]
        asyncio.run(a._dispatch([row("r1", C2, user=CLIENT, body="hey")]))
        ev = a.handled[-1]
        self.assertEqual(ev.source["chat_id"], f"{AID}~{CLIENT}:{C2}")
        self.assertEqual(ev.text, "hey")
        self.assertEqual(a._notes[AID], ["[yui] note: board"])

    def test_a_control_request_from_a_second_chat_is_still_the_owners(self):
        a = self.make()
        seen = []

        class Host:
            def handle(self, req, owner, who, agent):
                seen.append(owner)
                return {"ok": True}, None
        a._controls = Host()
        req = row("c1", C2, kind="control", body="list", meta={"op": "list", "section": "soul", "req": "x"})
        self.assertTrue(asyncio.run(a._control(AID, req)))
        req2 = row("c2", C2, user=CLIENT, kind="control", body="list", meta={"op": "list", "section": "soul", "req": "y"})
        asyncio.run(a._control(AID, req2))
        self.assertEqual(seen, [True, False])

    def test_a_talk_tap_from_a_second_chat_is_still_the_owners(self):
        a = self.make()
        took = []

        class T:
            def take(self, tap, who, agent):
                took.append(agent)
                return {"reply": "Done.", "note": "changed", "applied": None}
        a._talk = T()
        tap = {"id": "t1", "user_id": OWNER, "agent_id": AID, "sender": "user", "kind": "event", "body": "x",
               "meta": {"id": "prop-p-1", "preset": "choose", "value": {"choice": "Apply"},
                        "chat": {"id": C2, "first": False, "new": False}}}
        self.assertTrue(asyncio.run(a._talk_tap(AID, tap)))
        self.assertEqual(took, [AID])
        self.assertEqual(a._notes[AID], ["changed"], "the note is the agent's, not the chat's")
        self.assertEqual(a.written[-1]["meta"]["turn"], ["t1"])
        a.written.clear()
        tap["user_id"] = CLIENT
        self.assertTrue(asyncio.run(a._talk_tap(AID, tap)))
        self.assertEqual(a.written[-1]["body"], "Only the owner can do that.")
        self.assertEqual(took, [AID])

    def test_owner_check_in_dispatch_uses_the_base_key(self):
        a = self.make()
        asyncio.run(a._dispatch([row("r1", C2)]))
        self.assertEqual(a.handled[-1].source["user_name"], "Yui user")
        asyncio.run(a._dispatch([row("r2", C2, user=CLIENT)]))
        self.assertEqual(a.handled[-1].source["user_name"], "Yui user (shared)")

    # -- replies with no turn -----------------------------------------------

    def insert(self, a, key, body="ping"):
        a._client, a._token = object(), "t"
        a._spawn = lambda c: c.close()
        asyncio.run(a._insert(key, body))
        return a.written[-1]

    def test_a_reply_with_no_turn_names_the_chat_it_learned_from_a_row(self):
        a = self.make()
        asyncio.run(a._dispatch([row("r1", C2)]))
        asyncio.run(a._dispatch([row("r0", C1, True)]))
        a._busy.clear()
        self.assertEqual(self.insert(a, f"{AID}:{C2}")["meta"], {"chat": C2})
        self.assertEqual(self.insert(a, AID)["meta"], {"chat": C1})

    def test_a_reply_in_a_turn_carries_the_turn_and_no_chat(self):
        a = self.make()
        a._queue[f"{AID}:{C2}"] = [row("r1", C2)]
        asyncio.run(a._pump(f"{AID}:{C2}"))
        w = self.insert(a, f"{AID}:{C2}")
        self.assertEqual(w["meta"], {"turn": ["r1"]})

    def test_no_chat_is_named_for_one_never_learned(self):
        a = self.make()
        self.assertNotIn("meta", self.insert(a, AID))
        self.assertNotIn("meta", self.insert(a, f"{AID}~{CLIENT}"))

    def test_a_handoff_from_another_profile_names_no_chat(self):
        a = self.make()
        asyncio.run(a._dispatch([row("r1", C1, True)]))
        a._busy.clear()
        a._client, a._token = object(), "t"
        a._spawn = lambda c: c.close()
        asyncio.run(a._insert(AID, "from urza", "Urza"))
        self.assertNotIn("meta", a.written[-1])

    def test_the_paused_card_names_the_owners_chat_only(self):
        a = self.make()
        self.patch(ad.sandbox, "failures", lambda r: ["terminal: local shell"])
        a._connect_call = lambda body: asyncio.sleep(0)
        a._sandbox = lambda: asyncio.sleep(0, result={})
        a._flush_acks = lambda: asyncio.sleep(0)
        a._spawn = lambda c: c.close()
        asyncio.run(a._dispatch([row("r1", C2, user=CLIENT)]))
        self.assertEqual(a.handled, [])
        card = [w for w in a.written if w["user_id"] == OWNER][0]
        self.assertNotIn("meta", card, "the client's chat is not the owner's")

    def test_the_tables_read_note_stays_in_its_chat(self):
        a = self.make()
        k2 = f"{AID}:{C2}"
        a._token = "t"
        a._queue.clear()
        a._poke = lambda: None
        a._busy[k2] = (["r1"], time.time())
        self.patch(ad.tables, "has_words", lambda b: True)
        self.patch(ad.tables, "in_reply", lambda body, aid: ("", "rows: 3", None))
        a._client = object()
        asyncio.run(a._insert(k2, "```yui\ntables read x\n```"))
        queued = a._queue[k2][0]
        self.assertEqual(a._key(queued), k2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
