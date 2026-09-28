#!/usr/bin/env python3
"""YUI-171 step 3: tables in any agent's reply, against yuigui (live). yuigui
spec/TABLES.md section 8, "In the reply" and "The agent learns what it has".

On a fresh throwaway account (never a real one), Basil on Hermes, through the
real plugin module (hermes-plugin/yui/tables.py, the calls the adapter makes
before it saves a reply), and a second agent, Chef, on a webhook host.

  A. A reply with table words: the lines come out, the rows land, each query
     is drawn as a screen in the text the adapter saves.
  B. A reply of query lines alone is a read: nothing to save, the rows come
     back as the agent's next turn (note).
  C. A reply that deletes: nothing goes, the saved text carries Delete or Keep;
     the person's tap settles on the agent's next call.
  D. Only writes: "Saved." and the table that changed.
  E. The person gives foods to Chef: the person's next message to Chef carries
     the [yui] tables line (meta.tables), once; Basil's thread gets none.

    python3 supabase/tests/tables_reply_e2e.py [--transcript FILE]

The account is deleted at the end.
"""
import json, os, sys, tempfile, uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
exec(open(HERE / "agents_test.py").read().split("results = []")[0])

results, log = [], []
def say(line):
    print(line, flush=True); log.append(line)
def check(name, ok, detail=""):
    ok = bool(ok); results.append(ok)
    say(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{str(detail)[:400]}]" if detail else ""))

sys.path.insert(0, str(HERE.parent.parent / "hermes-plugin" / "yui"))
os.environ["YUI_CONNECTOR_FILE"] = str(Path(tempfile.mkdtemp()) / "connector.json")
os.environ["HERMES_PROFILE"] = "basil"
os.environ.pop("YUI_REMOTE_REF", None)
import connector as yc  # noqa: E402
import tables as yt  # noqa: E402

def reply(agent, body):
    text, note, refused = yt.in_reply(body, agent)
    if refused:
        say(f"    agent's next turn: {refused}")
    say(f"  basil replies {body!r}")
    say("    saved: " + (repr(text) if note is None else "nothing (a read)"))
    if note is not None:
        say("    next turn: " + note.replace("\n", "\n      "))
    return text, note

def person(agent, body):
    s, r = rest("POST", "yui_messages", tok, {"user_id": T, "agent_id": agent, "sender": "user", "kind": "text", "body": body},
                "return=representation")
    assert s in (200, 201), (s, r)
    return r[0]

T = str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub) values ('{T}','test.{T}')")
tok = mint(T, ttl=3600)
try:
    say("== setup: one person, Basil on Hermes, Chef on a webhook host")
    s, r = fn("yui-agents", {"action": "create", "name": "Basil", "pair": True}, tok)
    basil_id = r["agent"]["id"]
    s, r = fn("yui-connect", {"action": "pair", "code": r["pairing"]["code"], "remote_ref": "basil", "kind": "hermes"})
    yc.save({"token": r["connector_token"]})
    s, r = fn("yui-agents", {"action": "create", "name": "Chef", "pair": True}, tok)
    chef_id = r["agent"]["id"]
    s, r = fn("yui-connect", {"action": "pair", "code": r["pairing"]["code"], "remote_ref": "chef", "kind": "http"})
    check("both paired", basil_id and chef_id and r.get("connector_token", "").startswith("yui_ct_"))

    say("== A. table words in the reply come out; queries are drawn")
    text, note = reply(basil_id, "Logged your breakfast.\n```yui\n"
                       "table create foods Food:text Cal:number:kcal Protein:number:g\n"
                       "put foods oats Food=Oats Cal=300 Protein=10\nput foods eggs Food=\"Two eggs\" Cal=140 Protein=12\n"
                       "query foods sort=-Protein as table \"Foods\"\n```")
    check("no table words left in the saved text", note is None and "put foods" not in text and "table create" not in text, text)
    check("the query is drawn with the real rows", text.startswith("Logged your breakfast.") and "Two eggs" in text
          and "Oats" in text and "query foods" not in text, text)
    rows = sql(f"select count(*) n from yui_native_table_rows where agent_id = '{basil_id}' and tname = 'foods'")[0]["n"]
    check("the rows are in the store, held by Basil", rows == 2, rows)

    say("== B. query lines alone are a read")
    text, note = reply(basil_id, "```yui\nquery foods where=Food~oat\n```")
    check("nothing to save", text is None, text)
    check("the rows come back as the next turn", note and note.startswith("[yui] Your tables:") and "Oats | 300 | 10" in note
          and "Answer the person now" in note, note)
    ra = sql(f"select read_at is not null r from yui_native_tables where agent_id = '{basil_id}' and name = 'foods'")
    check("the read is on the record (read_at)", ra == [{"r": True}], ra)

    say("== C. a delete in the reply asks first")
    text, note = reply(basil_id, "Eggs are gone.\n```yui\nput foods eggs +delete\n```")
    held = sql(f"select id, ask from yui_table_holds where agent_id = '{basil_id}' and done_at is null")
    check("held, the saved text carries Delete or Keep", held and f"choose@{held[0]['id']}" in text and "Delete|Keep" in text, text)
    check("words that say it's gone are replaced", "Eggs are gone" not in text and text.startswith("Tap Delete to confirm."), text)
    tap = person(basil_id, f"[yui] {held[0]['id']} choose choice=Delete")
    said = yt.settled_note(basil_id)
    say(f"  person taps Delete; Basil's turn reads: {said}")
    check("the tap settles on the next call and the agent is told", said == f"[yui] The person tapped Delete on {held[0]['id']}: 1 gone.", said)

    say("== D. only writes: Saved. and the table")
    text, note = reply(basil_id, "```yui\nput foods Food=Toast Cal=80 Protein=3\n```")
    check("Saved. with the table that changed", text and text.startswith("Saved.\n```yui\ntable") and "Toast" in text, text)
    text, note = reply(basil_id, "```yui\nput foods Cal=lots\n```")
    check("a refused line leaves nothing to save", note is None and not (text or "").strip(), text)

    say("== E. hand over: the next turn opens with what Chef holds")
    s, r = rest("POST", "rpc/yui_tables_give", tok, {"from_agent": basil_id, "to_agent": chef_id, "tname": "foods"})
    check("person gives foods to Chef", s == 200 and r == "foods", (s, r))
    first = person(chef_id, "what do I have?")
    say(f"  person -> Chef: meta.tables = {first['meta'].get('tables')!r}")
    check("the [yui] tables line rides on the person's next message", first["meta"].get("tables")
          == "[yui] tables foods(2 rows: Food, Cal, Protein)", first["meta"])
    second = person(chef_id, "and now?")
    check("once only", "tables" not in second["meta"], second["meta"])
    other = person(basil_id, "hi")
    check("Basil's thread gets no line", "tables" not in other["meta"], other["meta"])
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
