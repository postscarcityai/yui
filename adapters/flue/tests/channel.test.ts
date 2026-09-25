// The Yui channel's verified ingress and the turn shape, no network:
//   node --test tests/channel.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash, createHmac } from "node:crypto";
import { createYuiChannel, toTurn, turnKey, withYuiGuide, yuiGuide, type YuiTurn } from "../src/yui.ts";
import * as web from "../src/channel.ts";

const SECRET = "test-secret";

/** Just enough of a Hono context for the route. */
function ctx(raw: string, headers: Record<string, string>) {
  const h = Object.fromEntries(Object.entries(headers).map(([k, v]) => [k.toLowerCase(), v]));
  return {
    req: { text: async () => raw, header: (n: string) => h[n.toLowerCase()] },
    json: (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } }),
    body: (_: null, status = 200) => new Response(null, { status }),
  };
}

function signed(payload: unknown, opts: { secret?: string; ts?: number; turn?: string } = {}) {
  const raw = JSON.stringify(payload);
  const ts = String(opts.ts ?? Math.floor(Date.now() / 1000));
  const sig = "sha256=" + createHmac("sha256", opts.secret ?? SECRET).update(`${ts}.${raw}`).digest("hex");
  return { raw, headers: { "content-type": "application/json", "x-yui-timestamp": ts, "x-yui-signature": sig,
                           ...(opts.turn ? { "x-yui-turn": opts.turn } : {}) } };
}

const PAYLOAD = {
  agent: { id: "a1", name: "Lunch", handle: "lunch", ref: "assistant" },
  turn: ["r1", "r2"],
  text: "hi\n[yui] n1 choose choice=Tea",
  messages: [
    { id: "r1", kind: "text", body: "hi", event: null, created_at: "2026-09-25T00:00:00Z" },
    { id: "r2", kind: "event", body: "[yui] n1 choose choice=Tea", event: { id: "n1", preset: "choose", value: { choice: "Tea" }, echo: "Tea" }, created_at: "2026-09-25T00:00:01Z" },
  ],
  guide: { version: "v16+test", body: "## You are talking to someone in Yui" },
};

function channel(answer = async (t: YuiTurn) => `ok ${t.key}`) {
  const seen: YuiTurn[] = [];
  const ch = createYuiChannel({ secret: SECRET, answer: async (t) => { seen.push(t); return answer(t); } });
  assert.equal(ch.routes.length, 1);
  assert.equal(ch.routes[0].method, "POST");
  assert.equal(ch.routes[0].path, "/webhook");
  return { handler: ch.routes[0].handler, seen };
}

test("a channel without a secret is refused", () => {
  assert.throws(() => createYuiChannel({ secret: "", answer: async () => null }), /needs a secret/);
});

test("a signed turn reaches answer() and the reply comes back", async () => {
  const { handler, seen } = channel();
  const { raw, headers } = signed(PAYLOAD, { turn: "k-from-header" });
  const r = await handler(ctx(raw, headers));
  assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), { reply: "ok k-from-header" });
  assert.equal(seen.length, 1);
  assert.equal(seen[0].agent.ref, "assistant");
  assert.deepEqual(seen[0].turn, ["r1", "r2"]);
  assert.equal(seen[0].text, PAYLOAD.text); // the tap as its [yui] line
  assert.equal(seen[0].messages[1].event?.preset, "choose");
});

test("the pushed guide becomes the agent's guide", async () => {
  const { handler } = channel();
  const { raw, headers } = signed(PAYLOAD);
  await handler(ctx(raw, headers));
  assert.equal(yuiGuide().version, "v16+test");
  assert.equal(withYuiGuide("Be brief."), "Be brief.\n\n## You are talking to someone in Yui");
});

test("no x-yui-turn: the key is the webhook bridge's, from the rows", async () => {
  const { handler, seen } = channel();
  const { raw, headers } = signed(PAYLOAD);
  await handler(ctx(raw, headers));
  assert.equal(seen[0].key, createHash("sha256").update("r1,r2").digest("hex").slice(0, 32));
  assert.equal(seen[0].key, turnKey(["r1", "r2"]));
});

test("an empty answer is a 204: the turn is done, no reply", async () => {
  const { handler } = channel(async () => "  ");
  const { raw, headers } = signed(PAYLOAD);
  const r = await handler(ctx(raw, headers));
  assert.equal(r.status, 204);
});

test("bad, missing or other-secret signatures are 401 and never reach answer()", async () => {
  const { handler, seen } = channel();
  const { raw, headers } = signed(PAYLOAD);
  for (const h of [
    { ...headers, "x-yui-signature": "sha256=" + "0".repeat(64) },
    { ...headers, "x-yui-signature": "" },
    { ...headers, "x-yui-signature": "md5=abc" },
    signed(PAYLOAD, { secret: "other" }).headers,
  ]) {
    const r = await handler(ctx(raw, h));
    assert.equal(r.status, 401);
  }
  // the right signature over a changed body
  const r = await handler(ctx(raw.replace("Tea", "Coffee"), headers));
  assert.equal(r.status, 401);
  assert.equal(seen.length, 0);
});

test("a stale or missing timestamp is 401 (replay window)", async () => {
  const { handler, seen } = channel();
  const old = signed(PAYLOAD, { ts: Math.floor(Date.now() / 1000) - 3600 });
  assert.equal((await handler(ctx(old.raw, old.headers))).status, 401);
  const { raw, headers } = signed(PAYLOAD);
  const { "x-yui-timestamp": _, ...noTs } = headers;
  assert.equal((await handler(ctx(raw, noTs))).status, 401);
  assert.equal(seen.length, 0);
});

test("wrong content type, bad JSON and non-turns are refused", async () => {
  const { handler, seen } = channel();
  const { raw, headers } = signed(PAYLOAD);
  assert.equal((await handler(ctx(raw, { ...headers, "content-type": "text/plain" }))).status, 415);
  const bad = "{not json";
  const ts = headers["x-yui-timestamp"];
  const sig = "sha256=" + createHmac("sha256", SECRET).update(`${ts}.${bad}`).digest("hex");
  assert.equal((await handler(ctx(bad, { ...headers, "x-yui-signature": sig }))).status, 400);
  for (const p of [{ ...PAYLOAD, turn: [] }, { ...PAYLOAD, agent: {} }, { ...PAYLOAD, text: 5 }]) {
    const s = signed(p);
    assert.equal((await handler(ctx(s.raw, s.headers))).status, 400);
  }
  assert.equal(seen.length, 0);
});

test("a body over the limit is 413", async () => {
  const ch = createYuiChannel({ secret: SECRET, answer: async () => "x", maxBytes: 100 });
  const { raw, headers } = signed(PAYLOAD);
  assert.equal((await ch.routes[0].handler(ctx(raw, headers))).status, 413);
});

test("toTurn: rows to the turn shape, taps carry their event", () => {
  const t = toTurn({ id: "a1", name: "Lunch", remote_ref: "assistant" }, [
    { id: "r1", agent_id: "a1", body: "hi", kind: "text", meta: null, created_at: "t1", delivered_at: null },
    { id: "r2", agent_id: "a1", body: "[yui] n1 choose choice=Tea", kind: "event", meta: { id: "n1", preset: "choose" }, created_at: "t2", delivered_at: null },
  ], { version: "v", body: "g" });
  assert.deepEqual(t.turn, ["r1", "r2"]);
  assert.equal(t.key, turnKey(["r1", "r2"]));
  assert.equal(t.text, "hi\n[yui] n1 choose choice=Tea");
  assert.equal(t.messages[0].event, null);
  assert.equal(t.messages[1].event?.id, "n1");
  assert.equal(t.agent.ref, "assistant");
});

test("the Web-only entry has the channel, and its key matches the connector's", async () => {
  assert.equal(web.createYuiChannel, createYuiChannel);
  assert.equal(await web.turnKeyOf(["r1", "r2"]), turnKey(["r1", "r2"]));
  const src = (await import("node:fs")).readFileSync(new URL("../src/channel.ts", import.meta.url), "utf8");
  assert.doesNotMatch(src, /from "node:/); // runs on workerd without nodejs_compat
});
