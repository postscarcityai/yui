"""The working row says what the agent is doing (YUI-63 step 2). Spec: yuigui
spec/YL.md section 5, The working row.

While a turn runs, the app shows one working row: the agent's face, a working
word and the seconds. A `doing` line puts a few plain words there instead, and
a thin bar when it carries a step (`doing "Reading your calendar" 2/5`).

The host never stores a doing as a message. Mid-turn it writes the newest one
onto the person's rows that turn answers (yui_messages.doing, migration
20260926010000_yui_doing.sql): no new row, no push, no event. The app reads it
while it waits. The reply ends the working row as it always has.

Where the words come from:
  * the agent's own `doing` lines, in anything it sends during the turn
    (interim messages). A message that was only doing lines is not written at
    all; doing lines anywhere else are taken out of the body, so an app never
    shows one as an Update chip;
  * the agent's tool calls (pre_tool_call), mapped to plain words
    ("Searching the web"), never tool names, ids or file names.

Only to a phone at or above yui_limits doing_min_build (unknown counts as too
old); an older app keeps Pondering. About one write a second per thread: the
newest wins and the last one always goes.
"""
import asyncio
import re
import threading
import time
import weakref
from typing import Optional, Tuple, Union

FENCE = re.compile(r"```yui([^\n]*)\n(.*?)```", re.S)
LINE = re.compile(r"^\s*(?:>\S+\s+)?doing(?:\s|$)")
TOKEN = re.compile(r'"(?:[^"\\]|\\.)*"|\S+')
STEP = re.compile(r"^(\d+)/(\d+)$")
FLAG = re.compile(r"^\+[a-z][\w-]*$", re.I)
KEY = re.compile(r"^[\w-]+=")

OFF = "off"  # `doing off`: the working word comes back
EVERY = 1.0  # seconds between writes to one thread
MAX_TEXT = 80  # the app shows one line; the host keeps the column small

# yui_limits doing_min_build, from the adapter's last session. None: not read yet.
LIMIT = {"min_build": None}

Doing = Union[dict, str, None]  # props, OFF, or None (no doing line at all)


def allowed(build: Optional[int], min_build: Optional[int] = None) -> bool:
    """True when a doing may go to this phone: its build draws the working row's words."""
    min_build = LIMIT["min_build"] if min_build is None else min_build
    return build is not None and min_build is not None and build >= min_build


def parse(line: str) -> Optional[Union[dict, str]]:
    """One `doing` line as yl.mjs doingLine reads it: props, OFF, or None for an error."""
    body = re.sub(r"^\s*(?:>\S+\s+)?", "", line.rstrip("\r"))
    toks = TOKEN.findall(body)[1:]  # after `doing`
    if "#" in toks:  # a "#" token followed by space or the end is a comment
        toks = toks[:toks.index("#")]
    if len(toks) == 1 and toks[0] == "off":
        return OFF
    quoted = [t.startswith('"') and t.endswith('"') and len(t) >= 2 for t in toks]
    if any(not q and (KEY.match(t) or FLAG.match(t)) for t, q in zip(toks, quoted)):
        return None
    step = None
    if toks and not quoted[-1] and "|" not in toks[-1]:
        m = STEP.match(toks[-1])
        if m:
            step = (int(m.group(1)), int(m.group(2)))
            toks, quoted = toks[:-1], quoted[:-1]
    words = [t[1:-1].replace('\\"', '"') if q else t for t, q in zip(toks, quoted)]
    text = " ".join(w for w in words if w)
    if not text and step is None:
        return None
    props: dict = {"text": text[:MAX_TEXT].rstrip()} if text else {}
    if step:
        n, m = step
        if m < 1 or n > m:
            return None
        props["step"], props["of"] = n, m
    return props


def split(body: str) -> Tuple[str, Doing]:
    """(the body without its doing lines, the newest doing in it). Fences left
    empty go too. The doing is None when the body had no valid doing line."""
    if "```yui" not in (body or "") or "doing" not in body:
        return body, None
    now: Doing = None

    def one(m: re.Match) -> str:
        nonlocal now
        kept = []
        for ln in m.group(2).split("\n"):
            if LINE.match(ln):
                d = parse(ln)
                if d is not None:
                    now = d
            else:
                kept.append(ln)
        if not any(ln.strip() for ln in kept):
            return ""
        return f"```yui{m.group(1)}\n" + "\n".join(kept) + "```"

    out = FENCE.sub(one, body)
    if out == body:
        return body, None
    return re.sub(r"\n{3,}", "\n\n", out).strip(), now


# -- tool calls, in plain words --------------------------------------------

TOOL_WORDS = {
    "web_search": "Searching the web",
    "web_extract": "Reading a web page",
    "read_file": "Reading a file",
    "search_files": "Looking through files",
    "write_file": "Writing it down",
    "patch": "Making an edit",
    "terminal": "Running a command",
    "process": "Checking on a job",
    "execute_code": "Running some code",
    "memory": "Checking my notes",
    "session_search": "Looking back at our chats",
    "skill_view": "Checking how to do this",
    "skills_list": "Checking how to do this",
    "skill_manage": "Updating what I know",
    "delegate_task": "Handing part of this to a helper",
    "todo": "Planning the steps",
    "vision_analyze": "Looking at the picture",
    "image_generate": "Making an image",
    "text_to_speech": "Recording audio",
    "cronjob": "Setting up a schedule",
    "send_message": "Sending a message",
    "yui_propose": "Drafting a change",
}
TOOL_PREFIXES = (("browser_", "Using the browser"), ("kanban_", "Checking the board"),
                 ("mcp_", "Using a connected app"), ("ha_", "Checking your home"))


def tool_words(name: str) -> Optional[str]:
    """Plain words for a tool call, or None to keep the working word."""
    name = name or ""
    if name in TOOL_WORDS:
        return TOOL_WORDS[name]
    return next((w for p, w in TOOL_PREFIXES if name.startswith(p)), None)


# -- hooks: which Yui thread a tool call belongs to ---------------------------

_lock = threading.Lock()
SESSIONS: dict = {}  # Hermes session id -> the Yui user whose turn it is
ADAPTERS: "weakref.WeakSet" = weakref.WeakSet()


def remember_session(session_id: str = "", platform: str = "", sender_id: str = "", **_) -> None:
    """pre_llm_call: note which Hermes sessions are Yui turns, and for whom."""
    if platform == "yui" and session_id and sender_id:
        with _lock:
            SESSIONS[session_id] = sender_id
            while len(SESSIONS) > 200:
                SESSIONS.pop(next(iter(SESSIONS)))
    return None


def on_tool(tool_name: str = "", session_id: str = "", **_) -> None:
    """pre_tool_call: a Yui turn's tool call becomes a doing (never blocks the tool)."""
    try:
        with _lock:
            user = SESSIONS.get(session_id)
        words = tool_words(tool_name)
        if not user or not words:
            return None
        for a in list(ADAPTERS):
            a.doing_from_tool(user, {"text": words})
    except Exception:
        pass
    return None


# -- the writer --------------------------------------------------------------

class Writer:
    """Newest-wins, about one write a second per thread. `write(key, value)` is
    a coroutine that puts value (props, or None for off) on the turn's rows."""

    def __init__(self, write, every: float = EVERY, clock=time.monotonic):
        self._write = write
        self._every = every
        self._clock = clock
        self._want: dict = {}   # key -> props or None
        self._sent: dict = {}   # key -> (value, at)
        self._tasks: dict = {}  # key -> pending task

    def note(self, key: str, value: Doing) -> None:
        if value is None:
            return
        self._want[key] = None if value == OFF else value
        if key in self._tasks and not self._tasks[key].done():
            return  # the pending write takes the newest
        last = self._sent.get(key)
        wait = 0.0 if not last else max(0.0, self._every - (self._clock() - last[1]))
        self._tasks[key] = asyncio.ensure_future(self._flush(key, wait))

    async def _flush(self, key: str, wait: float) -> None:
        if wait:
            await asyncio.sleep(wait)
        value = self._want.pop(key, None)
        last = self._sent.get(key)
        if last and last[0] == value:
            return
        self._sent[key] = (value, self._clock())
        await self._write(key, value)

    def end(self, key: str) -> None:
        """The turn is over: drop what waits, so nothing lands on a finished row."""
        t = self._tasks.pop(key, None)
        if t and not t.done():
            t.cancel()
        self._want.pop(key, None)
        self._sent.pop(key, None)
