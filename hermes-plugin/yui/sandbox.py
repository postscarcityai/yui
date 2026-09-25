"""Client-safe check for shared agents (YUI-95, spec yuigui/spec/AGENTS.md "Client-safe").

A shared agent talks to someone who is not its owner, on the owner's machine.
Each gateway reports its profile's sandbox with the heartbeat; yui-connect
marks the agent client_safe only when all five rules pass, and grant.py and
the database refuse to share any other agent. Before a turn for anyone but the
owner, the adapter runs report() again: if it no longer passes, the turn does
not run.

    report(cfg, profile, env_keys)  -> {"terminal", "files", "reach", "memory",
                                        "runner", "profile", "extra_keys"}
    failures(report)                -> [] when client-safe, else one line per broken rule

Anything this module can't be sure of counts as unsafe. Stdlib only, so
grant.py can load it without Hermes. yui-connect's clientSafe() mirrors failures().
"""
from __future__ import annotations

import ipaddress
import os
from pathlib import Path
from typing import Iterable, Optional
from urllib.parse import urlparse

SHELL_TOOLS = {"terminal", "execute_code", "process", "read_terminal", "close_terminal"}
FILE_TOOLS = {"read_file", "write_file", "patch", "search_files"}
# Tools that reach past the agent's own conversation: other people, the owner's
# accounts, the rest of the host.
REACH = {
    "browser": lambda t: t.startswith("browser_"),
    "computer use": lambda t: t == "computer_use",
    "delegation": lambda t: t == "delegate_task",
    "cron": lambda t: t == "cronjob",
    "kanban": lambda t: t.startswith("kanban_"),
    "skill editing": lambda t: t == "skill_manage",
    "messaging": lambda t: t in ("send_message", "send_message_tool"),
    "home assistant": lambda t: t.startswith("ha_"),
}
MEMORY_TOOLS = {"memory", "session_search"}
CONTAINED = {"docker", "modal", "singularity", "daytona"}
REMOTE = {"ssh"}
# Keys a profile may hold for its own model; anything else in .env is the owner's.
MODEL_KEYS = {"OPENROUTER_API_KEY", "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "NOUS_API_KEY", "GEMINI_API_KEY",
              "GOOGLE_API_KEY", "DEEPSEEK_API_KEY", "GROQ_API_KEY", "MISTRAL_API_KEY", "XAI_API_KEY",
              "CUSTOM_API_KEY", "TOGETHER_API_KEY", "FIREWORKS_API_KEY"}


def _tools(cfg: dict) -> Optional[set]:
    """The tools the profile's agent gets on the Yui channel, or None if unknown."""
    names = ((cfg.get("platform_toolsets") or {}).get("yui")
             if isinstance(cfg.get("platform_toolsets"), dict) else None)
    if names is None:
        names = cfg.get("toolsets")
    if names is None:
        names = ["hermes-cli"]  # Hermes' default: everything
    if isinstance(names, str):
        names = [names]
    try:
        import toolsets  # Hermes; absent when grant.py loads this module
        return set(toolsets.resolve_multiple_toolsets(list(names)))
    except Exception:
        return None


def _loopback(url: str) -> bool:
    host = (urlparse(url).hostname or "").lower()
    if host in ("localhost", ""):
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def report(cfg: dict, profile: Optional[str], env_keys: Iterable[str] = ()) -> dict:
    tools = _tools(cfg)
    known = tools is not None
    tools = tools or set()
    backend = str(((cfg.get("terminal") or {}).get("backend")) or "local").lower()

    if known and not tools & SHELL_TOOLS:
        terminal = "off"
    elif backend in CONTAINED:
        terminal = "container"
    elif backend in REMOTE:
        terminal = "remote"
    else:
        terminal = "local"

    if known and not tools & FILE_TOOLS:
        files = "off"
    elif backend in CONTAINED | REMOTE:
        files = "sandbox"  # Hermes' file tools run on the terminal backend
    else:
        files = "host"

    reach = sorted(name for name, hit in REACH.items() if any(hit(t) for t in tools))
    if not known:
        reach.append("unknown tools")
    if cfg.get("mcp_servers"):
        reach.append("mcp servers")

    mem_cfg = cfg.get("memory") if isinstance(cfg.get("memory"), dict) else {}
    # Hermes injects memory into every turn while it is enabled, tool or not;
    # session_search reads every past session, whoever it was with.
    memory_on = (mem_cfg.get("memory_enabled", True) is not False
                 or mem_cfg.get("user_profile_enabled", True) is not False
                 or bool(tools & MEMORY_TOOLS))
    # Hermes has no per-person memory yet, so the only passing answer is off.
    memory = "off" if not memory_on and known else "shared"

    model = cfg.get("model") if isinstance(cfg.get("model"), dict) else {}
    base = str(model.get("base_url") or "")
    # A model on this machine may be an agent with a shell (the Claude Code shim is).
    runner = "cli-agent" if (base and _loopback(base)) else "api"

    extra = sorted(k for k in env_keys if k not in MODEL_KEYS and not k.startswith("YUI_"))
    return {
        "terminal": terminal,
        "files": files,
        "reach": reach,
        "memory": memory,
        "runner": runner,
        "profile": "own" if profile and profile != "default" else "shared",
        "extra_keys": len(extra),
    }


def failures(r: Optional[dict]) -> list[str]:
    """One plain line per rule the report breaks. [] = client-safe."""
    if not isinstance(r, dict) or not r:
        return ["no sandbox report from its host yet"]
    out = []
    if r.get("profile") != "own":
        out.append("profile: not its own Hermes profile")
    if (r.get("extra_keys") or 0) > 0:
        out.append(f"keys: {r.get('extra_keys')} in its .env beyond its model key")
    if r.get("terminal") not in ("off", "container", "remote"):
        out.append("terminal: local shell")
    if r.get("files") not in ("off", "sandbox"):
        out.append("files: the host's files")
    reach = r.get("reach")
    if not isinstance(reach, list) or reach:
        out.append("reach: " + (", ".join(map(str, reach)) if isinstance(reach, list) else "unknown"))
    if r.get("memory") not in ("off", "per-user"):
        out.append("memory: shared between people")
    if r.get("runner") != "api":
        out.append("runner: a local agent with a shell")
    return out


def env_keys(home: Path) -> list[str]:
    """Names (never values) of the keys in a profile's .env."""
    try:
        lines = (home / ".env").read_text().splitlines()
    except OSError:
        return []
    return [ln.split("=", 1)[0].strip().removeprefix("export ").strip()
            for ln in lines if "=" in ln and not ln.lstrip().startswith("#")]


def current() -> dict:
    """This gateway's own report, from its live config. Never raises."""
    try:
        from hermes_cli.config import load_config
        cfg = load_config() or {}
    except Exception:
        return {"terminal": "local", "files": "host", "reach": ["unknown config"], "memory": "shared",
                "runner": "cli-agent", "profile": "shared", "extra_keys": 0}
    from . import connector
    home = Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")
    return report(cfg, connector.current_profile(), env_keys(home))
