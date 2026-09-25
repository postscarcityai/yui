"""The /commands this profile accepts, as the Yui composer suggests them (YUI-61).

Spec: yuigui/spec/AGENTS.md "Commands". The gateway reports the list to
`yui-connect` (action=commands) when it starts, when a profile is paired and
whenever the list changes (checked on every heartbeat), and the app shows it
when the person types / at the start of the composer.

The list is Hermes' own: the gateway-available built-ins from
`hermes_cli.commands.COMMAND_REGISTRY`, then plugin commands, then skills, the
same sources the Telegram menu and Discord's picker draw from. Commands that
make no sense from a phone thread (Telegram topics, home channel, gateway ops,
updates) are left out. Outside Hermes (the plugin's CLI run as a script) the
list is None: report nothing rather than a wrong list.
"""
from __future__ import annotations

import hashlib
import json

# Gateway-available, but not something to offer from the Yui thread.
HIDDEN = frozenset({
    "start",          # a platform's start ping, never typed
    "topic",          # Telegram DM topics
    "sethome",        # a Yui profile's thread is always its home channel
    "platform",       # pausing gateway platforms is host ops
    "restart",        # restarts the gateway this thread runs on
    "update",         # updates Hermes on the host
    "debug",          # uploads host logs
    "codex-runtime",  # a host runtime switch
    "footer",         # the runtime footer is for text channels
    "yolo",           # turns off every approval: never one tap away
    "commands",       # the paged text list; the suggestions replace it
    "yui",            # hand off to Yui, from inside Yui
})


def _entry(name: str, description: str, args: str = "") -> dict:
    e = {"name": name, "description": " ".join((description or "").split())[:100]}
    if args.strip():
        e["args"] = args.strip()[:60]
    return e


def registry() -> list[dict] | None:
    """[{name, description, args?}] in the order the composer lists them, or None outside Hermes."""
    try:
        from hermes_cli import commands as hc
    except Exception:
        return None
    try:
        gates = hc._resolve_config_gates()
        out, taken = [], set()
        for c in hc.COMMAND_REGISTRY:
            if c.name in HIDDEN or not hc._is_gateway_available(c, gates):
                continue
            out.append(_entry(c.name, c.description, c.args_hint))
            taken.add(c.name)
            taken.update(c.aliases)
        taken |= HIDDEN
        # Plugin commands first, then skills (alphabetical), as on Telegram and Discord.
        plugin_args = {n: a for n, _d, a in hc._iter_plugin_command_entries()}
        extra, _hidden = hc._collect_gateway_skill_entries(
            platform="yui", max_slots=150, reserved_names=set(taken), desc_limit=100)
        for name, desc, key in extra:
            # A skill goes by its real /key: a name clamped for Telegram's
            # 32 characters would not dispatch. Longer ones are left out.
            name = key.lstrip("/") if key else name
            if name in taken or len(name) > 32:
                continue
            out.append(_entry(name, desc, plugin_args.get(name, "")))
            taken.add(name)
        return out
    except Exception:
        return None


def fingerprint(cmds: list[dict] | None) -> str:
    return hashlib.sha256(json.dumps(cmds, sort_keys=True).encode()).hexdigest()[:16]
