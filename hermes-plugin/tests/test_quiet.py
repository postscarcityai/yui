"""Patch-only replies get no push (YUI-75).

    ~/.hermes/hermes-agent/venv/bin/python hermes-plugin/tests/test_quiet.py

A reply whose ```yui fences hold only patches (and bare `>S` focus lines),
with no words around them, changes what is already on screen: the war room
keeping page 2 current. connector.quiet() says so, and the adapter skips the
push for it. Anything that draws or says something still pushes.
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "yui"))
import connector  # noqa: E402


def fence(*lines):
    return "```yui\n" + "\n".join(lines) + "\n```\n"


class Quiet(unittest.TestCase):
    def test_patches_only_are_quiet(self):
        self.assertTrue(connector.quiet(fence(">2", "~need-t_a +lock", '~lane-app "Build 106"')))
        self.assertTrue(connector.quiet(fence('>2 ~mvp 64% sub="14 of 22"')))
        self.assertTrue(connector.quiet("\n" + fence("# refresh", "~need-t_a +lock") + "\n"))

    def test_anything_that_draws_or_speaks_pushes(self):
        self.assertFalse(connector.quiet("Build 106 is up.\n" + fence("~need-t_a +lock")))
        self.assertFalse(connector.quiet(fence(">2", "clear", "card Hi")))
        self.assertFalse(connector.quiet(fence("~need-t_a +lock", "say Done.")))
        self.assertFalse(connector.quiet(fence(">2 save war room")))
        self.assertFalse(connector.quiet(fence()))
        self.assertFalse(connector.quiet("just words"))
        self.assertFalse(connector.quiet(""))


if __name__ == "__main__":
    unittest.main()
