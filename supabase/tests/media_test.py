#!/usr/bin/env python3
"""YUI-21 media tests against PROOF (live).

The yui-media bucket is private. The app's token (yui_user) reads its own
media and uploads photos under from=user into its own agents' threads. The
host's token (yui_connector) reads media in threads it serves and uploads
under from=agent. Nobody else gets in: not anon, not the portal's
`authenticated` role, not another user, not a revoked host. Every test
account is deleted at the end. Needs a Supabase access token, like
accounts_test.py.
"""
import sys, time, uuid
exec(open(__file__.replace("media_test.py", "agents_test.py")).read().split("results = []")[0])

results = []
def check(name, ok, detail=""):
    results.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""))

PNG = b"\x89PNG\r\n\x1a\nyui-media-test"
STORE = f"{BASE}/storage/v1"

def hdr(tok):
    h = {"apikey": PUBLISHABLE}
    if tok: h["authorization"] = f"Bearer {tok}"
    return h

def raw(method, url, tok, data=None, ct="image/png", extra=None):
    req = urllib.request.Request(url, data=data, method=method, headers={**hdr(tok), "content-type": ct, **(extra or {})})
    try:
        with urllib.request.urlopen(req) as r: return r.status, r.read()
    except urllib.error.HTTPError as e: return e.code, e.read()

def up(tok, path, data=PNG, ct="image/png", upsert=False):
    return raw("POST", f"{STORE}/object/yui-media/{path}", tok, data, ct, {"x-upsert": "true"} if upsert else None)[0]

def get(tok, path):
    return raw("GET", f"{STORE}/object/authenticated/yui-media/{path}", tok)

def sign(tok, path, ttl=60):
    s, r = http("POST", f"{STORE}/object/sign/yui-media/{path}", hdr(tok), {"expiresIn": ttl})
    return s, (r.get("signedURL") if isinstance(r, dict) else None)

def delete(tok, path):
    s, r = http("DELETE", f"{STORE}/object/yui-media", hdr(tok), {"prefixes": [path]})
    return s, r

def listing(tok, prefix):
    s, r = http("POST", f"{STORE}/object/list/yui-media", hdr(tok), {"prefix": prefix, "limit": 100})
    return s, r

def mint_role(role, sub, secret=JWT_SECRET):
    h = b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode()); now = int(time.time())
    p = b64(json.dumps({"role": role, "sub": sub, "aud": "authenticated", "iat": now, "exp": now + 300}).encode())
    return f"{h}.{p}.{b64(hmac.new(secret.encode(), f'{h}.{p}'.encode(), hashlib.sha256).digest())}"

def exists(path):
    return sql(f"select count(*)::int n from storage.objects where bucket_id='yui-media' and name='{path}'")[0]["n"] == 1

A, B = str(uuid.uuid4()), str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub) values ('{A}','test.{A}'),('{B}','test.{B}')")
tokA, tokB = mint(A), mint(B)
try:
    print("== Setup: A and B each pair an agent; A has a second agent no host serves")
    def paired(tok, ref):
        s, r = fn("yui-agents", {"action": "create", "name": ref.title(), "pair": True}, tok)
        s2, p = fn("yui-connect", {"action": "pair", "code": r["pairing"]["code"], "remote_ref": ref, "host_name": "Test host"})
        assert s2 == 200, p
        return r["agent"]["id"], p["connector_token"], p["connector"]["id"]
    a_agent, a_ct, a_cid = paired(tokA, "alpha")
    b_agent, b_ct, _ = paired(tokB, "bravo")
    a_loose = fn("yui-agents", {"action": "create", "name": "Loose"}, tokA)[1]["agent"]["id"]
    hostA = fn("yui-connect", {"action": "session"}, a_ct)[1]["access_token"]
    hostB = fn("yui-connect", {"action": "session"}, b_ct)[1]["access_token"]
    P = lambda user, agent, side: f"{user}/{agent}/{side}/{uuid.uuid4()}.png"

    print("== Bucket")
    b = sql("select public, file_size_limit, allowed_mime_types from storage.buckets where id='yui-media'")[0]
    check("yui-media is private, 50 MB cap, images + mp4/mov only", b["public"] is False and b["file_size_limit"] == 52428800
          and set(b["allowed_mime_types"]) == {"image/jpeg", "image/png", "image/webp", "image/gif", "image/heic", "video/mp4", "video/quicktime"}, str(b))
    rows = sql("select policyname, roles::text r from pg_policies where schemaname='storage' and policyname like 'yui_media%'")
    check("every yui-media policy is for yui_user or yui_connector, none for authenticated/anon/public",
          rows and all(set(x["r"].strip("{}").split(",")) <= {"yui_user", "yui_connector"} for x in rows), str(rows))

    print("== App side (yui_user)")
    a_photo = P(A, a_agent, "user")
    check("A uploads a photo into its own agent's thread", up(tokA, a_photo) == 200 and exists(a_photo))
    s, url = sign(tokA, a_photo)
    fetched = raw("GET", f"{STORE}{url}", None)[1] if url else b""
    check("A signs its photo and the signed URL serves the bytes", s == 200 and fetched == PNG, f"{s}")
    check("A reads its photo with its token", get(tokA, a_photo) == (200, PNG))
    loose_photo = P(A, a_loose, "user")
    check("A uploads into its unserved agent's thread too (own agent)", up(tokA, loose_photo) == 200)
    s = up(tokA, P(A, a_agent, "agent"))
    check("A cannot upload as the agent (from=agent)", s in (400, 403), f"{s}")
    s = up(tokA, P(A, b_agent, "user"))
    check("A cannot upload under B's agent", s in (400, 403), f"{s}")
    s = up(tokA, P(B, b_agent, "user"))
    check("A cannot upload into B's folder", s in (400, 403), f"{s}")
    s = up(tokA, f"{A}/{a_agent}/user/../../{B}/x.png")
    check("A cannot climb out of its folder with ..", s in (400, 403), f"{s}")
    s = up(tokA, f"{A}/not-an-agent/user/x.png")
    check("A cannot upload to a path that names no agent", s in (400, 403), f"{s}")
    s = up(tokA, a_photo, data=b"\x89PNG\r\n\x1a\noverwrite", upsert=True)
    check("A cannot overwrite an object (no update, new picture = new path)", s in (400, 403, 409) and get(tokA, a_photo)[1] == PNG, f"{s}")
    s = up(tokA, P(A, a_agent, "user").replace(".png", ".html"), data=b"<script>x</script>", ct="text/html")
    check("the bucket refuses non-media content types", s in (400, 403, 415), f"{s}")

    b_photo = P(B, b_agent, "user")
    assert up(tokB, b_photo) == 200
    check("A cannot read B's photo", get(tokA, b_photo)[0] in (400, 403, 404))
    check("A cannot sign B's photo", sign(tokA, b_photo)[0] in (400, 403, 404))
    s, r = listing(tokA, f"{B}/")
    check("A lists nothing in B's folder", s == 200 and r == [], f"{s} {r}")
    delete(tokA, b_photo)
    check("A cannot delete B's photo", exists(b_photo))

    print("== Host side (yui_connector)")
    a_pic = P(A, a_agent, "agent")
    check("A's host uploads a picture into the agent it serves", up(hostA, a_pic) == 200 and exists(a_pic))
    s, url = sign(hostA, a_pic, ttl=3600)
    check("A's host signs its picture", s == 200 and url and "token=" in url, f"{s}")
    check("A's app reads the host's picture", get(tokA, a_pic) == (200, PNG))
    check("A's host reads the user's photo in its thread (so the agent can see it)", get(hostA, a_photo) == (200, PNG))
    check("A's host cannot read media in A's agent it does not serve", get(hostA, loose_photo)[0] in (400, 403, 404))
    s = up(hostA, P(A, a_agent, "user"))
    check("A's host cannot upload as the user (from=user)", s in (400, 403), f"{s}")
    s = up(hostA, P(A, a_loose, "agent"))
    check("A's host cannot upload into an agent it does not serve", s in (400, 403), f"{s}")
    s = up(hostA, P(B, b_agent, "agent"))
    check("A's host cannot upload into B's thread", s in (400, 403), f"{s}")
    check("A's host cannot read B's photo", get(hostA, b_photo)[0] in (400, 403, 404))
    check("B's host cannot read A's photo", get(hostB, a_photo)[0] in (400, 403, 404))
    delete(hostA, a_photo)
    check("A's host cannot delete anything", exists(a_photo))

    print("== Outsiders")
    check("anon cannot upload", up(None, P(A, a_agent, "user")) in (400, 401, 403))
    check("anon cannot read", get(None, a_photo)[0] in (400, 401, 403, 404))
    check("anon cannot sign", sign(None, a_photo)[0] in (400, 401, 403, 404))
    s = raw("GET", f"{STORE}/object/public/yui-media/{a_photo}", None)[0]
    check("no public URL: the bucket is private", s in (400, 403, 404), f"{s}")
    portal = mint_role("authenticated", A)
    check("the portal's authenticated role cannot read yui-media", get(portal, a_photo)[0] in (400, 403, 404))
    check("the portal's authenticated role cannot upload", up(portal, P(A, a_agent, "user")) in (400, 403))
    s, r = listing(portal, f"{A}/")
    check("the portal's authenticated role lists nothing", s in (400, 403) or r == [], f"{s} {r}")
    check("a forged yui token cannot read", get(mint(A, secret="not-the-secret"), a_photo)[0] in (400, 401, 403))
    for f, body in [("yui_media_names", {"uid": A}), ("yui_media_orphans", {})]:
        s, r = rest("POST", f"rpc/{f}", tokA, body)
        s2, r2 = rest("POST", f"rpc/{f}", hostA, body)
        check(f"{f} is server-only (app and host refused)", s in (401, 403, 404) and s2 in (401, 403, 404), f"{s} {s2}")

    print("== Signed URL expiry")
    s, url = sign(tokA, a_photo, ttl=1)
    time.sleep(3)
    s2 = raw("GET", f"{STORE}{url}", None)[0]
    check("a signed URL stops working after it expires", s == 200 and s2 in (400, 403), f"{s2}")

    print("== Orphans")
    sent = P(A, a_agent, "agent")
    assert up(hostA, sent) == 200
    s, _ = rest("POST", "yui_messages", hostA, {"user_id": A, "agent_id": a_agent, "sender": "agent",
                                               "body": f"```yui\nimage {BASE}/storage/v1/object/sign/yui-media/{sent}?token=x\n```"})
    orphans = {r["n"] for r in sql("select public.yui_media_orphans('0 seconds'::interval) n")}
    check("an unreferenced upload is an orphan once past the grace period", a_pic in orphans)
    check("a picture a message points at is not an orphan", s == 201 and sent not in orphans, f"{s}")
    orphans_1d = {r["n"] for r in sql("select public.yui_media_orphans('1 day'::interval) n")}
    check("a fresh unreferenced upload is kept for the grace period", a_pic not in orphans_1d)
    s, _ = fn("yui-agents", {"action": "delete", "id": a_loose}, tokA)
    assert s == 200, s
    orphans_1d = {r["n"] for r in sql("select public.yui_media_orphans('1 day'::interval) n")}
    check("media of a deleted agent is an orphan at once", loose_photo in orphans_1d)

    print("== Revoked host")
    s, _ = fn("yui-agents", {"action": "connector_revoke", "id": a_cid}, tokA)
    check("A revokes its host in the app", s == 200, f"{s}")
    # Storage's CDN may replay an object this same token already downloaded
    # (bytes the host has anyway) until the token dies, at most 60 minutes.
    # Anything new is refused at once, and so is signing.
    check("a revoked host cannot read media it never fetched", get(hostA, sent)[0] in (400, 403, 404))
    check("a revoked host cannot sign media it used to serve", sign(hostA, a_photo)[0] in (400, 403, 404))
    check("a revoked host cannot upload", up(hostA, P(A, a_agent, "agent")) in (400, 403))

    print("== App deletes its own media")
    delete(tokA, a_photo)
    check("A deletes its own photo", not exists(a_photo))
finally:
    for u, t in ((A, tokA), (B, tokB)):
        s, r = fn("yui-delete", {}, t)
        if s != 200:
            sql(f"delete from yui_users where id='{u}'")
    left = sql(f"select count(*)::int n from storage.objects where bucket_id='yui-media' and (name like '{A}/%' or name like '{B}/%')")[0]["n"]
    check("cleanup: test accounts deleted through yui-delete, zero objects left", left == 0, f"left={left}")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)
