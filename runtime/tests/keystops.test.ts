// A person's own key at every stop (YUI-139 step 2c): check-ins, hand-offs, Yui making agents, start blank and the web
// client each run on their key, never on Yui's OpenRouter. A photo the pick can't see says so; a lookup on a key with no
// web search says it ran on Yui's. Chat and photo per provider: keys.test.ts.
import { test } from "node:test";
import assert from "node:assert/strict";
import { openRouter, runAgent, runJob, runScheduled } from "../src/turn.ts";
import { freshYui, USER } from "./helpers.ts";

const KEY = "sk-stub-own-key-4242";
const YUI_KEY = "sk-or-yui-must-not-be-used";
const yui = openRouter(YUI_KEY);

/** Answers by script, recording every url and bearer the model side saw. */
function spy(answer: (n: number, body: any) => string = () => "Sure.") {
  const calls: { url: string; auth: string; model: string }[] = [];
  const fetchImpl = (async (url: string, init: any) => {
    const body = JSON.parse(init.body);
    calls.push({ url: String(url), auth: String(init.headers?.authorization ?? init.headers?.Authorization ?? ""), model: body.model });
    return new Response(JSON.stringify({ choices: [{ message: { role: "assistant", content: answer(calls.length - 1, body) }, finish_reason: "stop" }],
                                         usage: { prompt_tokens: 1, completion_tokens: 1 } }), { status: 200, headers: { "content-type": "application/json" } });
  }) as unknown as typeof fetch;
  return { calls, fetch: fetchImpl };
}

async function withKey(provider: "groq" | "anthropic" | "openrouter" = "groq", model: string | null = "llama-own") {
  const { store, byHandle } = await freshYui({ freeTurns: 1 });
  const baseUrl = provider === "openrouter" ? "https://openrouter.ai/api/v1" : provider === "anthropic" ? "https://api.anthropic.com/v1" : "https://api.groq.com/openai/v1";
  store.data.keys = { [USER]: { provider, baseUrl, model, key: KEY } };
  return { store, byHandle };
}

/** Every call went to the person's provider with their key, and none reached Yui's OpenRouter. */
function ownOnly(calls: { url: string; auth: string }[], host: string) {
  assert.ok(calls.length > 0, "the model was called");
  for (const c of calls) {
    assert.ok(c.url.startsWith(host), `${c.url} is their provider's`);
    assert.doesNotMatch(c.url, /openrouter/);
    assert.equal(c.auth, `Bearer ${KEY}`);
    assert.doesNotMatch(c.auth, new RegExp(YUI_KEY));
  }
}
const GROQ = "https://api.groq.com/openai/v1";

test("stop: a check-in fires on their key (runScheduled)", async () => {
  const { store, byHandle } = await withKey();
  const basil = await byHandle("basil");
  const now = Date.now();
  const m = spy(() => 'Sure.\n```schedule\nin 1h "Drink water"\n```');
  store.say(basil.id, "remind me in an hour");
  await runAgent(store, basil.id, { provider: yui, now: () => now, fetch: m.fetch });
  const [s] = await store.schedules(basil.id);
  const c = spy(() => "Water time.");
  await runScheduled(store, s.id, { provider: yui, now: () => now + 3_700_000, fetch: c.fetch });
  ownOnly([...m.calls, ...c.calls], GROQ);
  assert.equal(c.calls.length, 1, "the check-in ran a turn");
  assert.equal((await store.takeTurn(USER)).ok, true, "no free turn taken");
});

test("stop: a hand-off runs the second agent on their key too", async () => {
  const { store, byHandle } = await withKey();
  const y = await byHandle("yui");
  const m = spy((n) => n === 0 ? 'Gouda does that.\n```handoff\ngouda "Wants a beat"\n```' : "Here is a beat idea.");
  store.say(y.id, "I want to make a beat");
  await runAgent(store, y.id, { provider: yui, fetch: m.fetch });
  assert.equal(m.calls.length, 2, "Yui, then Gouda");
  ownOnly(m.calls, GROQ);
});

test("stop: Yui making an agent (YUI-137) runs on their key", async () => {
  const { store, byHandle } = await withKey();
  const y = await byHandle("yui");
  const before = (await store.agents(USER)).length;
  const m = spy(() => "Made it.\n```agents\nmake gouda\n```");
  store.say(y.id, "add a musician");
  await runAgent(store, y.id, { provider: yui, fetch: m.fetch });
  assert.equal((await store.agents(USER)).length, before + 1, "the agent was made");
  ownOnly(m.calls, GROQ);
});

test("stop: a blank agent making itself (YUI-138) runs on their key", async () => {
  const { store, byHandle } = await withKey();
  const y = await byHandle("yui");
  const m = spy((n) => n === 0 ? "One sec.\n```agents\nmake blank\n```" : 'All set.\n```agents\nself name="Luna" color=mint\n```');
  store.say(y.id, "make me a blank agent");
  await runAgent(store, y.id, { provider: yui, fetch: m.fetch });
  const blank = (await store.agents(USER)).find((a) => a.profile.blank);
  assert.ok(blank, "a blank agent exists");
  store.say(blank!.id, "you are for reading lists");
  await runAgent(store, blank!.id, { provider: yui, fetch: m.fetch });
  ownOnly(m.calls, GROQ);
});

test("stop: a turn from the web client (YUI-146) runs on their key", async () => {
  const { store, byHandle } = await withKey("anthropic", null);
  const basil = await byHandle("basil");
  const m = spy();
  const id = store.say(basil.id, "what should I eat before a run?");
  const row = store.data.rows.find((r) => r.id === id)!;
  row.meta = { client: "web" };
  await runAgent(store, basil.id, { provider: yui, fetch: m.fetch });
  ownOnly(m.calls, "https://api.anthropic.com/v1");
  assert.equal((await store.takeTurn(USER)).ok, true);
});

const PHOTO = "[yui] c1 camera photo=https://img.test/plate.jpg";

test("a photo on a pick with no seeing model says so in one line, no model call, nothing on Yui's route", async () => {
  const { store, byHandle } = await withKey("groq", null);
  const y = await byHandle("yui");
  const m = spy();
  store.say(y.id, PHOTO, "event");
  await runAgent(store, y.id, { provider: yui, fetch: m.fetch });
  assert.equal(m.calls.length, 0);
  const r = store.data.rows.filter((x) => x.agent_id === y.id && x.sender === "agent").pop()!;
  assert.match(r.body, /Your Groq pick can't see photos\. Choose a photo-capable model/);
  assert.equal(r.body.split("\n").length, 1);
  assert.equal((await store.pending(y.id)).length, 0, "handled, not left to retry");
});

test("a meal photo job on a pick with no seeing model says so too", async () => {
  const { store, byHandle } = await withKey("groq", null);
  const basil = await byHandle("basil");
  const m = spy();
  store.say(basil.id, PHOTO, "event");
  const r = await runAgent(store, basil.id, { provider: yui, fetch: m.fetch });
  assert.equal(r.jobs.length, 1, "the photo queued a meal job");
  const done = await runJob(store, r.jobs[0], { provider: yui, fetch: m.fetch });
  assert.equal(m.calls.length, 0);
  assert.equal(done.replies.length, 1);
  const last = store.data.rows.filter((x) => x.agent_id === basil.id && x.sender === "agent").pop()!;
  assert.match(last.body, /can't see photos/);
});

test("a photo on a named model goes to that model", async () => {
  const { store, byHandle } = await withKey("groq", "llama-vision");
  const y = await byHandle("yui");
  const m = spy();
  store.say(y.id, PHOTO, "event");
  await runAgent(store, y.id, { provider: yui, fetch: m.fetch });
  ownOnly(m.calls, GROQ);
  assert.equal(m.calls[0].model, "llama-vision");
});

/** A scripted Firecrawl. */
function firecrawl() {
  const calls: string[] = [];
  const f = (async (url: string) => {
    calls.push(new URL(url).pathname);
    return Response.json({ success: true, data: { web: [{ url: "https://www.espn.com/nba", title: "NBA", description: "Knicks won." }] } });
  }) as unknown as typeof fetch;
  return { calls, fetch: f };
}
const ask = (n: number) => n === 0 ? "```search\nknicks score\n```" : "The Knicks won.";

test("web search on a provider without it runs on Yui's lookups, and the card says so", async () => {
  const { store, byHandle } = await withKey("groq", "llama-own");
  const y = await byHandle("yui");
  const fc = firecrawl();
  const m = spy(ask);
  store.say(y.id, "did the knicks win?");
  await runAgent(store, y.id, { provider: yui, fetch: m.fetch, search: { key: "fc-yui", fetch: fc.fetch } });
  assert.equal(fc.calls.length, 1, "it looked it up");
  ownOnly(m.calls, GROQ);
  const r = store.data.rows.filter((x) => x.agent_id === y.id && x.sender === "agent").pop()!;
  assert.match(r.body, /Your Groq key has no web search, so that lookup used Yui's free ones \(20 a day\)/);
});

test("web search on a provider that has it adds no such card", async () => {
  const { store, byHandle } = await withKey("openrouter", null);
  const y = await byHandle("yui");
  const m = spy(ask);
  store.say(y.id, "did the knicks win?");
  await runAgent(store, y.id, { provider: yui, fetch: m.fetch, search: { key: "fc-yui", fetch: firecrawl().fetch } });
  const r = store.data.rows.filter((x) => x.agent_id === y.id && x.sender === "agent").pop()!;
  assert.doesNotMatch(r.body, /has no web search/);
});
