#!/usr/bin/env python3
"""Host a test build privately and send the install card (YUI-55).

Called by scripts/devbuild.sh. Uploads the .ipa and its itms-services manifest
to the private `yui-builds` bucket in Supabase Storage, signs both for 7 days,
and with --send posts a card with an Install button to the agent's Yui thread
(`hermes -p <profile> send --to yui`). Storage serves HTML as text/plain, so the
Safari fallback page is yuigui.com/install.html, which reads the manifest link
from the URL fragment (never sent to a server).

    devbuild_publish.py --ipa Yui.ipa --build 57.1 --sha <sha> --changes changes.txt \\
        [--out link.json] [--send yui]

Needs a Supabase access token (SUPABASE_ACCESS_TOKEN or the CLI's keychain
entry). The service key is fetched at run time and never written down. The
bucket has no policies: only the service role can read it. Old builds are
removed by supabase/scripts/media_sweep.py.
"""
import argparse, base64, json, os, re, secrets, subprocess, sys, tempfile, urllib.error, urllib.parse, urllib.request
from xml.sax.saxutils import escape

REF = "ewzzaoperdpxqxkshynx"
BASE = f"https://{REF}.supabase.co"
BUCKET = "yui-builds"
BUNDLE = "com.yuigui.app"
TTL = 7 * 24 * 3600


def access_token() -> str:
    t = os.environ.get("SUPABASE_ACCESS_TOKEN")
    if t:
        return t
    raw = subprocess.check_output(["security", "find-generic-password", "-s", "Supabase CLI", "-w"]).decode().strip()
    return base64.b64decode(raw.removeprefix("go-keyring-base64:")).decode()


def http(method, url, headers, data=None):
    req = urllib.request.Request(url, data=data, method=method, headers={"user-agent": "yui-devbuild", **headers})
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def service_key() -> str:
    s, body = http("GET", f"https://api.supabase.com/v1/projects/{REF}/api-keys?reveal=true",
                   {"authorization": f"Bearer {access_token()}"})
    if s >= 300:
        sys.exit(f"api keys: {s} {body[:200]!r}")
    return next(k["api_key"] for k in json.loads(body) if k["type"] == "secret")


class Store:
    def __init__(self, key: str):
        self.h = {"apikey": key, "authorization": f"Bearer {key}"}

    def put(self, path: str, data: bytes, ctype: str):
        s, body = http("POST", f"{BASE}/storage/v1/object/{BUCKET}/{path}",
                       {**self.h, "content-type": ctype, "x-upsert": "true"}, data)
        if s >= 300:
            sys.exit(f"upload {path}: {s} {body[:300]!r}")

    def sign(self, path: str) -> str:
        s, body = http("POST", f"{BASE}/storage/v1/object/sign/{BUCKET}/{path}",
                       {**self.h, "content-type": "application/json"}, json.dumps({"expiresIn": TTL}).encode())
        if s >= 300:
            sys.exit(f"sign {path}: {s} {body[:300]!r}")
        return f"{BASE}/storage/v1{json.loads(body)['signedURL']}"


def manifest(ipa_url: str, version: str, build: str) -> bytes:
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>items</key><array><dict>
  <key>assets</key><array><dict>
    <key>kind</key><string>software-package</string>
    <key>url</key><string>{escape(ipa_url)}</string>
  </dict></array>
  <key>metadata</key><dict>
    <key>bundle-identifier</key><string>{BUNDLE}</string>
    <key>bundle-version</key><string>{escape(version)}</string>
    <key>kind</key><string>software</string>
    <key>title</key><string>Yui {escape(build)}</string>
  </dict>
</dict></array></dict></plist>
""".encode()


def summary(lines: list[str]) -> str:
    """One line of what changed: the lead of each commit subject and its card."""
    out = []
    for s in lines:
        key = re.search(r"\(([A-Z]+-\d+)\)\s*$", s)
        lead = re.split(r"[:;.]\s|, ", s, maxsplit=1)[0].strip()
        if len(lead) > 60:
            lead = lead[:57].rsplit(" ", 1)[0] + "..."
        out.append(f"{lead} ({key.group(1)})" if key else lead)
    return ". ".join(out[:3]) + ("." if out else "") if out else "Rebuilt from main."


def yl(s: str) -> str:
    return '"' + s.replace('"', "'") + '"'


def ipa_version(ipa: str) -> str:
    """CFBundleShortVersionString from the .ipa's Info.plist."""
    import plistlib, zipfile
    with zipfile.ZipFile(ipa) as z:
        name = next(n for n in z.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n))
        return plistlib.loads(z.read(name))["CFBundleShortVersionString"]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--ipa", required=True)
    ap.add_argument("--build", required=True)
    ap.add_argument("--sha", required=True)
    ap.add_argument("--changes")
    ap.add_argument("--out")
    ap.add_argument("--send", metavar="PROFILE")
    a = ap.parse_args()

    lines = [l.strip() for l in open(a.changes)] if a.changes else []
    changed = summary([l for l in lines if l])
    store = Store(service_key())
    folder = f"{a.build}-{secrets.token_hex(6)}"
    with open(a.ipa, "rb") as f:
        store.put(f"{folder}/Yui.ipa", f.read(), "application/octet-stream")
    ipa_url = store.sign(f"{folder}/Yui.ipa")
    store.put(f"{folder}/manifest.plist", manifest(ipa_url, ipa_version(a.ipa), a.build), "text/xml")
    man_url = store.sign(f"{folder}/manifest.plist")
    install = "itms-services://?action=download-manifest&url=" + urllib.parse.quote(man_url, safe="")
    page_url = "https://www.yuigui.com/install.html#" + urllib.parse.urlencode({"b": a.build, "m": man_url})
    link = {"build": a.build, "sha": a.sha, "folder": folder, "install": install, "page": page_url,
            "changes": changed}
    if a.out:
        with open(a.out, "w") as f:
            json.dump(link, f, indent=2)
    print(f"hosted {a.build} in {BUCKET}/{folder} (links expire in 7 days)")

    if a.send:
        msg = (f"Test build {a.build} is ready. Tap Install on your phone.\n"
               "```yui\n"
               f"card {yl('Yui ' + a.build)} body={yl(changed)} sub={yl('Test build, straight from main. Link works 7 days.')} "
               f"cta=Install url={yl(install)}\n"
               "```\n")
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
            f.write(msg)
        r = subprocess.run(["hermes", "-p", a.send, "send", "--to", "yui", "--json", "--file", f.name],
                           capture_output=True, text=True)
        os.unlink(f.name)
        if r.returncode != 0 or '"success": true' not in r.stdout:
            print(f"send failed: {r.stdout.strip()} {r.stderr.strip()}"[:400], file=sys.stderr)
            return 1
        print(f"sent the install card to {a.send} in Yui")
    return 0


if __name__ == "__main__":
    sys.exit(main())
