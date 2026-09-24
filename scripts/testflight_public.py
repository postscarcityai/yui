#!/usr/bin/env python3
"""Put the newest VALID build in the external TestFlight group "Public".

Adds the build to the group, sets its What to Test from the commit that made
it, and submits it for Beta App Review when Apple allows it (one build in
review at a time; the next run picks up anything skipped). Idempotent: run it
after every upload and from a cron, it only acts on what is missing.

  python3 scripts/testflight_public.py            # newest VALID build
  python3 scripts/testflight_public.py --build 17 # a specific build number
"""
import json, os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = "6815454240"
GROUP = "Public"
IN_REVIEW = {"WAITING_FOR_BETA_REVIEW", "IN_BETA_REVIEW"}


def asc(method, path, body=None):
    args = [sys.executable, os.path.join(ROOT, "scripts", "asc.py"), method, path]
    if body is not None:
        args.append(json.dumps(body))
    out = subprocess.run(args, capture_output=True, text=True).stdout.strip()
    if out[:3].isdigit() and out[3:4] == " ":
        raise SystemExit(f"ASC {method} {path}: {out[:400]}")
    return json.loads(out) if out else {}


def what_to_test(number):
    subjects = subprocess.run(["git", "-C", ROOT, "log", "--reverse", "--format=%s"],
                              capture_output=True, text=True).stdout.splitlines()
    change = subjects[int(number) - 1] if 0 < int(number) <= len(subjects) else ""
    text = "New in this build: " + change if change else "A new Yui build."
    return text + "\nNeeds Hermes Agent on your computer. Send feedback with a screenshot in TestFlight."


def main():
    want = sys.argv[sys.argv.index("--build") + 1] if "--build" in sys.argv else None
    groups = asc("GET", f"/v1/apps/{APP}/betaGroups")["data"]
    group = next((g for g in groups if g["attributes"]["name"] == GROUP), None)
    if not group:
        raise SystemExit(f'no "{GROUP}" beta group on app {APP}')

    d = asc("GET", f"/v1/builds?filter[app]={APP}&sort=-uploadedDate&limit=10"
                   "&fields[builds]=version,processingState,expired,buildBetaDetail&include=buildBetaDetail")
    states = {x["id"]: x["attributes"]["externalBuildState"] for x in d.get("included", [])}
    builds = [b for b in d["data"] if not b["attributes"]["expired"]]
    if want:
        builds = [b for b in builds if b["attributes"]["version"] == want]
        if not builds:
            print(f"build {want} not on App Store Connect yet"); return
    build = builds[0] if builds else None
    if not build:
        print("no builds"); return
    n, bid = build["attributes"]["version"], build["id"]
    if build["attributes"]["processingState"] != "VALID":
        print(f"build {n} is {build['attributes']['processingState']}, try again once it is VALID"); return

    in_group = asc("GET", f"/v1/betaGroups/{group['id']}/builds?limit=50&fields[builds]=version")["data"]
    if not any(b["id"] == bid for b in in_group):
        asc("POST", f"/v1/betaGroups/{group['id']}/relationships/builds",
            {"data": [{"type": "builds", "id": bid}]})
        print(f"build {n} added to {GROUP}")

    if not asc("GET", f"/v1/builds/{bid}/betaBuildLocalizations")["data"]:
        asc("POST", "/v1/betaBuildLocalizations", {"data": {
            "type": "betaBuildLocalizations",
            "attributes": {"locale": "en-US", "whatsNew": what_to_test(n)},
            "relationships": {"build": {"data": {"type": "builds", "id": bid}}}}})

    state = states.get(bid)
    if state == "READY_FOR_BETA_SUBMISSION":
        busy = [b["attributes"]["version"] for b in d["data"] if states.get(b["id"]) in IN_REVIEW]
        if busy:
            print(f"build {n} waits: build {busy[0]} is already in beta review"); return
        r = asc("POST", "/v1/betaAppReviewSubmissions", {"data": {
            "type": "betaAppReviewSubmissions",
            "relationships": {"build": {"data": {"type": "builds", "id": bid}}}}})
        print(f"build {n} submitted for beta review: {r['data']['attributes']['betaReviewState']}")
    else:
        print(f"build {n}: {state}")


if __name__ == "__main__":
    main()
