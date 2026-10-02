"""Hermes cron failure lines never show as bubbles.

    python3 hermes-plugin/tests/test_syserror.py
"""

import importlib.util
import unittest
from pathlib import Path

PLUGIN = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("yui_syserror", PLUGIN / "yui" / "syserror.py")
syserror = importlib.util.module_from_spec(spec)
spec.loader.exec_module(syserror)

ERR = "Script execution failed: [Errno 35] Resource temporarily unavailable"
SHOT = [f"⚠️ Cron '{n}' failed: {ERR}" for n in (
    "yui-war-room-asks", "yui-crew-health", "yui-testflight-watch",
    "yui-feedback-watch", "yui-board-sync", "yui-war-room-asks")]


class SysError(unittest.TestCase):
    def test_the_six_lines_render_nothing(self):
        for line in SHOT:
            self.assertTrue(syserror.is_failure(line), line)

    def test_a_run_of_lines_in_one_message(self):
        self.assertTrue(syserror.is_failure("\n".join(SHOT)))

    def test_without_the_emoji_and_bare_script_line(self):
        self.assertTrue(syserror.is_failure(f"Cron 'x' failed: {ERR}"))
        self.assertTrue(syserror.is_failure(ERR))

    def test_traceback(self):
        self.assertTrue(syserror.is_failure('Traceback (most recent call last):\n  File "x.py", line 1, in <module>\nValueError: no'))

    def test_real_replies_stay(self):
        for body in (
            "Done. ⚠️ Heads up: the deploy is slow today.",
            "The cron 'yui-board-sync' failed last night because the disk was full. I freed space and reran it.",
            "⚠️ Build 82 is held. Needs your pick.",
            "Here is your plan.\n```yui\ncard \"Cron failed\" body=\"x\"\n```",
            "",
        ):
            self.assertFalse(syserror.is_failure(body), body)

    def test_mixed_message_stays(self):
        self.assertFalse(syserror.is_failure(SHOT[0] + "\nI will look into it now."))


if __name__ == "__main__":
    unittest.main()
