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
    ("Searching the web"), never tool names, ids or file names;
  * on the claude shim (127.0.0.1:8765), where Claude Code runs the tools and
    Hermes sees none of them: the turn's prompt carries a tag, the shim writes
    the newest tool name to <shim>/doing/<tag>.json, and a poller here maps it
    to the same plain words (YUI-63 step 3).

Only to a phone at or above yui_limits doing_min_build (unknown counts as too
old); an older app keeps Pondering. About one write a second per thread: the
newest wins and the last one always goes.
"""
import asyncio
import json
import os
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
    # Claude Code's own tools, for agents on the claude shim
    "Read": "Reading a file",
    "Grep": "Looking through files",
    "Glob": "Looking through files",
    "LS": "Looking through files",
    "Bash": "Running a command",
    "BashOutput": "Checking on a job",
    "WebSearch": "Searching the web",
    "WebFetch": "Reading a web page",
    "Edit": "Making an edit",
    "MultiEdit": "Making an edit",
    "NotebookEdit": "Making an edit",
    "Write": "Writing it down",
    "Task": "Handing part of this to a helper",
    "Agent": "Handing part of this to a helper",
    "TodoWrite": "Planning the steps",
    "Skill": "Checking how to do this",
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


def remember_session(session_id: str = "", platform: str = "", sender_id: str = "", **_) -> Optional[dict]:
    """pre_llm_call: note which Hermes sessions are Yui turns, and for whom. On
    the claude shim, tag the turn so its tool calls come back as a file."""
    if platform == "yui" and session_id and sender_id:
        with _lock:
            SESSIONS[session_id] = sender_id
            while len(SESSIONS) > 200:
                SESSIONS.pop(next(iter(SESSIONS)))
        if on_shim():
            return {"context": shim_tag(sender_id)}
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


# -- claude shim turns (YUI-63 step 3) ----------------------------------------
#
# The tag rides on the turn's user message (pre_llm_call context is API-time
# only, never stored). The shim takes it out before Claude sees the prompt, and
# on every tool_use writes {"tool": name, "at": t} to SHIM_DIR/<tag>.json, then
# {"done": true} when the run ends. Only the tool name crosses; the words come
# from tool_words, so no id, path or command ever reaches the row.

SHIM_DIR = os.path.expanduser("~/.local/share/hermes-claude-shim/doing")
SHIM_PORT = ":8765"
TAG = "[[yui-turn:{}]]"
POLL = 0.4  # seconds between looks at the tag files
TAG_TTL = 3 * 3600  # a tag whose run never said done
SHIM = {"on": None}  # None: not read yet
TURNS: dict = {}  # tag -> [user, started, last mtime]
_poller = {"thread": None}


def on_shim() -> bool:
    """True when this profile's model runs through a claude shim that takes the
    tag out. The shim makes SHIM_DIR when it starts; an older shim would hash
    the tag into its session key and cold-start every Yui turn."""
    if not os.path.isdir(SHIM_DIR):
        return False
    if SHIM["on"] is None:
        try:
            from hermes_cli.config import load_config_readonly
            base = str(((load_config_readonly() or {}).get("model") or {}).get("base_url") or "")
            SHIM["on"] = SHIM_PORT in base
        except Exception:
            SHIM["on"] = False
    return SHIM["on"]


def shim_tag(user: str) -> str:
    """A new tag for this user's turn, and a poller watching for its file."""
    tag = os.urandom(8).hex()
    with _lock:
        TURNS[tag] = [user, time.time(), None]
        if not (_poller["thread"] and _poller["thread"].is_alive()):
            _poller["thread"] = threading.Thread(target=_poll, name="yui-doing-shim", daemon=True)
            _poller["thread"].start()
    return TAG.format(tag)


def shim_tick(now: Optional[float] = None) -> int:
    """One look at every live tag: a new tool name becomes a doing. Returns the tags left."""
    now = time.time() if now is None else now
    with _lock:
        turns = list(TURNS.items())
    for tag, (user, started, seen) in turns:
        path = os.path.join(SHIM_DIR, tag + ".json")
        try:
            mtime = os.stat(path).st_mtime_ns
        except OSError:
            mtime = None
        if mtime is None or mtime == seen:
            if now - started > TAG_TTL:
                _drop(tag, None)
            continue
        try:
            with open(path) as f:
                ev = json.load(f)
        except (OSError, ValueError):
            continue  # caught mid-replace; the next look reads it
        with _lock:
            if tag in TURNS:
                TURNS[tag][2] = mtime
        if ev.get("done"):
            _drop(tag, path)
            continue
        words = tool_words(str(ev.get("tool") or ""))
        if words:
            for a in list(ADAPTERS):
                try:
                    a.doing_from_tool(user, {"text": words})
                except Exception:
                    pass
    with _lock:
        return len(TURNS)


def _drop(tag: str, path: Optional[str]) -> None:
    with _lock:
        TURNS.pop(tag, None)
    if path:
        try:
            os.remove(path)
        except OSError:
            pass


def _poll() -> None:
    while True:
        time.sleep(POLL)
        try:
            if not shim_tick():
                with _lock:
                    if not TURNS:
                        _poller["thread"] = None
                        return
        except Exception:
            pass


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
