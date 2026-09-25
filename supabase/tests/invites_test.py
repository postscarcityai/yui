#!/usr/bin/env python3
"""YUI-56: invites, live against PROOF.

yui_invites is server only (no anon, authenticated, yui_user or yui_connector
access); invite.py adds, approves (code stored hashed, TestFlight request
checked with --dry-run, never sent), declines and reissues; a signed-in
account claims by code through yui-auth (forgiving about case and dashes,
one-time, one invite per account, wrong codes rate limited); the Apple ID
email claims an approved invite and never a requested or declined one, and
never through a relay address (the SQL function yui-auth calls on Sign in with
Apple, which can't be driven headless); the waitlist import; deleting the
account deletes its invite, claimed or not. Throwaway accounts and
@example.com addresses only; everything is removed at the end.

    python3 supabase/tests/invites_test.py
"""
import json, os, subprocess, sys, uuid
exec(open(__file__.replace("invites_test.py", "agents_test.py")).read().split("results = []")[0])

results = []
def check(name, ok, detail=""):
    ok = bool(ok); results.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""), flush=True)

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "scripts", "invite.py")
RUN = uuid.uuid4().hex[:8]
def mail(tag): return f"yui-invite-test-{RUN}-{tag}@example.com"

def invite(*args):
    p = subprocess.run([sys.executable, SCRIPT, *args], capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr

def row(email):
    r = sql(f"select * from yui_invites where email = '{email}'")
    return r[0] if r else None

def claim_code(token, code):
    return fn("yui-auth", {"grant_type": "invite", "code": code}, token)

def claim_email(uid, email):
    e = "null" if email is None else "'" + email.replace("'", "''") + "'"
    return sql(f"select * from public.yui_claim_invite('{uid}'::uuid, null, {e})")

users = [str(uuid.uuid4()) for _ in range(4)]
T, U, V, W = users
try:
    sql("insert into yui_users(id, apple_sub) values " + ",".join(f"('{u}','test.{u}')" for u in users))
    tokT, tokU, tokV = mint(T), mint(U), mint(V)

    print("== Locked down")
    r = sql("select relrowsecurity from pg_class where relname = 'yui_invites'")[0]
    check("RLS is on", r["relrowsecurity"])
    r = sql("select count(*)::int n from pg_policies where tablename = 'yui_invites'")[0]
    check("no policies (server only)", r["n"] == 0, r["n"])
    for role in ["anon", "authenticated", "yui_user", "yui_connector"]:
        r = sql(f"""select bool_or(has_table_privilege('{role}', 'public.yui_invites', p)) any
                    from unnest(array['SELECT','INSERT','UPDATE','DELETE']) p""")[0]
        check(f"{role} has no privilege on yui_invites", not r["any"])
        r = sql(f"select has_function_privilege('{role}', 'public.yui_claim_invite(uuid,text,text)', 'EXECUTE') x")[0]
        check(f"{role} cannot call yui_claim_invite", not r["x"])
    s, _ = rest("GET", "yui_invites?select=*")
    check("anon GET yui_invites refused", s in (401, 403), s)
    s, _ = rest("POST", "yui_invites", None, {"email": mail("anon")})
    check("anon INSERT yui_invites refused", s in (401, 403), s)
    s, _ = rest("GET", "yui_invites?select=*", tokT)
    check("yui_user GET yui_invites refused", s in (401, 403), s)

    print("\n== invite.py")
    A = mail("a")
    rc, out = invite("add", "--email", A.upper(), "--first", "Test", "--last", "Invitee", "--phone", "+1 (555) 010-0000", "--template", "client-default")
    r = row(A)
    check("add writes a requested invite, email lowercased", rc == 0 and r and r["status"] == "requested", out.strip()[-80:])
    check("add keeps the phone digits and the template", r and r["phone"] == "+15550100000" and r["agent_template"] == "client-default")
    rc, out = invite("add", "--email", A, "--first", "Again", "--last", "X")
    check("add refuses a second invite for the same email", rc != 0 and "already" in out)
    rc, out = invite("add", "--email", "not-an-email", "--first", "X", "--last", "Y")
    check("add refuses a bad email", rc != 0)
    rc, out = invite("approve", A, "--template", "Bad Template!")
    check("approve refuses a bad template name", rc != 0)
    rc, out = invite("approve", A, "--dry-run")
    check("approve --dry-run shows the TestFlight request and sends nothing",
          rc == 0 and '"betaTesters"' in out and '"firstName": "Test"' in out and '"betaGroups"' in out
          and row(A)["status"] == "requested", out.strip()[:120])
    check("the dry run's request goes to the Invited group", "<Invited group id>" not in out)
    rc, out = invite("approve", A, "--no-testflight", "--json")
    res = json.loads(out.strip().splitlines()[-1]) if rc == 0 else {}
    codeA = res.get("code", "")
    r = row(A)
    check("approve makes a one-time code and a yuigui.com/i/ link",
          rc == 0 and len(codeA) == 11 and res.get("link") == "https://www.yuigui.com/i/" + codeA, out.strip()[:120])
    check("approve --no-testflight stops at approved", r["status"] == "approved" and r["approved_at"] and not r["asc_tester_id"])
    check("only the code's SHA-256 is stored", r["code_hash"] and codeA not in json.dumps(r, default=str)
          and len(r["code_hash"]) == 64)
    rc, out = invite("reissue", A)
    newA = out.split("new code ")[1].split()[0] if "new code " in out else ""
    check("reissue gives a new code", rc == 0 and newA and newA != codeA)
    s, r = claim_code(tokT, codeA)
    check("the old code stops working after reissue", s == 404 and r.get("error") == "invalid_code", s)
    rc, out = invite("list", "--status", "approved", "--json")
    check("list shows it", rc == 0 and A in out)

    print("\n== Claim by code (signed in)")
    s, r = fn("yui-auth", {"grant_type": "invite", "code": newA})
    check("no token: refused", s == 401, s)
    s, r = claim_code(tokT, "ZZZZZ-ZZZZZ")
    check("a wrong code: 404 invalid_code", s == 404 and r.get("error") == "invalid_code", s)
    s, r = claim_code(tokT, "ab")
    check("a too-short code: 400", s == 400, s)
    s, r = claim_code(tokT, "  " + newA.lower().replace("-", " ") + " ")
    check("the right code claims it, forgiving about case, dashes and spaces",
          s == 200 and r.get("invite", {}).get("first_name") == "Test", f"{s} {r}")
    check("the claim hands back the template for YUI-57", (r.get("invite") or {}).get("agent_template") == "client-default")
    r = row(A)
    check("the row is claimed by that account", r["status"] == "claimed" and r["claimed_user_id"] == T and r["claimed_at"])
    s, r = claim_code(tokU, newA)
    check("the code is one-time: a second account gets 404", s == 404, s)

    B = mail("b")
    invite("add", "--email", B, "--first", "Second", "--last", "Invite")
    rc, out = invite("approve", B, "--no-testflight", "--json")
    codeB = json.loads(out.strip().splitlines()[-1])["code"]
    s, r = claim_code(tokT, codeB)
    check("an account holds one invite: T cannot claim B's too", s == 404, s)
    s, r = claim_code(tokU, codeB)
    check("U claims B", s == 200, s)

    C = mail("c")
    invite("add", "--email", C, "--first", "Declined", "--last", "Person")
    rc, out = invite("approve", C, "--no-testflight", "--json")
    codeC = json.loads(out.strip().splitlines()[-1])["code"]
    rc, out = invite("decline", C)
    check("decline works and drops the code", rc == 0 and row(C)["status"] == "declined" and row(C)["code_hash"] is None)
    s, r = claim_code(tokV, codeC)
    check("a declined invite's code claims nothing", s == 404, s)
    rc, out = invite("approve", A)
    check("a claimed invite can't be approved again", rc != 0 and "claimed" in out)

    print("\n== Claim by Apple ID email (the Sign in with Apple path)")
    D, E = mail("d"), mail("e")
    invite("add", "--email", D, "--first", "Email", "--last", "Match")
    invite("add", "--email", E, "--first", "Not", "--last", "Approved")
    invite("approve", D, "--no-testflight")
    check("a relay or missing email claims nothing", claim_email(V, None) == [])
    check("a requested (not approved) invite is never claimed by email", claim_email(V, E) == [] and row(E)["status"] == "requested")
    check("a declined invite is never claimed by email", claim_email(V, C) == [])
    got = claim_email(V, D.upper())
    check("an approved invite is claimed by its email, case-insensitive", len(got) == 1 and got[0]["first_name"] == "Email")
    check("V now holds D", row(D)["claimed_user_id"] == V)
    sql(f"update yui_invites set status = 'invited', invited_at = now() where email = '{E}'")
    check("an account that holds one claims no second by email", claim_email(V, E) == [])
    s, r = fn("yui-auth", {"grant_type": "apple", "identity_token": "not.a.token", "nonce": "x", "invite_code": codeB})
    check("Sign in with Apple still refuses a bad Apple token, invite code or not", s == 401, s)

    print("\n== Wrong codes are rate limited")
    seen = []
    for i in range(14):
        s, _ = claim_code(tokV, f"WRONG-{i:05d}")
        seen.append(s)
    check("after about 10 wrong codes: 429", 429 in seen and seen[0] == 404, ",".join(map(str, seen)))

    print("\n== Waitlist rows come over as requests")
    Wm = mail("waitlist")
    sql(f"insert into yui_waitlist (email, name, note, source) values ('{Wm}', 'Wait Lister', 'utm_source=x', 'cta:/')")
    mig = open(os.path.join(HERE, "..", "migrations", "20260924110000_yui_invites.sql")).read()
    sql("insert into public.yui_invites" + mig.split("insert into public.yui_invites", 1)[1].split(";")[0])
    r = row(Wm)
    check("a waitlist row becomes a requested invite with its name, source and UTM",
          r and r["status"] == "requested" and r["first_name"] == "Wait Lister" and r["source"] == "cta:/" and r["utm"] == "utm_source=x")
    sql("insert into public.yui_invites" + mig.split("insert into public.yui_invites", 1)[1].split(";")[0])
    check("running the import twice adds nothing", sql(f"select count(*)::int n from yui_invites where email = '{Wm}'")[0]["n"] == 1)

    print("\n== Deleting the account deletes the invite")
    s, r = fn("yui-delete", {}, tokT)
    check("T deletes its account", s == 200 and r.get("deleted"), s)
    check("T's claimed invite is gone", row(A) is None)
    sql(f"update yui_users set email = '{E}' where id = '{W}'")
    s, r = fn("yui-delete", {}, mint(W))
    check("W (never claimed) deletes its account", s == 200, s)
    check("an unclaimed invite with W's email is gone too", row(E) is None)
    check("other people's invites stay", row(B) is not None and row(D) is not None)
finally:
    sql(f"delete from yui_invites where email like 'yui-invite-test-{RUN}-%'")
    sql(f"delete from yui_waitlist where email like 'yui-invite-test-{RUN}-%'")
    sql("delete from yui_users where id in (" + ",".join(f"'{u}'" for u in users) + ")")
    sql("delete from yui_rate_buckets where " + " or ".join(f"key = 'invite:u:{u}'" for u in users))
    left = sql(f"select (select count(*) from yui_invites where email like 'yui-invite-test-{RUN}-%') + "
               "(select count(*) from yui_users where id in (" + ",".join(f"'{u}'" for u in users) + ")) n")[0]["n"]
    check("cleanup: no test invite or account left", left == 0, left)

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)
