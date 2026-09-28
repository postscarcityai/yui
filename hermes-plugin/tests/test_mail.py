"""yui_mail: Hermes Yui's hand on the mailbox. The tool posts to yui-mail with
Yui's mail key and reads the answer back in plain words; the rules are the
server's.

    python3 hermes-plugin/tests/test_mail.py

Nothing leaves the machine: urlopen is a stand-in that keeps the requests.
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
HOME = Path(tempfile.mkdtemp())
os.environ["YUI_CONNECTOR_FILE"] = str(HOME / "connector.json")
os.environ.pop("YUI_MAIL_KEY", None)
import connector  # noqa: E402
import mail  # noqa: E402


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


class MailTool(unittest.TestCase):
    def setUp(self):
        self.real = mail.urllib.request.urlopen
        (HOME / "mail.json").write_text(json.dumps({"key": "yui_mk_test"}))

    def tearDown(self):
        mail.urllib.request.urlopen = self.real
        os.environ.pop("YUI_MAIL_KEY", None)

    def use(self, fake):
        mail.urllib.request.urlopen = fake
        return fake

    def test_key_from_file_then_env(self):
        self.assertEqual(mail.key(), "yui_mk_test")
        os.environ["YUI_MAIL_KEY"] = "yui_mk_env"
        self.assertEqual(mail.key(), "yui_mk_env")

    def test_no_key_says_so_and_sends_nothing(self):
        (HOME / "mail.json").unlink()
        f = self.use(Fake())
        out = json.loads(mail.tool_handler({"action": "inbox"}))
        self.assertFalse(out["ok"])
        self.assertIn("no mail key", out["text"])
        self.assertEqual(f.sent, [])

    def test_inbox_posts_with_the_mail_key(self):
        f = self.use(Fake(body={"threads": [{"id": "t1", "status": "new", "counterpart": "ana@x.com", "subject": "Hi", "summary": None}]}))
        out = json.loads(mail.tool_handler({"action": "inbox", "status": "new", "q": ""}))
        self.assertTrue(out["ok"])
        self.assertIn("ana@x.com: Hi", out["text"])
        sent = f.sent[0]
        self.assertTrue(sent["url"].endswith("/functions/v1/yui-mail"))
        self.assertEqual(sent["headers"]["Authorization"], "Bearer yui_mk_test")
        self.assertEqual(sent["body"], {"action": "inbox", "status": "new"})  # empty q is dropped

    def test_refusals_read_as_words(self):
        self.use(Fake(status=409, body={"error": "no_promo_consent"}))
        out = json.loads(mail.tool_handler({"action": "send", "to": "a@b.co", "subject": "s", "text": "t"}))
        self.assertFalse(out["ok"])
        self.assertEqual(out["error"], "no_promo_consent")
        self.assertIn("never asked for news", out["text"])

    def test_unknown_action_never_calls(self):
        f = self.use(Fake())
        out = json.loads(mail.tool_handler({"action": "delete_everything"}))
        self.assertFalse(out["ok"])
        self.assertEqual(f.sent, [])

    def test_thread_and_campaign_summaries(self):
        r = {"thread": {"subject": "Invite", "counterpart": "ana@x.com", "status": "handled"},
             "messages": [{"direction": "in", "from_addr": "ana@x.com", "created_at": "2026-09-28T10:00:00Z", "text_body": "Can I try Yui?", "attachments": []},
                          {"direction": "out", "from_addr": "yui@yuigui.com", "sent_by": "yui", "status": "delivered", "created_at": "2026-09-28T10:01:00Z", "text_body": "Yes!", "attachments": []}]}
        s = mail.summary(200, r)
        self.assertIn("Can I try Yui?", s)
        self.assertIn("you (yui, delivered)", s)
        self.assertEqual(mail.summary(200, {"ok": True, "dry_run": True, "would_send": 12}), "A campaign now would go to 12 people.")

    def test_schema_actions_match(self):
        self.assertEqual(mail.SCHEMA["parameters"]["properties"]["action"]["enum"], mail.ACTIONS)


if __name__ == "__main__":
    unittest.main()
