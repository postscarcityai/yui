#!/usr/bin/env python3
"""YUI-171 tables for any agent, against yuigui (live). yuigui spec/TABLES.md section 8.

On a fresh throwaway account (never a real one), two agents of one person:
Basil on Hermes (the real plugin module, hermes-plugin/yui/tables.py, with a
Hermes connector token) and Claude over MCP (yui-mcp tool yui_tables with an
MCP connector token).

  A. Basil makes foods, writes rows, reads them back; a bad line is refused
     with why and the rest still land; 51 lines are refused whole.
  B. Claude asks for foods: "No table called foods yet" (Basil holds it).
  C. Basil asks to delete a row: nothing goes, the person gets Delete or Keep
     in Basil's thread; the person taps Delete; Basil's next call settles it.
  D. The person gives foods to Claude (yui_tables_give, as the person).
     Claude reads the same rows over MCP; Basil reads nothing. Claude writes.
     A stranger's agent id is refused.
  E. The token reaches only its own agents; read_at is on the record.

    python3 supabase/tests/tables_any_agent_e2e.py [--transcript FILE]

The account is deleted at the end.
"""
import json, os, sys, tempfile, uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
exec(open(HERE / "agents_test.py").read().split("results = []")[0])

MCP = f"{BASE}/functions/v1/yui-mcp"
results, log = [], []
def say(line):
    print(line, flush=True); log.append(line)
def check(name, ok, detail=""):
    ok = bool(ok); results.append(ok)
    say(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{str(detail)[:400]}]" if detail else ""))

_n = [0]
def mcp_tool(token, name, args):
    _n[0] += 1
    s, r = http("POST", MCP, {"accept": "application/json, text/event-stream", "authorization": f"Bearer {token}"},
                {"jsonrpc": "2.0", "id": _n[0], "method": "tools/call", "params": {"name": name, "arguments": args}})
    assert s == 200 and "result" in r, (s, r)
    res = r["result"]
    text = res["content"][0]["text"]
    data = json.loads(text.rsplit("\n", 1)[1]) if not res.get("isError") else None
    return res, text, data

# The real plugin module, pointed at a temp connector file holding Basil's host token.
sys.path.insert(0, str(HERE.parent.parent / "hermes-plugin" / "yui"))
os.environ["YUI_CONNECTOR_FILE"] = str(Path(tempfile.mkdtemp()) / "connector.json")
os.environ["HERMES_PROFILE"] = "basil"
os.environ.pop("YUI_REMOTE_REF", None)
import connector as yc  # noqa: E402
import tables as yt  # noqa: E402

def basil(lines=""):
    s, r = yt.call(lines)
    say(f"  basil yui_tables({lines!r}) -> {s}")
    say("    " + yt.summary(s, r).replace("\n", "\n    "))
    return s, r

def claude(lines="", agent=None):
    res, text, data = mcp_tool(mcp_ct, "yui_tables", {"lines": lines, **({"agent": agent} if agent else {})})
    say(f"  claude yui_tables({lines!r}) ->{' isError' if res.get('isError') else ''}")
    say("    " + text.rsplit("\n", 1)[0].replace("\n", "\n    ") if data else "    " + text)
    return res, text, data

T = str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub) values ('{T}','test.{T}')")
tok = mint(T, ttl=3600)
mcp_ct = None
try:
    say("== setup: one person, Basil on Hermes, Claude over MCP")
    s, r = fn("yui-agents", {"action": "create", "name": "Basil", "pair": True}, tok)
    basil_id = r["agent"]["id"]
    s, r = fn("yui-connect", {"action": "pair", "code": r["pairing"]["code"], "remote_ref": "basil", "kind": "hermes"})
    yc.save({"token": r["connector_token"]})
    s, r = fn("yui-agents", {"action": "create", "name": "Claude", "pair": True}, tok)
    claude_id = r["agent"]["id"]
    s, r = fn("yui-connect", {"action": "pair", "code": r["pairing"]["code"], "remote_ref": "claude", "kind": "mcp",
                              "host_name": "Claude Code"})
    mcp_ct = r["connector_token"]
    check("both paired", basil_id and claude_id and mcp_ct.startswith("yui_ct_"))

    say("== A. Basil (Hermes plugin) makes a table and reads it")
    s, r = basil('table create foods Food:text Cal:number:kcal Protein:number:g\n'
                 'put foods oats Food=Oats Cal=300 Protein=10\nput foods eggs Food="Two eggs" Cal=140 Protein=12\n'
                 'put foods Food=Toast Cal=80 Protein=3\nput foods Cal=lots\nquery foods sort=-Protein')
    check("writes land, the query hands rows back", s == 200 and len(r["ok"]) == 5
          and r["results"][0]["rows"] == [["Two eggs", 140, 12], ["Oats", 300, 10], ["Toast", 80, 3]], r)
    check("a bad line is refused with why", len(r["failed"]) == 1 and "Cal" in r["failed"][0]["error"], r["failed"])
    rows = sql(f"select count(*) n from yui_native_table_rows where agent_id = '{basil_id}' and tname = 'foods'")[0]["n"]
    check("rows are in the one store, held by Basil", rows == 3, rows)
    s, r = yt.call("\n".join(["query foods"] * 51))
    check("51 lines: refused whole", s == 400 and r.get("error") == "too_many_lines", (s, r))

    say("== B. Claude (MCP) cannot see Basil's table")
    res, text, data = claude("query foods")
    check("Claude hears 'No table called foods yet'", res.get("isError") and "No table called foods yet" in text, text)

    say("== C. a delete asks the person first")
    s, r = basil("put foods oats +delete")
    held = r.get("held") or {}
    check("held, nothing deleted", s == 200 and held.get("id", "").startswith("del-")
          and held.get("ask") == "Delete Oats from foods?", r)
    ask = sql(f"select body from yui_messages where id = '{held.get('message_id')}' and agent_id = '{basil_id}' and sender = 'agent'")
    check("Delete or Keep is in Basil's thread", ask and f"choose@{held['id']}" in ask[0]["body"] and "Delete|Keep" in ask[0]["body"], ask)
    s, r = basil("query foods")
    check("the row is still there before the tap", r["results"][0]["count"] == 3, r["results"])
    s, r = rest("POST", "yui_messages", tok, {"user_id": T, "agent_id": basil_id, "sender": "user", "kind": "event",
                                               "body": f"[yui] {held['id']} choose choice=Delete",
                                               "meta": {"id": held["id"], "preset": "choose", "value": {"choice": "Delete"}}},
                "return=minimal")
    check("the person taps Delete (as the person)", s in (200, 201), (s, r))
    s, r = basil("query foods")
    check("Basil's next call settles it: Oats gone", r["settled"] == [{"id": held["id"], "choice": "Delete", "deleted": 1}]
          and [x[0] for x in r["results"][0]["rows"]] == ["Two eggs", "Toast"], r)

    say("== D. the person gives foods to Claude")
    s, r = rest("POST", "rpc/yui_tables_give", tok, {"from_agent": basil_id, "to_agent": claude_id, "tname": "foods"})
    say(f"  person yui_tables_give(foods: Basil -> Claude) -> {s} {r}")
    check("handed over", s == 200 and r == "foods", (s, r))
    res, text, data = claude("query foods sort=-Protein")
    check("Claude reads the same rows over MCP", data and data["results"][0]["rows"] == [["Two eggs", 140, 12], ["Toast", 80, 3]], text)
    s, r = basil("query foods")
    check("Basil reads nothing now", s == 200 and r["failed"] == [{"line": "query foods", "error": "No table called foods yet"}], r)
    res, text, data = claude("put foods Food=Rice Cal=200 Protein=4\nquery foods where=Food~ric")
    check("Claude writes to it", data and data["results"][0]["rows"] == [["Rice", 200, 4]], text)
    res, text, data = claude("")
    check("no lines: what Claude holds", data and data["tables"] == [{"name": "foods", "rows": 3, "cols": ["Food", "Cal", "Protein"]}], text)
    other = str(uuid.uuid4())
    s, r = rest("POST", "rpc/yui_tables_give", tok, {"from_agent": other, "to_agent": claude_id, "tname": "foods"})
    check("someone else's agent: refused", s >= 400 and "no_such_agent" in json.dumps(r), (s, r))
    s, r = basil("table create foods Food:text")
    s, r = rest("POST", "rpc/yui_tables_give", tok, {"from_agent": basil_id, "to_agent": claude_id, "tname": "foods"})
    check("same name twice: refused with a new name to try", s >= 400 and "name_taken: try foods-basil" in json.dumps(r), (s, r))

    say("== E. a token reaches only its own agents; reads are on the record")
    s, r = yt.call("query foods", agent="claude")
    check("Basil's host token cannot pass agent=claude", s == 404 and r.get("error") == "no_such_agent", (s, r))
    ra = sql(f"select read_at is not null r from yui_native_tables where agent_id = '{claude_id}' and name = 'foods'")
    check("Claude's read is on the record (read_at)", ra == [{"r": True}], ra)
finally:
    s, _ = fn("yui-delete", {}, tok)
    left = sql(f"select (select count(*) from yui_users where id = '{T}') + "
               f"(select count(*) from yui_native_tables where user_id = '{T}') + "
               f"(select count(*) from yui_table_holds where user_id = '{T}') + "
               f"(select count(*) from yui_messages where user_id = '{T}') n")[0]["n"]
    check("throwaway account deleted, nothing left", s == 200 and left == 0, f"{s} {left}")

say(f"\n{sum(results)}/{len(results)} passed")
if "--transcript" in sys.argv:
    Path(sys.argv[sys.argv.index("--transcript") + 1]).write_text("\n".join(log) + "\n")
sys.exit(0 if all(results) else 1)
