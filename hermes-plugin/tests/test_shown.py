"""What the person is looking at when they type (t_53b06721).

    ~/.hermes/hermes-agent/venv/bin/python hermes-plugin/tests/test_shown.py
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_board import _load, PLUGIN  # noqa: E402

shown = _load("yui_shown", PLUGIN / "yui" / "shown.py")

BEFORE_AFTER = ("Guide v40 is live now.\n```yui\nsketch \"Board\" frame=window\nrow \"Site: good\"\n"
                "row \"New feature: needs help\" +hi note=\"example\"\nrow \"Old way\" +x\n"
                "card \"Before and after\" body=\"Guide v40 is live now\" cta=\"See it\" url=https://x.test\n```")


class Plain(unittest.TestCase):
    def test_typed_lines_only(self):
        self.assertTrue(shown.plain("What are you waiting on me for with this?"))
        for t in ("[yui] n1 choose choice=Legs", "[yui] reply to=1 from=agent quote=\"x\"", "/new", "  ", ""):
            self.assertFalse(shown.plain(t), t)


class Headline(unittest.TestCase):
    def test_words_titles_rows(self):
        h = shown.headline(BEFORE_AFTER)
        self.assertIn("Guide v40 is live now.", h)
        self.assertIn("Board", h)
        self.assertIn("New feature: needs help", h)
        self.assertNotIn("Old way", h)  # struck-out rows are the before half

    def test_short(self):
        self.assertLessEqual(len(shown.headline("word " * 500)), shown.NOTE_CHARS)


class Note(unittest.TestCase):
    ASKED = "2026-09-29T23:42:00+00:00"

    def row(self, at, body=BEFORE_AFTER):
        return {"body": body, "created_at": at}

    def test_fresh_message_names_itself(self):
        n = shown.note(self.row("2026-09-29T23:38:00+00:00"), self.ASKED)
        self.assertIn("4 min old", n)
        self.assertIn("Before and after", n)
        self.assertIn("examples", n)
        self.assertIn("Answer about it first", n)

    def test_old_message_gives_no_note(self):
        self.assertIsNone(shown.note(self.row("2026-09-29T21:00:00+00:00"), self.ASKED))

    def test_nothing_shown_no_note(self):
        self.assertIsNone(shown.note(None, self.ASKED))
        self.assertIsNone(shown.note(self.row("2026-09-29T23:40:00+00:00", ""), self.ASKED))
        self.assertIsNone(shown.note({"body": "hi", "created_at": "junk"}, self.ASKED))


if __name__ == "__main__":
    unittest.main()
