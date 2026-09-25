"""Group threads on the host (YUI-93): notes on what the other members said.

    ~/.hermes/hermes-agent/venv/bin/python hermes-plugin/tests/test_groups.py

The routing itself is SQL, tested live in supabase/tests/group_test.py.
These need nothing but the plugin source.
"""

import asyncio
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_board import _adapter_module, _load, PLUGIN  # noqa: E402

groups = _load("yui_groups", PLUGIN / "yui" / "groups.py")

G1, G2 = "11111111-0000-0000-0000-000000000001", "11111111-0000-0000-0000-000000000002"


class Threads(unittest.TestCase):
    def test_group_rows_name_their_thread(self):
        rows = [{"meta": {}}, {"thread_id": G1, "meta": {"group": {"thread": G1}}},
                {"meta": {"group": {"thread": G2}}}, {"thread_id": G1}]
        self.assertEqual(groups.threads_in(rows), [G2, G1])

    def test_solo_rows_have_none(self):
        self.assertEqual(groups.threads_in([{"meta": {"mention": {}}}, {"meta": None}, {}]), [])

    def test_at_most_three_newest(self):
        rows = [{"thread_id": str(i)} for i in range(5)]
        self.assertEqual(groups.threads_in(rows), ["2", "3", "4"])


class Notes(unittest.TestCase):
    def test_lines(self):
        rows = [
            {"kind": "asked", "title": "Race week", "to_names": "Sage, Quill", "words": "plan  Saturday"},
            {"kind": "answered", "title": "Race week", "name": "Sage", "words": "Rest Friday. [screen]"},
            {"kind": "answered", "title": "Race week", "name": "Quill", "words": ""},
            {"kind": "stopped", "title": "Race week", "name": "Coach", "words": "Stopped."},
            {"kind": "something new", "title": "Race week", "words": "?"},
        ]
        self.assertEqual(groups.notes(rows), [
            "[yui] note: in Race week the person asked Sage, Quill, not you: plan Saturday",
            "[yui] note: in Race week, Sage answered: Rest Friday. [screen]",
            "[yui] note: in Race week the person pressed Stop. Hand nothing more on for what came before it.",
        ])

    def test_nothing(self):
        self.assertEqual(groups.notes([]), [])


class FakeResponse:
    def __init__(self, rows, status=200):
        self.rows, self.status_code, self.text = rows, status, ""

    def json(self):
        return self.rows


class FakeClient:
    def __init__(self, rows, status=200):
        self.rows, self.status, self.calls = rows, status, []

    async def post(self, url, headers=None, json=None):
        self.calls.append((url, json))
        return FakeResponse(self.rows, self.status)


class AdapterPath(unittest.TestCase):
    def make(self, rows=(), status=200):
        ad = _adapter_module()
        a = ad.YuiAdapter.__new__(ad.YuiAdapter)
        a._cursor, a._client = {"a1": "2026-09-25T00:00:00+00:00"}, FakeClient(list(rows), status)
        a._rest_headers = lambda: {}
        a.saved = 0

        def save():
            a.saved += 1
        a._save_cursor = save
        return ad, a

    def test_notes_since_last_turn_in_that_group(self):
        rows = [{"id": "m1", "created_at": "2026-09-25T01:00:00+00:00", "kind": "answered",
                 "name": "Sage", "title": "Race week", "words": "Rest Friday."}]
        ad, a = self.make(rows)
        got = asyncio.run(a._group_notes("a1", G1, "2026-09-25T02:00:00+00:00"))
        self.assertEqual(got, ["[yui] note: in Race week, Sage answered: Rest Friday."])
        url, body = a._client.calls[0]
        self.assertTrue(url.endswith("/rest/v1/rpc/yui_group_notes"), url)
        self.assertEqual(body, {"agent": "a1", "thread": G1, "since": "2026-09-25T00:00:00+00:00",
                                "upto": "2026-09-25T02:00:00+00:00"})
        self.assertEqual(a._cursor[f"group:a1:{G1}"], "2026-09-25T01:00:00+00:00")
        self.assertEqual(a.saved, 1)
        a._client.rows = []
        asyncio.run(a._group_notes("a1", G1, None))
        self.assertEqual(a._client.calls[1][1]["since"], "2026-09-25T01:00:00+00:00")
        asyncio.run(a._group_notes("a1", G2, None))
        self.assertEqual(a._client.calls[2][1]["since"], "2026-09-25T00:00:00+00:00")  # its own floor per group

    def test_a_failure_is_no_notes(self):
        ad, a = self.make(status=404)
        self.assertEqual(asyncio.run(a._group_notes("a1", G1, None)), [])

        async def boom(*_, **__):
            raise OSError("network down")
        a._client.post = boom
        self.assertEqual(asyncio.run(a._group_notes("a1", G1, None)), [])
        self.assertNotIn(f"group:a1:{G1}", a._cursor)


if __name__ == "__main__":
    unittest.main(verbosity=2)
