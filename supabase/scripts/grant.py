#!/usr/bin/env python3
"""YUI-95 shared agents: templates, grants and the client-safe check.

    grant.py safe <agent>                         the sandbox report and which rules pass
    grant.py template save <name> --title T --agent A [--agent B] [--look A=candy] [--hello A=TEXT] [--by Sam]
    grant.py template list
    grant.py template show <name>
    grant.py template delete <name>
    grant.py grant <agent> <email|user id> [--look candy|JSON] [--hello TEXT] [--by Sam]
    grant.py revoke <agent> <email|user id>
    grant.py list [--user <email|user id>] [--all]

Spec: yuigui spec/AGENTS.md, "Shared agents". An agent is named by its handle,
its Hermes profile (remote_ref), its name or its id; `--owner <email|id>`
picks whose agents when more than one account has that name.

Only a client-safe agent can be shared: its host reports a sandbox that passes
all five rules (yui-connect sets yui_agents.client_safe from the heartbeat).
Anything else is refused with the rule that failed and exit code 3. There is
no --force, and the database refuses the same insert on its own.

A grant gives one person their own thread with the agent, in the look given
(`--look`: a preset name like candy, or a theme object as JSON; default the
agent's own) with `--hello` waiting as its first message. Revoke hides the
thread from them and stops the host serving it at once. `invite.py approve
<id> --template <name>` hands a template out with an invite: claiming it
applies the template (yui_claim_invite).

Needs a Supabase access token (SUPABASE_ACCESS_TOKEN or the CLI's keychain
entry), like invite.py. Prints people's emails only to this terminal.
"""
import argparse, importlib.util, json, os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kill_switch import sql, lit  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "yui_sandbox", os.path.join(HERE, "..", "..", "hermes-plugin", "yui", "sandbox.py"))
sandbox = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sandbox)

UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
TEMPLATE = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
REFUSED = 3


class Refused(Exception):
    pass


def jlit(v) -> str:
    return lit(json.dumps(v)) + "::jsonb"


def owner_id(key: str | None) -> str | None:
    if not key:
        return None
    u = user(key)
    return u["id"]


def user(key: str) -> dict:
    where = f"id = {lit(key)}::uuid" if UUID.match(key) else f"lower(email) = lower({lit(key)})"
    rows = sql(f"select id, email from yui_users where {where}")
    if not rows:
        sys.exit(f"no Yui account for {key} (they sign in once first, or use an invite with a template)")
    return rows[0]


def agent(key: str, owner: str | None) -> dict:
    k = key.lower().lstrip("@")
    where = (f"id = {lit(key)}::uuid" if UUID.match(key) else
             f"(handle = {lit(k)} or lower(remote_ref) = {lit(k)} or lower(name) = {lit(k)})")
    if owner:
        where += f" and user_id = {lit(owner)}::uuid"
    rows = sql(f"""select id, user_id, name, handle, remote_ref, client_safe, sandbox, client_safe_at
                   from yui_agents where {where} order by created_at""")
    if not rows:
        sys.exit(f"no agent {key}")
    if len({r["user_id"] for r in rows}) > 1:
        sys.exit(f"{key} names agents in {len({r['user_id'] for r in rows})} accounts: add --owner <email>")
    if len(rows) > 1:
        sys.exit(f"{key} names {len(rows)} agents: use its id ({', '.join(r['id'] for r in rows)})")
    r = rows[0]
    if isinstance(r.get("sandbox"), str):
        r["sandbox"] = json.loads(r["sandbox"])
    return r


def why_not(a: dict) -> list[str]:
    """The rules this agent breaks right now; [] = client-safe. The DB mark wins:
    a report that passes here still needs the host to have said so."""
    report = {k: v for k, v in (a.get("sandbox") or {}).items() if k not in ("why", "at")}
    fails = sandbox.failures(report or None)
    if not fails and not a.get("client_safe"):
        fails = ["its host has not reported it client-safe"]
    return fails


def require_safe(a: dict) -> None:
    fails = why_not(a)
    if fails:
        raise Refused(f"refused: {a['handle'] or a['name']} is not client-safe ({'; '.join(fails)})")


def look(v: str | None) -> dict:
    if not v:
        return {}
    if v.strip().startswith("{"):
        try:
            obj = json.loads(v)
        except ValueError:
            sys.exit("look: not valid JSON")
        if not isinstance(obj, dict):
            sys.exit("look: a theme object")
        return obj
    if not re.match(r"^[a-z][a-z0-9-]{0,23}$", v):
        sys.exit("look: a preset name (candy, ocean, ...) or a theme object as JSON")
    return {"preset": v, "by": "owner"}


def hello(v: str | None) -> str | None:
    if v is None:
        return None
    v = v.strip()
    if not 1 <= len(v) <= 2000:
        sys.exit("hello: 1 to 2,000 characters")
    return v


def by_name(v: str | None) -> str | None:
    if v is None:
        return None
    v = v.strip()
    if not 1 <= len(v) <= 40:
        sys.exit("--by: 1 to 40 characters")
    return v


def per_agent(pairs: list[str], flag: str) -> dict:
    out = {}
    for p in pairs or []:
        if "=" not in p:
            sys.exit(f"{flag}: AGENT=VALUE")
        k, v = p.split("=", 1)
        out[k.strip().lower().lstrip("@")] = v
    return out


def write(q: str):
    """sql() for writes: the database's own client-safe refusal is exit 3 too."""
    try:
        return sql(q)
    except SystemExit as e:
        if "agent_not_client_safe" in str(e.code):
            raise Refused("refused by the database: agent_not_client_safe")
        raise


def cmd_safe(a) -> int:
    ag = agent(a.agent, owner_id(a.owner))
    rep = ag.get("sandbox") or {}
    print(f"{ag['name']} (@{ag['handle']}, profile {ag['remote_ref'] or '-'})")
    if rep:
        for k in ("profile", "extra_keys", "terminal", "files", "reach", "memory", "runner"):
            if k in rep:
                print(f"  {k:<10} {rep[k] if not isinstance(rep[k], list) else ', '.join(rep[k]) or 'none'}")
        print(f"  reported   {rep.get('at', '?')}")
    fails = why_not(ag)
    if fails:
        print("not client-safe:\n" + "\n".join(f"  - {f}" for f in fails))
        return REFUSED
    print(f"client-safe since {ag['client_safe_at']}")
    return 0


def cmd_template(a) -> int:
    own = owner_id(a.owner)
    if a.tcmd == "list":
        where = f"where t.owner_id = {lit(own)}::uuid" if own else ""
        rows = sql(f"""select t.name, t.title, t.shared_by, count(i.agent_id)::int n,
                              string_agg(ag.handle, ', ' order by i.sort) agents
                         from yui_agent_templates t
                         left join yui_agent_template_items i on i.template_id = t.id
                         left join yui_agents ag on ag.id = i.agent_id
                         {where} group by t.id order by t.name""")
        for r in rows:
            print(f"{r['name']:<24} {r['title']:<28} {r['n']} agent(s): {r['agents'] or '-'}")
        print(f"{len(rows)} template(s)")
        return 0

    if not TEMPLATE.match(a.name):
        sys.exit("template name: lowercase letters, digits and dashes")

    def find() -> dict:
        where = f"name = {lit(a.name)}" + (f" and owner_id = {lit(own)}::uuid" if own else "")
        rows = sql(f"select id, owner_id, name, title, shared_by from yui_agent_templates where {where}")
        if not rows:
            sys.exit(f"no template {a.name}")
        if len(rows) > 1:
            sys.exit(f"{a.name} is a template in {len(rows)} accounts: add --owner <email>")
        return rows[0]

    if a.tcmd == "show":
        t = find()
        print(f"{t['name']}: {t['title']}" + (f" (shared by {t['shared_by']})" if t["shared_by"] else ""))
        for r in sql(f"""select ag.name, ag.handle, ag.client_safe, i.theme, i.first_message, i.sort
                           from yui_agent_template_items i join yui_agents ag on ag.id = i.agent_id
                          where i.template_id = {lit(t['id'])}::uuid order by i.sort"""):
            state = "safe" if r["client_safe"] else "NOT SAFE NOW (skipped on claim)"
            print(f"  {r['sort']}. {r['name']} @{r['handle']} [{state}] look={json.dumps(r['theme'])}")
            if r["first_message"]:
                print(f"     says: {r['first_message'][:120]}")
        return 0

    if a.tcmd == "delete":
        t = find()
        sql(f"delete from yui_agent_templates where id = {lit(t['id'])}::uuid")
        print(f"deleted template {t['name']} (grants already made keep their look and first message)")
        return 0

    # save: every agent must be client-safe, and all belong to one owner.
    if not a.agent:
        sys.exit("template save: at least one --agent")
    if not a.title or not 1 <= len(a.title.strip()) <= 60:
        sys.exit("--title: 1 to 60 characters")
    looks, hellos = per_agent(a.look, "--look"), per_agent(a.hello, "--hello")
    agents = [agent(k, own) for k in a.agent]
    owners = {x["user_id"] for x in agents}
    if len(owners) > 1:
        sys.exit("a template holds one owner's agents")
    for x in agents:
        require_safe(x)
    owner = owners.pop()
    keys = {k: x for k, x in zip([k.lower().lstrip("@") for k in a.agent], agents)}
    for k in list(looks) + list(hellos):
        if k not in keys:
            sys.exit(f"--look/--hello names {k}, which is not one of the --agent values")
    items = []
    for i, (k, x) in enumerate(keys.items()):
        items.append(f"({lit(x['id'])}::uuid, {lit(owner)}::uuid, {jlit(look(looks.get(k)))}, "
                     f"{lit(hello(hellos[k])) if k in hellos else 'null'}, {i})")
    by = by_name(a.by)
    # One call, one implicit transaction: the template and its items land together.
    tsel = f"(select id from yui_agent_templates where owner_id = {lit(owner)}::uuid and name = {lit(a.name)})"
    rows = write(f"""insert into yui_agent_templates (owner_id, name, title, shared_by)
            values ({lit(owner)}::uuid, {lit(a.name)}, {lit(a.title.strip())}, {lit(by) if by else 'null'})
            on conflict (owner_id, name) do update set title = excluded.title, shared_by = excluded.shared_by;
          delete from yui_agent_template_items where template_id = {tsel};
          insert into yui_agent_template_items (template_id, agent_id, owner_id, theme, first_message, sort)
          select {tsel}, v.agent_id, v.owner_id, v.theme, v.first_message, v.sort
            from (values {', '.join(items)}) v(agent_id, owner_id, theme, first_message, sort)
          returning agent_id""")
    print(f"saved template {a.name}: {len(rows)} agent(s): {', '.join(x['handle'] for x in agents)}")
    print(f"hand it out: invite.py approve <id|email> --template {a.name}")
    return 0


def cmd_grant(a) -> int:
    ag = agent(a.agent, owner_id(a.owner))
    require_safe(ag)
    who = user(a.user)
    if who["id"] == ag["user_id"]:
        sys.exit("that is the agent's owner")
    first = hello(a.hello)
    by = by_name(a.by)
    # One call, one implicit transaction: the grant and its first message land
    # together or not at all. now() is the transaction's time, so it names this
    # call's grant (an existing live grant is left alone).
    live = f"g.agent_id = {lit(ag['id'])}::uuid and g.user_id = {lit(who['id'])}::uuid and g.revoked_at is null"
    rows = write(f"""insert into yui_agent_grants (agent_id, owner_id, user_id, theme, first_message, shared_by)
            values ({lit(ag['id'])}::uuid, {lit(ag['user_id'])}::uuid, {lit(who['id'])}::uuid,
                    {jlit(look(a.look))}, {lit(first) if first else 'null'}, {lit(by) if by else 'null'})
            on conflict do nothing;
          insert into yui_messages (user_id, agent_id, sender, kind, body, meta)
          select g.user_id, g.agent_id, 'agent', 'text', g.first_message, '{{"first": true}}'::jsonb
            from yui_agent_grants g where {live} and g.granted_at = now() and g.first_message is not null;
          select g.id, (g.first_message is not null) as messages
            from yui_agent_grants g where {live} and g.granted_at = now()""")
    if not rows or not rows[0]["id"]:
        print(f"{who['email'] or who['id']} already has {ag['name']}")
        return 0
    print(f"granted {ag['name']} to {who['email'] or who['id']} (grant {rows[0]['id']}"
          f"{', first message waiting' if rows[0]['messages'] else ''})")
    return 0


def cmd_revoke(a) -> int:
    ag = agent(a.agent, owner_id(a.owner))
    who = user(a.user)
    rows = sql(f"""update yui_agent_grants set revoked_at = now()
                    where agent_id = {lit(ag['id'])}::uuid and user_id = {lit(who['id'])}::uuid
                      and revoked_at is null returning id""")
    if not rows:
        print(f"{who['email'] or who['id']} has no live grant for {ag['name']}")
        return 1
    print(f"revoked {ag['name']} from {who['email'] or who['id']}: the thread is hidden and its host stops at once")
    return 0


def cmd_list(a) -> int:
    where = [] if a.all else ["g.revoked_at is null"]
    if a.user:
        where.append(f"g.user_id = {lit(user(a.user)['id'])}::uuid")
    own = owner_id(a.owner)
    if own:
        where.append(f"g.owner_id = {lit(own)}::uuid")
    rows = sql(f"""select g.id, ag.name, ag.handle, ag.client_safe, u.email, g.template, g.granted_at, g.revoked_at
                     from yui_agent_grants g join yui_agents ag on ag.id = g.agent_id
                     join yui_users u on u.id = g.user_id
                    {'where ' + ' and '.join(where) if where else ''} order by g.granted_at""")
    for r in rows:
        state = f"revoked {str(r['revoked_at'])[:16]}" if r["revoked_at"] else ("live" if r["client_safe"] else "paused")
        print(f"{r['name']:<16} {r['email'] or '-':<36} {state:<22} {r['template'] or ''}  {str(r['granted_at'])[:16]}")
    print(f"{len(rows)} grant(s)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--owner", help="whose agents, when a name is in more than one account")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("safe").add_argument("agent")
    t = sub.add_parser("template").add_subparsers(dest="tcmd", required=True)
    s = t.add_parser("save")
    s.add_argument("name")
    s.add_argument("--title", required=True)
    s.add_argument("--agent", action="append")
    s.add_argument("--look", action="append", help="AGENT=preset or AGENT=JSON")
    s.add_argument("--hello", action="append", help="AGENT=first message")
    s.add_argument("--by", help="who is sharing, as the client sees it: Sam")
    t.add_parser("list")
    t.add_parser("show").add_argument("name")
    t.add_parser("delete").add_argument("name")
    g = sub.add_parser("grant")
    g.add_argument("agent")
    g.add_argument("user")
    g.add_argument("--look")
    g.add_argument("--hello")
    g.add_argument("--by")
    r = sub.add_parser("revoke")
    r.add_argument("agent")
    r.add_argument("user")
    ls = sub.add_parser("list")
    ls.add_argument("--user")
    ls.add_argument("--all", action="store_true", help="revoked grants too")
    a = ap.parse_args()
    try:
        return {"safe": cmd_safe, "template": cmd_template, "grant": cmd_grant,
                "revoke": cmd_revoke, "list": cmd_list}[a.cmd](a)
    except Refused as e:
        print(str(e), file=sys.stderr)
        return REFUSED


if __name__ == "__main__":
    sys.exit(main())
