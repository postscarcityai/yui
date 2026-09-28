#!/usr/bin/env python3
"""Tables in the Python webhook bridge, offline (TABLES.md section 8).

A fake Yui (session, yui_messages, /tables) and a stub agent run on localhost;
the bridge talks to them through $YUI_SUPABASE_URL. Nothing touches the live
backend.

    python3 adapters/webhook/tests/test_tables_offline.py
"""
import json, os, sys, tempfile, threading, unittest, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

AGENT = "11111111-2222-3333-4444-555555555555"


class Fake:
    """Yui's side and the agent's side, both scripted per test."""

    def __init__(self):
        self.reset()

    def reset(self):
        self.inbox = []        # the person's rows waiting for the bridge
        self.saved = []        # rows the bridge wrote
        self.tables_calls = []
        self.tables_answer = lambda body: (200, {})
        self.posts = []        # what the agent got
        self.agent_answers = []


fake = Fake()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, status, body=None):
        raw = json.dumps(body).encode() if body is not None else b""
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def body(self):
        n = int(self.headers.get("content-length") or 0)
        return json.loads(self.rfile.read(n)) if n else None

    def do_GET(self):
        q = self.path
        if "sender=eq.user" in q:
            return self.send(200, [r for r in fake.inbox if not r.get("handled_at")])
        return self.send(200, [])  # nothing answered before

    def do_PATCH(self):
        b = self.body()
        ids = self.path.split("id=in.(")[1].split(")")[0].split(",")
        for r in fake.inbox:
            if r["id"] in ids:
                r.update(b)
        self.send(204)

    def do_POST(self):
        path, b = urlparse(self.path).path, self.body()
        if path.endswith("/yui-connect/tables"):
            assert self.headers["authorization"] == "Bearer yui_ct_test"
            fake.tables_calls.append(b)
            return self.send(*fake.tables_answer(b))
        if path.endswith("/yui-connect"):
            if b["action"] == "session":
                return self.send(200, {"access_token": "at", "user_id": "u1", "expires_at": "2099-01-01T00:00:00Z",
                                       "agents": [{"id": AGENT, "name": "Basil", "handle": "basil", "remote_ref": "basil"}],
                                       "guide": {"version": "v", "body": "g"}})
            return self.send(200, {})
        if path.endswith("/yui-push"):
            return self.send(200, {})
        if path.endswith("/rest/v1/yui_messages"):
            fake.saved.append(b)
            return self.send(201)
        self.send(404, {"error": "no"})


class AgentHandler(Handler):
    def do_POST(self):
        fake.posts.append({"body": self.body(), "turn_key": self.headers["x-yui-turn"]})
        self.send(200, fake.agent_answers.pop(0) if fake.agent_answers else {})


def serve(h):
    s = ThreadingHTTPServer(("127.0.0.1", 0), h)
    threading.Thread(target=s.serve_forever, daemon=True).start()
    return s


yui_srv, agent_srv = serve(Handler), serve(AgentHandler)
os.environ["YUI_SUPABASE_URL"] = f"http://127.0.0.1:{yui_srv.server_port}"
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "python"))
import yui_webhook as yw  # noqa: E402  (after the env var: the module reads it on import)

yw.log = lambda msg: None


def row(body, meta=None):
    return {"id": str(uuid.uuid4()), "agent_id": AGENT, "body": body, "kind": "text", "meta": meta,
            "created_at": "2026-09-27T10:00:00Z", "delivered_at": None}


class TablesTest(unittest.TestCase):
    def setUp(self):
        fake.reset()
        self.dir = tempfile.TemporaryDirectory()
        path = Path(self.dir.name) / "webhook.json"
        path.write_text(json.dumps({"token": "yui_ct_test", "floors": {AGENT: "2026-01-01T00:00:00Z"}}))
        self.state_path = path
        self.bridge = yw.Bridge(yw.State(path), f"http://127.0.0.1:{agent_srv.server_port}/")
        self.bridge.session()

    def tearDown(self):
        self.dir.cleanup()

    def turn(self, body, meta=None):
        fake.inbox.append(row(body, meta))
        self.bridge.run_turns()

    def bodies(self):
        return [r["body"] for r in fake.saved]

    def test_tables_and_reply_result_on_next_post(self):
        fake.agent_answers = [{"reply": "Logged.", "tables": "put meals Food=Oats Cal=300"}, {"reply": "ok"}]
        fake.tables_answer = lambda b: (200, {"ok": ["put meals"], "failed": [], "results": [], "held": None,
                                              "settled": [], "tables": [{"name": "meals", "rows": 1}]})
        self.turn("log oats")
        self.assertEqual(fake.tables_calls, [{"agent": AGENT, "lines": "put meals Food=Oats Cal=300"}])
        self.assertEqual(self.bodies(), ["Logged."])
        self.assertEqual(len(fake.posts), 1)
        self.assertNotIn("tables", fake.posts[0]["body"])
        # kept on disk, so a restart still hands it over
        kept = json.loads(self.state_path.read_text())["tables"][AGENT]
        self.assertEqual(kept, {"results": [], "failed": [], "held": None, "tables": [{"name": "meals", "rows": 1}]})
        self.bridge = yw.Bridge(yw.State(self.state_path), self.bridge.webhook)
        self.bridge.session()
        self.turn("thanks")
        self.assertEqual(fake.posts[1]["body"]["tables"], kept)
        self.assertEqual(json.loads(self.state_path.read_text())["tables"], {})

    def test_tables_alone_is_a_read(self):
        res = [{"table": "meals", "cols": ["Food", "Cal"], "keys": ["r1"], "rows": [["Oats", 300]], "count": 1}]
        note = "[yui] Your tables:\nmeals: Oats, 300"
        fake.agent_answers = [{"tables": "query meals"}, {"reply": "You ate oats."}]
        fake.tables_answer = lambda b: (200, {"ok": ["query meals"], "failed": [], "results": res, "held": None,
                                              "settled": [], "tables": [], "note": note})
        self.turn("what did I eat")
        self.assertEqual(len(fake.posts), 2)
        first, second = fake.posts[0], fake.posts[1]
        self.assertEqual(second["body"]["turn"], first["body"]["turn"])
        self.assertNotEqual(second["turn_key"], first["turn_key"])
        self.assertEqual(second["body"]["round"], 1)
        self.assertEqual(second["body"]["tables"], {"results": res, "failed": [], "held": None, "tables": [], "note": note})
        self.assertEqual(second["body"]["text"], "what did I eat\n" + note)
        self.assertEqual(self.bodies(), ["You ate oats."])
        self.assertTrue(fake.inbox[0].get("handled_at"))

    def test_reads_stop_after_two_rounds(self):
        fake.agent_answers = [{"tables": "query meals"}] * 4
        fake.tables_answer = lambda b: (200, {"results": [], "failed": [], "note": "[yui] Your tables: none"})
        self.turn("loop")
        self.assertEqual(len(fake.posts), 3)
        self.assertEqual(self.bodies(), [])
        self.assertTrue(fake.inbox[0].get("handled_at"))
        self.assertIn(AGENT, json.loads(self.state_path.read_text())["tables"])

    def test_reply_with_put_saves_server_text(self):
        reply = "Logged.\n```yui\nput meals Food=Oats Cal=300\n```"
        fake.agent_answers = [{"reply": reply}]
        fake.tables_answer = lambda b: (200, {"text": "Logged.", "failed": [], "wrote": 1, "held": None,
                                              "settled": [], "tables": []})
        self.turn("log oats")
        self.assertEqual(fake.tables_calls, [{"agent": AGENT, "reply": reply}])
        self.assertEqual(self.bodies(), ["Logged."])
        self.assertEqual(len(fake.posts), 1)

    def test_plain_reply_makes_no_call(self):
        fake.agent_answers = [{"reply": "I would put it on the table later.\n```yui\nchoose \"Pick\" A|B\n```"}]
        self.turn("hi")
        self.assertEqual(fake.tables_calls, [])
        self.assertEqual(len(self.bodies()), 1)

    def test_read_reply_saves_nothing_and_posts_again(self):
        reply = "```tables\nquery meals\n```"
        note = "[yui] Your tables:\nmeals: Oats"
        fake.agent_answers = [{"reply": reply}, {"reply": "Oats."}]
        fake.tables_answer = lambda b: (200, {"read": True, "text": "", "ok": ["query meals"], "failed": [],
                                              "results": [{"table": "meals", "rows": [["Oats"]]}], "note": note,
                                              "tables": [{"name": "meals"}]})
        self.turn("what did I eat")
        self.assertEqual(fake.tables_calls, [{"agent": AGENT, "reply": reply}])
        self.assertEqual(len(fake.posts), 2)
        self.assertEqual(fake.posts[1]["body"]["tables"],
                         {"results": [{"table": "meals", "rows": [["Oats"]]}], "failed": [], "note": note,
                          "tables": [{"name": "meals"}]})
        self.assertEqual(self.bodies(), ["Oats."])

    def test_hand_over_line_comes_first(self):
        line = "[yui] tables foods(3 rows: Food, Cal)"
        fake.agent_answers = [{}]
        self.turn("hello", {"tables": line})
        self.assertEqual(fake.posts[0]["body"]["text"], f"{line}\nhello")

    def test_tables_failure_saves_the_reply(self):
        reply = "put meals Food=Oats\nLogged."
        fake.agent_answers = [{"reply": reply}]
        fake.tables_answer = lambda b: (500, {"error": "boom"})
        self.turn("log oats")
        self.assertEqual(len(fake.tables_calls), 1)
        self.assertEqual(self.bodies(), [reply])
        self.assertTrue(fake.inbox[0].get("handled_at"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
