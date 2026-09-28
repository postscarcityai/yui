"""yui_tables (YUI-171, yuigui spec/TABLES.md section 8): the Hermes tool posts
the agent's table words to yui-connect /tables and reads the answer back in
plain words. The rules are the server's; here only the call and its reading.

    python3 hermes-plugin/tests/test_tables.py

Nothing leaves the machine: urlopen is a stand-in that keeps the requests.
The live round trip (plugin writes, MCP reads) is supabase/tests/tables_any_agent_e2e.py.
"""
import io
import json
import os
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "yui"))
os.environ["YUI_CONNECTOR_FILE"] = str(Path(tempfile.mkdtemp()) / "connector.json")
import connector  # noqa: E402
import tables  # noqa: E402


class Fake:
    def __init__(self, status=200, body=None):
        self.status, self.body, self.sent = status, body or {}, []

    def __call__(self, req, timeout=None):
        self.sent.append({"url": req.full_url, "headers": dict(req.header_items()), "body": json.loads(req.data)})
        if self.status != 200:
            raise urllib.error.HTTPError(req.full_url, self.status, "x", {}, io.BytesIO(json.dumps(self.body).encode()))
        outer = self

        class R:
            status = 200
            def read(self): return json.dumps(outer.body).encode()
            def __enter__(self): return self
            def __exit__(self, *a): return False
        return R()


ROWS = {"table": "foods", "cols": [{"name": "Food", "type": "text"}, {"name": "Cal", "type": "number", "unit": "kcal"}],
        "keys": ["oats", None], "rows": [["Oats", 300], ["Toast", 80]], "count": 3}


class TablesTool(unittest.TestCase):
    def setUp(self):
        connector.save({"token": "yui_ct_test"})
        os.environ.pop("YUI_REMOTE_REF", None)
        os.environ["HERMES_PROFILE"] = "basil"
        self._urlopen = tables.urllib.request.urlopen

    def tearDown(self):
        tables.urllib.request.urlopen = self._urlopen

    def fake(self, *a, **k):
        f = Fake(*a, **k)
        tables.urllib.request.urlopen = f
        return f

    def test_posts_lines_for_this_profile_with_the_machine_token(self):
        f = self.fake(body={"agent": "Basil", "ok": ["query foods"], "failed": [], "results": [ROWS], "held": None,
                            "settled": [], "tables": []})
        out = json.loads(tables.tool_handler({"lines": "query foods"}))
        sent = f.sent[0]
        self.assertTrue(sent["url"].endswith("/functions/v1/yui-connect/tables"))
        self.assertEqual(sent["headers"]["Authorization"], "Bearer yui_ct_test")
        self.assertEqual(sent["body"], {"agent": "basil", "lines": "query foods"})
        self.assertTrue(out["ok"])
        self.assertIn("1 line done.", out["text"])
        self.assertIn("foods\nkey | Food | Cal (kcal)\noats | Oats | 300\n | Toast | 80", out["text"])
        self.assertIn("(3 rows match; the first 2 are here.)", out["text"])
        self.assertEqual(out["results"][0]["rows"][0], ["Oats", 300])

    def test_remote_ref_overrides_the_profile(self):
        os.environ["YUI_REMOTE_REF"] = "chef,other"
        f = self.fake(body={"ok": [], "failed": [], "results": [], "settled": [], "tables": []})
        tables.call("query foods")
        self.assertEqual(f.sent[0]["body"]["agent"], "chef")

    def test_refused_lines_and_held_deletes_read_as_words(self):
        self.fake(body={"ok": [], "failed": [{"line": "query nope", "error": "No table called nope yet"}],
                        "results": [], "held": {"id": "del-ab12", "ask": "Delete Oats from foods?"},
                        "settled": [{"id": "del-zz", "choice": "Delete", "deleted": 1}], "tables": []})
        text = json.loads(tables.tool_handler({"lines": "query nope\nput foods oats +delete"}))["text"]
        self.assertIn("The person tapped Delete on del-zz: 1 gone.", text)
        self.assertIn('Refused "query nope": No table called nope yet.', text)
        self.assertIn('Nothing deleted yet: the person sees "Delete Oats from foods?" with Delete or Keep.', text)

    def test_no_lines_lists_what_it_holds(self):
        self.fake(body={"ok": [], "failed": [], "results": [], "settled": [],
                        "tables": [{"name": "foods", "rows": 44, "cols": ["Food", "Cal"]}]})
        text = json.loads(tables.tool_handler({}))["text"]
        self.assertEqual(text, "You hold: foods (44 rows: Food, Cal)")

    def test_errors_write_nothing_and_say_why(self):
        self.fake(429, {"error": "rate_limited"})
        out = json.loads(tables.tool_handler({"lines": "query foods"}))
        self.assertFalse(out["ok"])
        self.assertIn("Too many tables calls", out["text"])
        self.fake(400, {"error": "too_many_lines", "message": "51 lines in one call; 50 at most. Nothing was written."})
        self.assertIn("50 at most", json.loads(tables.tool_handler({"lines": "x"}))["text"])

    def test_not_paired(self):
        connector.save({})
        f = self.fake()
        out = json.loads(tables.tool_handler({"lines": "query foods"}))
        self.assertEqual(f.sent, [])
        self.assertEqual(out["error"], "not_paired")

    def test_cli_has_tables(self):
        import argparse
        ap = argparse.ArgumentParser()
        connector.build_parser(ap)
        a = ap.parse_args(["tables", "query foods", "--json"])
        self.assertEqual((a.lines, a.json, a.fn), ("query foods", True, tables.cmd_tables))

    def test_schema_is_a_tool(self):
        self.assertEqual(tables.SCHEMA["name"], "yui_tables")
        self.assertIn("+delete", tables.SCHEMA["description"])
        self.assertEqual(list(tables.SCHEMA["parameters"]["properties"]), ["lines"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
