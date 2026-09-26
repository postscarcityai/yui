"""Agent controls from the drawer, no agent turn (YUI-70). Spec: yuigui/spec/CONTROLS.md.

The app's Controls tab reads and changes what this agent is made of: its
SOUL.md, its memory entries, its skills, its schedules, and (read only) its
model and channels. Each request is one `yui_messages` row with
kind='control'; `meta` carries the operation:

    {"v": 1, "req": "c-8f2a", "op": "put", "section": "soul", "id": "SOUL.md",
     "rev": "b41c09...", "value": {"text": "# Scout\\n..."}}

The adapter hands it here instead of to the agent and writes one answer row
back (kind='control', sender='agent', same `req`, no push). The agent hears
about a change on its next turn in one line (note()).

The host does not trust the phone. Refused, with a plain message:
not the owner, an id that is a path or not in the section's list, a stale
`rev` (conflict, with the current item), a delete without `confirmed: true`,
an unknown op/section/verb/`v`, SOUL.md or a bundled skill for delete, a
SKILL.md without frontmatter, a schedule time that does not parse, an empty
personality, anything over 32 KB, a write to an item shown with a secret
hidden, more than 30 writes a minute.

Secrets never leave: .env, auth.json and keys are never read. Every text that
goes out (SOUL.md, memory, SKILL.md, a schedule prompt) runs through the
host's redaction; a line with a key in it shows as HIDDEN and the item is
read only, so a save cannot write the placeholder over the real value.

Every accepted write copies the old content to <profile home>/yui/controls-trash/
(swept after 30 days) and logs one JSON line to <profile home>/yui/controls.log.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import time
from collections import deque
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Dict, List, Optional

V = 1
SECTIONS = {"soul": "rw", "memory": "rwd", "skills": "rwd", "schedules": "rwd", "model": "r", "channels": "r"}
OPS = ("list", "get", "put", "act", "delete")
VERBS = {"schedules": ("pause", "resume", "run"), "skills": ("enable", "disable")}
MAX_BYTES = 32 * 1024
WRITES_PER_MINUTE = 30
TRASH_DAYS = 30
HIDDEN = "[hidden on your Mac]"
SOUL = "SOUL.md"
MEMORY_FILES = {"mem": "MEMORY.md", "user": "USER.md"}
MEMORY_LIMITS = {"mem": 2200, "user": 1375}  # the memory tool's defaults (tools/memory_tool.py)
ENTRY_DELIMITER = "\n§\n"
SKIP_DIRS = {".hub", ".restore-backups", ".git", "__pycache__", "node_modules"}

ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$")
# Token shapes the host's redaction might not know, checked on top of it.
KEYISH = re.compile(
    r"(sk-[A-Za-z0-9_-]{16,}|sk_(live|test)_[A-Za-z0-9]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_\w{20,}"
    r"|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"
    r"|yui_ct_[A-Za-z0-9_-]{8,}|sb_secret_[A-Za-z0-9_-]{8,}|\b\d{8,10}:[A-Za-z0-9_-]{30,}\b"
    r"|-----BEGIN [A-Z ]*PRIVATE KEY-----"
    r"|\b(api[_-]?key|secret|token|password|passwd|bearer)\b\s*[:=]\s*['\"]?[A-Za-z0-9_./+-]{12,})", re.I)

MESSAGES = {
    "version": "Update the Yui plugin on your Mac.",
    "not_owner": "Only the owner can change this agent's settings.",
    "bad_op": "The host doesn't know that request.",
    "bad_section": "The host doesn't know that section.",
    "not_allowed": "That can't be changed from the phone.",
    "bad_id": "That isn't something the host listed.",
    "not_found": "It's gone from the host. Pull to refresh.",
    "conflict": "Changed on the host since you opened it.",
    "confirm": "Deleting needs a confirm.",
    "bad_verb": "The host doesn't know that action.",
    "read_only": "Part of this is hidden on your Mac, so it can only be changed there.",
    "too_big": "That's over 32 KB.",
    "empty": "An agent needs a personality. It can't be empty.",
    "no_frontmatter": "A skill needs its name and description at the top.",
    "bad_schedule": "That time doesn't parse.",
    "keep_soul": "An agent always has a personality. Edit it instead.",
    "bundled": "This skill ships with Hermes. Switch it off instead.",
    "too_fast": "Too many changes at once. Wait a minute.",
    "too_long": "That's over this memory's size limit.",
    "unsafe": "The host refused that text.",
    "failed": "The host couldn't do that.",
}


class Refused(Exception):
    def __init__(self, error: str, message: Optional[str] = None, **extra):
        super().__init__(error)
        self.error, self.message, self.extra = error, message or MESSAGES.get(error, error), extra


def rev_of(value) -> str:
    raw = value if isinstance(value, str) else json.dumps(value, sort_keys=True, default=str)
    return hashlib.sha256(raw.encode()).hexdigest()[:12]


def report() -> dict:
    """The capability report yui-connect stores in yui_agents.controls."""
    return {"v": V, "sections": dict(SECTIONS)}


def request_of(row: dict) -> Optional[dict]:
    """The request when the row is a control from the person, else None."""
    if row.get("kind") != "control" or row.get("sender", "user") != "user":
        return None
    meta = row.get("meta")
    return meta if isinstance(meta, dict) else {}


# -- secrets ------------------------------------------------------------------

def _host_redact(text: str) -> str:
    try:
        from agent.redact import redact_sensitive_text
        return redact_sensitive_text(text, force=True, file_read=True)
    except Exception:
        return text


def redact(text: str) -> tuple[str, bool]:
    """(text safe to send, whether anything was hidden). Line by line: a line
    with a key in it is replaced whole, so no part of a key goes out."""
    out, hid = [], False
    for line in (text or "").split("\n"):
        if KEYISH.search(line) or _host_redact(line) != line:
            out.append(HIDDEN)
            hid = True
        else:
            out.append(line)
    return "\n".join(out), hid


# -- small helpers --------------------------------------------------------------

def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _mtime(p: Path) -> Optional[str]:
    try:
        return datetime.fromtimestamp(p.stat().st_mtime, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except OSError:
        return None


def _atomic_write(p: Path, text: str) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_name(f".{p.name}.yui-tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, p)


def _check_size(text: str) -> None:
    if len(text.encode()) > MAX_BYTES:
        raise Refused("too_big")


def _text_value(req: dict) -> str:
    v = req.get("value")
    text = v.get("text") if isinstance(v, dict) else None
    if not isinstance(text, str):
        raise Refused("bad_op", "Nothing to save.")
    _check_size(text)
    if HIDDEN in text:
        raise Refused("read_only")
    return text


def _first_line(text: str, n: int = 80) -> str:
    for line in (text or "").splitlines():
        line = line.strip().lstrip("#").strip()
        if line:
            return line[:n]
    return ""


def when_in_words(display: str) -> str:
    """ "0 8 * * 1-5" -> "weekdays 8:00", "every 30m" -> "every 30 minutes"."""
    d = (display or "").strip()
    m = re.fullmatch(r"every (\d+)\s*(m|min|minutes?|h|hours?|d|days?)", d, re.I)
    if m:
        n, u = int(m.group(1)), m.group(2)[0].lower()
        unit = {"m": "minute", "h": "hour", "d": "day"}[u]
        return f"every {n} {unit}{'s' if n != 1 else ''}"
    parts = d.split()
    if len(parts) == 5:
        mi, hr, dom, mon, dow = parts
        step = re.fullmatch(r"\*/(\d+)", mi)
        if step and hr == dom == mon == dow == "*":
            return f"every {step.group(1)} minutes"
        if re.fullmatch(r"\d+", mi) and hr == "*" and dom == mon == dow == "*":
            return f"hourly at :{int(mi):02d}"
        if re.fullmatch(r"\d+", mi) and re.fullmatch(r"\d+(,\d+)*", hr) and dom == mon == "*":
            times = ", ".join(f"{int(h)}:{int(mi):02d}" for h in hr.split(","))
            days = {"*": "daily", "1-5": "weekdays", "0,6": "weekends", "6,0": "weekends"}.get(dow)
            if days is None and re.fullmatch(r"[0-6]", dow):
                days = ["Sundays", "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays"][int(dow)]
            if days:
                return f"{days} {times}"
    return d


# -- the host ---------------------------------------------------------------------

class Host:
    """One profile's settings. `home` is the profile's HERMES_HOME.

    `cron` is the cron.jobs module (the gateway's own); tests pass a fresh
    import bound to a temp home. `config` loads/saves the profile's config
    (hermes_cli.config); tests may pass a stand-in.
    """

    def __init__(self, home: Path, cron=None, config=None, clock: Callable[[], float] = time.time):
        self.home = Path(home)
        self._cron = cron
        self._config = config
        self.clock = clock
        self._writes: deque = deque()

    # -- entry point --------------------------------------------------------------

    def handle(self, req: dict, *, owner: bool, who: str = "", agent: str = "", via: str = "",
               proposal: str = "", dry: bool = False) -> tuple[dict, Optional[str]]:
        """(answer meta, change for the agent's note or None).

        `dry` runs every check a write would (Talk about this, YUI-69: a
        proposal is checked before it reaches the phone) and writes nothing.
        `via` and `proposal` go on the log line."""
        req = req if isinstance(req, dict) else {}
        base = {"v": V, "req": str(req.get("req") or "")[:40]}
        try:
            if req.get("v") != V:
                raise Refused("version")
            if not owner:
                raise Refused("not_owner")
            op, section = req.get("op"), req.get("section")
            if op not in OPS:
                raise Refused("bad_op")
            if section not in SECTIONS:
                raise Refused("bad_section")
            need = {"list": "r", "get": "r", "put": "w", "act": "w", "delete": "d"}[op]
            if need not in SECTIONS[section]:
                raise Refused("keep_soul" if (section, op) == ("soul", "delete") else "not_allowed")
            base["section"] = section
            if op == "list":
                return {**base, "ok": True, "items": getattr(self, f"_{section}_list")()}, None
            iid = req.get("id")
            if not isinstance(iid, str) or not ID.match(iid) or ".." in iid:
                raise Refused("bad_id")
            base["id"] = iid
            if op == "get":
                rev, item = getattr(self, f"_{section}_get")(iid)
                return {**base, "ok": True, "rev": rev, "item": item}, None
            if op == "act":
                verb = req.get("verb")
                if verb not in VERBS.get(section, ()):
                    raise Refused("bad_verb")
            if op == "delete" and req.get("confirmed") is not True:
                raise Refused("confirm")
            if dry:
                rev, item = self._check(op, section, iid, req)
                return {**base, "ok": True, "rev": rev, "item": item}, None
            self._rate()
            if op == "act":
                old, rev, item, change = getattr(self, f"_{section}_act")(iid, req["verb"])
            else:
                cur, _ = getattr(self, f"_{section}_get")(iid)
                if req.get("rev") != cur:
                    _, item = getattr(self, f"_{section}_get")(iid)
                    raise Refused("conflict", rev=cur, item=item)
                old = cur
                if op == "put":
                    rev, item, change = getattr(self, f"_{section}_put")(iid, req)
                else:
                    rev, item, change = getattr(self, f"_{section}_delete")(iid), None, None
                    change = self._deleted_change(section, iid)
            self._log(who, op, section, iid, old, rev, agent, via, proposal)
            out = {**base, "ok": True, "rev": rev, "item": item}
            if item and item.get("id") and item["id"] != iid:
                out["id"] = item["id"]  # a memory entry's id follows its text
            if op == "delete":
                out["deleted"] = True
            return out, change
        except Refused as e:
            return {**base, "ok": False, "error": e.error, "message": e.message, **e.extra}, None
        except Exception as e:  # never let one bad request take the gateway down
            return {**base, "ok": False, "error": "failed", "message": MESSAGES["failed"],
                    "detail": type(e).__name__}, None

    def _rate(self) -> None:
        now = self.clock()
        while self._writes and now - self._writes[0] > 60:
            self._writes.popleft()
        if len(self._writes) >= WRITES_PER_MINUTE:
            raise Refused("too_fast")
        self._writes.append(now)

    # -- trash + log ------------------------------------------------------------

    @property
    def _yui(self) -> Path:
        return self.home / "yui"

    def trash(self, section: str, iid: str, src: Optional[Path] = None, text: Optional[str] = None) -> Path:
        """Keep the old copy for 30 days: a file or folder, or a text."""
        root = self._yui / "controls-trash"
        root.mkdir(parents=True, exist_ok=True)
        self._sweep(root)
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%f")
        dest = root / f"{stamp}-{section}-{iid}"
        if src is not None and src.is_dir():
            shutil.copytree(src, dest)
        elif src is not None and src.exists():
            shutil.copy2(src, dest)
        else:
            dest.write_text(text or "", encoding="utf-8")
        return dest

    def _sweep(self, root: Path) -> None:
        cutoff = self.clock() - TRASH_DAYS * 86400
        for p in root.iterdir():
            try:
                if p.stat().st_mtime < cutoff:
                    shutil.rmtree(p) if p.is_dir() else p.unlink()
            except OSError:
                pass

    def _check(self, op: str, section: str, iid: str, req: dict) -> tuple:
        """What a write would refuse, without writing: (current rev, item)."""
        cur, item = getattr(self, f"_{section}_get")(iid)
        if op == "act":
            return cur, item
        if req.get("rev") != cur:
            raise Refused("conflict", rev=cur, item=item)
        if op == "put":
            getattr(self, f"_{section}_prepare")(iid, req)
        elif section == "skills" and iid in self._bundled():
            raise Refused("bundled")
        return cur, item

    def _log(self, who: str, op: str, section: str, iid: str, old: Optional[str], new: Optional[str],
             agent: str, via: str = "", proposal: str = "") -> None:
        self._yui.mkdir(parents=True, exist_ok=True)
        line = {"at": _now(), "who": who, "agent": agent, "op": op, "section": section, "id": iid,
                "old": old, "new": new}
        if via:
            line["via"] = via
        if proposal:
            line["proposal"] = proposal
        with open(self._yui / "controls.log", "a", encoding="utf-8") as f:
            f.write(json.dumps(line) + "\n")

    def _deleted_change(self, section: str, iid: str) -> str:
        return {"memory": "one memory forgotten", "skills": f'skill "{iid}" deleted',
                "schedules": f'"{getattr(self, "_last_name", iid)}" deleted'}.get(section, f"{section} {iid} deleted")

    # -- soul ---------------------------------------------------------------------

    @property
    def _soul(self) -> Path:
        return self.home / SOUL

    def _soul_list(self) -> List[dict]:
        text = self._soul.read_text(encoding="utf-8") if self._soul.exists() else ""
        return [{"id": SOUL, "title": _first_line(text) or "Personality", "rev": rev_of(text),
                 "updated": _mtime(self._soul)}]

    def _soul_get(self, iid: str):
        if iid != SOUL:
            raise Refused("bad_id")
        raw = self._soul.read_text(encoding="utf-8") if self._soul.exists() else ""
        text, hid = redact(raw)
        outline = [ln.lstrip("#").strip() for ln in text.splitlines() if re.match(r"^#{1,3}\s+\S", ln)]
        return rev_of(raw), {"id": SOUL, "text": text, "outline": outline[:20], "read_only": hid,
                             "updated": _mtime(self._soul)}

    def _soul_prepare(self, iid: str, req: dict) -> str:
        _, cur = self._soul_get(iid)
        if cur["read_only"]:
            raise Refused("read_only")
        text = _text_value(req)
        if not text.strip():
            raise Refused("empty")
        return text

    def _soul_put(self, iid: str, req: dict):
        text = self._soul_prepare(iid, req)
        self.trash("soul", SOUL, src=self._soul)
        _atomic_write(self._soul, text)
        rev, item = self._soul_get(iid)
        return rev, item, "personality edited"

    # -- memory -------------------------------------------------------------------

    def _mem_path(self, kind: str) -> Path:
        return self.home / "memories" / MEMORY_FILES[kind]

    def _mem_entries(self, kind: str) -> List[str]:
        p = self._mem_path(kind)
        if not p.exists():
            return []
        raw = p.read_text(encoding="utf-8")
        return [e.strip() for e in raw.split(ENTRY_DELIMITER) if e.strip()]

    @staticmethod
    def _mem_id(kind: str, entry: str) -> str:
        return f"{kind}-{rev_of(entry)[:10]}"

    def _mem_find(self, iid: str) -> tuple[str, List[str], int]:
        kind = iid.split("-", 1)[0]
        if kind not in MEMORY_FILES:
            raise Refused("bad_id")
        entries = self._mem_entries(kind)
        for i, e in enumerate(entries):
            if self._mem_id(kind, e) == iid:
                return kind, entries, i
        raise Refused("not_found")

    def _memory_list(self) -> List[dict]:
        out = []
        for kind, group in (("mem", "remembers"), ("user", "you")):
            for e in reversed(self._mem_entries(kind)):  # newest first: entries are appended
                text, hid = redact(e)
                out.append({"id": self._mem_id(kind, e), "group": group, "title": _first_line(text),
                            "rev": rev_of(e), "read_only": hid})
        return out

    def _memory_get(self, iid: str):
        kind, entries, i = self._mem_find(iid)
        text, hid = redact(entries[i])
        return rev_of(entries[i]), {"id": iid, "group": "remembers" if kind == "mem" else "you",
                                    "text": text, "read_only": hid}

    def _mem_write(self, kind: str, entries: List[str]) -> None:
        path = self._mem_path(kind)
        try:
            from tools.memory_tool import MemoryStore
            lock = MemoryStore._file_lock(path)
        except Exception:
            import contextlib
            lock = contextlib.nullcontext()
        with lock:
            self.trash("memory", MEMORY_FILES[kind], src=path)
            _atomic_write(path, ENTRY_DELIMITER.join(entries) if entries else "")

    def _memory_prepare(self, iid: str, req: dict):
        kind, entries, i = self._mem_find(iid)
        if redact(entries[i])[1]:
            raise Refused("read_only")
        text = _text_value(req).strip()
        if not text:
            raise Refused("bad_op", "Use Forget to remove a memory.")
        try:  # the memory tool's own injection scan
            from tools.memory_tool import _scan_memory_content
            if _scan_memory_content(text):
                raise Refused("unsafe")
        except ImportError:
            pass
        entries = entries[:i] + [text] + entries[i + 1:]
        if len(ENTRY_DELIMITER.join(entries)) > self._mem_limit(kind):
            raise Refused("too_long")
        return kind, entries, text

    def _memory_put(self, iid: str, req: dict):
        kind, entries, text = self._memory_prepare(iid, req)
        self._mem_write(kind, entries)
        new = self._mem_id(kind, text)
        rev, item = self._memory_get(new)
        return rev, item, "one memory edited"

    def _mem_limit(self, kind: str) -> int:
        cfg = (self._load_config().get("memory") or {})
        key = "memory_char_limit" if kind == "mem" else "user_char_limit"
        try:
            return int(cfg.get(key) or MEMORY_LIMITS[kind])
        except (TypeError, ValueError):
            return MEMORY_LIMITS[kind]

    def _memory_delete(self, iid: str) -> Optional[str]:
        kind, entries, i = self._mem_find(iid)
        self._mem_write(kind, entries[:i] + entries[i + 1:])
        return None

    # -- skills -------------------------------------------------------------------

    @property
    def _skills_dir(self) -> Path:
        return self.home / "skills"

    def _skill_dirs(self) -> Dict[str, Path]:
        """name -> folder, for every SKILL.md under the profile's skills folder."""
        out: Dict[str, Path] = {}
        root = self._skills_dir
        if not root.is_dir():
            return out
        for md in sorted(root.rglob("SKILL.md")):
            rel = md.relative_to(root).parts
            if any(p.startswith(".") or p in SKIP_DIRS for p in rel[:-1]):
                continue
            d = md.parent
            if d.is_symlink() or not d.resolve().is_relative_to(root.resolve()):
                continue
            out.setdefault(d.name, d)
        return out

    def _bundled(self) -> set:
        p = self._skills_dir / ".bundled_manifest"
        if not p.exists():
            return set()
        return {ln.split(":", 1)[0].strip() for ln in p.read_text(encoding="utf-8").splitlines() if ln.strip()}

    def _disabled(self) -> set:
        skills = self._load_config().get("skills") or {}
        return set(skills.get("disabled") or [])

    @staticmethod
    def _frontmatter(text: str) -> dict:
        m = re.match(r"^---\s*\n(.*?)\n---\s*(\n|$)", text, re.S)
        if not m:
            return {}
        try:
            from agent.skill_utils import yaml_load
            data = yaml_load(m.group(1))
            return data if isinstance(data, dict) else {}
        except Exception:
            out = {}
            for ln in m.group(1).splitlines():
                k, _, v = ln.partition(":")
                if v.strip():
                    out[k.strip()] = v.strip().strip("'\"")
            return out

    def _skills_list(self) -> List[dict]:
        bundled, off = self._bundled(), self._disabled()
        out = []
        for name, d in sorted(self._skill_dirs().items()):
            raw = (d / "SKILL.md").read_text(encoding="utf-8", errors="replace")
            fm = self._frontmatter(raw)
            desc, _ = redact(" ".join(str(fm.get("description") or "").split())[:160])
            out.append({"id": name, "title": str(fm.get("name") or name)[:60], "description": desc,
                        "enabled": name not in off, "bundled": name in bundled, "rev": rev_of(raw)})
        return out

    def _skill_dir(self, iid: str) -> Path:
        d = self._skill_dirs().get(iid)
        if d is None:
            raise Refused("bad_id")
        return d

    def _skills_get(self, iid: str):
        d = self._skill_dir(iid)
        raw = (d / "SKILL.md").read_text(encoding="utf-8", errors="replace")
        text, hid = redact(raw)
        fm = self._frontmatter(raw)
        return rev_of(raw), {"id": iid, "title": str(fm.get("name") or iid)[:60], "text": text,
                             "read_only": hid, "enabled": iid not in self._disabled(),
                             "bundled": iid in self._bundled(), "updated": _mtime(d / "SKILL.md")}

    def _skills_prepare(self, iid: str, req: dict):
        d = self._skill_dir(iid)
        if redact((d / "SKILL.md").read_text(encoding="utf-8", errors="replace"))[1]:
            raise Refused("read_only")
        text = _text_value(req)
        fm = self._frontmatter(text)
        if not fm.get("name") or not fm.get("description"):
            raise Refused("no_frontmatter")
        return d, text

    def _skills_put(self, iid: str, req: dict):
        d, text = self._skills_prepare(iid, req)
        self.trash("skills", iid, src=d / "SKILL.md")
        _atomic_write(d / "SKILL.md", text)
        rev, item = self._skills_get(iid)
        return rev, item, f'skill "{iid}" edited'

    def _skills_act(self, iid: str, verb: str):
        self._skill_dir(iid)
        before = self._disabled()
        old = "off" if iid in before else "on"
        after = before | {iid} if verb == "disable" else before - {iid}
        if after != before:
            self._save_disabled(after)
        rev, item = self._skills_get(iid)
        return old, rev, item, f'skill "{iid}" switched {"off" if verb == "disable" else "on"}'

    def _skills_delete(self, iid: str) -> Optional[str]:
        d = self._skill_dir(iid)
        if iid in self._bundled():
            raise Refused("bundled")
        self.trash("skills", iid, src=d)
        shutil.rmtree(d)
        if iid in self._disabled():
            self._save_disabled(self._disabled() - {iid})
        return None

    # -- config (the CLI's own load/save) ------------------------------------------

    def _load_config(self) -> dict:
        if self._config is not None:
            return self._config.load_config()
        try:
            from hermes_cli.config import load_config
            return load_config()
        except Exception:
            try:
                import yaml
                return yaml.safe_load((self.home / "config.yaml").read_text()) or {}
            except Exception:
                return {}

    def _save_disabled(self, disabled: set) -> None:
        mod = self._config
        if mod is None:
            from hermes_cli import config as mod
        cfg = mod.load_config()
        self.trash("skills", "config.yaml", src=self.home / "config.yaml")
        try:
            from hermes_cli.skills_config import save_disabled_skills
            save_disabled_skills(cfg, set(disabled))  # writes config["skills"]["disabled"] and saves
        except ImportError:
            cfg.setdefault("skills", {})["disabled"] = sorted(disabled)
            mod.save_config(cfg)

    # -- schedules ----------------------------------------------------------------

    @property
    def cron(self):
        if self._cron is None:
            from cron import jobs
            self._cron = jobs
        return self._cron

    def _job(self, iid: str) -> dict:
        for j in self.cron.list_jobs(include_disabled=True):
            if j.get("id") == iid:
                return j
        raise Refused("bad_id")

    @staticmethod
    def _job_rev(j: dict) -> str:
        return rev_of({"prompt": j.get("prompt"), "schedule": j.get("schedule_display"), "name": j.get("name")})

    @staticmethod
    def _job_row(j: dict) -> dict:
        paused = j.get("state") == "paused" or not j.get("enabled", True)
        name, _ = redact(str(j.get("name") or j.get("id"))[:60])
        return {"id": j["id"], "title": name, "when": when_in_words(j.get("schedule_display") or ""),
                "schedule": j.get("schedule_display"), "next_run": None if paused else j.get("next_run_at"),
                "paused": paused, "last_run": j.get("last_run_at"), "last_ok": _last_ok(j),
                "rev": Host._job_rev(j)}

    def _schedules_list(self) -> List[dict]:
        return [self._job_row(j) for j in self.cron.list_jobs(include_disabled=True)]

    def _schedules_get(self, iid: str):
        j = self._job(iid)
        text, hid = redact(j.get("prompt") or "")
        deliver = j.get("deliver")
        item = {**self._job_row(j), "text": text, "read_only": hid,
                "deliver": deliver if isinstance(deliver, str) else None,
                "last_error": redact(str(j.get("last_error") or ""))[0][:200] or None}
        return self._job_rev(j), item

    def _schedules_prepare(self, iid: str, req: dict):
        j = self._job(iid)
        v = req.get("value") if isinstance(req.get("value"), dict) else {}
        updates = {}
        if "text" in v:
            if redact(j.get("prompt") or "")[1]:
                raise Refused("read_only")
            text = _text_value(req)
            if not text.strip() and not j.get("script"):
                raise Refused("empty", "A schedule needs a prompt.")
            updates["prompt"] = text
        if "schedule" in v:
            s = v.get("schedule")
            if not isinstance(s, str) or not s.strip() or len(s) > 100:
                raise Refused("bad_schedule")
            try:
                parsed = self.cron.parse_schedule(s.strip())
            except Exception:
                raise Refused("bad_schedule")
            if parsed.get("kind") == "once":
                raise Refused("bad_schedule", "Pick a time that repeats.")
            updates["schedule"] = parsed
            updates["schedule_display"] = parsed.get("display") or s.strip()
        if not updates:
            raise Refused("bad_op", "Nothing to save.")
        return j, updates

    def _schedules_put(self, iid: str, req: dict):
        j, updates = self._schedules_prepare(iid, req)
        self.trash("schedules", iid, text=json.dumps(j, indent=2, default=str))
        self.cron.update_job(iid, updates)
        rev, item = self._schedules_get(iid)
        return rev, item, f'"{item["title"]}" edited'

    def _schedules_act(self, iid: str, verb: str):
        j = self._job(iid)
        old = j.get("state")
        fn = {"pause": self.cron.pause_job, "resume": self.cron.resume_job, "run": self.cron.trigger_job}[verb]
        if fn(iid) is None:
            raise Refused("not_found")
        rev, item = self._schedules_get(iid)
        if verb == "run":
            item["running_soon"] = True
        words = {"pause": "paused", "resume": "resumed", "run": "run now"}[verb]
        return old, rev, item, f'"{item["title"]}" {words}'

    def _schedules_delete(self, iid: str) -> Optional[str]:
        j = self._job(iid)
        self._last_name = str(j.get("name") or iid)[:60]
        self.trash("schedules", iid, text=json.dumps(j, indent=2, default=str))
        if not self.cron.remove_job(iid):
            raise Refused("not_found")
        return None

    # -- model (read only) ----------------------------------------------------------

    def _model_info(self) -> dict:
        cfg = self._load_config()
        m = cfg.get("model") or {}
        if isinstance(m, str):
            m = {"default": m}
        name = str(m.get("default") or m.get("model") or "not set")
        return {"id": "model", "model": name, "provider": provider_words(m),
                "toolsets": [{"name": str(t), "on": True} for t in (cfg.get("toolsets") or [])]}

    def _model_list(self) -> List[dict]:
        info = self._model_info()
        return [{"id": "model", "title": info["model"], "sub": info["provider"], "rev": rev_of(info)}]

    def _model_get(self, iid: str):
        if iid != "model":
            raise Refused("bad_id")
        info = self._model_info()
        return rev_of(info), info

    # -- channels (read only) -------------------------------------------------------

    def _channels_info(self) -> List[dict]:
        names = {}
        try:
            state = json.loads((self.home / "gateway_state.json").read_text())
            for k, v in (state.get("platforms") or {}).items():
                names[k] = (v or {}).get("state") == "connected"
        except (OSError, ValueError):
            pass
        for k, v in (self._load_config().get("platforms") or {}).items():
            if isinstance(v, dict) and v.get("enabled"):
                names.setdefault(k, False)
        return [{"id": k, "title": PLATFORM_NAMES.get(k, k.replace("_", " ").title()), "live": live}
                for k, live in sorted(names.items()) if re.match(r"^[a-z0-9_-]{1,40}$", k)]

    def _channels_list(self) -> List[dict]:
        return [{**c, "rev": rev_of(c)} for c in self._channels_info()]

    def _channels_get(self, iid: str):
        for c in self._channels_info():
            if c["id"] == iid:
                return rev_of(c), c
        raise Refused("bad_id")


PLATFORM_NAMES = {"yui": "Yui", "telegram": "Telegram", "discord": "Discord", "slack": "Slack", "email": "Email",
                  "whatsapp": "WhatsApp", "signal": "Signal", "imessage": "iMessage", "sms": "SMS",
                  "matrix": "Matrix", "api_server": "API", "webhook": "Webhook"}


def provider_words(m: dict) -> str:
    """"Claude on this Mac", "OpenRouter": the provider, never its key or URL."""
    base = str(m.get("base_url") or "")
    name = str(m.get("default") or m.get("model") or "").lower()
    family = next((f for k, f in (("claude", "Claude"), ("gpt", "GPT"), ("gemini", "Gemini"), ("llama", "Llama"),
                                  ("qwen", "Qwen"), ("hermes", "Hermes"), ("grok", "Grok")) if k in name), None)
    if re.search(r"//(127\.0\.0\.1|localhost|0\.0\.0\.0)[:/]", base):
        return f"{family or 'A model'} on this Mac"
    provider = str(m.get("provider") or "").strip()
    nice = {"anthropic": "Anthropic", "openrouter": "OpenRouter", "openai": "OpenAI", "nous": "Nous Portal",
            "google": "Google", "gemini": "Google", "custom": "a custom endpoint"}.get(provider.lower(), provider.title())
    if family and nice:
        return f"{family} through {nice}"
    return nice or family or "not set"


def _last_ok(j: dict) -> Optional[bool]:
    s = j.get("last_status")
    if s in ("ok", "success", "succeeded"):
        return True
    if s in ("error", "failed", "failure"):
        return False
    return None


def body_of(req: dict, ans: dict) -> str:
    """The plain line a control row carries for anyone reading the table. No values."""
    op, section = req.get("op") if isinstance(req, dict) else None, ans.get("section") or "?"
    what = f"{op or '?'} {section}" + (f" {ans['id']}" if ans.get("id") else "")
    return f"controls: {what}" + ("" if ans.get("ok") else f" ({ans.get('error')})")


def note(changes: List[str]) -> str:
    """What the agent reads on its next turn."""
    uniq = list(dict.fromkeys(changes))
    counts = {}
    for c in changes:
        counts[c] = counts.get(c, 0) + 1
    parts = []
    for c in uniq:
        n = counts[c]
        if c == "one memory forgotten" and n > 1:
            c = f"{n} memories forgotten"
        elif c == "one memory edited" and n > 1:
            c = f"{n} memories edited"
        parts.append(c)
    return "[yui] Your settings changed in Controls: " + ", ".join(parts[:12]) + ". (Already applied on the host; no reply needed.)"
