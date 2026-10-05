// YUI-190: the person taps Stop while an agent works. The turn or job ends where it is and
// writes nothing (no reply, no memory, no table rows, no job), and its rows are handled.
import { test } from "node:test";
import assert from "node:assert/strict";
import { runAgent, runJob } from "../src/turn.ts";
import { answerControl } from "../src/controls.ts";
import { isStop } from "../src/stop.ts";
import type { LocalStore } from "../src/store.ts";
import { fakeModel, freshYui, provider, USER } from "./helpers.ts";

const SALMON = { food: true, title: "Salmon bowl", sure: "Clear photo.", question: null,
  items: [{ food: "Salmon, grilled", portion: "1 fillet", cal: 310, protein: 33, carbs: 0, fat: 19 }] };

/** The person's Stop, as the app sends it, answered as yui-native answers it. */
async function stop(store: LocalStore, agentId: string, user = USER) {
  const id = store.id("row");
  store.data.rows.push({ id, agent_id: agentId, sender: "user", kind: "control", body: "stop", meta: { op: "stop" },
                         created_at: new Date().toISOString(), ...(user === USER ? {} : { user_id: user }) } as any);
  assert.equal(await answerControl(store, id), true, "a stop is a control, never a turn");
  return id;
}

/** A model that answers only once released, and ends its call when the signal aborts. */
function hangingModel(text: string) {
  let aborted = false;
  let started!: () => void;
  const begun = new Promise<void>((r) => (started = r));
  const fetch = ((_url: string, init: any) => new Promise((resolve, reject) => {
    started();
    const answer = setTimeout(() => resolve(new Response(JSON.stringify({ choices: [{ message: { role: "assistant", content: text }, finish_reason: "stop" }] }),
                                         { status: 200, headers: { "content-type": "application/json" } })), 5000);
    init.signal?.addEventListener("abort", () => { aborted = true; clearTimeout(answer); reject(init.signal.reason ?? new Error("aborted")); });
  })) as unknown as typeof globalThis.fetch;
  return { fetch, begun, aborted: () => aborted };
}

const agentReplies = (store: LocalStore, agentId: string) =>
  store.data.rows.filter((r) => r.agent_id === agentId && r.sender === "agent" && r.kind === "text");

test("Stop mid-answer ends the model call and writes nothing", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const before = agentReplies(store, yui.id).length;
  const m = hangingModel("Sure.\n```remember\nme: name = Sam\n```");
  const row = store.say(yui.id, "remember my name is Sam and plan my week");
  const t0 = Date.now();
  const run = runAgent(store, yui.id, { provider, fetch: m.fetch, stopPoll: 20 });
  await m.begun;
  await stop(store, yui.id);
  const r = await run;
  assert.ok(Date.now() - t0 < 2000, "the turn ends at the stop, not when the model would have answered");
  assert.ok(m.aborted(), "the model call itself was aborted");
  assert.equal(r.replies.length, 0);
  assert.equal(agentReplies(store, yui.id).length, before, "no reply, not even 'can't reach its model'");
  assert.equal(store.data.memory.length, 0, "nothing remembered");
  const mine = store.data.rows.find((x) => x.id === row)!;
  assert.ok(mine.handled_at, "the stopped row is handled, so no later wake answers it");
  assert.equal(mine.doing ?? null, null, "the working words are cleared");
  const ack = store.data.rows.find((x) => x.kind === "control" && x.sender === "agent")!;
  assert.deepEqual({ ok: ack.meta.ok, op: ack.meta.op, rows: ack.meta.rows }, { ok: true, op: "stop", rows: 1 });
});

test("a stop that lands while the answer is being written: the write is refused, nothing lands", async () => {
  const { store, byHandle } = await freshYui();
  const basil = await byHandle("basil");
  const tables0 = JSON.stringify(store.data.tables?.[basil.id] ?? null);
  const before = agentReplies(store, basil.id).length;
  // The model answers at once, and the stop arrives between its answer and the first write.
  const m = fakeModel(() => {
    const id = store.id("row");
    store.data.rows.push({ id, agent_id: basil.id, sender: "user", kind: "control", body: "stop", meta: { op: "stop" },
                           created_at: new Date().toISOString() });
    return "Logged.\n```remember\nme: diet = vegetarian\n```";
  });
  store.say(basil.id, "I'm vegetarian now, update everything");
  const r = await runAgent(store, basil.id, { provider, fetch: m.fetch, stopPoll: 10_000 });
  assert.equal(m.calls.length, 1);
  assert.equal(r.replies.length, 0);
  assert.equal(agentReplies(store, basil.id).length, before);
  assert.equal(store.data.memory.length, 0);
  assert.equal(JSON.stringify(store.data.tables?.[basil.id] ?? null), tables0, "no half-written table rows");
});

test("Stop after Basil's 'working out the macros': the queued job is dropped, no breakdown, no meal rows", async () => {
  const { store, byHandle } = await freshYui();
  const basil = await byHandle("basil");
  const m = fakeModel(() => JSON.stringify(SALMON));
  store.say(basil.id, "[yui] c1 camera photo=https://img.test/bowl.jpg", "event");
  const r = await runAgent(store, basil.id, { provider, fetch: m.fetch });
  assert.equal(r.jobs.length, 1, "the ack went out and the job is queued");
  const meals0 = JSON.stringify(store.data.tables?.[basil.id]?.tables.meals ?? null);
  const replies = agentReplies(store, basil.id).length;
  await stop(store, basil.id);
  const job = store.data.jobs!.find((j) => j.id === r.jobs[0])!;
  assert.equal(job.status, "failed");
  assert.deepEqual(job.result, { stopped: true });
  const done = await runJob(store, r.jobs[0], { provider, fetch: m.fetch });
  assert.equal(done.replies.length, 0);
  assert.equal(m.calls.length, 0, "the model is never asked");
  assert.equal(agentReplies(store, basil.id).length, replies);
  assert.equal(JSON.stringify(store.data.tables?.[basil.id]?.tables.meals ?? null), meals0);
});

test("Stop while the macros are being worked out: the job ends mid-call and logs nothing", async () => {
  const { store, byHandle } = await freshYui();
  const basil = await byHandle("basil");
  store.say(basil.id, "[yui] c1 camera photo=https://img.test/bowl.jpg", "event");
  const r = await runAgent(store, basil.id, { provider, fetch: fakeModel(() => "").fetch });
  const meals0 = JSON.stringify(store.data.tables?.[basil.id]?.tables.meals ?? null);
  const replies = agentReplies(store, basil.id).length;
  const m = hangingModel(JSON.stringify(SALMON));
  const run = runJob(store, r.jobs[0], { provider, fetch: m.fetch, stopPoll: 20 });
  await m.begun;
  await stop(store, basil.id);
  const done = await run;
  assert.ok(m.aborted());
  assert.equal(done.replies.length, 0);
  assert.equal(agentReplies(store, basil.id).length, replies, "no breakdown and no 'couldn't work out that meal'");
  assert.equal(JSON.stringify(store.data.tables?.[basil.id]?.tables.meals ?? null), meals0);
  assert.deepEqual(store.data.jobs!.find((j) => j.id === r.jobs[0])!.result, { stopped: true });
});

test("a stop before the turn began, or from someone else, stops nothing", async () => {
  const { store, byHandle } = await freshYui();
  const gouda = await byHandle("gouda");
  await stop(store, gouda.id); // an old stop, before this ask
  await new Promise((r) => setTimeout(r, 5));
  store.say(gouda.id, "make me a beat");
  const m = fakeModel(() => {
    // Someone Gouda is shared with taps Stop on their own thread meanwhile.
    store.data.rows.push({ id: store.id("row"), agent_id: gouda.id, sender: "user", kind: "control", body: "stop", meta: { op: "stop" },
                           created_at: new Date().toISOString(), user_id: "u2" } as any);
    return "Here's a beat.";
  });
  const r = await runAgent(store, gouda.id, { provider, fetch: m.fetch });
  assert.equal(r.replies.length, 1);
  assert.equal(store.data.rows.find((x) => x.id === r.replies[0])!.body, "Here's a beat.");
});

test("an old Stop never cancels a later question, even when an older ask is still unhandled", async () => {
  const { store, byHandle } = await freshYui();
  const gouda = await byHandle("gouda");
  const old = store.say(gouda.id, "an ask nobody answered");
  store.data.rows.find((x) => x.id === old)!.created_at = "2026-09-29T23:00:00.000Z";
  store.data.rows.push({ id: store.id("row"), agent_id: gouda.id, sender: "user", kind: "control", body: "stop", meta: { op: "stop" },
                         created_at: "2026-09-29T23:07:00.000Z" } as any);
  const fresh = store.say(gouda.id, "make me a beat");
  const m = fakeModel(() => "Here's a beat.");
  const r = await runAgent(store, gouda.id, { provider, fetch: m.fetch });
  assert.equal(r.replies.length, 1, "the fresh question is answered");
  assert.equal(store.data.rows.find((x) => x.id === r.replies[0])!.body, "Here's a beat.");
  assert.ok(store.data.rows.find((x) => x.id === fresh)!.handled_at);
});

test("isStop reads only the person's stop control", () => {
  assert.equal(isStop({ kind: "control", sender: "user", meta: { op: "stop" } }), true);
  assert.equal(isStop({ kind: "control", sender: "agent", meta: { op: "stop" } }), false);
  assert.equal(isStop({ kind: "text", sender: "user", meta: { op: "stop" } }), false);
  assert.equal(isStop({ kind: "control", sender: "user", meta: { op: "list" } }), false);
});
