#!/usr/bin/env python3
"""YUI-21 end to end: an agent's picture reaches the app, the person's photo reaches the agent.

Runs the real `yui` platform adapter as the agent against PROOF, on a
throwaway account, never anyone's real one:
  1. Make a test user, an agent and a host connector (temp files only), plus
     a fresh session for the simulator.
  2. The agent renders a picture with fal nano-banana-2 (FAL_KEY) and replies
     with it in a ```yui fence. The adapter uploads it to yui-media and swaps
     in a signed URL. A local file goes through send_image_file the same way.
  3. YuiUITests/MediaTests runs in the simulator: the picture renders; then the
     agent sends a `camera`, the test picks a photo, the app uploads it.
  4. The adapter hands the agent that photo as a local file (and as vision
     media); the agent answers; the test sees the answer.
  5. The account is deleted through yui-delete; zero objects may remain.

Run it with the Hermes venv (the adapter imports the gateway):
    ~/.hermes/hermes-agent/venv/bin/python hermes-plugin/tests/media_e2e.py \
        --sim <simulator udid> --out /tmp/yui-media-proof
FAL_KEY must be in the environment. Needs a Supabase access token like the
supabase/tests. Exit 0 only when every check passed.
"""
import argparse, asyncio, hashlib, json, os, secrets, shutil, subprocess, sys, tempfile, time, uuid
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
ap = argparse.ArgumentParser()
ap.add_argument("--sim", required=True, help="simulator udid for the UI test")
ap.add_argument("--out", default="/tmp/yui-media-proof")
ap.add_argument("--hermes", default=str(Path.home() / ".hermes/hermes-agent"))
args = ap.parse_args()
OUT = Path(args.out)
shutil.rmtree(OUT, ignore_errors=True)
(OUT / "shots").mkdir(parents=True)

# Isolate the host: its connector token, cursor and media cache live in a temp dir.
TMP = Path(tempfile.mkdtemp(prefix="yui-media-e2e-"))
os.environ["YUI_CONNECTOR_FILE"] = str(TMP / "connector.json")
os.environ["HERMES_HOME"] = str(TMP)
sys.path[:0] = [args.hermes, str(REPO / "hermes-plugin")]
exec(open(REPO / "supabase/tests/agents_test.py").read().split("results = []")[0])

from gateway.config import PlatformConfig  # noqa: E402
from gateway.platform_registry import PlatformEntry, platform_registry  # noqa: E402
from yui import connector, media  # noqa: E402
from yui.adapter import YuiAdapter  # noqa: E402

# What the plugin loader does for a profile that has the plugin enabled.
platform_registry.register(PlatformEntry(name="yui", label="Yui", adapter_factory=lambda cfg: YuiAdapter(cfg),
                                         check_fn=lambda: True))

results = []
def check(name, ok, detail=""):
    results.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""), flush=True)

def log(msg): print(f"  .. {msg}", flush=True)

T = str(uuid.uuid4())
sql(f"insert into yui_users(id, apple_sub) values ('{T}','test.{T}')")
tokT = mint(T, ttl=3600)


async def main():
    s, r = fn("yui-agents", {"action": "create", "name": "Studio", "pair": True}, tokT)
    agent = r["agent"]["id"]
    s2, p = connector.pair(r["pairing"]["code"], "media-e2e", "Media test host")
    check("test account, agent and host paired", (s, s2) == (200, 200), f"{s} {s2}")
    rt = secrets.token_urlsafe(32)
    sql(f"insert into yui_sessions(user_id, refresh_hash, expires_at) values "
        f"('{T}', '{hashlib.sha256(rt.encode()).hexdigest()}', now() + interval '1 day')")

    seen: list = []
    adapter = YuiAdapter(PlatformConfig(enabled=True, extra={"remote_ref": "media-e2e"}))

    async def on_message(event):  # the agent: look at what came in
        seen.append(event)
        log(f"agent got: {event.text[:140]}  media={event.media_urls}")
    adapter.handle_message = on_message
    check("adapter connects as the agent's host", await adapter.connect())

    # 2. Generate, reply with it.
    t0 = time.time()
    fal_url = await asyncio.to_thread(media.generate, "storyboard frame 1: a coral ceramic mug on a sunny kitchen "
                                      "table, steam rising, soft morning light, clean flat illustration", "16:9")
    log(f"fal rendered in {time.time() - t0:.1f}s: {fal_url[:60]}...")
    res = await adapter.send(agent, "Here's frame 1 of the storyboard.\n```yui\nimage " + fal_url + ' "Frame 1"\n```')
    row = sql(f"select body from yui_messages where id='{res.message_id}'")[0]["body"]
    (OUT / "agent-message.txt").write_text(row)
    signed = row.split("image ", 1)[1].split(" ", 1)[0]
    check("the reply's picture is a signed yui-media link, not the fal URL",
          media.is_ours(signed) and "/object/sign/yui-media/" in signed and fal_url not in row, signed[:110])
    s, data = media._http("GET", signed, {})
    (OUT / "agent-picture.jpg").write_bytes(data)
    check("the signed link serves the rendered picture (anyone holding it, no token)",
          s == 200 and media.sniff(data) == "image/jpeg", f"{s} {len(data)} bytes")
    s, _ = media._http("GET", signed.split("?")[0].replace("/object/sign/", "/object/public/"), {})
    check("the same object has no public URL", s >= 400, f"{s}")
    res2 = await adapter.send_image_file(agent, str(OUT / "agent-picture.jpg"), caption="Local copy")
    row2 = sql(f"select body from yui_messages where id='{res2.message_id}'")[0]["body"]
    check("send_image_file uploads a local file the same way", "/object/sign/yui-media/" in row2
          and str(OUT) not in row2, row2[:120])

    # 3. The simulator.
    env = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
           "TEST_RUNNER_YUI_RT": rt, "TEST_RUNNER_YUI_USER": T, "TEST_RUNNER_YUI_SHOTS": str(OUT / "shots")}
    env.pop("HERMES_HOME", None)
    subprocess.run(["xcodegen", "generate", "--quiet"], cwd=REPO, env=env, check=True)
    ui = subprocess.Popen(["xcodebuild", "test", "-project", "Yui.xcodeproj", "-scheme", "Yui",
                           "-destination", f"id={args.sim}", "-derivedDataPath", "/tmp/yui21-dd",
                           "-only-testing:YuiUITests/MediaTests"],
                          cwd=REPO, env=env, stdout=open(OUT / "xcodebuild.log", "w"), stderr=subprocess.STDOUT)

    async def until(cond, secs):
        end = time.time() + secs
        while time.time() < end:
            if cond():
                return True
            if ui.poll() is not None:
                return cond()
            await asyncio.sleep(1)
        return False

    got_picture = await until(lambda: (OUT / "shots/picture").exists(), 600)
    check("the app rendered the agent's picture", got_picture)
    if got_picture:
        await adapter.send(agent, '```yui\ncamera "Snap something for me"\n```')
        got = await until(lambda: any(e.media_urls for e in seen), 240)
        ev = next((e for e in seen if e.media_urls), None)
        check("the person's photo reached the agent", got and ev is not None)
        if ev:
            f = Path(ev.media_urls[0])
            ok = f.is_file() and media.sniff(f.read_bytes()) == "image/jpeg" and str(f) in ev.text
            check("as a local file the agent can open, named in the event line, typed for vision",
                  ok and ev.media_types == ["image/jpeg"] and ev.message_type.value == "photo", ev.text[:160])
            check("the event names no bucket path any more", not media.USER_PATH.search(ev.text))
            shutil.copy(f, OUT / "person-photo-as-agent-sees-it.jpg")
            (OUT / "agent-event.txt").write_text(ev.text + "\n" + json.dumps(ev.media_urls))
            await adapter.send(agent, "Thanks, I got your photo. It's a good one.")
    rc = await asyncio.to_thread(ui.wait, 300)
    ran = "Executed 1 test, with 0 failures" in (OUT / "xcodebuild.log").read_text()
    check("MediaTests ran and passed in the simulator", rc == 0 and ran, f"xcodebuild exit {rc}, log {OUT / 'xcodebuild.log'}")
    await adapter.disconnect()


try:
    asyncio.run(main())
finally:
    s, r = fn("yui-delete", {}, tokT)
    left = sql(f"select count(*)::int n from storage.objects where bucket_id='yui-media' and name like '{T}/%'")[0]["n"]
    check("test account deleted through yui-delete, zero media objects left", s == 200 and left == 0,
          f"{s} removed={r.get('media_removed') if isinstance(r, dict) else r} left={left}")
    shutil.rmtree(TMP, ignore_errors=True)

print(f"\n{sum(results)}/{len(results)} passed  (proof in {OUT})")
sys.exit(0 if all(results) else 1)
