"""Slash commands in the composer (YUI-61): the list the plugin reports to Yui.

    ~/.hermes/hermes-agent/venv/bin/python hermes-plugin/tests/test_commands.py

The registry tests read Hermes' real COMMAND_REGISTRY (HERMES_AGENT, default
~/.hermes/hermes-agent) and skip without it. The adapter tests fake the
yui-connect call, so nothing leaves the machine.
"""

import asyncio
import json
import os
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_board import AGENT, PLUGIN, _adapter_module, _load  # noqa: E402

slash = _load("yui_commands", PLUGIN / "yui" / "commands.py")

try:
    sys.path.insert(0, str(AGENT))
    from hermes_cli import commands as hc  # noqa: E402
except Exception:  # pragma: no cover
    hc = None

NAME = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")  # what yui-connect keeps


@unittest.skipIf(hc is None, "hermes-agent not importable")
class Registry(unittest.TestCase):
    def setUp(self):
        self.cmds = slash.registry()
        self.names = [c["name"] for c in self.cmds]

    def test_the_everyday_commands_are_there_with_descriptions(self):
        for name in ("new", "model", "stop", "status", "help", "retry", "undo", "background", "reasoning"):
            self.assertIn(name, self.names)
        new = next(c for c in self.cmds if c["name"] == "new")
        self.assertTrue(new["description"].startswith("Start a new session"))
        self.assertEqual(new["args"], "[name]")
        self.assertNotIn("args", next(c for c in self.cmds if c["name"] == "stop"), "no hint, no key")

    def test_built_ins_come_first_in_registry_order(self):
        order = [c.name for c in hc.COMMAND_REGISTRY if c.name in self.names]
        self.assertEqual(self.names[:len(order)], order)

    def test_terminal_only_and_host_ops_are_left_out(self):
        cli_only = {c.name for c in hc.COMMAND_REGISTRY if not hc._is_gateway_available(c)}
        self.assertTrue(cli_only, "Hermes has CLI-only commands")
        self.assertFalse(cli_only & set(self.names), "a terminal-only command leaked")
        self.assertFalse(slash.HIDDEN & set(self.names), "a hidden command leaked")
        for name in ("sethome", "topic", "restart", "update", "yolo", "yui"):
            self.assertNotIn(name, self.names)

    def test_every_entry_survives_yui_connect(self):
        self.assertEqual(len(self.names), len(set(self.names)), "no duplicates")
        self.assertLessEqual(len(self.cmds), 200)
        self.assertLess(len(json.dumps(self.cmds)), 32768, "fits the column check")
        for c in self.cmds:
            self.assertTrue(NAME.match(c["name"]), c)
            self.assertLessEqual(set(c), {"name", "description", "args"})
            self.assertLessEqual(len(c["description"]), 100)
            self.assertNotIn("\n", c["description"])
            self.assertLessEqual(len(c.get("args", "")), 60)

    def test_aliases_are_not_listed_twice(self):
        self.assertNotIn("reset", self.names, "/reset is /new")
        self.assertNotIn("bg", self.names)

    def test_skills_go_by_their_real_command(self):
        from agent.skill_commands import get_skill_commands
        keys = {k.lstrip("/") for k in get_skill_commands()}
        known = {c.name for c in hc.COMMAND_REGISTRY} | {n for n, _d, _a in hc._iter_plugin_command_entries()}
        rest = [n for n in self.names if n not in known]
        self.assertTrue(rest, "skills are listed")
        self.assertFalse(set(rest) - keys, "every other entry is a skill the gateway dispatches")

    def test_fingerprint_follows_the_list(self):
        self.assertEqual(slash.fingerprint(self.cmds), slash.fingerprint(json.loads(json.dumps(self.cmds))))
        self.assertNotEqual(slash.fingerprint(self.cmds), slash.fingerprint(self.cmds[1:]))


class NoHermes(unittest.TestCase):
    def test_outside_hermes_it_reports_nothing(self):
        real = sys.modules.pop("hermes_cli", None), sys.modules.pop("hermes_cli.commands", None)
        sys.modules["hermes_cli"] = None  # import fails
        try:
            self.assertIsNone(slash.registry())
        finally:
            del sys.modules["hermes_cli"]
            if real[0]:
                sys.modules["hermes_cli"] = real[0]
            if real[1]:
                sys.modules["hermes_cli.commands"] = real[1]


class Report(unittest.TestCase):
    """The gateway sends the list on start, when it serves a new agent and when the list changes."""

    def make(self, cmds):
        ad = _adapter_module()
        a = ad.YuiAdapter.__new__(ad.YuiAdapter)
        a._remote_ref, a._agents, a._commands_sent, a.sent = "yui", {"a1": {"id": "a1"}}, None, []
        self.cmds = cmds
        ad.slash.registry = lambda: self.cmds

        async def call(body):
            a.sent.append(body)
            return {"agents": 1, "commands": len(body["commands"])}
        a._connect_call = call
        return a

    def test_sends_once_then_only_on_change(self):
        a = self.make([{"name": "new", "description": "Start a new session", "args": "[name]"}])
        asyncio.run(a._report_commands())
        asyncio.run(a._report_commands())
        self.assertEqual(len(a.sent), 1, "an unchanged list is not resent every heartbeat")
        self.assertEqual(a.sent[0]["action"], "commands")
        self.assertEqual(a.sent[0]["remote_ref"], "yui")
        self.assertEqual(a.sent[0]["commands"][0]["name"], "new")
        self.cmds = self.cmds + [{"name": "humanizer", "description": "Humanize text"}]
        asyncio.run(a._report_commands())
        self.assertEqual(len(a.sent), 2, "a new skill is reported")
        a._agents["a2"] = {"id": "a2"}
        asyncio.run(a._report_commands())
        self.assertEqual(len(a.sent), 3, "a newly paired agent gets the list")

    def test_no_agents_or_no_registry_sends_nothing(self):
        a = self.make(None)
        asyncio.run(a._report_commands())
        a = self.make([{"name": "new", "description": "x"}])
        a._agents = {}
        asyncio.run(a._report_commands())
        self.assertEqual(a.sent, [])

    def test_a_failed_report_is_retried_and_never_raises(self):
        a = self.make([{"name": "new", "description": "x"}])

        async def boom(body):
            raise RuntimeError("yui-connect commands: 500 None")
        ok = a._connect_call
        a._connect_call = boom
        asyncio.run(a._report_commands())
        self.assertIsNone(a._commands_sent)
        a._connect_call = ok
        asyncio.run(a._report_commands())
        self.assertEqual(len(a.sent), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
