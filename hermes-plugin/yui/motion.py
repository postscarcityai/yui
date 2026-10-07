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

try:
    from . import motion_hero
except ImportError:  # loaded by file path (yuigui site/scripts/motion/look_set.py)
    import importlib.util as _ilu
    _spec = _ilu.spec_from_file_location("motion_hero", Path(__file__).with_name("motion_hero.py"))
    motion_hero = _ilu.module_from_spec(_spec)
    _spec.loader.exec_module(motion_hero)

MODES = ("off", "on")
MAX_ASK = 700            # characters of ask the maker sees
MAX_SCENES = 12
MAX_FILMS_PER_HOUR = 8
FIRST_SCENE_TIMEOUT = 45.0
FILM_TIMEOUT = 150.0
OPENER_MODEL = "claude-haiku-4-5-20251001"
PROMPT = Path(__file__).with_name("motion_prompt.md")
SPEC = os.environ.get("YUI_MOTION_SPEC", "on").strip().lower() != "off"  # the scene 1 writer starts before the noun is known (MOTION-21)
EARLY = os.environ.get("YUI_MOTION_EARLY", "on").strip().lower() != "off"  # scene 1 goes out on a partial drawing while the parts stream (MOTION-21)
REST_EARLY = os.environ.get("YUI_MOTION_REST_EARLY", "on").strip().lower() != "off"  # the scene 2+ writer starts with scene 1's, not after it (MOTION-22)
HERO = os.environ.get("YUI_MOTION_HERO", "on").strip().lower() != "off"  # the kit draws the hero (MOTION-14); off = the model draws it

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
          "(at most 10 lines, 3 s), opens on the hero drawing of the ask and shows the subject at once. Name it with one word, no spaces. No words before the first header.")
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


class _Running:
    """An async generator that runs now, not on its first `async for`: its scenes wait in a queue (MOTION-22). A bare
    async generator does nothing until someone iterates it, so the scene 2+ writer used to start only after scene 1 was
    written and sent."""

    def __init__(self, agen):
        self._agen, self._q = agen, asyncio.Queue()
        self._task = asyncio.ensure_future(self._pump())

    async def _pump(self):
        try:
            async for s in self._agen:
                self._q.put_nowait(s)
        except asyncio.CancelledError:
            raise
        except Exception:
            pass
        finally:
            self._q.put_nowait(None)

    def __aiter__(self):
        return self

    async def __anext__(self):
        s = await self._q.get()
        if s is None:
            self._q.put_nowait(None)
            raise StopAsyncIteration
        return s

    async def aclose(self):
        self._task.cancel()
        try:
            await self._task
        except BaseException:
            pass
        try:
            await self._agen.aclose()
        except Exception:
            pass


async def split_film(ask: str) -> AsyncIterator[dict]:
    """Scene 1 from a small fast model, the rest from the big one, both started at once. Scene 1 plays the moment
    the small model finishes it; the rest follow in order. If the small model gives nothing, the film starts at scene 2.
    The hero object is picked from the ask by a word match and drawn by the kit (motion_hero): scene 1 gets it written
    in, scenes 2+ are told its name and get it written in when they leave it out. When the word match finds nothing, one cheap
    call may draw a hero the kit lacks from kit shapes, cached by name (motion_hero.draw_new, MOTION-15)."""
    hero = motion_hero.pick(ask) if HERO else None
    label, define = hero, ""
    task, early, guess, spec = None, None, None, None
    if HERO and not hero:
        # MOTION-18: the parts call streams its noun first; the writers start on it while the parts are still coming
        early = asyncio.get_running_loop().create_future()
        ev = motion_hero.Early()  # MOTION-21: the shapes as they stream in

        def heard(n):
            ev.noun = n
            early.done() or early.set_result(n)
        task = asyncio.ensure_future(motion_hero.draw_new(ask, on_noun=heard, on_text=ev))
        if SPEC:  # MOTION-21: scene 1 is the long pole now, so its writer starts with the parts call; the noun only confirms there is a hero
            spec = asyncio.ensure_future(_first(claude_cli(ask, OPENER_MODEL, OPENER + motion_hero.OPENER_NOTE_SPEC, think=False)))
        await asyncio.wait({task, early}, return_when=asyncio.FIRST_COMPLETED)
        if task.done():  # cached, or no streaming: the hero is known
            new, task = task.result(), None
            if new:
                hero, label, define = new["name"], new["label"], motion_hero.define_call(new)
        elif early.result() and motion_hero.noun_id(early.result()):
            hero, label = motion_hero.noun_id(early.result()), early.result().strip().lower()[:24]
            guess = (hero, label)

    def start(hero, label, reuse=True):
        notes = dict(name=hero, label=label)
        nonlocal spec
        if spec is not None and hero and reuse:  # the speculative scene 1 writer already has the job
            op, spec = spec, None
        else:
            if spec is not None:
                spec.cancel()
                spec = None
            op = asyncio.ensure_future(_first(claude_cli(ask, OPENER_MODEL, OPENER + (motion_hero.OPENER_NOTE.format(**notes) if hero else ""), think=False)))
        rest = claude_cli(ask, extra=CONTINUE + (motion_hero.CONTINUE_NOTE.format(**notes) if hero else ""))
        return op, (_Running(rest) if REST_EARLY else rest)

    opener, rest = start(hero, label)
    first = True
    try:
        s = await opener
        if task is not None:  # the writers ran on the noun alone: check the parts agree before scene 1 goes out
            partial = None
            while s and guess and EARLY and not task.done():  # MOTION-21: scene 1 need not wait for the last parts, the silhouette comes first
                partial = ev.hero()
                if partial and partial["name"] == guess[0]:
                    break
                partial = None
                await asyncio.wait({task}, timeout=0.05)
            if partial:  # scene 1 goes out on the shapes whole so far; scenes 2+ get the whole drawing
                yield dict(s, code=motion_hero.put_in(s["code"], hero, True, motion_hero.define_call(partial)))
                first = False
                s = None
                new = await task
                new = new if new and new["name"] == hero else partial
                label, define = new["label"], motion_hero.define_call(new)
            else:
                new = await task
                if guess and not (new and new["name"] == guess[0]):  # the parts failed or named something else: write again without the guess
                    opener.cancel()
                    await rest.aclose()
                    hero, label, define = (new["name"], new["label"], motion_hero.define_call(new)) if new else (None, None, "")
                    opener, rest = start(hero, label, reuse=False)
                    s = await opener
                elif new:
                    label, define = new["label"], motion_hero.define_call(new)
        if s:
            yield dict(s, code=motion_hero.put_in(s["code"], hero, True, define)) if hero else s
            first = False
        async for s in rest:
            yield dict(s, code=motion_hero.put_in(s["code"], hero, first, define)) if hero else s
            first = False
    finally:
        opener.cancel()
        if spec is not None:
            spec.cancel()
        await rest.aclose()
        if task is not None and not task.done():
            task.cancel()


def prime(config_extra: Optional[dict] = None) -> None:
    """Start the warm `claude` for the film's parts call (MOTION-18) when this host makes films; called when the adapter connects."""
    try:
        if HERO and motion_hero.THINGS_ON and motion_hero.WARM_ON and mode(config_extra) != "off" and maker(config_extra) is split_film:
            motion_hero._warm().prime(motion_hero.THING_MODEL)
    except Exception:
        pass


def unprime() -> None:
    try:
        motion_hero._warm().shutdown()
    except Exception:
        pass


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
