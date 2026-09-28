// Tables in the Node webhook bridge, offline (TABLES.md section 8).
//
// A fake Yui (session, yui_messages, /tables) and a stub agent run on localhost;
// the bridge talks to them through $YUI_SUPABASE_URL. Nothing touches the live
// backend.
//
//   node --test adapters/webhook/tests/tables-offline.test.mjs
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, beforeEach, test } from "node:test";

const AGENT = "11111111-2222-3333-4444-555555555555";
let fake;
const reset = () => {
  fake = { inbox: [], saved: [], tablesCalls: [], tablesAnswer: () => [200, {}], posts: [], agentAnswers: [] };
};
reset();

const send = (res, status, body) => {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(body === undefined ? "" : JSON.stringify(body));
};
const readBody = async (req) => {
  let raw = "";
  for await (const c of req) raw += c;
  return raw ? JSON.parse(raw) : null;
};

const yui = createServer(async (req, res) => {
  const b = await readBody(req);
  const path = new URL(req.url, "http://x").pathname;
  if (req.method === "GET") {
    return send(res, 200, req.url.includes("sender=eq.user") ? fake.inbox.filter((r) => !r.handled_at) : []);
  }
  if (req.method === "PATCH") {
    const ids = decodeURIComponent(req.url).split("id=in.(")[1].split(")")[0].split(",");
    for (const r of fake.inbox) if (ids.includes(r.id)) Object.assign(r, b);
    return send(res, 204);
  }
  if (path.endsWith("/yui-connect/tables")) {
    assert.equal(req.headers.authorization, "Bearer yui_ct_test");
    fake.tablesCalls.push(b);
    return send(res, ...fake.tablesAnswer(b));
  }
  if (path.endsWith("/yui-connect")) {
    if (b.action === "session") {
      return send(res, 200, {
        access_token: "at", user_id: "u1", expires_at: "2099-01-01T00:00:00Z",
        agents: [{ id: AGENT, name: "Basil", handle: "basil", remote_ref: "basil" }], guide: { version: "v", body: "g" },
      });
    }
    return send(res, 200, {});
  }
  if (path.endsWith("/yui-push")) return send(res, 200, {});
  if (path.endsWith("/rest/v1/yui_messages")) {
    fake.saved.push(b);
    return send(res, 201);
  }
  send(res, 404, { error: "no" });
});

const agentSrv = createServer(async (req, res) => {
  fake.posts.push({ body: await readBody(req), turnKey: req.headers["x-yui-turn"] });
  send(res, 200, fake.agentAnswers.length ? fake.agentAnswers.shift() : {});
});

const listen = (s) => new Promise((ok) => s.listen(0, "127.0.0.1", () => ok(s.address().port)));
let Bridge, State, webhook, dir, statePath, bridge;

before(async () => {
  process.env.YUI_SUPABASE_URL = `http://127.0.0.1:${await listen(yui)}`;
  webhook = `http://127.0.0.1:${await listen(agentSrv)}/`;
  // After the env var: the module reads it on import.
  const m = await import("../node/yui-webhook.mjs");
  ({ Bridge, State } = m);
  m.setLog(() => {});
});
after(() => {
  yui.close();
  agentSrv.close();
});

const fresh = async () => {
  bridge = new Bridge(new State(statePath), { webhook });
  await bridge.session();
};
beforeEach(async () => {
  reset();
  if (dir) rmSync(dir, { recursive: true, force: true });
  dir = mkdtempSync(join(tmpdir(), "yui-tables-"));
  statePath = join(dir, "webhook.json");
  writeFileSync(statePath, JSON.stringify({ token: "yui_ct_test", floors: { [AGENT]: "2026-01-01T00:00:00Z" } }));
  await fresh();
});
after(() => dir && rmSync(dir, { recursive: true, force: true }));

const turn = async (body, meta = null) => {
  fake.inbox.push({ id: randomUUID(), agent_id: AGENT, body, kind: "text", meta,
                    created_at: "2026-09-27T10:00:00Z", delivered_at: null });
  await bridge.runTurns();
};
const bodies = () => fake.saved.map((r) => r.body);
const kept = () => JSON.parse(readFileSync(statePath, "utf8")).tables;

test("tables and a reply: reply saved, result on the next POST", async () => {
  fake.agentAnswers = [{ reply: "Logged.", tables: "put meals Food=Oats Cal=300" }, { reply: "ok" }];
  fake.tablesAnswer = () => [200, { ok: ["put meals"], failed: [], results: [], held: null, settled: [],
                                    tables: [{ name: "meals", rows: 1 }] }];
  await turn("log oats");
  assert.deepEqual(fake.tablesCalls, [{ agent: AGENT, lines: "put meals Food=Oats Cal=300" }]);
  assert.deepEqual(bodies(), ["Logged."]);
  assert.equal(fake.posts.length, 1);
  assert.ok(!("tables" in fake.posts[0].body));
  const want = { results: [], failed: [], held: null, tables: [{ name: "meals", rows: 1 }] };
  assert.deepEqual(kept()[AGENT], want); // on disk, so a restart still hands it over
  await fresh();
  await turn("thanks");
  assert.deepEqual(fake.posts[1].body.tables, want);
  assert.deepEqual(kept(), {});
});

test("tables alone is a read: a second POST with the rows", async () => {
  const res = [{ table: "meals", cols: ["Food", "Cal"], keys: ["r1"], rows: [["Oats", 300]], count: 1 }];
  const note = "[yui] Your tables:\nmeals: Oats, 300";
  fake.agentAnswers = [{ tables: "query meals" }, { reply: "You ate oats." }];
  fake.tablesAnswer = () => [200, { ok: ["query meals"], failed: [], results: res, held: null, settled: [],
                                    tables: [], note }];
  await turn("what did I eat");
  assert.equal(fake.posts.length, 2);
  const [first, second] = fake.posts;
  assert.deepEqual(second.body.turn, first.body.turn);
  assert.notEqual(second.turnKey, first.turnKey);
  assert.equal(second.body.round, 1);
  assert.deepEqual(second.body.tables, { results: res, failed: [], held: null, tables: [], note });
  assert.equal(second.body.text, "what did I eat\n" + note);
  assert.deepEqual(bodies(), ["You ate oats."]);
  assert.ok(fake.inbox[0].handled_at);
});

test("reads stop after two rounds", async () => {
  fake.agentAnswers = Array(4).fill({ tables: "query meals" });
  fake.tablesAnswer = () => [200, { results: [], failed: [], note: "[yui] Your tables: none" }];
  await turn("loop");
  assert.equal(fake.posts.length, 3);
  assert.deepEqual(bodies(), []);
  assert.ok(fake.inbox[0].handled_at);
  assert.ok(AGENT in kept());
});

test("a reply with a put line: the server's text is saved", async () => {
  const reply = "Logged.\n```yui\nput meals Food=Oats Cal=300\n```";
  fake.agentAnswers = [{ reply }];
  fake.tablesAnswer = () => [200, { text: "Logged.", failed: [], wrote: 1, held: null, settled: [], tables: [] }];
  await turn("log oats");
  assert.deepEqual(fake.tablesCalls, [{ agent: AGENT, reply }]);
  assert.deepEqual(bodies(), ["Logged."]);
  assert.equal(fake.posts.length, 1);
});

test("a reply with no table words makes no call", async () => {
  fake.agentAnswers = [{ reply: "I would put it on the table later.\n```yui\nchoose \"Pick\" A|B\n```" }];
  await turn("hi");
  assert.deepEqual(fake.tablesCalls, []);
  assert.equal(bodies().length, 1);
});

test("a read reply saves nothing and POSTs again", async () => {
  const reply = "```tables\nquery meals\n```";
  const note = "[yui] Your tables:\nmeals: Oats";
  fake.agentAnswers = [{ reply }, { reply: "Oats." }];
  fake.tablesAnswer = () => [200, { read: true, text: "", ok: ["query meals"], failed: [],
                                    results: [{ table: "meals", rows: [["Oats"]] }], note, tables: [{ name: "meals" }] }];
  await turn("what did I eat");
  assert.deepEqual(fake.tablesCalls, [{ agent: AGENT, reply }]);
  assert.equal(fake.posts.length, 2);
  assert.deepEqual(fake.posts[1].body.tables,
                   { results: [{ table: "meals", rows: [["Oats"]] }], failed: [], note, tables: [{ name: "meals" }] });
  assert.deepEqual(bodies(), ["Oats."]);
});

test("the hand over line comes first", async () => {
  const line = "[yui] tables foods(3 rows: Food, Cal)";
  fake.agentAnswers = [{}];
  await turn("hello", { tables: line });
  assert.equal(fake.posts[0].body.text, `${line}\nhello`);
});

test("a /tables failure saves the reply as written", async () => {
  const reply = "put meals Food=Oats\nLogged.";
  fake.agentAnswers = [{ reply }];
  fake.tablesAnswer = () => [500, { error: "boom" }];
  await turn("log oats");
  assert.equal(fake.tablesCalls.length, 1);
  assert.deepEqual(bodies(), [reply]);
  assert.ok(fake.inbox[0].handled_at);
});
