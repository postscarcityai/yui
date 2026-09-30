"""What the person is looking at when they type (t_53b06721).

A typed line with no Reply on it ("What are you waiting on me for with this?")
carries no header, so "this" had nothing to point at and the agent grabbed an
old open item instead. The host reads the agent's newest message in the thread
and hands its headline to the agent as a note, so a line about "this" or "that"
is answered about that screen first.

Pure text work. The adapter fetches the row (adapter._shown_note); no network here.
"""

import re
from datetime import datetime, timezone
from typing import Optional

FRESH_SECONDS = 30 * 60
NOTE_CHARS = 420
FENCE = re.compile(r"```yui\s*\n(.*?)(```|\Z)", re.S)
TITLED = re.compile(r'^(?:card|sketch|deck|plan|list|table|form|stat|chart|choose|pick|ask|slide|timeline|map|shapes)(?:@\S+)?\s+"([^"]+)"', re.M)
FIELD = re.compile(r'\b(?:body|caption)="([^"]+)"')
ROW = re.compile(r'^row\s+"([^"]+)"(.*)$', re.M)


def plain(text: str) -> bool:
    """A typed line: not a tap, a reply header, a mention or a slash command."""
    t = (text or "").lstrip()
    return bool(t) and not t.startswith("[yui]") and not t.startswith("/")


def headline(body: str) -> str:
    """The agent's message in a line or two: its words, then what it drew (titles
    and the first rows, `+x` rows left out: they are the struck-out half)."""
    body = body or ""
    words = " ".join(FENCE.sub(" ", body).split())
    parts = [words] if words else []
    for m in FENCE.finditer(body):
        block = m.group(1)
        titles = TITLED.findall(block)
        if titles:
            parts.append("screen: " + "; ".join(titles[:3]))
        fields = FIELD.findall(block)
        if fields:
            parts.append(fields[0])
        rows = [r for r, rest in ROW.findall(block) if "+x" not in rest.split()]
        if rows:
            parts.append("rows: " + "; ".join(rows[:4]))
    out = " | ".join(parts)
    return out if len(out) <= NOTE_CHARS else out[:NOTE_CHARS - 1].rstrip() + "…"


def age(created_at: Optional[str], now: Optional[datetime] = None) -> Optional[float]:
    try:
        then = datetime.fromisoformat((created_at or "").replace("Z", "+00:00"))
    except ValueError:
        return None
    if then.tzinfo is None:
        then = then.replace(tzinfo=timezone.utc)
    return ((now or datetime.now(tz=timezone.utc)) - then).total_seconds()


def note(row: Optional[dict], asked_at: Optional[str] = None) -> Optional[str]:
    """The line the agent reads first, or None: no message, an old one, or
    a message of nothing (a menu or patch only)."""
    if not row:
        return None
    ref = datetime.fromisoformat(asked_at.replace("Z", "+00:00")) if asked_at else None
    secs = age(row.get("created_at"), ref)
    if secs is None or secs > FRESH_SECONDS or secs < 0:
        return None
    said = headline(row.get("body") or "")
    if not said:
        return None
    mins = max(1, round(secs / 60))
    return (f'[yui] note: your newest message here is {mins} min old and is what they are looking at: "{said}". '
            'Words like "this", "that" or "it" mean that message. Answer about it first. '
            'Sample rows in it are examples, not their open items. Bring up another open item only if they ask, '
            'and then say when they last saw it and what they answered.')
