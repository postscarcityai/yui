"""Handoff to Yui from any other channel (YUI-8).

On Telegram (or the CLI, Slack, ...) the user says "send it to Yui", "pull
this up on Yui", or types /yui. The agent then puts the current flow into
its Yui thread as a screen, and the phone gets a push that opens it.

Two hooks do it, so no skill has to be installed on every profile:
  * pre_gateway_dispatch turns "/yui [note]" into a plain handoff request
    before the gateway looks for commands.
  * pre_llm_call adds the how-to, with the channel guide, to the turn when
    the user's message mentions Yui. Nothing is added otherwise, and nothing
    on the Yui channel itself (its platform hint already carries the guide).
"""
import re

from . import adapter

MENTION = re.compile(r"\byui\b", re.IGNORECASE)
SLASH = re.compile(r"^/yui(?:@\w+)?(?:\s+(.*))?$", re.IGNORECASE | re.DOTALL)

REQUEST = "Send this to Yui now so I can pick it up on my phone: {what}."

HOWTO = """[Yui handoff]
The user wants this in the Yui app on their phone. Do it in one step:
call send_message with target "yui" and the content as the message (no
send_message tool? write the message to a file and run
`hermes -p {profile} send --to yui --file <path>`). It lands in
your Yui thread (or the user's main Yui agent's thread if you have none), and
their phone gets a push that opens it. Make it a screen, not a wall of text:
a line or two of plain text, then ```yui fenced Yui Lines for the part they act
on (choose/ask/form/list/timer), per the guide below. Then reply here in one
short line saying it is in Yui. Do not paste the Yui Lines into this chat.

{guide}"""


def rewrite_slash(event=None, **_):
    """/yui [note] -> a handoff request the agent acts on."""
    text = (getattr(event, "text", None) or "").strip()
    m = SLASH.match(text)
    source = getattr(event, "source", None)
    platform = getattr(getattr(source, "platform", None), "value", "")
    if not m or platform == "yui":
        return None
    note = (m.group(1) or "").strip()
    return {"action": "rewrite", "text": REQUEST.format(what=note or "what we are working on right now")}


def inject_howto(user_message=None, platform="", **_):
    if platform == "yui" or not user_message or not MENTION.search(str(user_message)):
        return None
    from . import connector
    return {"context": HOWTO.format(guide=adapter.platform_hint(), profile=connector.current_profile() or "default")}


def slash_command(raw_args: str = "") -> str:
    # Gateways never get here: rewrite_slash turns /yui into a request first.
    return ('Say "send it to Yui" (or /yui in Telegram) and I will put what we are '
            "working on into your Yui thread and ping your phone.")
