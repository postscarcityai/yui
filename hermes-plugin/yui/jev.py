"""Jev at decision points (YUI-215). Spec: yuigui docs/proposals/the-jev-layer.md (PROP-2).

Jev (TypeSafe, on OpenRouter as typesafe/jev-1.13) answers small closed
questions about a short text with a choice or a probability, in about a tenth
of a second. Point 1 here: before an agent turn, one call picks the reply
shape (line, yes/no, card, pages, full screen) and asks three more things
(how many, map, camera). Never blocks a turn: 600 ms, no retry, no key means
no call, any error means no decision.

Two modes, both off until a key is in the environment:
  shadow (default with a key): the decision is logged next to the shape the
    agent actually sent (`<profile home>/yui/jev.jsonl`, counts and numbers,
    never the message text). The turn is untouched.
  hint (`yui.jev_hint: true` in config or YUI_JEV_HINT=1, off by default):
    a decision above the confidence line adds ONE line to the turn context,
    `[yui] hint: shape=card (0.91). ...`. The agent may overrule it. Only for
    the shapes in HINT_SHAPES (card, pages, full): a `line` hint made the
    channel eval worse (see docs/research/jev-results.md), so lines and yes/no
    stay shadow-only until live logs say otherwise (`yui.jev_hint_shapes`).

Key: OPENROUTER_API_KEY (or YUI_JEV_KEY) from the gateway's environment, never
from the repo. Spend: JEV_SPEND_CAP dollars a day (default 1.00); past it the
call is skipped until tomorrow.
"""

from __future__ import annotations

import json
import os
import re
import threading
import time
import urllib.request
from datetime import datetime
from pathlib import Path
from typing import Optional

URL = "https://openrouter.ai/api/alpha/decisions"
MODEL = "typesafe/jev-1.13"
TIMEOUT = 0.6            # seconds; a turn never waits longer on Jev
MESSAGE_CAP = 400        # characters of the person's words that leave the machine
SHAPES = ("line", "yesno", "card", "pages", "full")
SHAPE_AT = 0.80          # choice confidence at or above: hint (tuned on the eval, see docs/research/jev-results.md)
NOUL_YES = 0.85          # noul at or above: yes; at or below 1 - this: no; between: no hint
NOUL_NO = 1 - NOUL_YES

# One call, up to five questions (TypeSafe: atomic questions, composed in code).
QUESTIONS = {
    "shape": {
        "type": "choice",
        "instructions": "How should the assistant answer this message on a phone screen?",
        "criteria": {
            "line": "One short sentence is enough: a quick fact, a status check, an acknowledgement, or a remark that needs no screen.",
            "yesno": "The message is a yes or no question. The answer is yes or no plus at most one line.",
            "card": "One card or one small screen with one thing on it: a link, a chart, a timer, a list, a picker, a form.",
            "pages": "Three or four separate things must each be read, one at a time: a tour, a walkthrough, a roadmap, a summary of changes.",
            "full": "An interactive multi-step flow the person answers on screen: a quiz, an interview, a guided setup, a game, a jam.",
        },
    },
    "things": {
        "type": "score",
        "instructions": "How many separate things must the answer show?",
        "criteria": ["One", "Two", "Three", "Four", "Five or more"],
    },
    "map": {
        "type": "noul",
        "instructions": "Is the person asking where something is, or about a place, a route or an area?",
        "criteria": {"true": "The answer is about places on a map.", "false": "The answer is not about places."},
    },
    "camera": {
        "type": "noul",
        "instructions": "Does the assistant need the person to take a photo or scan something to answer?",
        "criteria": {"true": "A photo, a scan or a barcode is needed.", "false": "No photo is needed."},
    },
    "camera_kind": {
        "type": "choice",
        "instructions": "If a photo is needed, which kind?",
        "criteria": {
            "plain": "A plain photo.",
            "meal": "A photo of food or a meal to log.",
            "document": "A page or document to scan.",
            "none": "No photo is needed.",
        },
    },
}


def home() -> Path:
    return Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")


def log_path() -> Path:
    return Path(os.environ.get("YUI_JEV_LOG") or home() / "yui" / "jev.jsonl")


def key() -> str:
    return os.environ.get("YUI_JEV_KEY") or os.environ.get("OPENROUTER_API_KEY") or ""


def enabled() -> bool:
    return bool(key()) and os.environ.get("YUI_JEV", "1") != "0"


def plain(body: str) -> bool:
    """A typed message worth a decision: not a tap or event (`[yui] ...`), not a slash command, not empty."""
    b = (body or "").strip()
    return bool(b) and not b.startswith(("[yui]", "/"))


HINT_SHAPES = ("card", "pages", "full")  # measured: these did not hurt the eval, a line hint did (jev-results.md)


def hint_shapes(config_extra: Optional[dict] = None) -> tuple:
    """Shapes allowed to become a hint: `yui.jev_hint_shapes` (a list) or YUI_JEV_HINT_SHAPES (comma list), else HINT_SHAPES."""
    raw = os.environ.get("YUI_JEV_HINT_SHAPES") or (config_extra or {}).get("jev_hint_shapes")
    if isinstance(raw, str):
        raw = raw.split(",")
    got = tuple(x.strip() for x in (raw or ()) if str(x).strip() in SHAPES)
    return got or HINT_SHAPES


def hint_on(config_extra: Optional[dict] = None) -> bool:
    """The hint flag: off by default. `yui.jev_hint: true` in config, or YUI_JEV_HINT=1."""
    if os.environ.get("YUI_JEV_HINT") in ("1", "true", "yes"):
        return True
    return bool((config_extra or {}).get("jev_hint"))


# --- spend cap -----------------------------------------------------------------------------------

_spend_lock = threading.Lock()
_spend = {"day": "", "usd": 0.0}


def cap() -> float:
    try:
        return float(os.environ.get("JEV_SPEND_CAP", "1.00"))
    except ValueError:
        return 1.00


def _spent_today() -> float:
    today = datetime.now().strftime("%Y-%m-%d")
    with _spend_lock:
        if _spend["day"] != today:
            _spend.update(day=today, usd=0.0)
            try:  # a restart keeps the day's total: read it back from the log
                for ln in log_path().read_text().splitlines()[-5000:]:
                    r = json.loads(ln)
                    if r.get("date") == today:
                        _spend["usd"] += float(r.get("cost") or 0)
            except (OSError, ValueError):
                pass
        return _spend["usd"]


def _add_spend(usd: float) -> None:
    with _spend_lock:
        _spend["usd"] += usd


# --- the call ------------------------------------------------------------------------------------

def call(state: dict, questions: dict, timeout: float = TIMEOUT, api_key: Optional[str] = None) -> Optional[dict]:
    """One Decisions API call. Returns {answers, cost, ms, input_tokens} or None on any failure. Never raises."""
    k = api_key or key()
    if not k:
        return None
    body = json.dumps({"model": MODEL, "state": state, "questions": questions}).encode()
    req = urllib.request.Request(URL, body, {"Authorization": "Bearer " + k, "Content-Type": "application/json"})
    t = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            d = json.load(r)
    except Exception:
        return None
    ms = round((time.perf_counter() - t) * 1000)
    u = d.get("usage") or {}
    return {"answers": d.get("answers") or {}, "cost": float(u.get("cost") or 0), "ms": ms,
            "input_tokens": int(u.get("input_tokens") or 0)}


def state_for(message: str, agent: str = "", has_photo: bool = False, last_shape: str = "none") -> dict:
    """The least that works: the person's words cut to MESSAGE_CAP, a few facts. No thread, no other agents' text."""
    return {"message": (message or "")[:MESSAGE_CAP], "agent": agent, "has_photo": has_photo,
            "last_agent_shape": last_shape}


def decide(message: str, agent: str = "", has_photo: bool = False, last_shape: str = "none",
           timeout: float = TIMEOUT, api_key: Optional[str] = None) -> Optional[dict]:
    """The reply-shape decision for one message, or None. Keys: shape, conf, things, map, camera, camera_kind, ms, cost."""
    if api_key is None and not enabled():
        return None
    if _spent_today() >= cap():
        return None
    r = call(state_for(message, agent, has_photo, last_shape), QUESTIONS, timeout, api_key)
    if not r:
        return None
    _add_spend(r["cost"])
    return read(r)


def read(r: dict) -> dict:
    a = r["answers"]
    sh, th, mp, cm, ck = (a.get(n) or {} for n in ("shape", "things", "map", "camera", "camera_kind"))
    return {
        "shape": sh.get("choice"), "conf": sh.get("confidence"), "probs": sh.get("probabilities"),
        "things": th.get("score"), "things_conf": th.get("confidence"),
        "map": mp.get("noul"), "camera": cm.get("noul"),
        "camera_kind": ck.get("choice"), "camera_kind_conf": ck.get("confidence"),
        "ms": r["ms"], "cost": r["cost"], "input_tokens": r["input_tokens"],
    }


# --- point 2: the tool router for the native crew (shadow only) -----------------------------------

def tool_question(tools: dict) -> dict:
    """One choice over an agent's tool names, plus none. `tools`: {name: what it does}."""
    crit = dict(tools)
    crit["none"] = "Chat, a question, thanks, or anything else that needs none of these tools."
    return {"tool": {"type": "choice", "instructions": "Which tool, if any, is the person asking the agent to use?",
                     "criteria": crit}}


def route(message: str, agent: str, tools: dict, timeout: float = TIMEOUT, api_key: Optional[str] = None) -> Optional[dict]:
    """Jev's pick among an agent's tools: {tool, conf, probs, ms, cost} or None."""
    r = call({"message": (message or "")[:MESSAGE_CAP], "agent": agent}, tool_question(tools), timeout, api_key)
    if not r:
        return None
    a = r["answers"].get("tool") or {}
    return {"tool": a.get("choice"), "conf": a.get("confidence"), "probs": a.get("probabilities"),
            "ms": r["ms"], "cost": r["cost"], "input_tokens": r["input_tokens"]}


# --- what to say to the agent --------------------------------------------------------------------

SHAPE_SAYS = {
    "line": "No screen, one short sentence.",
    "yesno": "Answer yes or no, then at most one line. No screen.",
    "card": "One card, one thing on it.",
    "pages": "A short deck, at most four pages.",
    "full": "A full screen flow is fine.",
}


def hint(d: Optional[dict], shape_at: float = SHAPE_AT, shapes: tuple = HINT_SHAPES, map_hint: bool = False) -> str:
    """One hint line for the turn, or "" when Jev is not sure or the shape is shadow-only. The agent may overrule it (never a rule).
    The map hint is off by default: on the eval it was right 3 times and turned a plain fact into a map once."""
    if not d or d.get("shape") not in shapes or (d.get("conf") or 0) < shape_at:
        return ""
    shape = d["shape"]
    n = d.get("things")
    if n is not None:  # two hints that clash: drop both
        if shape in ("line", "yesno") and n >= 3.0:
            return ""
        if shape == "pages" and n < 1.5:
            return ""
    bits = [f"shape={shape} ({d['conf']:.2f})"]
    line = SHAPE_SAYS[shape]
    if map_hint and d.get("map") is not None and d["map"] >= NOUL_YES:
        bits.append("map")
        line += " Show it on a map."
    if d.get("camera") is not None and d["camera"] >= NOUL_YES and d.get("camera_kind") in ("plain", "meal"):
        bits.append(f"camera={d['camera_kind']}")
        line += " It needs a photo."
    return f"[yui] hint: {', '.join(bits)}. {line}"


# --- the shape an agent actually sent ------------------------------------------------------------

FENCE = re.compile(r"```yui[^\n]*\n(.*?)(?:```|\Z)", re.S)
WORD = re.compile(r"\S+")
YESNO = re.compile(r"^\W*(?:yes|no|yep|nope|yeah|not yet|not quite)\b", re.I)


def sent_shape(body: str) -> str:
    """Classify a finished reply into the same five shapes, from its lines. A guess from the text, good enough to compare."""
    body = body or ""
    fences = FENCE.findall(body)
    text = FENCE.sub(" ", body)
    words = len(WORD.findall(text))
    if not fences:
        return "yesno" if YESNO.match(text) and words <= 40 else "line"
    lines = "\n".join(fences)
    first = [ln.split()[0] for ln in lines.split("\n") if ln.strip() and not ln.lstrip().startswith(("#", "//"))]
    head = {w.split("@")[0].lower() for w in first}
    if head & {"flow", "quiz", "game", "interview"}:
        return "full"
    pages = len(re.findall(r"^\s*(?:page|slide|step|item)\b", lines, re.M | re.I))
    if head & {"deck", "plan", "sketch"} or pages >= 3:
        return "pages" if pages >= 3 or "deck" in head else "full" if "plan" in head else "card"
    return "card"


# --- shadow log ----------------------------------------------------------------------------------

def record(d: dict, sent: Optional[str], profile: str = "", agent: str = "") -> None:
    """One row: the decision and the shape actually sent. Numbers only, never the words. Never raises."""
    try:
        now = datetime.now()
        row = {"date": now.strftime("%Y-%m-%d"), "time": now.strftime("%H:%M:%S"), "profile": profile, "agent": agent,
               "sent": sent, "shape": d.get("shape"), "conf": d.get("conf"), "things": d.get("things"),
               "map": d.get("map"), "camera": d.get("camera"), "camera_kind": d.get("camera_kind"),
               "ms": d.get("ms"), "cost": d.get("cost"), "hint": bool(d.get("hinted"))}
        p = log_path()
        p.parent.mkdir(parents=True, exist_ok=True)
        with p.open("a") as f:
            f.write(json.dumps(row) + "\n")
    except Exception:
        pass
