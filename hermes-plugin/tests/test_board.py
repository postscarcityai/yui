"""Board order from the app (YUI-66): a saved timeline order becomes kanban
priority with no agent turn, and only for the paired owner.

    ~/.hermes/hermes-agent/venv/bin/python hermes-plugin/tests/test_board.py

The plan tests need nothing. The DB and adapter tests need hermes-agent on the
path (HERMES_AGENT, default ~/.hermes/hermes-agent); they skip without it.
Every DB here is a fresh temp file, never the real board.
"""

import asyncio
import importlib.util
import os
import sys
import tempfile
import time
import types
import unittest
from pathlib import Path

PLUGIN = Path(__file__).resolve().parent.parent
AGENT = Path(os.environ.get("HERMES_AGENT") or Path.home() / ".hermes/hermes-agent")


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


board = _load("yui_board", PLUGIN / "yui" / "board.py")

try:
    sys.path.insert(0, str(AGENT))
    from hermes_cli import kanban_db as kb  # noqa: E402
except Exception:  # pragma: no cover
    kb = None


def task(i, title, status="todo", priority=0, assignee="yui"):
    return {"id": i, "title": title, "status": status, "priority": priority, "assignee": assignee}


BOARD = [
    task("t_66", "YUI-66 (backlog): reorder mode", "ready", 2),
    task("t_73", "YUI-73: war room panels", "todo", 0),
    task("t_68", "YUI-68 (next): reply to a message", "scheduled", 1),
    task("t_65", "YUI-65: war room timeline", "done", 12),
    task("t_70", "YUI-70: agent controls", "running", 11),
    task("t_fb1", "Yui beta feedback: the gallery X is dead", "todo", 0),
    task("t_fb2", "Yui beta feedback: Done pill covered", "todo", 0),
]


def event(order, board_name="yui", preset="timeline"):
    return {"id": "row-1", "kind": "event", "user_id": "owner", "agent_id": "a1", "body": "[yui] war timeline",
            "meta": {"id": "war", "preset": preset, "value": {"order": order, "board": board_name}}}


class Plan(unittest.TestCase):
    def test_order_of(self):
        self.assertEqual(board.order_of(event(["YUI-73", "YUI-66"])), ("yui", ["YUI-73", "YUI-66"]))
        self.assertIsNone(board.order_of(event(["YUI-73"], preset="storyboard")))
        no_board = event(["YUI-73"])
        del no_board["meta"]["value"]["board"]
        self.assertIsNone(board.order_of(no_board), "an order with no board is an ordinary event")
        self.assertIsNone(board.order_of({**event(["x"]), "kind": "text"}))
        self.assertIsNone(board.order_of(event([])))

    def test_new_order_counts_up_from_the_lowest(self):
        r = board.plan("yui", ["YUI-73", "YUI-68", "YUI-66"], BOARD)
        self.assertEqual(r["order"], ["t_73", "t_68", "t_66"])
        to = {m["id"]: m["to"] for m in r["moves"]}
        # floor 0 (YUI-73), so 2, 1, 0: YUI-73 pulls first. YUI-68 was already 1.
        self.assertEqual(to, {"t_73": 2, "t_66": 0})
        self.assertEqual(r["skipped"], [])

    def test_running_done_unknown_and_ambiguous_stay_put(self):
        r = board.plan("yui", ["YUI-70", "YUI-65", "YUI-99", "Yui beta feedback", "YUI-66", "YUI-66"], BOARD)
        self.assertEqual(r["order"], ["t_66"])
        self.assertEqual([(s["key"], s["why"]) for s in r["skipped"]], [
            ("YUI-70", "running"), ("YUI-65", "done"), ("YUI-99", "not on the board"),
            ("Yui beta feedback", "matches 2 cards"), ("YUI-66", "listed twice")])
        self.assertEqual(r["moves"], [], "one card alone keeps its priority")

    def test_task_id_key_and_card_prefix_boundary(self):
        r = board.plan("yui", ["t_fb2", "t_fb1"], BOARD)
        self.assertEqual(r["order"], ["t_fb2", "t_fb1"])
        self.assertEqual({m["id"]: m["to"] for m in r["moves"]}, {"t_fb2": 1})
        # YUI-6 must not match YUI-66.
        self.assertEqual(board.plan("yui", ["YUI-6"], BOARD)["skipped"][0]["why"], "not on the board")

    def test_a_reorder_keeps_the_slots_it_had(self):
        tasks = [task("t_a", "YUI-54: menu", "ready", 12, assignee=None),
                 task("t_b", "YUI-68: reply", "ready", 11, assignee=None),
                 task("t_c", "YUI-73: panels", "ready", 11, assignee=None),
                 task("t_d", "YUI-61: slash", "ready", 9, assignee=None)]
        r = board.plan("yui", ["YUI-73", "YUI-54", "YUI-68"], tasks)
        # Slots 12, 11, 11 become 13, 12, 11: all still above YUI-61 (9), which was not on screen.
        # YUI-54 already holds 12 and YUI-68 11, so only YUI-73 is written.
        self.assertEqual({m["id"]: m["to"] for m in r["moves"]}, {"t_c": 13})
        # A swap at the top of a gapped queue keeps the gap: 12 and 0 trade places.
        gap = [task("t_x", "YUI-1: x", "ready", 12), task("t_y", "YUI-2: y", "ready", 0),
               task("t_z", "YUI-3: z", "ready", 5)]
        self.assertEqual({m["id"]: m["to"] for m in board.plan("yui", ["YUI-2", "YUI-1"], gap)["moves"]},
                         {"t_y": 12, "t_x": 0})

    def test_unassigned_backlog_cards_count_as_the_boards(self):
        tasks = [task("t_a", "YUI-54: menu", "ready", 0, assignee=None), task("t_b", "YUI-68: reply", "ready", 0)]
        self.assertEqual(board.plan("yui", ["YUI-54", "YUI-68"], tasks)["order"], ["t_a", "t_b"])

    def test_other_assignees_are_not_touched(self):
        tasks = BOARD + [task("t_r1", "AMC-4: docket", "todo", 0, assignee="r0ss")]
        r = board.plan("yui", ["AMC-4", "YUI-66"], tasks)
        self.assertEqual(r["order"], ["t_66"])
        self.assertEqual(r["skipped"][0]["why"], "not on the board")

    def test_reply_and_note(self):
        r = board.plan("yui", ["YUI-73", "YUI-66", "YUI-70"], BOARD)
        self.assertEqual(board.reply(r), "Board order saved: YUI-73, YUI-66. Left in place: YUI-70 (running).")
        self.assertIn("no reply needed", board.note(r))
        self.assertIn("YUI-73, YUI-66", board.note(r))
        self.assertTrue(board.reply(board.plan("yui", ["YUI-99"], BOARD)).startswith("Couldn't reorder the board."))


@unittest.skipIf(kb is None, "hermes-agent not importable")
class RealBoard(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.db = Path(self.dir.name) / "kanban.db"
        with kb.connect_closing(self.db) as conn:
            now = int(time.time())
            for i, t in enumerate(BOARD + [task("t_r1", "AMC-4: docket", "todo", 3, assignee="r0ss"),
                                           task("t_u", "YUI-74: unassigned", "ready", 0, assignee=None)]):
                conn.execute("INSERT INTO tasks (id, title, assignee, status, priority, created_at) "
                             "VALUES (?, ?, ?, ?, ?, ?)",
                             (t["id"], t["title"], t["assignee"], t["status"], t["priority"], now + i))
            conn.commit()

    def tearDown(self):
        self.dir.cleanup()

    def rows(self, sql, *args):
        with kb.connect_closing(self.db) as conn:
            return conn.execute(sql, args).fetchall()

    def test_apply_writes_priority_and_events(self):
        r = board.apply("yui", ["YUI-68", "YUI-73", "YUI-66", "YUI-70"], self.db)
        self.assertEqual(r["order"], ["t_68", "t_73", "t_66"])
        pri = dict(self.rows("SELECT id, priority FROM tasks"))
        self.assertEqual((pri["t_68"], pri["t_73"], pri["t_66"]), (2, 1, 0))
        self.assertEqual((pri["t_70"], pri["t_65"]), (11, 12), "running and done cards keep their priority")
        ev = self.rows("SELECT task_id, payload FROM task_events WHERE kind = 'reprioritized' ORDER BY task_id")
        self.assertEqual([e[0] for e in ev], ["t_66", "t_68", "t_73"])
        self.assertIn('"by": "yui-app"', ev[0][1])
        # The dispatcher's own ordering now follows the saved order.
        queued = [r[0] for r in self.rows("SELECT id FROM tasks WHERE id IN ('t_66','t_68','t_73') "
                                          "ORDER BY priority DESC, created_at ASC")]
        self.assertEqual(queued, ["t_68", "t_73", "t_66"])
        r2 = board.apply("yui", ["YUI-74", "AMC-4", "YUI-68"], self.db)
        self.assertEqual(r2["order"], ["t_u", "t_68"], "an unassigned card moves, another agent's does not")
        self.assertEqual(dict(self.rows("SELECT id, priority FROM tasks"))["t_r1"], 3)

    def test_saving_the_same_order_again_writes_nothing(self):
        board.apply("yui", ["YUI-68", "YUI-73", "YUI-66"], self.db)
        n = len(self.rows("SELECT 1 FROM task_events WHERE kind = 'reprioritized'"))
        r = board.apply("yui", ["YUI-68", "YUI-73", "YUI-66"], self.db)
        self.assertEqual(r["moves"], [])
        self.assertEqual(len(self.rows("SELECT 1 FROM task_events WHERE kind = 'reprioritized'")), n)
        self.assertTrue(board.reply(r).startswith("Board order was already"))


def _adapter_module():
    """adapter.py with the gateway imports stubbed, so its board path runs without a gateway."""
    for name in ("gateway", "gateway.config", "gateway.platforms", "gateway.platforms.base"):
        sys.modules.setdefault(name, types.ModuleType(name))
    cfg, base = sys.modules["gateway.config"], sys.modules["gateway.platforms.base"]
    cfg.Platform = lambda n: n
    cfg.PlatformConfig = object

    class Base:
        def __init__(self, config=None, platform=None):
            self.config = config
    base.BasePlatformAdapter = Base
    for n in ("MessageEvent", "MessageType", "ProcessingOutcome", "SendResult"):
        setattr(base, n, type(n, (), {}))
    pkg = types.ModuleType("yuipkg")
    pkg.__path__ = [str(PLUGIN / "yui")]
    sys.modules["yuipkg"] = pkg
    spec = importlib.util.spec_from_file_location("yuipkg.adapter", PLUGIN / "yui" / "adapter.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules["yuipkg.adapter"] = mod
    spec.loader.exec_module(mod)
    return mod


@unittest.skipIf(kb is None, "hermes-agent not importable")
class AdapterPath(RealBoard):
    """The adapter takes the row, applies it, answers without a turn, and queues no turn."""

    def make(self, user_id="owner"):
        ad = _adapter_module()
        a = ad.YuiAdapter.__new__(ad.YuiAdapter)
        a._remote_ref, a._user_id, a._notes, a._acks = "yui", user_id, {}, set()
        a.marked, a.written = [], []

        async def mark(ids, column):
            a.marked.append((tuple(ids), column))
            return True

        async def write(row):
            a.written.append(row)
            return "sent"
        a._mark, a._write_row = mark, write
        db = self.db
        orig = board.apply
        ad.board.apply = lambda name, keys: orig(name, keys, db)
        return a

    def test_owner_reorders_without_a_turn(self):
        a = self.make()
        took = asyncio.run(a._board_order("a1", event(["YUI-73", "YUI-66"])))
        self.assertTrue(took)
        self.assertEqual(a.written[0]["body"], "Board order saved: YUI-73, YUI-66.")
        self.assertEqual(a.written[0]["meta"]["turn"], ["row-1"], "the reply names the row, so a restart never replays it")
        self.assertIn("row-1", a._acks)
        self.assertIn(("row-1",), [m[0] for m in a.marked])
        self.assertIn("YUI-73, YUI-66", a._notes["a1"][0])
        pri = dict(self.rows("SELECT id, priority FROM tasks"))
        self.assertGreater(pri["t_73"], pri["t_66"])

    def test_someone_else_cannot_reorder(self):
        a = self.make(user_id="someone-else")
        before = self.rows("SELECT id, priority FROM tasks ORDER BY id")
        self.assertTrue(asyncio.run(a._board_order("a1", event(["YUI-73", "YUI-66"]))))
        self.assertEqual(a.written[0]["body"], "Only the owner can reorder this board.")
        self.assertEqual(self.rows("SELECT id, priority FROM tasks ORDER BY id"), before)
        self.assertEqual(a._notes, {})

    def test_another_boards_order_goes_to_the_agent(self):
        a = self.make()
        self.assertFalse(asyncio.run(a._board_order("a1", event(["YUI-73"], board_name="r0ss"))))
        self.assertFalse(asyncio.run(a._board_order("a1", {**event(["YUI-73"]), "kind": "text"})))
        self.assertEqual(a.written, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
