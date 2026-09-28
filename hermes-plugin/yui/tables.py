"""yui_tables: tables for any agent (YUI-171, yuigui spec/TABLES.md section 8).

The person's own little database in Yui, reached from a Hermes agent. The tool
posts the agent's table words to yui-connect /tables with this machine's
connector token; the server runs them on the same store native agents keep
(supabase/functions/_shared/tables.ts). The rules live there, never here: this
file only makes the call and reads the answer back to the model.

    hermes -p basil yui tables "query foods sort=-Protein limit=5"

The agent is this profile's Yui agent (its remote_ref: YUI_REMOTE_REF, else the
profile name). Stdlib only.

In the reply (step 3): table words in a ```yui block of the agent's answer come
out before the answer is saved. The adapter hands the whole answer to the same
call (reply=), saves the text it gets back (queries drawn as screens), and when
the answer was only query lines (a read) gives the rows back to the agent as
its next turn instead of saving anything.
"""
import json
import os
import re
import urllib.error
import urllib.request

try:
    from . import connector
except ImportError:  # run as a plain module in tests
    import connector  # type: ignore[no-redef]

SCHEMA = {
    "name": "yui_tables",
    "description": (
        "The person's own little database in Yui: tables you make, rows you write and read, kept for them even if "
        "they switch agents. lines are table words, one per line, run in order: `table create meals Day:date "
        "Food:text Cal:number:kcal` (types text, number, date, bool; a third part is the unit), `put meals Day=today "
        "Food=Oats Cal=300` (a bare word after the table name is the row key; put it again to change that row), "
        "`query meals where=Day=today sort=-Cal limit=10` (where: = != < > <= >= and ~ contains; also cols=, sum=, "
        "avg=, group=Day:week), `put meals r3 +delete`, `table drop meals`. Queries hand the rows back to you; to "
        "show them, put `query meals as table` (or a table, list or chart line) in your ```yui block. Deletes never "
        "run on your say: the person gets Delete or Keep, and their tap (`[yui] del-... choose`) settles on your "
        "next yui_tables call. No lines: settle taps and list the tables you hold. Limits: 50 lines a call, 20 "
        "tables an agent, 100 a person, 500 rows back from a query."),
    "parameters": {
        "type": "object",
        "properties": {
            "lines": {"type": "string", "description": "Table words, one per line, no ``` fence. Empty: list what you hold."},
        },
    },
}


def remote_ref() -> str:
    ref = os.getenv("YUI_REMOTE_REF") or connector.current_profile() or "default"
    return ref.split(",")[0].strip()


def call(lines: str = "", agent: str | None = None, reply: str | None = None) -> tuple[int, dict]:
    """POST yui-connect/tables. (status, body); 401 not_paired when this machine has no token."""
    token = connector.load().get("token")
    if not token:
        return 401, {"error": "not_paired"}
    body: dict = {"agent": agent or remote_ref()}
    if reply is not None:
        body["reply"] = reply
    else:
        body["lines"] = lines or ""
    req = urllib.request.Request(
        f"{connector.BASE}/tables", data=json.dumps(body).encode(), method="POST",
        headers={"content-type": "application/json", "apikey": connector.PUBLISHABLE, "user-agent": "yui-connect",
                 "authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"{}")
        except ValueError:
            return e.code, {"error": f"http_{e.code}"}
    except (urllib.error.URLError, TimeoutError) as e:
        return 503, {"error": "unreachable", "message": str(e)}


# Any table word: a reply without one never makes the call.
WORDS = re.compile(r"^[ \t]*(?:table[ \t]+(?:create|drop)[ \t]|put[ \t]+[A-Za-z]|query[ \t]+[A-Za-z])|^```tables\b", re.M)
TAP = re.compile(r"^\[yui\]\s+del-[A-Za-z0-9]+\s+choose\b")
MORE = "Here they are.\n"  # after two reads in a row, the next read is drawn for the person instead


def has_words(text: str) -> bool:
    return bool(WORDS.search(text or ""))


def in_reply(body: str, agent: str) -> tuple[str | None, str | None, str]:
    """An answer on its way to the person: (text to save, None, refused), or (None, note, "")
    when it only read, the note being the agent's next turn. refused says which table
    writes did not land, for the agent's next turn. Yui unreachable: the answer as is."""
    status, r = call(agent=agent, reply=body)
    if status != 200:
        return body, None, ""
    if r.get("read"):
        return None, r.get("note") or "[yui] Your tables: (nothing matched)", ""
    bad = [f["error"] for f in r.get("failed") or []][:3]
    return r.get("text", body), None, (f"[yui] Table writes in your last reply were refused: {'; '.join(bad)}." if bad else "")


def settled_note(agent: str) -> str:
    """After a Delete or Keep tap: settle it now and say what happened, for the agent's turn."""
    status, r = call("", agent=agent)
    if status != 200 or not r.get("settled"):
        return ""
    return "[yui] " + summary(status, {"settled": r["settled"]})


def rows_text(r: dict) -> str:
    cols = r.get("cols") or []
    keys = r.get("keys") or []
    with_key = any(k is not None for k in keys)
    head = (["key"] if with_key else []) + [c["name"] + (f" ({c['unit']})" if c.get("unit") else "") for c in cols]
    out = [r.get("table", ""), " | ".join(head)]
    for i, row in enumerate(r.get("rows") or []):
        cells = ([keys[i] or ""] if with_key else []) + ["" if v is None else str(v) for v in row]
        out.append(" | ".join(cells))
    if len(out) == 2:
        out.append("(no rows)")
    if (r.get("count") or 0) > len(r.get("rows") or []):
        out.append(f"({r['count']} rows match; the first {len(r['rows'])} are here.)")
    return "\n".join(out)


def summary(status: int, r: dict) -> str:
    """Plain words for the model: what ran, what was refused and why, the rows."""
    if status != 200:
        why = {
            "not_paired": "This machine is not paired with Yui.",
            "unauthorized": "Yui did not accept this machine's token. Pair again from the Yui app.",
            "no_such_agent": f"This token serves no Yui agent called {remote_ref()}.",
            "rate_limited": "Too many tables calls this minute. Wait a minute and try again.",
            "unreachable": "Yui can't be reached right now. Try again in a minute.",
        }.get(r.get("error", ""), r.get("message") or f"Yui answered {status} ({r.get('error', 'error')}).")
        return f"Nothing was written. {why}"
    parts = []
    for s in r.get("settled") or []:
        parts.append({"Delete": f"The person tapped Delete on {s['id']}: {s['deleted']} gone.",
                      "Keep": f"The person tapped Keep on {s['id']}: nothing deleted."}.get(
            s["choice"], f"{s['id']} waited a week with no tap: nothing deleted."))
    if r.get("ok"):
        parts.append(f"{len(r['ok'])} line{'' if len(r['ok']) == 1 else 's'} done.")
    for f in r.get("failed") or []:
        parts.append(f"Refused \"{f['line']}\": {f['error']}." if f.get("line") else f"Refused: {f['error']}.")
    if r.get("held"):
        parts.append(f"Nothing deleted yet: the person sees \"{r['held']['ask']}\" with Delete or Keep.")
    if not parts:
        t = r.get("tables") or []
        parts.append("You hold: " + ", ".join(f"{x['name']} ({x['rows']} rows: {', '.join(x['cols'])})" for x in t)
                     if t else "You hold no tables yet.")
    rows = [rows_text(x) for x in r.get("results") or []]
    return "\n\n".join([" ".join(parts), *rows])


def tool_handler(args: dict, **kw) -> str:
    """yui_tables, for hosts whose model calls Hermes tools."""
    status, r = call(str(args.get("lines") or ""))
    return json.dumps({"ok": status == 200, "text": summary(status, r),
                       **({"results": r.get("results"), "held": r.get("held")} if status == 200 else {"error": r.get("error")})})


def cmd_tables(args) -> int:
    """hermes -p <profile> yui tables "query foods" [--json]"""
    status, r = call(args.lines or "", agent=getattr(args, "agent", None))
    print(json.dumps(r, indent=2) if getattr(args, "json", False) else summary(status, r))
    return 0 if status == 200 and not r.get("failed") else 1


def add_cli(sub) -> None:
    t = sub.add_parser("tables", help="run table words on this profile's Yui tables (yui_tables)")
    t.add_argument("lines", nargs="?", default="", help="table create / put / query lines; none lists the tables")
    t.add_argument("--agent", help="which Yui agent (default: this profile's)")
    t.add_argument("--json", action="store_true", help="print the server's answer as JSON")
    t.set_defaults(fn=cmd_tables)
