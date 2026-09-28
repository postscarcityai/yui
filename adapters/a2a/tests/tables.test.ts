// Tables in the A2A bridge (YUI-171, yuigui spec/TABLES.md section 8): table
// words in the answer go through Yui's tables call before the answer is saved,
// a read sends the rows back to the agent, a data part {"yui": "tables"} runs
// its lines, and a hand-over line opens the turn. No network: fetch is a stub
// that plays Yui (rows, the tables call, push) and a scripted A2A agent.
//
//   node --test tests/*.test.ts
import { test, describe, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Bridge, State, SUPABASE_URL, TABLE_WORDS } from "../src/bridge.ts";

const AID = "11111111-2222-3333-4444-555555555555";
const AGENT = { id: AID, name: "Chef", remote_ref: "chef" };
const CARD = { name: "Chef", url: "http://agent.test/rpc", preferredTransport: "JSONRPC", protocolVersion: "0.3.0",
               capabilities: { streaming: false }, skills: [] };

type Answer = { text?: string; data?: unknown[] };
type TablesFn = (body: any) => [number, any];

/** One fake world per test: Yui's rows and endpoints, and an agent that answers from a script. */
function world(script: Answer[], tables: TablesFn) {
  const rows: any[] = []; // the person's rows
  const saved: any[] = []; // replies the bridge wrote
  const tableCalls: any[] = [];
  const sent: any[] = []; // messages the agent got (0.3 wire shape)
  const answers = [...script];
  let n = 0;
  const json = (s: number, b: unknown) => new Response(JSON.stringify(b), { status: s, headers: { "content-type": "application/json" } });
  const fake = async (input: any, init: any = {}): Promise<Response> => {
    const url = String(input instanceof Request ? input.url : input);
    const method = init.method ?? "GET";
    const body = init.body ? JSON.parse(init.body) : undefined;
    if (url.startsWith("http://agent.test/.well-known/agent-card.json")) return json(200, CARD);
    if (url === "http://agent.test/rpc") {
      sent.push(body.params.message);
      const a = answers.shift() ?? { text: "(out of script)" };
      const parts = [...(a.text !== undefined ? [{ kind: "text", text: a.text }] : []),
                     ...(a.data ?? []).map((d) => ({ kind: "data", data: d }))];
      const task = { kind: "task", id: `task-${++n}`, contextId: AID, status: { state: "completed" },
                     artifacts: [{ artifactId: "a1", parts }] };
      return json(200, { jsonrpc: "2.0", id: body.id, result: task });
    }
    if (url === `${SUPABASE_URL}/functions/v1/yui-connect/tables`) {
      tableCalls.push({ body, auth: init.headers?.authorization });
      const [s, r] = tables(body);
      return json(s, r);
    }
    if (url.startsWith(`${SUPABASE_URL}/functions/v1/yui-push`)) return json(200, {});
    if (url.startsWith(`${SUPABASE_URL}/rest/v1/yui_messages`)) {
      const q = decodeURIComponent(url);
      if (method === "POST") {
        saved.push(body);
        return new Response(null, { status: 201 });
      }
      if (method === "PATCH") {
        const ids = /id=in\.\(([^)]*)\)/.exec(q)![1].split(",");
        for (const r of rows) if (ids.includes(r.id)) Object.assign(r, body);
        return new Response(null, { status: 204 });
      }
      if (q.includes("sender=eq.agent")) return json(200, []);
      return json(200, rows.filter((r) => !r.handled_at));
    }
    throw new Error(`unexpected fetch ${method} ${url}`);
  };
  return { rows, saved, tableCalls, sent, fake, answers };
}

let prevFetch: typeof fetch;
let w: ReturnType<typeof world>;
let state: State;
let bridge: Bridge;

function setup(script: Answer[], tables: TablesFn = () => [500, { error: "not in this test" }]) {
  w = world(script, tables);
  globalThis.fetch = w.fake as typeof fetch;
  state = new State(join(mkdtempSync(join(tmpdir(), "yui-a2a-tables-")), "s.json"));
  state.data.token = "yui_ct_test";
  state.data.remotes = { chef: { card: "http://agent.test" } };
  state.data.floors[AID] = "2026-01-01T00:00:00Z";
  bridge = new Bridge(state, { guide: false });
  bridge.token = "jwt";
  bridge.userId = "user-1";
  bridge.tokenExp = Date.now() / 1000 + 3600;
  bridge.agents.set(AID, AGENT);
}

let seq = 0;
function say(body: string, meta: any = null) {
  w.rows.push({ id: `row-${++seq}`, agent_id: AID, body, kind: "text", meta, created_at: new Date().toISOString(),
                delivered_at: null });
}

const texts = (m: any) => m.parts.filter((p: any) => p.kind === "text").map((p: any) => p.text);
const datas = (m: any) => m.parts.filter((p: any) => p.kind === "data").map((p: any) => p.data);

beforeEach(() => { prevFetch = globalThis.fetch; });
afterEach(() => { globalThis.fetch = prevFetch; });

describe("tables: the reply path", () => {
  test("the cheap check: table words yes, ordinary words no", () => {
    for (const t of ["Logged.\nput meals Food=Oats Cal=300", "  table create foods Food:text", "table drop foods ",
                     "query meals where=Day=today", "```tables\nmeals\n```"]) assert.ok(TABLE_WORDS.test(t), t);
    for (const t of ["Put the kettle on.", "I'll query that later", "tables are nice", "a table for two"]) {
      assert.ok(!TABLE_WORDS.test(t), t);
    }
  });

  test("a reply with a put line: the server's text is saved instead", async () => {
    setup([{ text: "Logged your oats.\n```yui\nput meals Food=Oats Cal=300\n```" }],
          () => [200, { text: "Logged your oats.", failed: [], wrote: 1, held: null, settled: [], tables: [] }]);
    say("had oats");
    await bridge.turn(AGENT);
    assert.equal(w.tableCalls.length, 1);
    assert.deepEqual(w.tableCalls[0].body, { agent: AID, reply: "Logged your oats.\n```yui\nput meals Food=Oats Cal=300\n```" });
    assert.equal(w.tableCalls[0].auth, "Bearer yui_ct_test");
    assert.deepEqual(w.saved.map((r) => r.body), ["Logged your oats."]);
    assert.deepEqual(w.saved[0].meta.turn, ["row-" + seq]);
  });

  test("a reply with no table words makes no tables call", async () => {
    setup([{ text: "Hello there." }]);
    say("hi");
    await bridge.turn(AGENT);
    assert.equal(w.tableCalls.length, 0);
    assert.deepEqual(w.saved.map((r) => r.body), ["Hello there."]);
  });

  test("a read: nothing saved, the note goes back, the second answer is saved", async () => {
    const note = "[yui] Your tables:\n\nquery meals\nDay | Food\ntoday | Oats\n\n[yui] Answer the person now.";
    setup([{ text: "```tables\nmeals\n```" }, { text: "You had oats today." }],
          (b) => b.reply.startsWith("```tables")
            ? [200, { read: true, text: "", ok: ["query meals"], failed: [], results: [], note, tables: [] }]
            : [500, { error: "unexpected" }]);
    say("what did I eat?");
    await bridge.turn(AGENT);
    assert.equal(w.sent.length, 2);
    assert.deepEqual(texts(w.sent[1]), [note]);
    assert.notEqual(w.sent[1].messageId, w.sent[0].messageId);
    assert.equal(w.tableCalls.length, 1, "the plain second answer makes no call");
    assert.deepEqual(w.saved.map((r) => r.body), ["You had oats today."]);
    assert.equal(state.data.inflight[AID], undefined);
  });

  test("reads stop after two rounds; a third read saves nothing", async () => {
    const read = { text: "```tables\nmeals\n```" };
    setup([read, read, read], () => [200, { read: true, text: "", ok: [], failed: [], results: [], note: "[yui] Your tables: none" }]);
    say("what did I eat?");
    await bridge.turn(AGENT);
    assert.equal(w.sent.length, 3);
    assert.equal(w.saved.length, 0);
    assert.equal(state.data.inflight[AID], undefined);
    assert.ok(w.rows.every((r) => r.handled_at), "the turn is done");
  });

  test("the tables call fails: the original text is saved unchanged", async () => {
    const said = "Logged.\nput meals Food=Oats Cal=300";
    setup([{ text: said }], () => [429, { error: "rate_limited" }]);
    say("had oats");
    await bridge.turn(AGENT);
    assert.equal(w.tableCalls.length, 1);
    assert.deepEqual(w.saved.map((r) => r.body), [said]);
  });

  test("the tables call cannot connect: the original text is saved unchanged", async () => {
    const said = "Logged.\nput meals Food=Oats Cal=300";
    setup([{ text: said }]);
    const inner = w.fake;
    globalThis.fetch = (async (u: any, i: any) => {
      if (String(u).endsWith("/yui-connect/tables")) throw new TypeError("fetch failed");
      return inner(u, i);
    }) as typeof fetch;
    say("had oats");
    await bridge.turn(AGENT);
    assert.deepEqual(w.saved.map((r) => r.body), [said]);
  });
});

describe("tables: the data part", () => {
  const result = { table: "meals", cols: [{ name: "Food", type: "text" }], keys: [null], rows: [["Oats"]], count: 1 };

  test("with text: the text is saved, the rows ride on the next message (kept on disk)", async () => {
    setup([{ text: "Noted.", data: [{ yui: "tables", lines: "query meals where=Day=today" }] }, { text: "Sure." }],
          (b) => [200, { ok: ["query meals where=Day=today"], failed: [], results: [result], held: null, settled: [],
                         tables: [{ name: "meals", rows: 1 }], note: "meals: Oats" }]);
    say("log it");
    await bridge.turn(AGENT);
    assert.deepEqual(w.tableCalls.map((c) => c.body), [{ agent: AID, lines: "query meals where=Day=today" }]);
    assert.deepEqual(w.saved.map((r) => r.body), ["Noted."]);
    assert.equal(w.sent.length, 1, "no follow-up when there were words for the person");
    const onDisk = new State(state.path).data.tables[AID];
    assert.deepEqual(onDisk, { yui: "tables", results: [result], failed: [], held: null, tables: [{ name: "meals", rows: 1 }] });

    await bridge.flushAcks();
    say("thanks");
    await bridge.turn(AGENT);
    assert.equal(w.sent.length, 2);
    assert.deepEqual(texts(w.sent[1]), ["thanks"]);
    assert.deepEqual(datas(w.sent[1]), [onDisk]);
    assert.equal(state.data.tables[AID], undefined, "sent once");
    assert.deepEqual(w.saved.map((r) => r.body), ["Noted.", "Sure."]);
  });

  test("alone: a read, the rows go back at once with the note, the answer is saved", async () => {
    setup([{ data: [{ yui: "tables", lines: "query meals" }] }, { text: "You had oats." }],
          () => [200, { ok: ["query meals"], failed: [], results: [result], held: null, settled: [], tables: [],
                        note: "[yui] Your tables:\n\nmeals: Oats" }]);
    say("what did I eat?");
    await bridge.turn(AGENT);
    assert.equal(w.sent.length, 2);
    assert.deepEqual(texts(w.sent[1]), ["[yui] Your tables:\n\nmeals: Oats"]);
    assert.deepEqual(datas(w.sent[1]), [{ yui: "tables", results: [result], failed: [], held: null, tables: [] }]);
    assert.deepEqual(w.saved.map((r) => r.body), ["You had oats."]);
    assert.equal(state.data.tables[AID], undefined);
  });

  test("alone, and the call fails: the agent still hears why, with no rows", async () => {
    setup([{ data: [{ yui: "tables", lines: "query meals" }] }, { text: "Sorry, I can't see your meals." }],
          () => [400, { error: "too_many_lines", message: "51 lines in one call" }]);
    say("what did I eat?");
    await bridge.turn(AGENT);
    assert.equal(w.sent.length, 2);
    const back = datas(w.sent[1])[0] as any;
    assert.equal(back.results.length, 0);
    assert.match(back.failed[0].error, /too_many_lines/);
    assert.match(texts(w.sent[1])[0], /^\[yui\] Your tables: Refused "query meals"/);
    assert.deepEqual(w.saved.map((r) => r.body), ["Sorry, I can't see your meals."]);
  });
});

describe("tables: the hand-over line", () => {
  test("meta.tables opens the text the agent gets", async () => {
    setup([{ text: "Got them." }]);
    say("you have my foods now", { tables: "[yui] tables foods(3 rows: Food, Cal)" });
    await bridge.turn(AGENT);
    assert.deepEqual(texts(w.sent[0]), ["[yui] tables foods(3 rows: Food, Cal)\nyou have my foods now"]);
  });
});
