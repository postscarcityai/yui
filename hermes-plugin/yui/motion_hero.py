"""Motion hero: the kit draws the thing the ask is about (MOTION-14; yuigui spec/MOTION.md).

The film writer paints blobs for things with a body (a heart, a chicken, a car). So the plugin picks the hero object from
the ask with a word match against the names of the kit's drawn things (`api.thing(name, x, y, size)` in yuigui
site/public/demo/motion/kit.js), puts it in scene 1 itself, and tells scenes 2+ its name so they keep it on screen.
No model call, so no time added to the first scene. When nothing fits the ask, there is no hero and the film is made as before.

MOTION-15: when the word match finds nothing, one cheap model call (`draw_new`) names the thing the ask is about and returns a
small set of parts built only from the kit's shape vocabulary (ellipse, circle, rect, poly, line; never free-form SVG). The
plugin validates them, turns them into the kit's part lists and the film registers them with `api.defineThing`, then draws
them through `api.thing` like any other hero. The result is cached on disk by the thing's name (and the ask by its words), so
the same noun is never drawn twice. When the call fails, is slow or returns nothing usable, the film goes on without a hero.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import math
import os
import re
import time
from pathlib import Path
from typing import Optional

# kit thing -> words that mean it. Every name here must be a thing in kit.js (test_motion_hero checks it when the sibling yuigui checkout is there).
WORDS = {
    "dog": r"dogs?|pupp(?:y|ies)|canines?", "cat": r"cats?|kittens?|kitty|felines?", "fish": r"fish(?:es)?|salmon|trout|goldfish",
    "bird": r"birds?|sparrows?|robins?|parrots?|owls?|eagles?|pigeons?|songbirds?", "chicken": r"chickens?|hens?|roosters?|poultry",
    "cow": r"cows?|cattle|cows'|dairy|bulls?", "turtle": r"turtles?|tortoises?", "butterfl": None, "bee": r"bees?|beehives?|bumblebees?",
    "butterfly": r"butterfl(?:y|ies)|caterpillars?|moths?",
    "heart": r"hearts?|cardiac|heartbeats?", "lungs": r"lungs?|breathing|respiratory", "brain": r"brains?|neurons?|neural",
    "stomach": r"stomachs?|digestion|digestive", "tooth": r"teeth|tooth|dental|dentist", "bone": r"bones?|skeleton|skeletal",
    "eyeball": r"eyes?|eyeballs?|retina", "car": r"cars?|automobiles?|sedans?|vehicles?", "bus": r"buses|bus|buses",
    "truck": r"trucks?|lorry|lorries|freight", "plane": r"planes?|airplanes?|aeroplanes?|aircraft|jets?|airliners?|flights?",
    "boat": r"boats?|sailboats?|sailing|yachts?|ferr(?:y|ies)", "bicycle": r"bicycles?|bikes?|cycling|cyclists?",
    "train": r"trains?|locomotives?|railways?|railroads?", "rocket": r"rockets?|spacecraft|spaceships?|space shuttle",
    "hammer": r"hammers?|mallets?", "wrench": r"wrenches|wrench|spanners?", "scissors": r"scissors|shears", "saw": r"saws?|sawing|handsaws?",
    "screwdriver": r"screwdrivers?", "paintbrush": r"paint ?brush(?:es)?|paint(?:ing)? a (?:wall|room|house)", "key": r"keyholes?|keychains?|(?:door|house|car|front|room) keys?",
    "ladder": r"ladders?", "house": r"houses?|homes?(?! (?:screen|page|tab|button|row|view|feed))|apartments?|cottages?|mortgages?|rent(?:ing)?|landlords?",
    "castle": r"castles?|fortress(?:es)?|fortif\w+|medieval", "skyscraper": r"skyscrapers?|high-?rises?|office buildings?",
    "city": r"cit(?:y|ies)|skylines?|downtown", "colosseum": r"colosseum|coliseum|roman empire|romans?|rome|gladiators?",
    "church": r"churche?s?|cathedrals?|chapels?", "tent": r"tents?|camping|campsites?|campers?", "bridge": r"bridges?|suspension bridges?",
    "lighthouse": r"lighthouses?", "mug": r"mugs?|cups? of|coffee|tea cups?|teacups?|espresso|latte", "lemon": r"lemons?|citrus",
    "apple": r"apples?", "pizza": r"pizzas?", "bread": r"bread|loaf|loaves|baguettes?|sourdough", "egg": r"eggs?",
    "cake": r"cakes?|birthdays?|cupcakes?", "bottle": r"bottles?|wine|beer|brew(?:ing)?", "chair": r"chairs?|seating",
    "bed": r"beds?|sleep(?:ing)?|bedroom|mattress", "clock": r"clocks?|timers?|o'clock", "book": r"books?|novels?|libraries|library",
    "laptop": r"laptops?|notebooks? computers?", "camera": r"cameras?|photograph(?:y|s)?|photos?", "umbrella": r"umbrellas?|rain(?:y|ing)? gear",
    "battery": r"batter(?:y|ies)|chargers?", "plant": r"plants?|houseplants?|seedlings?|sprouts?|garden(?:ing)?|flowerpots?|photosynthesis",
    "coins": r"coins?|money|cash|savings?|dollars?|piggy bank", "box": r"boxes|box|parcels?|packages?|cartons?|shipping boxes?|deliver(?:y|ies)",
    "can": r"watering cans?", "tank": r"tanks?|reservoirs?|water levels?", "robot": r"robots?|androids?",
    "engine": r"engines?|pistons?|motors?|combustion|four-?stroke", "newsletter": r"newsletters?|magazines?|newspapers?",
    "envelope": r"envelopes?|e-?mails?|letters?|inbox|mail", "calendar": r"calendars?|schedules?|deadlines?|appointments?",
    "globe": r"globes?|continents?|planets?|the earth|the world|world map|countries",
}
del WORDS["butterfl"]
# things a passing mention should not pick over a body noun in the same ask (a lemon in a chicken recipe)
WEAK = {"lemon", "apple", "egg", "box", "coins", "envelope", "mug", "calendar", "globe", "clock", "key", "bed", "book", "camera", "bottle", "house", "city"}
SKIP = re.compile(r"\bapi\.three\b|\b3d\b|three\.js|\breal 3d\b", re.I)
COOK = re.compile(r"\b(roast(?:ed|ing)?|bak(?:e|ed|ing)|cook(?:ed|ing)?|recipe|oven|dinner|grill(?:ed|ing)?|fry|fried|garlic|stuff(?:ed|ing)?|carv(?:e|ing))\b", re.I)
_PATS = {n: re.compile(r"\b(?:" + w + r")\b", re.I) for n, w in WORDS.items()}


def pick(ask: str) -> Optional[str]:
    """The kit thing the ask is about, or None. The earliest word in the ask wins (the subject usually comes first)."""
    text = ask or ""
    if not text.strip() or SKIP.search(text):
        return None
    best: Optional[tuple[int, int, str]] = None
    for name, pat in _PATS.items():
        m = pat.search(text)
        if m:
            cand = (1 if name in WEAK else 0, m.start(), name)
            if best is None or cand < best:
                best = cand
    if best is None:
        return None
    name = best[2]
    if name == "chicken" and COOK.search(text):
        name = "roast"
    elif name == "roast":
        name = "chicken"
    return name


HERO_SIZE = 280   # scene 1; the labels around it need room (MOTION-14 raised cramped frames from 9 to 16 at 300; 260/200 fixed that but the judge then called the roast small)
HERO_SIZE_LATER = 230


def hero_call(name: str, k: str = "api.seg(t, 0, 1.2)", size: int = HERO_SIZE) -> str:
    """The line that draws the hero in the middle band. Guarded: a phone with an older kit skips it."""
    return f'if (api.thing) api.thing("{name}", api.w / 2, api.h * 0.47, {size}, {{k: {k}}});'


# ---- things the kit lacks (MOTION-15) ----
FILLS = ("ink", "panel", "accent", "a2", "warn", "good", "bad")
MAX_PARTS = 12
MIN_PARTS = 5
LIM = 70.0
CACHE_ENV = "YUI_MOTION_THINGS_CACHE"
CALL_TIMEOUT = 14.0
THINGS_ON = os.environ.get("YUI_MOTION_THINGS", "on").strip().lower() != "off"
THING_MODEL = os.environ.get("YUI_MOTION_THING_MODEL", "claude-sonnet-5-5")  # haiku drew loose bits; sonnet draws one object in the same ~6 s

THING_PROMPT = """You name the thing a short film is about and sketch it as parts. Reply with JSON only, no words around it.

ASK: {ask}

If the ask is about one physical thing with a recognisable body or outline (an animal, machine, building, tool, plant, vehicle, organ, instrument; for a job or a person name the object they work with), reply {{"noun":"<one or two lowercase words>","parts":[...]}}. If it is about a plan, numbers, status, screens, software, a feeling, a place or a process with no single body, reply {{"noun":null}}.

parts: 7 to 12 shapes, back to front, drawn side-on in a box about -55..55 wide and -45..45 tall (y points down), centred on 0,0. Start with the big silhouette (body, hull, tower, case), then the details that name the thing (ears, trunk, lens, strings, blades, legs, wheels). The shapes must touch or overlap so it reads as one object, never loose bits. Shapes:
 {{"s":"ellipse","x":0,"y":0,"rx":30,"ry":20,"f":"a2"}}
 {{"s":"circle","x":0,"y":0,"r":10,"f":"panel"}}
 {{"s":"rect","x":0,"y":0,"w":20,"h":30,"f":"warn"}}  (x,y is the centre)
 {{"s":"poly","p":[[x,y],[x,y],...],"f":"accent","smooth":true}}  (closed filled shape, 3 to 12 points; smooth rounds the corners)
 {{"s":"line","p":[[x,y],[x,y],...],"w":1.5,"smooth":true}}  (open stroke, 2 to 12 points, w 0.5 to 3)
Fill f is one of: ink panel accent a2 warn good bad (leave out f for no fill). Use 3 or more different fills. The body must fill most of the box (at least 80 units wide or 60 tall).

Think of the outline first: where the head, the body and each end are, then place every part so it joins the next. A mushroom for example: {{"noun":"mushroom","parts":[{{"s":"rect","x":0,"y":22,"w":20,"h":44,"f":"panel"}},{{"s":"poly","p":[[-52,2],[-40,-26],[-14,-42],[14,-42],[40,-26],[52,2]],"f":"bad","smooth":true}},{{"s":"line","p":[[-52,2],[52,2]],"w":1.5}},{{"s":"circle","x":-22,"y":-16,"r":6,"f":"panel"}},{{"s":"circle","x":10,"y":-26,"r":5,"f":"panel"}},{{"s":"circle","x":28,"y":-8,"r":5,"f":"panel"}},{{"s":"ellipse","x":0,"y":46,"rx":30,"ry":6,"f":"good"}}]}}.
"""


def _num(v, lo=-LIM, hi=LIM) -> float:
    x = float(v)
    if not math.isfinite(x):
        raise ValueError("nan")
    return min(hi, max(lo, x))


def _f(x: float) -> str:
    return f"{x:.1f}".rstrip("0").rstrip(".")


def _smooth(pts: list, closed: bool) -> str:
    """Catmull-Rom through the points as cubic curves."""
    n = len(pts)
    d = f"M{_f(pts[0][0])} {_f(pts[0][1])}"
    for i in range(n if closed else n - 1):
        p0 = pts[(i - 1) % n] if (closed or i > 0) else pts[0]
        p1, p2 = pts[i], pts[(i + 1) % n]
        p3 = pts[(i + 2) % n] if (closed or i + 2 < n) else pts[-1]
        c1 = (p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6)
        c2 = (p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6)
        d += f" C{_f(c1[0])} {_f(c1[1])} {_f(c2[0])} {_f(c2[1])} {_f(p2[0])} {_f(p2[1])}"
    return d + ("Z" if closed else "")


def _ell(x, y, rx, ry) -> str:
    return (f"M{_f(x - rx)} {_f(y)} A{_f(rx)} {_f(ry)} 0 1 1 {_f(x + rx)} {_f(y)} "
            f"A{_f(rx)} {_f(ry)} 0 1 1 {_f(x - rx)} {_f(y)}Z")


def build_parts(spec) -> Optional[list]:
    """The model's parts, checked, as the kit's part list [[path, fill, stroke, width scale], ...], or None when anything is
    off. Only the five shapes of the vocabulary are read; every number is clamped; the model never writes a path string."""
    if not isinstance(spec, list) or not (MIN_PARTS <= len(spec) <= MAX_PARTS + 4):
        return None
    out, fills, xs, ys = [], set(), [], []
    try:
        for sh in spec[:MAX_PARTS]:
            kind = sh.get("s")
            f = sh.get("f")
            if f is not None and f not in FILLS:
                return None
            if kind == "ellipse":
                x, y, rx, ry = _num(sh["x"]), _num(sh["y"]), _num(sh["rx"], 2, LIM), _num(sh["ry"], 2, LIM)
                d, pts = _ell(x, y, rx, ry), [(x - rx, y - ry), (x + rx, y + ry)]
            elif kind == "circle":
                x, y, r = _num(sh["x"]), _num(sh["y"]), _num(sh["r"], 1.5, LIM)
                d, pts = _ell(x, y, r, r), [(x - r, y - r), (x + r, y + r)]
            elif kind == "rect":
                x, y, w, h = _num(sh["x"]), _num(sh["y"]), _num(sh["w"], 2, 2 * LIM), _num(sh["h"], 2, 2 * LIM)
                d = f"M{_f(x - w / 2)} {_f(y - h / 2)} L{_f(x + w / 2)} {_f(y - h / 2)} L{_f(x + w / 2)} {_f(y + h / 2)} L{_f(x - w / 2)} {_f(y + h / 2)}Z"
                pts = [(x - w / 2, y - h / 2), (x + w / 2, y + h / 2)]
            elif kind in ("poly", "line"):
                raw = sh["p"]
                if not isinstance(raw, list) or not (3 if kind == "poly" else 2) <= len(raw) <= 12:
                    return None
                pts = [(_num(p[0]), _num(p[1])) for p in raw]
                closed = kind == "poly"
                if sh.get("smooth") and len(pts) >= 3:
                    d = _smooth(pts, closed)
                else:
                    d = "M" + " L".join(f"{_f(a)} {_f(b)}" for a, b in pts) + ("Z" if closed else "")
            else:
                return None
            xs += [p[0] for p in pts]
            ys += [p[1] for p in pts]
            if kind == "line":
                out.append([d, 0, "fg", _num(sh.get("w") or 1.2, 0.5, 3)])
            else:
                out.append([d, f or 0, "fg", 1])
                if f:
                    fills.add(f)
    except (KeyError, TypeError, ValueError, AttributeError, IndexError):
        return None
    if len(fills) < 2 or sum(1 for p in out if p[1]) < 3:
        return None
    if max(xs) - min(xs) < 60 and max(ys) - min(ys) < 45:
        return None
    return out


def noun_id(noun: str) -> Optional[str]:
    n = re.sub(r"[^a-z0-9 -]", "", (noun or "").strip().lower()).strip()
    n = re.sub(r"[ -]+", "_", n)
    return n if re.fullmatch(r"[a-z][a-z0-9_]{1,23}", n) else None


def cache_path() -> Path:
    env = os.environ.get(CACHE_ENV)
    if env:
        return Path(env)
    return Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes") / "yui_motion_things.json"


def _ask_key(ask: str) -> str:
    return hashlib.sha1(re.sub(r"\W+", " ", (ask or "").lower()).strip().encode()).hexdigest()[:16]


def _load() -> dict:
    try:
        d = json.loads(cache_path().read_text())
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def _save(d: dict) -> None:
    try:
        p = cache_path()
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_suffix(".tmp")
        tmp.write_text(json.dumps(d, indent=1))
        tmp.replace(p)
    except OSError:
        pass


# MOTION-23: things the kit lacks that films ask about, drawn and checked once, shipped with the plugin. The disk cache wins over the seed.
SEED_ON = os.environ.get("YUI_MOTION_SEED", "on").strip().lower() != "off"
SEED_FILE = Path(__file__).with_name("motion_things_seed.json")


def _seed() -> dict:
    global _SEED
    if _SEED is None:
        try:
            d = json.loads(SEED_FILE.read_text())
            words = {n: re.compile(r"\b(?:" + w + r")\b", re.I) for n, w in (d.get("words") or {}).items() if n in (d.get("things") or {})}
            _SEED = {"things": d["things"], "words": words}
        except (OSError, ValueError, KeyError, TypeError, re.error):
            _SEED = {"things": {}, "words": {}}
    return _SEED


_SEED: Optional[dict] = None


def _things() -> dict:
    """Every drawn thing by name: the seed under the disk cache."""
    return {**(_seed()["things"] if SEED_ON else {}), **(_load().get("things") or {})}


def seeded(ask: str) -> Optional[dict]:
    """The seed or learned thing the ask is about ({"name", "label", "parts"}), or None. Run after pick() misses; the earliest word wins."""
    if not SEED_ON or not THINGS_ON or not (ask or "").strip() or SKIP.search(ask):
        return None
    best = None
    for name, pat in _seed()["words"].items():
        m = pat.search(ask)
        if m and (best is None or m.start() < best[0]):
            best = (m.start(), name)
    for name, pat in _learned_words().items():  # MOTION-25: nouns drawn and checked in the background after a first ask
        m = pat.search(ask)
        if m and (best is None or m.start() < best[0]):
            best = (m.start(), name)
    if best is None:
        return None
    th = _things().get(best[1])
    return dict(th, name=best[1]) if th else None


def cached(ask: str) -> Optional[dict]:
    """The stored hero for this ask: {"name", "label", "parts"}, or {} when the ask was seen and has no body, or None when new."""
    d = _load()
    hit = (d.get("asks") or {}).get(_ask_key(ask))
    if hit is None:
        return None
    if not hit:
        return {}
    th = _things().get(hit)
    return dict(th, name=hit) if th else None


def remember(ask: str, hero: Optional[dict]) -> None:
    d = _load()
    d.setdefault("asks", {})[_ask_key(ask)] = hero["name"] if hero else ""
    if hero:
        d.setdefault("things", {})[hero["name"]] = {"label": hero["label"], "parts": hero["parts"]}
    _save(d)


# MOTION-25: a noun in neither the kit, the seed nor the cache is drawn again in the background once its film is over, checked by the
# same judge as the seed, and kept under its narrow word forms, so the second ask is a seed hit. Nothing here runs inside a turn.
LEARN_ON = os.environ.get("YUI_MOTION_LEARN", "on").strip().lower() != "off"
LEARN_JUDGE_ENV = "YUI_MOTION_LEARN_JUDGE"  # the judge script (yuigui site/scripts/motion/learn_judge.py); no script, no learning
LEARN_MAX_INFLIGHT = int(os.environ.get("YUI_MOTION_LEARN_INFLIGHT", "2"))
LEARN_DAILY = int(os.environ.get("YUI_MOTION_LEARN_DAILY", "20"))
LEARN_TRIES = 2  # per noun, ever: a drawing that failed the judge twice is not tried a third time
LEARN_PARTS_TIMEOUT = 40.0
LEARN_JUDGE_TIMEOUT = 300.0
# Single words that mean something else in a software or planning ask; a seed word wins over the parts call, so these are never learned.
LEARN_AMBIGUOUS = {"cell", "cloud", "ship", "phone", "plant", "bank", "table", "chart", "graph", "key", "screen", "window", "file", "folder", "tree",
                   "map", "board", "card", "page", "pipe", "stack", "mouse", "network", "server", "tool", "light", "box", "net", "web", "bug", "frame"}
_LEARN_INFLIGHT: set = set()
_LEARN_TASKS: set = set()
_LEARN_LOG: list = []  # [{"noun", "pass", "why", "s"}], newest last, kept for the eval and the logs
_LEARNED: dict = {"pat": None, "words": {}}


def _forms(w: str) -> str:
    plural = w[:-1] + "ies" if w.endswith("y") and w[-2] not in "aeiou" else w + ("es" if w.endswith(("s", "x", "ch", "sh")) else "s")
    return r"(?:" + re.escape(w) + "|" + re.escape(plural) + ")"


def learn_words(label: str) -> Optional[str]:
    """The narrow pattern a learned noun answers to: its own name and plural, and for a two-word name its last word alone when that word
    is not an everyday one ('snare drum' also answers to 'drum'; 'kayak' and 'boat' never answer to 'kayak paddle'; 'cell' is never learned)."""
    toks = re.findall(r"[a-z][a-z0-9]*", (label or "").lower())
    if not toks or len(toks) > 2 or len(toks[-1]) < 3 or (len(toks) == 1 and toks[0] in LEARN_AMBIGUOUS):
        return None
    if len(toks) == 1:
        return _forms(toks[0])
    full = r"[ -]?".join([re.escape(toks[0]), _forms(toks[1])])
    head = toks[1]
    return full + "|" + _forms(head) if len(head) >= 4 and head not in LEARN_AMBIGUOUS else full


def _learned_words() -> dict:
    """{name: compiled pattern} for the nouns the cache holds as learned (words are stored as pattern strings)."""
    if not LEARN_ON:
        return {}
    d = _load()
    raw = d.get("words") or {}
    key = json.dumps(raw, sort_keys=True)
    if _LEARNED["pat"] != key:
        out = {}
        for n, w in raw.items():
            if n in (d.get("things") or {}):
                try:
                    out[n] = re.compile(r"\b(?:" + w + r")\b", re.I)
                except re.error:
                    pass
        _LEARNED["pat"], _LEARNED["words"] = key, out
    return _LEARNED["words"]


def learn_judge_script() -> Optional[Path]:
    p = Path(os.path.expanduser(os.environ.get(LEARN_JUDGE_ENV) or "~/dev/yuigui/site/scripts/motion/learn_judge.py"))
    return p if p.is_file() else None


def learn_idle() -> bool:
    return not _LEARN_TASKS


def _learn_note(name: str, ok: bool, why: str, t0: float, **kw) -> None:
    _LEARN_LOG.append(dict(noun=name, ok=ok, why=why, s=round(time.time() - t0, 1), **kw))
    del _LEARN_LOG[:-200]


def _known(name: str) -> bool:
    return name in WORDS or name in _seed()["things"] or name in _learned_words()


def learn_after(ask: str, name: Optional[str]) -> bool:
    """Called when a film that had to draw its hero from the parts call is over. Queues the background job; True when one started.
    `name` is the hero the film used; None when the parts call failed (nothing was kept for the ask), and the job then names the thing itself.
    Never raises, never waits: a refusal (off, capped, already known, tried twice, ambiguous word) just returns False."""
    try:
        if not (LEARN_ON and THINGS_ON and (ask or "").strip()) or SKIP.search(ask):
            return False
        key = name or "ask:" + _ask_key(ask)
        if name and (_known(name) or not learn_words(name.replace("_", " "))):
            return False
        if not name and cached(ask) is not None:  # seen before: kept, or the model said it has no body
            return False
        if key in _LEARN_INFLIGHT or len(_LEARN_INFLIGHT) >= LEARN_MAX_INFLIGHT or learn_judge_script() is None:
            return False
        d = _load()
        if (d.get("learn") or {}).get(key, {}).get("n", 0) >= LEARN_TRIES:
            return False
        day = time.strftime("%Y-%m-%d")
        if (d.get("learn_day") or {}).get("d") == day and d["learn_day"].get("n", 0) >= LEARN_DAILY:
            return False
        loop = asyncio.get_running_loop()
        _LEARN_INFLIGHT.add(key)
        t = loop.create_task(_learn(key, name, ask))
        _LEARN_TASKS.add(t)
        t.add_done_callback(_LEARN_TASKS.discard)
        return True
    except Exception:
        return False


def _learn_count(name: str, ok: bool, why: str) -> None:
    d = _load()
    day = time.strftime("%Y-%m-%d")
    ld = d.get("learn_day") or {}
    d["learn_day"] = {"d": day, "n": (ld.get("n", 0) if ld.get("d") == day else 0) + 1}
    rec = (d.get("learn") or {}).get(name, {})
    d.setdefault("learn", {})[name] = {"n": rec.get("n", 0) + 1, "ok": ok, "why": why[:120], "at": int(time.time())}
    _save(d)


def learn_ask(label: str) -> str:
    a = "an" if label[:1] in "aeiou" else "a"
    return f"{a.title()} {label}, shown clearly."  # the seed's own ask (seed_build.ask_for), so a learned drawing is made like a seed one


async def _parts(ask: str) -> Optional[dict]:
    try:
        return parse_reply(await asyncio.wait_for(_call_cold(ask), LEARN_PARTS_TIMEOUT))  # a process of its own: never the warm one a turn is using
    except Exception:
        return None


async def _learn(key: str, name: Optional[str], ask: str) -> None:
    t0 = time.time()
    shown = name or key
    try:
        thing, why = None, "no parts"
        for _ in range(2):  # as seed_build: one retry when the parts come back empty or name another thing
            hero = await _parts(learn_ask(name.replace("_", " ")) if name else ask)
            if hero and hero.get("parts") and (not name or hero["name"] == name):
                thing = hero
                break
            why = f"parts named {hero['name']}" if hero and hero.get("name") else "no parts"
        if thing and not name:  # the film's own call failed: the thing is whatever the model names from the ask
            name = shown = thing["name"]
            if _known(name) or not learn_words(name.replace("_", " ")) or name in _LEARN_INFLIGHT:
                thing, why = None, f"{name} not learnable"
            elif (_load().get("learn") or {}).get(name, {}).get("n", 0) >= LEARN_TRIES:
                thing, why = None, f"{name} tried twice"
        if not thing:
            _learn_count(key, False, why)
            return _learn_note(shown, False, why, t0)
        ok, why = await _judge(thing)
        _learn_count(name, ok, why)
        if key != name:
            _learn_count(key, ok, why)
        if ok:
            d = _load()
            d.setdefault("things", {})[name] = {"label": thing["label"], "parts": thing["parts"]}  # the checked drawing replaces the unchecked one
            d.setdefault("words", {})[name] = learn_words(name.replace("_", " "))
            _save(d)
        _learn_note(name, ok, why, t0)
    except BaseException as e:  # a crash or a cancel here never reaches a reply
        try:
            _learn_note(shown, False, f"crash {type(e).__name__}", t0)
        except Exception:
            pass
        if isinstance(e, asyncio.CancelledError):
            raise
    finally:
        _LEARN_INFLIGHT.discard(key)


async def _judge(thing: dict) -> tuple:
    """(passed, why): the judge script renders the drawing as a one-scene film and looks at it, in its own process group."""
    import signal
    import tempfile
    script = learn_judge_script()
    if script is None:
        return False, "no judge"
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(thing, f)
    cmd = ["nice", "-n", "10", "uv", "run", "--quiet", "--with", "playwright", "--with", "pillow", "python", str(script), str(Path(__file__).parent), f.name]
    env = dict(os.environ, USER=os.environ.get("USER") or "yui", PATH=os.environ.get("PATH", "") + ":/opt/homebrew/bin:" + str(Path.home() / ".local/bin"))
    proc = await asyncio.create_subprocess_exec(*cmd, stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.PIPE,
                                                stderr=asyncio.subprocess.DEVNULL, env=env, start_new_session=True)
    try:
        out, _ = await asyncio.wait_for(proc.communicate(), LEARN_JUDGE_TIMEOUT)
        for ln in reversed(out.decode("utf-8", "replace").splitlines()):
            if ln.startswith("{"):
                r = json.loads(ln)
                return bool(r.get("pass")), ",".join(r.get("fail") or []) or str(r.get("note") or "ok")
        return False, "judge gave nothing"
    except asyncio.TimeoutError:
        return False, "judge timeout"
    finally:
        if proc.returncode is None:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
        try:
            os.unlink(f.name)
        except OSError:
            pass


def parse_reply(text: str) -> Optional[dict]:
    """{"name", "label", "parts"} from the model's JSON, {} for 'no single thing', None when unusable."""
    i = (text or "").find("{")
    if i < 0:
        return None
    try:
        d, _ = json.JSONDecoder().raw_decode(text[i:])  # the first object; a second line after it is ignored (MOTION-20)
    except ValueError:
        return None
    if not isinstance(d, dict):
        return None
    if d.get("noun") in (None, "", "null"):
        return {}
    name = noun_id(str(d["noun"]))
    if not name:
        return None
    if name in WORDS:  # the model named something the kit already draws: use the kit's drawing
        return {"name": name, "label": name.replace("_", " "), "parts": None}
    parts = build_parts(d.get("parts"))
    if not parts:
        return None
    return {"name": name, "label": str(d["noun"]).strip().lower()[:24], "parts": parts}


WARM_ON = os.environ.get("YUI_MOTION_WARM", "on").strip().lower() != "off"  # a claude kept open for this call (MOTION-18); off = start one per call


def _warm():
    try:
        from . import warm
    except ImportError:  # loaded by file path (yuigui site/scripts/motion/look_set.py)
        import importlib.util as ilu
        import sys
        warm = sys.modules.get("yui_motion_warm")
        if warm is None:
            spec = ilu.spec_from_file_location("yui_motion_warm", Path(__file__).with_name("warm.py"))
            warm = ilu.module_from_spec(spec)
            sys.modules["yui_motion_warm"] = warm
            spec.loader.exec_module(warm)
    return warm


async def _call_cold(ask: str) -> str:
    env = dict(os.environ, USER=os.environ.get("USER") or "yui", MAX_THINKING_TOKENS="0")
    cmd = ["claude", "-p", "--model", THING_MODEL, "--tools", "", "--no-session-persistence", "--effort", "low", "--strict-mcp-config",
           "--mcp-config", '{"mcpServers":{}}', "--disable-slash-commands", THING_PROMPT.format(ask=ask[:400])]
    proc = await asyncio.create_subprocess_exec(*cmd, stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.PIPE,
                                                stderr=asyncio.subprocess.DEVNULL, env=env)
    try:
        out, _ = await asyncio.wait_for(proc.communicate(), CALL_TIMEOUT)
        return out.decode("utf-8", "replace")
    finally:
        if proc.returncode is None:
            try:
                proc.kill()
            except ProcessLookupError:
                pass


NOUN = re.compile(r'"noun"\s*:\s*(?:null|"([^"\n]{0,40})")')


def noun_watch(on_noun):
    """An on_text callback for the streaming call: tells `on_noun(noun or None)` once, the moment the reply's first field is whole."""
    seen = []

    def on_text(text: str) -> None:
        if seen:
            return
        m = NOUN.search(text)
        if m:
            seen.append(1)
            on_noun(m.group(1) or None)
    return on_text


EARLY_MIN = 6  # shapes whole before scene 1 may go out on a partial drawing (MOTION-21)


def shapes_so_far(text: str) -> list:
    """The shapes of the streaming parts reply that are already whole (each a dict), in order."""
    i = text.find('"parts"')
    j = text.find("[", i) if i >= 0 else -1
    if j < 0:
        return []
    dec, pos, out = json.JSONDecoder(), j + 1, []
    while True:
        while pos < len(text) and text[pos] in " \t\r\n,":
            pos += 1
        if pos >= len(text) or text[pos] != "{":
            return out
        try:
            obj, pos = dec.raw_decode(text, pos)
        except ValueError:
            return out
        out.append(obj)


class Early:
    """Hears the streaming parts reply; `hero()` is the drawing the shapes whole so far make (the big silhouette comes first,
    so a prefix reads as the thing with fewer details), or None while there are too few (MOTION-21)."""

    def __init__(self):
        self.text, self.noun, self._n, self._hero = "", None, 0, None

    def __call__(self, text: str) -> None:
        self.text = text

    def hero(self) -> Optional[dict]:
        sh = shapes_so_far(self.text)
        if len(sh) < EARLY_MIN:
            return None
        if len(sh) != self._n:
            self._n = len(sh)
            parts = build_parts(sh)
            name = noun_id(self.noun or "")
            self._hero = {"name": name, "label": (self.noun or "").strip().lower()[:24], "parts": parts} if parts and name else None
        return self._hero


async def _call_model(ask: str, on_noun=None, on_text=None) -> str:
    """The parts call: on the warm process when there is one, else (warm off or failed) one `claude -p` per call.
    `on_noun` hears the noun while the parts are still being written (warm only; MOTION-18)."""
    if WARM_ON:
        t0 = time.time()
        try:
            watch = noun_watch(on_noun) if on_noun else None
            if on_text:
                def watch(text, _w=watch):
                    on_text(text)
                    if _w:
                        _w(text)
            return await _warm().ask(THING_PROMPT.format(ask=ask[:400]), THING_MODEL, CALL_TIMEOUT, watch)
        except Exception:
            if CALL_TIMEOUT - (time.time() - t0) < 4:
                raise
    return await _call_cold(ask)


async def draw_new(ask: str, call=None, on_noun=None, on_text=None) -> Optional[dict]:
    """The hero for an ask the word match missed: {"name", "label", "parts"} (parts None = a kit thing), or None for no hero.
    Cached by name; never raises. `call` is the model call (a test seam): async (ask) -> text.
    `on_noun(noun or None)` is called early, while the model is still writing the parts (the film starts its writers on it)."""
    if not THINGS_ON or not (ask or "").strip() or SKIP.search(ask):
        return None
    hit = cached(ask)
    if hit is not None:
        return hit or None
    try:
        hero = parse_reply(await (call(ask) if call else _call_model(ask, on_noun, on_text)))
    except Exception:
        return None
    if hero is None:
        return None  # a failed call is not remembered: the next ask tries again
    th = _things().get(hero.get("name")) if hero else None
    if hero.get("parts") and th:  # the noun is already drawn from an earlier ask
        hero = {"name": hero["name"], "label": th["label"], "parts": th["parts"]}
    remember(ask, hero or None)
    return hero or None


def define_call(hero: dict) -> str:
    """The line that registers a drawn hero with the kit. Empty for a kit thing."""
    if not hero.get("parts"):
        return ""
    return f'if (api.defineThing) api.defineThing("{hero["name"]}", {json.dumps(hero["parts"], separators=(",", ":"))});'


_LOOK = re.compile(r"^[ \t]*api\.look\([^)\n]*\)[ \t]*;?[ \t]*$", re.M)


def put_in(code: str, name: str, first: bool, define: str = "") -> str:
    """Scene code with the hero drawn in it, after the scene's look call (the look paints the background).
    Scene 1 draws the hero on; later scenes keep it on screen, already drawn, unless the scene already calls api.thing.
    `define` registers a hero the kit lacks (define_call) and goes in front of the draw call."""
    if "api.thing(" in code and not first:
        return (define + "\n" + code) if define and "api.defineThing(" not in code else code
    line = hero_call(name, "api.seg(t, 0, 1.2)" if first else "1", HERO_SIZE if first else HERO_SIZE_LATER)
    if define and "api.defineThing(" not in code:
        line = define + "\n" + line
    m = _LOOK.search(code)
    if m:
        return code[: m.end()] + "\n" + line + code[m.end():]
    return line + "\n" + code


OPENER_NOTE = ("\n\nHERO: the kit has ALREADY drawn the hero of this ask, a {label}, big in the middle of the screen (api.thing). Do not draw "
               "the {label} yourself and do not hide it. It is centred at (api.w/2, api.h*0.47) and about 280 px wide and tall: aim every callout at a spot inside that box. api.thing returns nothing and has no other fields. Write the rest of scene 1 around it: a title near the top, one or two api.callout "
               "labels on its parts (put each label in open space beside it, 12 px clear), something moving. Do not call api.look "
               "unless you want a different look; the hero is drawn after it.")
OPENER_NOTE_SPEC = ("\n\nHERO: if the ask is about one physical thing with a body (an animal, machine, building, tool, plant, vehicle), the kit has ALREADY drawn it, big in the middle "
                    "of the screen (api.thing). Do not draw it yourself and do not hide it. It is centred at (api.w/2, api.h*0.47) and about 280 px wide and tall: aim every callout at a spot inside that box. "
                    "Write the rest of scene 1 around it: a title near the top, one or two api.callout labels on its parts (put each label in open space beside it, 12 px clear), something moving. "
                    "Do not call api.look unless you want a different look; the hero is drawn after it.")
CONTINUE_NOTE = ("\n\nHERO: the hero of this ask is a {label}, drawn by the kit as api.thing(\"{name}\", x, y, size, {{k: 1}}) (x centre, y about "
                 "api.h*0.47, size 200 to 240; wrap it as `if (api.thing) api.thing(...)`; it returns nothing). Every scene you write keeps the {label} on screen "
                 "with that call, the same drawing, so the film reads as one thing: draw it first, then your callouts, arrows, counters and "
                 "captions around it. You may move it, scale it up with api.cam or api.focus, or draw a second api.thing beside it. Never "
                 "paint your own version of the {label}.")
