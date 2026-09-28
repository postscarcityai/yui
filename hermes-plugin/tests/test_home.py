"""An agent's home from its Hermes profile (YUI-168, yuigui spec/HOME.md).

    ~/.hermes/hermes-agent/venv/bin/python hermes-plugin/tests/test_home.py

A profile's home.yui (beside its SOUL.md) goes into its Yui thread once, on first
pair: its lines less comments in one fence, as an agent row marked native=home
that sends no push. `hermes yui home` shows it, `--send` writes it again.
"""

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "yui"))
import connector  # noqa: E402

HOME = """# Luna's home
menu shortcut@plan "Plan dinner" say="Plan tonight's dinner"
menu shortcut@cook "What can I cook?" say="What can I cook with what I have?"

>2
list@pantry title=Pantry Rice Eggs +check
save pantry
"""


class Home(unittest.TestCase):
    def test_body_drops_comments_and_blank_lines(self):
        body = connector.home_body(HOME)
        self.assertTrue(body.startswith("```yui\nmenu shortcut@plan"))
        self.assertTrue(body.endswith("save pantry\n```"))
        self.assertNotIn("#", body)
        self.assertNotIn("\n\n", body)
        self.assertIsNone(connector.home_body("# only a comment\n\n"))

    def test_home_row_is_marked_and_the_home_is_quiet(self):
        row = connector.home_row("u1", "a1", connector.home_body(HOME))
        self.assertEqual(row["meta"], {"native": "home"})
        self.assertEqual((row["sender"], row["kind"]), ("agent", "text"))

    def test_home_file_sits_beside_the_soul(self):
        with mock.patch.object(connector, "hermes_root", return_value=Path("/h")):
            self.assertEqual(connector.home_file("luna"), Path("/h/profiles/luna/home.yui"))
            self.assertEqual(connector.home_file("default"), Path("/h/home.yui"))

    def test_send_home_without_a_file_does_nothing(self):
        with tempfile.TemporaryDirectory() as d, mock.patch.object(connector, "hermes_root", return_value=Path(d)), \
                mock.patch.object(connector, "call") as call:
            self.assertEqual(connector.send_home("luna"), (0, {"error": "no_home", "path": os.path.join(d, "profiles/luna/home.yui")}))
            call.assert_not_called()

    def test_send_home_writes_into_its_own_thread_only(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "profiles" / "luna"
            p.mkdir(parents=True)
            (p / "home.yui").write_text(HOME)
            (Path(d) / "profiles" / "nova").mkdir()
            (Path(d) / "profiles" / "nova" / "home.yui").write_text(HOME)
            sess = {"user_id": "u1", "access_token": "t", "agents": [{"id": "x", "remote_ref": "urza", "name": "Urza"},
                                                                     {"id": "a1", "remote_ref": "luna", "name": "Luna"}]}
            sent = {}

            class R:
                status = 201
                def __enter__(self): return self
                def __exit__(self, *a): return False
                def read(self): return b'[{"id": "m1"}]'

            def urlopen(req, timeout=0):
                sent["url"], sent["body"] = req.full_url, req.data
                return R()

            with mock.patch.object(connector, "hermes_root", return_value=Path(d)), \
                    mock.patch.object(connector, "load", return_value={"token": "k"}), \
                    mock.patch.object(connector, "call", return_value=(200, sess)), \
                    mock.patch.object(connector.urllib.request, "urlopen", urlopen):
                self.assertEqual(connector.send_home("luna"), (201, {"message_id": "m1", "agent": "Luna"}))
                self.assertIn(b'"agent_id": "a1"', sent["body"])
                self.assertIn(b'"native": "home"', sent["body"])
                self.assertTrue(sent["url"].endswith("/rest/v1/yui_messages"))
                # No agent of its own: nothing is written into anyone else's thread.
                self.assertEqual(connector.send_home("nova"), (404, {"error": "no_agent", "profile": "nova"}))


if __name__ == "__main__":
    unittest.main()
