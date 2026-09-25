// Mini App taps back to the bot: Telegram's initData check, sendData lines,
// the bridge POST. Offline, with a made-up token. Run: node --test tests/*.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { readBridgePost, readWebAppData, signInitData, verifyInitData } from "../src/webapp.ts";

const TOKEN = "123456:TEST-not-a-real-token";
const now = Math.floor(Date.now() / 1000);
const fields = (extra: Record<string, string> = {}) => ({
  auth_date: String(now), query_id: "AAE-test", user: JSON.stringify({ id: 99, first_name: "Test" }), ...extra,
});

test("initData signed with the bot token verifies", async () => {
  const d = await verifyInitData(await signInitData(fields({ start_param: "abc" }), TOKEN), TOKEN);
  assert.deepEqual(d, { auth_date: now, user: { id: 99, first_name: "Test" }, query_id: "AAE-test", start_param: "abc" });
});

// Telegram's own example shape: the hash from core.telegram.org's algorithm,
// computed here independently with node:crypto, must match ours.
test("the check matches Telegram's algorithm (node:crypto)", async () => {
  const { createHmac } = await import("node:crypto");
  const f = fields();
  const check = Object.keys(f).sort().map((k) => `${k}=${(f as any)[k]}`).join("\n");
  const secret = createHmac("sha256", "WebAppData").update(TOKEN).digest();
  const hash = createHmac("sha256", secret).update(check).digest("hex");
  const q = new URLSearchParams(f); q.set("hash", hash);
  assert.ok(await verifyInitData(q.toString(), TOKEN));
});

test("tampered, wrong token, expired or unsigned initData fails", async () => {
  const good = await signInitData(fields(), TOKEN);
  assert.equal(await verifyInitData(good.replace("%22id%22%3A99", "%22id%22%3A100"), TOKEN), null);
  assert.equal(await verifyInitData(good, "999:other"), null);
  const old = await signInitData(fields({ auth_date: String(now - 90000) }), TOKEN);
  assert.equal(await verifyInitData(old, TOKEN), null);
  assert.ok(await verifyInitData(old, TOKEN, 100000));
  assert.equal(await verifyInitData(new URLSearchParams(fields()).toString(), TOKEN), null);
  assert.equal(await verifyInitData("", TOKEN), null);
});

test("sendData: only a Yui event line gets through", () => {
  assert.equal(readWebAppData({ web_app_data: { data: "[yui] n1 timer done rounds=8" } }), "[yui] n1 timer done rounds=8");
  assert.equal(readWebAppData({ web_app_data: { data: '[yui] n2 form form.name="Ann Lee"' } }), '[yui] n2 form form.name="Ann Lee"');
  assert.equal(readWebAppData({ web_app_data: { data: "hello" } }), null);
  assert.equal(readWebAppData({ web_app_data: { data: "[yui] react msg=1 emoji=👍" } }), null, "a reaction is not a Mini App tap");
  assert.equal(readWebAppData({}), null);
  assert.equal(readWebAppData(undefined), null);
});

test("bridge POST: verified user and line, or why not", async () => {
  const initData = await signInitData(fields(), TOKEN);
  assert.deepEqual(await readBridgePost({ initData, line: "[yui] n1 slide value=4" }, TOKEN), { ok: true, user: { id: 99, first_name: "Test" }, line: "[yui] n1 slide value=4" });
  assert.deepEqual(await readBridgePost({ initData, line: "rm -rf" }, TOKEN), { ok: false, error: "not a Yui event line" });
  assert.deepEqual(await readBridgePost({ initData: "x=1&hash=00", line: "[yui] n1 slide value=4" }, TOKEN), { ok: false, error: "initData did not verify" });
  const nouser = await signInitData({ auth_date: String(now) }, TOKEN);
  assert.deepEqual(await readBridgePost({ initData: nouser, line: "[yui] n1 slide value=4" }, TOKEN), { ok: false, error: "no user in initData" });
  assert.deepEqual(await readBridgePost(null, TOKEN), { ok: false, error: "not a Yui event line" });
});
