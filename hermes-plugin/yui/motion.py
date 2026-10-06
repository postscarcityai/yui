"""Motion: the agent asks for a film, the plugin makes it (MOTION-1; yuigui spec/MOTION.md sections 0.4 and 0.5).

The agent writes ONE line, `motion "<what to show, with the facts>"`, in a ```yui block. It never writes scenes
and the channel guide does not carry the drawing kit. This module takes the line out of the reply before it is
saved, and the adapter then has the maker write the film scene by scene. Each scene goes to the phone as its own
row, a `motion` block the app joins into one film (spec 0.5), so scene 1 plays while the rest is written.

    motion "How a heart pumps blood" film=m7 part=1
    === scene hook 4 ===
    <JavaScript body of (t, c, api)>
    end

Parts 2.. carry `part=<n>`; when the maker is done a last part with no scene carries `+last`. The maker is the `claude` CLI streamed (as in
yuigui site/scripts/motion/film.py) when this host has it; otherwise the profile's OpenAI-compatible endpoint.
Modes (`yui.motion` in config or YUI_MOTION): `on` (default) or `off` (the line is dropped and the agent
hears it is off). A phone whose build cannot play it gets the ask as words. Counts per hour are capped.
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import shutil
import time
import uuid
from pathlib import Path
from typing import AsyncIterator, Optional

MODES = ("off", "on")
MAX_ASK = 700            # characters of ask the maker sees
MAX_SCENES = 12
MAX_FILMS_PER_HOUR = 8
FIRST_SCENE_TIMEOUT = 45.0
FILM_TIMEOUT = 150.0
OPENER_MODEL = "claude-haiku-4-5-20251001"
PROMPT = Path(__file__).with_name("motion_prompt.md")

# The agent's line: `motion "ask"` or `motion ask words`. A block (`film=`, or scenes on the next line) is already ours.
LINE = re.compile(r'^\s*motion\s+(?P<rest>\S.*?)\s*$')
FENCE = re.compile(r"(```yui[^\n]*\n)(.*?)(```|\Z)", re.S)
SCENE_HEAD = re.compile(r"^=== ((?:scene )?(.+?) ([\d.]+)|end) ===\s*$", re.M)
_calls: list[float] = []


def mode(config_extra: Optional[dict] = None) -> str:
    m = str(os.environ.get("YUI_MOTION") or (config_extra or {}).get("motion") or "on").strip().lower()
    return m if m in MODES else "on"


def _ask_of(rest: str) -> Optional[str]:
    rest = rest.strip()
    if re.search(r"\b(film|part)=", rest):
        return None  # one of ours
    m = re.match(r'^"(.*)"\s*(?:\w+=\S+\s*)*$', rest)
    ask = (m.group(1) if m else rest).strip()
    return ask[:MAX_ASK] or None


def split(body: str) -> tuple[str, Optional[str]]:
    """(body without the agent's motion line, the ask). Only the first line in the reply counts; a block we
    wrote ourselves (it has `film=`) is left alone. Never raises."""
    found: list[str] = []

    def fence(m: re.Match) -> str:
        keep = []
        lines = m.group(2).split("\n")
        i = 0
        while i < len(lines):
            ln = lines[i]
            hit = LINE.match(ln)
            nxt = next((x for x in lines[i + 1:] if x.strip()), "")
            if hit and not nxt.startswith("==="):
                ask = _ask_of(hit.group("rest"))
                if ask and not found:
                    found.append(ask)
                    i += 1
                    continue
            keep.append(ln)
            i += 1
        text = "\n".join(keep)
        return m.group(1) + text + m.group(3) if text.strip() else ""

    try:
        out = FENCE.sub(fence, body or "")
    except Exception:
        return body, None
    return (out, found[0]) if found else (body, None)


def allowed(now: Optional[float] = None) -> bool:
    now = now if now is not None else time.time()
    while _calls and now - _calls[0] > 3600:
        _calls.pop(0)
    if len(_calls) >= MAX_FILMS_PER_HOUR:
        return False
    _calls.append(now)
    return True


def words(ask: str) -> str:
    """What an older phone gets: the ask as one line of words."""
    return "```yui\nsay " + json.dumps(ask[:200], ensure_ascii=False) + "\n```"


def title_of(ask: str) -> str:
    t = re.split(r"(?<=[.!?])\s", ask.strip())[0].strip().rstrip(".")
    return (t[:56] + "...") if len(t) > 58 else t


def drawing(n: int) -> str:
    """The working row's words while scene `n` is made (MOTION-5): plain words, never an id."""
    return "Drawing the first scene" if n <= 1 else f"Drawing scene {n}"


def block(film: str, title: str, part: int, scene: dict, last: bool) -> str:
    """The row for one scene (spec 0.5). Code never contains a line that is only `end`."""
    code = "\n".join(ln for ln in scene["code"].split("\n") if ln.strip() != "end")
    head = f"motion {json.dumps(title, ensure_ascii=False)} film={film} part={part}" if part == 1 else f"motion film={film} part={part}"
    if last:
        head += " +last"
    return "```yui\n" + head + f"\n=== scene {scene['name']} {scene['dur']:g} ===\n{code}\nend\n```"


def close(film: str, part: int) -> str:
    """The row that says the film is whole: a head with no scene."""
    return f"```yui\nmotion film={film} part={part} +last\n```"


def clean_scene(name: str, dur: str, code: str) -> Optional[dict]:
    code = re.sub(r"^```[a-z]*\n|\n```\s*$", "", code.strip())
    if not code:
        return None
    try:
        d = min(20.0, max(0.5, float(dur)))
    except ValueError:
        return None
    return {"name": re.sub(r"[^A-Za-z0-9_-]", "", name)[:24] or "scene", "dur": d, "code": code}


def harvest(text: str, done: int) -> tuple[list[dict], int]:
    """Scenes complete in `text` (a scene is complete when the next header or the end marker has arrived),
    after the first `done` marks. Returns (new scenes, marks consumed)."""
    marks = list(SCENE_HEAD.finditer(text))
    out = []
    for i, m in enumerate(marks[:-1]):
        if m.group(1) == "end" or i < done:
            continue
        s = clean_scene(m.group(2), m.group(3), text[m.end():marks[i + 1].start()])
        if s:
            out.append(s)
        done = i + 1
    return out, done


OPENER = ("\n\nYOUR JOB: write ONLY scene 1, then `=== end ===`. A slower writer draws the rest. Scene 1 is SMALL "
          "(at most 14 lines, 3 s), opens on the hero drawing of the ask and shows the subject at once. Name it with one word, no spaces. No words before the first header.")
CONTINUE = ("\n\nYOUR JOB: scene 1 is already written by someone else (it opens on the hero drawing with a title and a "
            "caption). Do NOT write it. Start at the next scene and write 4 to 6 scenes of 4 to 7 s that carry on from it. "
            "Name your scenes s2, s3, ...; the first scene you write is s2.")


def prompt_for(ask: str, theme: Optional[str] = None, extra: str = "") -> str:
    p = PROMPT.read_text()
    if theme:
        p += f"\n\nTHEME: {theme}"
    p += extra
    return p + "\n\nASK: " + ask + "\n"


async def claude_cli(ask: str, model: str = "claude-sonnet-5-5", extra: str = "", think: bool = True) -> AsyncIterator[dict]:
    """Stream the film from the `claude` CLI: yields each scene the moment it is complete."""
    env = dict(os.environ, USER=os.environ.get("USER") or "yui")
    if not think:
        env["MAX_THINKING_TOKENS"] = "0"  # haiku thinks ~25 s before the first word otherwise, even at --effort low
    cmd = ["claude", "-p", "--model", model, "--tools", "", "--no-session-persistence", "--output-format", "stream-json",
           "--include-partial-messages", "--verbose", "--effort", "low", "--strict-mcp-config", "--mcp-config",
           '{"mcpServers":{}}', "--disable-slash-commands", prompt_for(ask, extra=extra)]
    proc = await asyncio.create_subprocess_exec(*cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL, env=env)
    text, done, scenes = "", 0, 0
    try:
        assert proc.stdout is not None
        async for raw in proc.stdout:
            try:
                ev = json.loads(raw)
            except ValueError:
                continue
            if ev.get("type") != "stream_event":
                continue
            d = ev.get("event", {})
            if d.get("type") == "content_block_delta" and d.get("delta", {}).get("type") == "text_delta":
                text += d["delta"]["text"]
                new, done = harvest(text, done)
                for s in new:
                    scenes += 1
                    yield s
                    if scenes >= MAX_SCENES:
                        return
        new, done = harvest(text + "\n=== end ===\n", done)
        for s in new[: MAX_SCENES - scenes]:
            yield s
    finally:
        if proc.returncode is None:
            try:
                proc.kill()
            except ProcessLookupError:
                pass


async def split_film(ask: str) -> AsyncIterator[dict]:
    """Scene 1 from a small fast model, the rest from the big one, both started at once. Scene 1 plays the moment
    the small model finishes it; the rest follow in order. If the small model gives nothing, the film starts at scene 2."""
    opener = asyncio.ensure_future(_first(claude_cli(ask, OPENER_MODEL, OPENER, think=False)))
    rest = claude_cli(ask, extra=CONTINUE)
    try:
        s = await opener
        if s:
            yield s
        async for s in rest:
            yield s
    finally:
        opener.cancel()
        await rest.aclose()


async def _first(agen) -> Optional[dict]:
    try:
        async for s in agen:
            return s
    finally:
        await agen.aclose()
    return None


def maker(config_extra: Optional[dict] = None):
    """The scene source for this host: an async generator function `(ask) -> scenes`."""
    custom = (config_extra or {}).get("motion_maker")
    if callable(custom):
        return custom
    if shutil.which("claude"):
        return split_film
    return None


async def make(ask: str, film: Optional[str] = None, source=None, timeout: float = FILM_TIMEOUT) -> AsyncIterator[tuple[int, str, str, bool]]:
    """(part, title, row body, last) for each part of the film for `ask`. Each scene goes out the moment the maker
    finishes it (scene 1 is what the phone waits for); when the maker is done a closing part with no scene carries
    `+last`, so the phone knows the film is whole. Yields nothing when the maker gives no scene at all."""
    src = source or maker()
    if src is None:
        return
    film = film or ("m" + uuid.uuid4().hex[:6])
    title = title_of(ask)
    part = 0
    t0 = time.time()
    agen = src(ask)
    try:
        while True:
            left = (FIRST_SCENE_TIMEOUT if part == 0 else timeout) - (time.time() - t0)
            if left <= 0:
                break
            try:
                s = await asyncio.wait_for(agen.__anext__(), left)
            except (StopAsyncIteration, asyncio.TimeoutError):
                break
            part += 1
            yield part, title, block(film, title, part, s, False), False
        if part:
            part += 1
            yield part, title, close(film, part), True
    finally:
        try:
            await agen.aclose()
        except Exception:
            pass
