#!/usr/bin/env python3
"""YUI-56 invites: list requests, approve or decline them, invite someone directly.

    invite.py list [--status requested] [--json]
    invite.py add --email E --first F --last L [--phone P] [--template T] [--notes N]
    invite.py approve <id|email> [--template T] [--no-testflight] [--dry-run] [--json]
    invite.py decline <id|email>
    invite.py reissue <id|email>          a new code (the old one stops working)
    invite.py group                       make sure the TestFlight group exists

`approve` is Chris's sign-off, so only run it after he says yes. It makes a
one-time code (stored as its SHA-256, shown once), then adds the person as a
tester to the external TestFlight group "Invited" through the App Store
Connect API. Apple emails them the TestFlight invite; Yui sends no email of
its own. Their first Sign in with Apple claims the invite by that email; if
they hide their email, the link https://www.yuigui.com/i/<code> (or the code
typed on the sign-in screen) claims it. `--dry-run` prints the App Store
Connect request instead of sending it; `--no-testflight` stops at approved.

Table and states: migration 20260924110000_yui_invites.sql. Needs a Supabase
access token (SUPABASE_ACCESS_TOKEN or the CLI's keychain entry), like the
tests, and the App Store Connect key scripts/asc.py reads. Prints a person's
details only to this terminal; never commit its output.
"""
import argparse, hashlib, json, os, re, secrets, subprocess, sys, urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from kill_switch import sql, lit  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
APP = "6815454240"
GROUP = "Invited"
LINK = "https://www.yuigui.com/i/"
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
EMAIL = re.compile(r"^[^\s@]+@[^\s@]+\.[^\s@]{2,}$")
TEMPLATE = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
# No 0/O, 1/I/L, U: easy to read out loud and to type.
ALPHABET = "ABCDEFGHJKMNPQRSTVWXYZ23456789"
COLUMNS = ("id, first_name, last_name, email, phone, source, status, agent_template, notes, "
           "asc_tester_id, asc_error, claimed_user_id, created_at, approved_at, invited_at, claimed_at")


def new_code() -> str:
    raw = "".join(secrets.choice(ALPHABET) for _ in range(10))
    return f"{raw[:5]}-{raw[5:]}"


def code_hash(code: str) -> str:
    """Same rule as yui-auth's normCode: uppercase, letters and digits only."""
    return hashlib.sha256(re.sub(r"[^A-Z0-9]", "", code.upper()).encode()).hexdigest()


def find(key: str) -> dict:
    where = f"id = {lit(key)}::uuid" if UUID.match(key) else f"lower(email) = lower({lit(key)})"
    rows = sql(f"select {COLUMNS} from yui_invites where {where}")
    if not rows:
        sys.exit(f"no invite for {key}")
    return rows[0]


def asc(method: str, path: str, body=None):
    args = [sys.executable, os.path.join(ROOT, "scripts", "asc.py"), method, path]
    if body is not None:
        args.append(json.dumps(body))
    out = subprocess.run(args, capture_output=True, text=True).stdout.strip()
    if out[:3].isdigit() and out[3:4] == " ":
        return int(out[:3]), out[4:]
    return 200, (json.loads(out) if out else {})


def group_id(create: bool) -> str | None:
    s, r = asc("GET", f"/v1/apps/{APP}/betaGroups?limit=200")
    if s >= 300:
        raise SystemExit(f"App Store Connect: {s} {r[:300]}")
    g = next((g for g in r["data"] if g["attributes"]["name"] == GROUP), None)
    if g or not create:
        return g and g["id"]
    s, r = asc("POST", "/v1/betaGroups", {"data": {
        "type": "betaGroups",
        "attributes": {"name": GROUP, "publicLinkEnabled": False},
        "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})
    if s >= 300:
        raise SystemExit(f"could not create the {GROUP} group: {s} {r[:300]}")
    print(f'created the TestFlight group "{GROUP}"; scripts/testflight_public.py adds builds to it')
    return r["data"]["id"]


def add_tester(inv: dict, dry: bool) -> tuple[str | None, str | None]:
    """Returns (tester id, error). Apple emails the person when this works."""
    attrs = {"email": inv["email"]}
    if inv["first_name"]:
        attrs["firstName"] = inv["first_name"]
    if inv["last_name"]:
        attrs["lastName"] = inv["last_name"]
    gid = group_id(create=not dry) or "<Invited group id>"
    body = {"data": {"type": "betaTesters", "attributes": attrs,
                     "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": gid}]}}}}
    if dry:
        print("dry run, would send: POST /v1/betaTesters " + json.dumps(body))
        return None, None
    s, r = asc("POST", "/v1/betaTesters", body)
    if s < 300:
        return r["data"]["id"], None
    if s == 409:
        # Already a tester of this app (another group): add them to Invited.
        q, found = asc("GET", "/v1/betaTesters?filter[email]=" + urllib.parse.quote(inv["email"]) + f"&filter[apps]={APP}&limit=1")
        if q < 300 and found.get("data"):
            tid = found["data"][0]["id"]
            s2, r2 = asc("POST", f"/v1/betaGroups/{gid}/relationships/betaTesters",
                         {"data": [{"type": "betaTesters", "id": tid}]})
            return (tid, None) if s2 < 300 else (None, f"{s2} {str(r2)[:300]}")
    return None, f"{s} {str(r)[:300]}"


def show(rows, as_json: bool):
    if as_json:
        print(json.dumps(rows, indent=1, default=str))
        return
    for r in rows:
        name = " ".join(x for x in (r["first_name"], r["last_name"]) if x) or "(no name)"
        extra = f"  template={r['agent_template']}" if r["agent_template"] else ""
        print(f"{r['id']}  {r['status']:<9}  {name}  <{r['email']}>  {r['phone'] or ''}"
              f"  {r['source'] or ''}  {str(r['created_at'])[:10]}{extra}")
    print(f"{len(rows)} invite(s)")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("list")
    p.add_argument("--status", choices=["requested", "approved", "invited", "claimed", "declined"])
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("add")
    p.add_argument("--email", required=True)
    p.add_argument("--first", required=True)
    p.add_argument("--last", required=True)
    p.add_argument("--phone")
    p.add_argument("--template")
    p.add_argument("--notes")
    p = sub.add_parser("approve")
    p.add_argument("key")
    p.add_argument("--template")
    p.add_argument("--no-testflight", action="store_true")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--json", action="store_true")
    for name in ("decline", "reissue"):
        sub.add_parser(name).add_argument("key")
    sub.add_parser("group")
    a = ap.parse_args()

    if getattr(a, "template", None) and not TEMPLATE.match(a.template):
        sys.exit("template: lowercase letters, digits and dashes")

    if a.cmd == "list":
        where = f"where status = {lit(a.status)}" if a.status else ""
        show(sql(f"select {COLUMNS} from yui_invites {where} order by created_at"), a.json)
        return 0

    if a.cmd == "group":
        print(f'TestFlight group "{GROUP}": {group_id(create=True)}')
        return 0

    if a.cmd == "add":
        email = a.email.strip().lower()
        if not EMAIL.match(email):
            sys.exit("that email does not look right")
        phone = re.sub(r"[^\d+]", "", a.phone or "") or None
        vals = ", ".join(lit(v) if v else "null" for v in
                         (email, a.first.strip()[:80], a.last.strip()[:80], phone, a.template, a.notes))
        rows = sql(f"""insert into yui_invites (email, first_name, last_name, phone, agent_template, notes, source)
                       values ({vals}, 'invite.py')
                       on conflict (lower(email)) do nothing returning {COLUMNS}""")
        if not rows:
            sys.exit(f"{email} already has an invite: invite.py approve {email}")
        show(rows, False)
        return 0

    inv = find(a.key)

    if a.cmd == "decline":
        if inv["status"] == "claimed":
            sys.exit("already claimed; suspend the account instead (kill_switch.py)")
        sql(f"update yui_invites set status = 'declined', declined_at = now(), code_hash = null where id = {lit(inv['id'])}")
        print(f"{inv['id']} declined")
        return 0

    if a.cmd == "reissue":
        if inv["status"] not in ("approved", "invited"):
            sys.exit(f"invite is {inv['status']}; approve it first")
        code = new_code()
        sql(f"update yui_invites set code_hash = {lit(code_hash(code))} where id = {lit(inv['id'])}")
        print(f"new code {code}\nlink {LINK}{code}")
        return 0

    # approve
    if inv["status"] in ("claimed", "declined"):
        sys.exit(f"invite is {inv['status']}")
    if a.dry_run:
        add_tester(inv, dry=True)
        return 0
    code = new_code()
    tmpl = f", agent_template = {lit(a.template)}" if a.template else ""
    sql(f"""update yui_invites set status = case when status = 'invited' then status else 'approved' end,
              approved_at = coalesce(approved_at, now()), declined_at = null,
              code_hash = {lit(code_hash(code))}{tmpl}
            where id = {lit(inv['id'])}""")
    result = {"id": inv["id"], "status": "approved", "code": code, "link": LINK + code, "testflight": None}
    if not a.no_testflight and inv["status"] != "invited":
        tid, err = add_tester(inv, dry=False)
        if tid:
            sql(f"""update yui_invites set status = 'invited', invited_at = now(), asc_tester_id = {lit(tid)},
                      asc_error = null where id = {lit(inv['id'])}""")
            result.update(status="invited", testflight="Apple is emailing the TestFlight invite")
        else:
            sql(f"update yui_invites set asc_error = {lit(err or '')} where id = {lit(inv['id'])}")
            result["testflight"] = f"failed: {err}"
    elif inv["status"] == "invited":
        result.update(status="invited", testflight="already a tester")
    if a.json:
        print(json.dumps(result))
    else:
        print(f"{result['id']} {result['status']}\ncode {code}\nlink {result['link']}\n"
              f"testflight {result['testflight'] or 'skipped'}")
    return 0 if not (result["testflight"] or "").startswith("failed") else 1


if __name__ == "__main__":
    sys.exit(main())
