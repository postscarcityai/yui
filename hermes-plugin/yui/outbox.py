"""Agent replies that could not be written yet (YUI-28). Spec: yuigui/spec/RELAY.md.

A reply is never dropped because the network blinked or the Mac was waking up.
Each one gets its id on this machine, then goes into `<profile home>/yui/
outbox.jsonl` if the insert fails. The running gateway flushes the file oldest
first, so replies land in the order they were written. A resend that hits the
primary key (409) was already written, and counts as sent.

Out-of-process senders (cron, `hermes send --to yui`) append to the same file
when they cannot reach Yui, and the profile's gateway delivers them later.
A lock file keeps the gateway and those senders from writing over each other.
Stdlib only.
"""
import fcntl
import json
import os
import time
from contextlib import contextmanager
from pathlib import Path


def state_dir() -> Path:
    home = Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")
    return home / "yui"


class Outbox:
    def __init__(self, path: Path | None = None):
        self.path = path or state_dir() / "outbox.jsonl"

    @contextmanager
    def _locked(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(self.path.with_suffix(".lock"), os.O_WRONLY | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)

    def _read(self) -> list:
        try:
            lines = self.path.read_text().splitlines()
        except FileNotFoundError:
            return []
        out = []
        for line in lines:
            try:
                out.append(json.loads(line))
            except ValueError:
                continue  # a torn line from a crash mid-write: skip it, keep the rest
        return out

    def _write(self, items: list) -> None:
        tmp = self.path.with_suffix(".tmp")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write("".join(json.dumps(i) + "\n" for i in items))
        os.replace(tmp, self.path)

    def add(self, row: dict, sender: str | None = None, handoff: bool = False) -> None:
        """Queue one reply row (it must carry its own `id`)."""
        with self._locked():
            items = self._read()
            if any(i["row"]["id"] == row["id"] for i in items):
                return
            items.append({"row": row, "sender": sender, "handoff": handoff, "queued_at": time.time()})
            self._write(items)

    def items(self) -> list:
        with self._locked():
            return self._read()

    def peek(self) -> dict | None:
        with self._locked():
            items = self._read()
            return items[0] if items else None

    def pop(self, row_id: str) -> None:
        with self._locked():
            self._write([i for i in self._read() if i["row"]["id"] != row_id])

    def __len__(self) -> int:
        with self._locked():
            return len(self._read())
