"""A warm `claude` process for short model calls (MOTION-18; yuigui spec/MOTION.md).

`claude -p` spends about 2 s starting before it writes a word. The film's parts call (motion_hero.draw_new) is on the
critical path of scene 1, so this keeps one `claude` open (stream-json in and out) with nothing in it yet, and the call
only pays for the model. A process serves `MAX_USES` calls and is then retired; the next one is already starting by then,
so a call never waits for a start, and one ask never sees another ask's words (a process that kept its chat would).
When a process dies, times out or answers nothing, the call is retried once on a fresh one. An idle process is closed after
`IDLE_S`. Everything is best effort: `ask` raises on failure and the caller (draw_new) already goes on without a hero.
"""

from __future__ import annotations

import asyncio
import json
import os
import time
from typing import Optional

MAX_USES = int(os.environ.get("YUI_MOTION_WARM_USES", "1"))
IDLE_S = 30 * 60
STREAM_LIMIT = 1 << 24


class _Proc:
    def __init__(self, proc, loop, model: str):
        self.proc, self.loop, self.model = proc, loop, model
        self.uses = 0
        self.born = time.time()
        self.lock = asyncio.Lock()

    def alive(self) -> bool:
        return self.proc.returncode is None and not self.loop.is_closed()

    def kill(self) -> None:
        if self.proc.returncode is None:
            try:
                self.proc.kill()
                asyncio.ensure_future(self.proc.wait())  # reap it
            except (ProcessLookupError, RuntimeError):
                pass


_slot: dict[str, _Proc] = {}      # model -> the warm process waiting for its next call
_reaper: dict[str, asyncio.Handle] = {}
stats = {"spawned": 0, "calls": 0, "retries": 0}


async def _spawn(model: str) -> _Proc:
    env = dict(os.environ, USER=os.environ.get("USER") or "yui", MAX_THINKING_TOKENS="0")
    cmd = ["claude", "-p", "--model", model, "--tools", "", "--no-session-persistence", "--effort", "low", "--strict-mcp-config",
           "--mcp-config", '{"mcpServers":{}}', "--disable-slash-commands", "--input-format", "stream-json",
           "--output-format", "stream-json", "--include-partial-messages", "--verbose"]
    proc = await asyncio.create_subprocess_exec(*cmd, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
                                                stderr=asyncio.subprocess.DEVNULL, env=env, limit=STREAM_LIMIT)
    stats["spawned"] += 1
    return _Proc(proc, asyncio.get_running_loop(), model)


def _arm_idle(model: str) -> None:
    h = _reaper.pop(model, None)
    if h:
        h.cancel()
    _reaper[model] = asyncio.get_running_loop().call_later(IDLE_S, _expire, model)


def _expire(model: str) -> None:
    p = _slot.pop(model, None)
    _reaper.pop(model, None)
    if p:
        p.kill()


async def _refill(model: str) -> None:
    try:
        if model not in _slot:
            _slot[model] = await _spawn(model)
            _arm_idle(model)
    except Exception:
        pass


def prime(model: str) -> None:
    """Start the warm process now (call it when the adapter connects); never raises, needs a running loop."""
    try:
        if model not in _slot or not _slot[model].alive():
            _slot.pop(model, None)
            asyncio.ensure_future(_refill(model))
    except RuntimeError:
        pass


async def _take(model: str) -> _Proc:
    p = _slot.pop(model, None)
    h = _reaper.pop(model, None)
    if h:
        h.cancel()
    if p is not None and not p.alive():
        p.kill()
        p = None
    if p is None:
        p = await _spawn(model)
    return p


async def _run(p: _Proc, prompt: str, timeout: float, on_text=None) -> str:
    assert p.proc.stdin is not None and p.proc.stdout is not None
    msg = {"type": "user", "message": {"role": "user", "content": prompt}}
    p.proc.stdin.write((json.dumps(msg) + "\n").encode())
    await p.proc.stdin.drain()
    streamed, whole = "", ""

    async def read() -> str:
        nonlocal streamed, whole
        async for raw in p.proc.stdout:
            try:
                ev = json.loads(raw)
            except ValueError:
                continue
            t = ev.get("type")
            if t == "stream_event":
                d = (ev.get("event") or {}).get("delta") or {}
                if d.get("type") == "text_delta":
                    streamed += d.get("text", "")
                    if on_text:
                        on_text(streamed)
            elif t == "assistant":
                for b in (ev.get("message") or {}).get("content") or []:
                    if b.get("type") == "text":
                        whole += b.get("text", "")
            elif t == "result":
                if ev.get("is_error"):
                    raise RuntimeError("claude result is_error")
                return whole or streamed or str(ev.get("result") or "")
        raise RuntimeError("claude closed")

    return await asyncio.wait_for(read(), timeout)


async def ask(prompt: str, model: str, timeout: float = 14.0, on_text=None) -> str:
    """The model's text for `prompt`; `on_text(text so far)` is called as it streams (a retry streams again from the start).
    Raises when two processes in a row fail (or the time is out)."""
    deadline = time.time() + timeout
    last: Optional[BaseException] = None
    for attempt in range(2):
        left = deadline - time.time()
        if left <= 0:
            break
        p = await _take(model)
        ok = False
        try:
            async with p.lock:
                out = await _run(p, prompt, left, on_text)
            p.uses += 1
            stats["calls"] += 1
            ok = bool(out.strip())
            if ok:
                return out
            last = RuntimeError("empty")
        except (asyncio.TimeoutError, RuntimeError, OSError, ValueError) as e:
            last = e
        finally:
            if ok and p.uses < MAX_USES and p.alive():
                _slot.setdefault(model, p)
                _arm_idle(model)
            else:
                p.kill()
                asyncio.ensure_future(_refill(model))
        if attempt == 0:
            stats["retries"] += 1
    raise last or asyncio.TimeoutError()


def shutdown() -> None:
    for m in list(_slot):
        _expire(m)
