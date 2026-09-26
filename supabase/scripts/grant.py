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
    grant.py plan [--by Sam]                      the owner's invite plan, as Yui Lines (YUI-97)
    grant.py send --answers JSON [--no-testflight] [--dry-run]   the plan's answers: template, invite, link

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

The owner's side (YUI-97): `plan` prints the one-screen invite plan the yui
agent sends (only client-safe agents are offered; the rest are named with the
rule that hides them), and `send` takes what the plan's Invite tap returned
(`{plan: {...}}`) and runs template save, invite.py add and approve. That tap
is the owner's yes for that person, so only ever run it from the owner's own tap.
Revoke also sends the person's phones a silent push so their list drops the
agent at once.

Needs a Supabase access token (SUPABASE_ACCESS_TOKEN or the CLI's keychain
entry), like invite.py. Prints people's emails only to this terminal.
"""
import argparse, importlib.util, json, os, re, secrets, subprocess, sys, urllib.error, urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kill_switch import REF, access_token, sql, lit  # noqa: E402

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


# A broken rule in the owner's words (the app says the same, AgentsView.swift).
PLAIN = [("no sandbox report", "its computer hasn't reported a sandbox yet"),
         ("its host has not", "its computer hasn't reported a sandbox yet"),
         ("profile:", "it shares a Hermes profile with your other agents"),
         ("keys:", "its profile holds keys beyond its model key"),
         ("terminal:", "it has a shell on your computer"),
         ("files:", "it can read your files"),
         ("reach:", "it can reach your other tools"),
         ("memory:", "its memory is shared between people"),
         ("runner:", "its model runs as an agent with a shell")]
LOOKS = ["candy", "ocean", "forest"]


def plain(rule: str) -> str:
    return next((words for key, words in PLAIN if rule.startswith(key)), rule)


def q(s: str) -> str:
    """A Yui Lines quoted value."""
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ") + '"'


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
    print(f"their phones: {revoke_push(ag['id'], who['id'])}")
    return 0


def service_key() -> str:
    """PROOF's service role key, from the Management API (never stored)."""
    req = urllib.request.Request(f"https://api.supabase.com/v1/projects/{REF}/api-keys?reveal=true",
                                 headers={"authorization": f"Bearer {access_token()}", "user-agent": "yui-grant"})
    with urllib.request.urlopen(req, timeout=30) as r:
        keys = json.loads(r.read())
    return next(k["api_key"] for k in keys if k.get("name") == "service_role")


def revoke_push(agent_id: str, user_id: str) -> str:
    """A silent push (kind revoked, no content): the app drops the agent now, not on its next refresh."""
    try:
        key = service_key()
        req = urllib.request.Request(f"https://{REF}.supabase.co/functions/v1/yui-push", method="POST",
                                     data=json.dumps({"action": "revoked", "agent_id": agent_id,
                                                      "user_id": user_id}).encode(),
                                     headers={"authorization": f"Bearer {key}", "apikey": key,
                                              "content-type": "application/json"})
        with urllib.request.urlopen(req, timeout=30) as r:
            out = json.loads(r.read())
        return f"told {out.get('delivered', 0)} of {out.get('devices', 0)} phone(s)"
    except (urllib.error.URLError, OSError, StopIteration, ValueError) as e:
        return f"push not sent ({e}); the app drops it on its next refresh"


def owner_agents(own: str | None) -> list[dict]:
    if not own:
        rows = sql("select distinct user_id from yui_agents where client_safe or sandbox is not null")
        if len(rows) != 1:
            sys.exit("more than one account has agents: add --owner <email>")
        own = rows[0]["user_id"]
    rows = sql(f"""select id, user_id, name, handle, remote_ref, client_safe, sandbox, client_safe_at
                     from yui_agents where user_id = {lit(own)}::uuid and avatar is distinct from 'yui'
                    order by sort, created_at""")
    for r in rows:
        if isinstance(r.get("sandbox"), str):
            r["sandbox"] = json.loads(r["sandbox"])
    return rows


def cmd_plan(a) -> int:
    """The owner's invite plan (spec "The owner's side"), as a ```yui block."""
    agents = owner_agents(owner_id(a.owner))
    safe = [x for x in agents if not why_not(x)]
    hidden = [x for x in agents if why_not(x)]
    if not safe:
        rules = "|".join(f"{x['name']}: {plain(why_not(x)[0])}" for x in hidden) or "You have no agents yet"
        print("```yui")
        print(f'card "Nothing is safe to share yet" body={q("Only an agent in its own sandbox can talk to someone else. Fix one of these and ask again.")}')
        print(f"list {q(rules)}")
        print("```")
        return REFUSED
    points = [f"{x['name']}. Safe to share" for x in safe] + \
             [f"{x['name']} is hidden: {plain(why_not(x)[0])}" for x in hidden]
    n = len(safe)
    print("```yui")
    lead = "One of your agents is" if n == 1 else f"{n} of your agents are"
    print(f"say {q(f'{lead} safe to share. Pick who gets what.')}")
    print('plan@invite "New client invite" submit=Invite')
    print(f'page "Who can be shared" body={q("Only agents marked safe to share show up here. Each one runs in its own sandbox: no shell, none of your files, nothing from your other clients.")} points={q("|".join(points))}')
    # Keys without spaces: the tap comes back flattened as plan.who.apple_id_email=...
    print('form@who "Who is it for?" first:text! last:text! apple_id_email:email! phone:phone')
    print(f'pick@agents "Which agents do they get?" {"|".join(q(x["name"]) for x in safe)}')
    print(f'choose@look "How should they look?" "Each agent\'s own"|{"|".join(x.capitalize() for x in LOOKS)}')
    by = "your_name:text!" if not a.by else ""
    print(f'form@hello "What does each one say first?" {" ".join(x["handle"] + "_says:long" for x in safe)} {by}'.rstrip())
    print(f'choose@save "Save this as a template?" "Save as client-default"|"Just this once"')
    print("```")
    return 0


def _value(body: str, i: int) -> tuple[object, int]:
    """One value at body[i:]: pieces (quoted or bare) joined by |; returns (str or list, next index)."""
    parts, cur = [], ""
    while i < len(body) and body[i] not in " \n":
        if body[i] == '"':
            i += 1
            while i < len(body) and body[i] != '"':
                if body[i] == "\\" and i + 1 < len(body):
                    i += 1
                    cur += "\n" if body[i] == "n" else body[i]
                else:
                    cur += body[i]
                i += 1
            i += 1
        elif body[i] == "|":
            parts.append(cur)
            cur = ""
            i += 1
        else:
            cur += body[i]
            i += 1
    parts.append(cur)
    return (parts if len(parts) > 1 else parts[0]), i


def event_answers(line: str) -> dict:
    """The Invite tap as the agent reads it (Thread.swift YLEvent.line):
    `[yui] invite plan plan.who.first=Ren plan.agents=Coach|"Basil Leaf" plan.look=Ocean ...`:
    keys flattened with dots, lists joined with |, text with spaces or | quoted."""
    out: dict = {}
    body = line.split(" plan ", 1)[1] if line.startswith("[yui] ") and " plan " in line else line
    i = 0
    while i < len(body):
        m = re.compile(r"\s*([^\s=]+)=").match(body, i)
        if not m:
            break
        key = m.group(1)
        val, i = _value(body, m.end())
        path = key.split(".")
        if path[0] == "plan":
            path = path[1:]
        node = out
        for k in path[:-1]:
            node = node.setdefault(k, {})
        if path[-1] in ("agents", "picked") and isinstance(val, str):
            val = [val] if val else []
        node[path[-1]] = val
    return out


def answers(raw: str) -> dict:
    raw = raw.strip()
    if not raw.startswith("{"):
        v = event_answers(raw)
        if not v:
            sys.exit("--answers: the plan's answers, as JSON or as the [yui] invite plan line")
        return v
    try:
        v = json.loads(raw)
    except ValueError:
        sys.exit("--answers: not JSON")
    v = v.get("plan", v) if isinstance(v, dict) else None
    if not isinstance(v, dict):
        sys.exit("--answers: the plan's answers, {who, agents, look, hello, save}")
    return v


def field(obj, *names) -> str:
    """A form answer by any of its keys ("Apple ID email", "email"), trimmed."""
    obj = obj if isinstance(obj, dict) else {}
    if isinstance(obj.get("form"), dict):
        obj = obj["form"]
    low = {str(k).lower().replace("_", " "): v for k, v in obj.items()}
    for n in names:
        v = low.get(n.lower().replace("_", " "))
        if isinstance(v, str) and v.strip():
            return v.strip()
    return ""


def cmd_send(a) -> int:
    """The plan's Invite tap: a template of the picked agents, an invite with it, the link."""
    ans = answers(a.answers)
    own = owner_id(a.owner)
    who = ans.get("who") or {}
    first, last = field(who, "first"), field(who, "last")
    email, phone = field(who, "apple_id_email", "Apple ID email", "email").lower(), field(who, "phone")
    if not (first and last and email):
        sys.exit("who: first, last and email are required")
    picked = ans.get("agents") or {}
    picked = picked.get("picked", []) if isinstance(picked, dict) else picked
    if not isinstance(picked, list) or not picked:
        sys.exit("agents: pick at least one")
    agents = owner_agents(own)
    by_name_ = {x["name"].lower(): x for x in agents}
    chosen = []
    for name in picked:
        x = by_name_.get(str(name).split(",")[0].strip().lower())
        if not x:
            sys.exit(f"agents: no agent {name}")
        require_safe(x)  # refused (exit 3) if it stopped passing since the plan went out
        chosen.append(x)
    look_ans = ans.get("look")
    look_ans = (look_ans.get("choice") if isinstance(look_ans, dict) else look_ans) or ""
    preset = look_ans.lower() if look_ans.lower() in LOOKS else None
    hello_ans = ans.get("hello") or {}
    sharer = a.by or field(hello_ans, "your_name", "Your name, as they see it", "by", "from")
    if not sharer:
        sys.exit("hello: who is sharing (your name, as they see it)")
    save_ans = ans.get("save")
    save_ans = (save_ans.get("choice") if isinstance(save_ans, dict) else save_ans) or ""
    m = re.match(r"^Save as ([a-z0-9][a-z0-9-]{0,39})$", save_ans.strip())
    name = m.group(1) if m else f"once-{secrets.token_hex(3)}"
    here = os.path.dirname(os.path.abspath(__file__))
    tcmd = [sys.executable, os.path.join(here, "grant.py")] + (["--owner", a.owner] if a.owner else []) + \
           ["template", "save", name, "--title", f"For {first} {last}" if not m else "Client default", "--by", sharer]
    for x in chosen:
        tcmd += ["--agent", x["id"]]
        says = field(hello_ans, f"{x['handle']}_says", f"{x['name']} says", x["handle"], x["name"])
        if says:
            tcmd += ["--hello", f"{x['id']}={says}"]
        if preset:
            tcmd += ["--look", f"{x['id']}={preset}"]
    plan = {"template": name, "agents": [x["name"] for x in chosen], "look": preset or "own", "by": sharer,
            "to": f"{first} {last} <{email}>"}
    if a.dry_run:
        print(json.dumps({"dry_run": True, **plan}))
        return 0
    r = subprocess.run(tcmd, capture_output=True, text=True)
    if r.returncode:
        print(r.stderr.strip() or r.stdout.strip(), file=sys.stderr)
        return r.returncode
    inv = [sys.executable, os.path.join(here, "invite.py")]
    add = inv + ["add", "--email", email, "--first", first, "--last", last, "--template", name] + \
          (["--phone", phone] if phone else [])
    r = subprocess.run(add, capture_output=True, text=True)
    if r.returncode and "already has an invite" not in (r.stderr + r.stdout):
        print(r.stderr.strip() or r.stdout.strip(), file=sys.stderr)
        return r.returncode
    r = subprocess.run(inv + ["approve", email, "--template", name, "--json"] +
                       (["--no-testflight"] if a.no_testflight else []), capture_output=True, text=True)
    try:
        out = json.loads(r.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        print(r.stderr.strip() or r.stdout.strip(), file=sys.stderr)
        return r.returncode or 1
    print(json.dumps({**plan, "invite": out["id"], "status": out["status"], "link": out["link"],
                      "testflight": out["testflight"]}))
    return r.returncode


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
    pl = sub.add_parser("plan")
    pl.add_argument("--by", help="who is sharing, when you don't want the plan to ask")
    se = sub.add_parser("send")
    se.add_argument("--answers", required=True, help="the plan's answers as JSON: {plan: {...}} or {...}")
    se.add_argument("--by")
    se.add_argument("--no-testflight", action="store_true")
    se.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    try:
        return {"safe": cmd_safe, "template": cmd_template, "grant": cmd_grant, "revoke": cmd_revoke,
                "list": cmd_list, "plan": cmd_plan, "send": cmd_send}[a.cmd](a)
    except Refused as e:
        print(str(e), file=sys.stderr)
        return REFUSED


if __name__ == "__main__":
    sys.exit(main())
