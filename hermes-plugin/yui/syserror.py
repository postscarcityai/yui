"""Hermes system failure lines never become chat bubbles (TestFlight feedback AOT6HtDztEGJPipFz9PrGK4).

Hermes posts "⚠️ Cron 'name' failed: Script execution failed: [Errno 35] ..." to
the thread when a cron script cannot start. They are machine noise: the person
cannot act on them, and they would also push to the phone. `is_failure(body)`
is true only when the WHOLE message is such a line (or lines), so a real reply
that mentions a failure, or carries a ⚠️ inside, is never touched.
"""

from __future__ import annotations

import re

LEAD = r"(?:[⚠❗\U0001f6a8]️?\s*)?"
LINE = re.compile(
    rf"^{LEAD}(?:"
    r"cron(?: job)?\s+['\"`][^'\"`\n]{1,80}['\"`]\s+failed\b[^\n]*"
    r"|script execution failed\b[^\n]*"
    r"|cron(?: job)?\s+['\"`][^'\"`\n]{1,80}['\"`]\s+(?:timed out|errored)\b[^\n]*"
    r")$",
    re.I,
)
TRACE = re.compile(r"^Traceback \(most recent call last\):\n(?:[ \t]+.*\n|\w.*\n?)+$")


def is_failure(body: str) -> bool:
    text = (body or "").strip()
    if not text or len(text) > 2000:
        return False
    if TRACE.match(text):
        return True
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    return bool(lines) and all(LINE.match(ln) for ln in lines)
