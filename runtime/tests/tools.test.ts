// Check-ins, hand-offs and a person's own key. Web search: search.test.ts.
import { test } from "node:test";
import assert from "node:assert/strict";
import { next, parseLine, zoned } from "../src/schedule.ts";
import { runAgent, runScheduled } from "../src/turn.ts";
import { fakeModel, freshYui, lastUser, provider, system, USER } from "./helpers.ts";

const NY = "America/New_York";

test("wall-clock times in a zone, across a daylight-saving change", () => {
  assert.equal(new Date(zoned(2026, 6, 1, 7, 0, NY)).toISOString(), "2026-07-01T11:00:00.000Z"); // EDT
  assert.equal(new Date(zoned(2026, 11, 1, 7, 0, NY)).toISOString(), "2026-12-01T12:00:00.000Z"); // EST
  // Friday Oct 30 2026, 23:00 NY; next "every mon 07:00" is Mon Nov 2, after the clocks go back.
  const after = zoned(2026, 9, 30, 23, 0, NY);
  assert.equal(new Date(next({ every: "mon", at: "07:00" }, NY, after)!).toISOString(), "2026-11-02T12:00:00.000Z");
});

test("check-in lines", () => {
  const now = Date.parse("2026-09-27T13:00:00Z"); // 9:00 in New York, a Sunday
  const a = parseLine('every weekday 07:30 "Workout check-in"', NY, now)!;
  assert.deepEqual(a, { rule: { every: "mon,tue,wed,thu,fri", at: "07:30" }, note: "Workout check-in" });
  assert.equal(new Date(next((a as any).rule, NY, now)!).toISOString(), "2026-09-28T11:30:00.000Z");
  assert.deepEqual(parseLine('in 2h "How was the run?"', NY, now), { rule: { once: "2026-09-27T15:00:00.000Z" }, note: "How was the run?" });
  assert.deepEqual(parseLine('once 2026-09-28 18:00 "Prep meals"', NY, now), { rule: { once: "2026-09-28T22:00:00.000Z" }, note: "Prep meals" });
  assert.equal(parseLine('once 2026-09-01 18:00 "past"', NY, now), null);
  assert.equal(parseLine('every day 25:00 "bad"', NY, now), null);
  assert.equal(parseLine('in 400d "too far"', NY, now), null);
  assert.deepEqual(parseLine("cancel s2", NY, now), { cancel: "s2" });
});

test("an agent sets a check-in in the person's zone; it fires and opens the thread", async () => {
  const { store, byHandle } = await freshYui();
  store.data.timezones = { [USER]: NY };
  const arnold = await byHandle("arnold");
  const now = Date.parse("2026-09-27T13:00:00Z");
  const set = fakeModel(() => 'Locked in.\n```schedule\nevery mon,wed,fri 07:00 "Check in about today\'s workout"\n```');
  store.say(arnold.id, "check in with me mon wed fri at 7");
  await runAgent(store, arnold.id, { provider, fetch: set.fetch, now: () => now });
  assert.match(system(set.calls[0]), /Sunday, September 27, 2026[\s\S]*America\/New_York/);
  const [s] = await store.schedules(arnold.id);
  assert.equal(s.nextAt, "2026-09-28T11:00:00.000Z");
  assert.equal(s.tz, NY);

  const fire = fakeModel(() => "Morning! Legs today.\n```yui\ntimer 40/20x8 Tabata\n```");
  const at = Date.parse(s.nextAt!) + 1000;
  const r = await runScheduled(store, s.id, { provider, fetch: fire.fetch, now: () => at });
  assert.equal(r.replies.length, 1);
  assert.match(String(lastUser(fire.calls[0]).content), /\[yui\] check-in s1 "Check in about today's workout"/);
  assert.match(system(fire.calls[0]), /\[s1\] every mon,wed,fri 07:00/);
  const reply = store.data.rows.find((x) => x.id === r.replies[0])!;
  assert.equal(reply.meta.checkin, true);
  assert.equal((await store.schedule(s.id))!.nextAt, "2026-09-30T11:00:00.000Z", "the next one is Wednesday");
  assert.ok(!store.data.rows.some((x) => x.sender === "user" && x.body.includes("check-in")), "nothing is written as the person");
});

test("a one-time check-in is gone once it fires; cancel removes one", async () => {
  const { store, byHandle } = await freshYui();
  const basil = await byHandle("basil");
  const now = Date.parse("2026-09-27T13:00:00Z");
  store.say(basil.id, "remind me in an hour, and every day at noon");
  await runAgent(store, basil.id, { provider, now: () => now,
    fetch: fakeModel(() => 'Sure.\n```schedule\nin 1h "Drink water"\nevery day 12:00 "Lunch?"\n```').fetch });
  const [once, daily] = await store.schedules(basil.id);
  await runScheduled(store, once.id, { provider, fetch: fakeModel(() => "Water time.").fetch, now: () => now + 3_700_000 });
  assert.equal(await store.schedule(once.id), null);
  store.say(basil.id, "stop the lunch one");
  await runAgent(store, basil.id, { provider, now: () => now, fetch: fakeModel(() => "Done.\n```schedule\ncancel s1\n```").fetch });
  assert.equal(await store.schedule(daily.id), null);
});

test("hand-off: Yui passes the person to Gouda, who opens its own thread with the context", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const gouda = await byHandle("gouda");
  const m = fakeModel((c) => /Who you are: Yui/.test(system(c))
    ? 'Gouda is your musician; I passed it on.\n```handoff\ngouda "Wants a lo-fi beat at 80 bpm, plays bass"\n```'
    : 'Yui says lo-fi at 80. Here you go.\n```yui\nloop 80 "Lo-fi" p=x...x.x.|....|...\n```\n```handoff\nyui "loop back"\n```');
  store.say(yui.id, "I want to make a beat");
  const r = await runAgent(store, yui.id, { provider, fetch: m.fetch });
  assert.equal(r.replies.length, 2);
  assert.match(String(lastUser(m.calls[1]).content), /\[yui\] handoff from=yui note="Wants a lo-fi beat at 80 bpm, plays bass"/);
  const g = store.data.rows.filter((x) => x.agent_id === gouda.id && x.sender === "agent").pop()!;
  assert.match(g.body, /Yui says lo-fi at 80/);
  assert.equal(m.calls.length, 2, "a handed-off agent can't hand on");
  // The answer carries the card that takes the person to Gouda (YUI-144): the phone jumps on it.
  const y = store.data.rows.filter((x) => x.agent_id === yui.id && x.sender === "agent").pop()!;
  assert.match(y.body, /^Gouda is your musician; I passed it on\.\n```yui\ncard "Gouda" body="Wants a lo-fi beat at 80 bpm, plays bass" url=yui:\/\/agent\/gouda cta="Open Gouda"\n```$/);
  assert.doesNotMatch(g.body, /yui:\/\/agent/, "no card back: Gouda can't hand on");
});

test("a hand-off card the agent draws itself hands off too, once, with its body as the note (YUI-144)", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const basil = await byHandle("basil");
  const m = fakeModel((c) => /Who you are: Yui/.test(system(c))
    ? 'Basil does food.\n```yui\ncard "Basil" body="She just finished leg day, wants dinner ideas" url=yui://agent/basil cta="Open Basil"\n```'
    : "Leg day dinner: salmon, rice, greens.");
  store.say(yui.id, "what should I eat after leg day?");
  await runAgent(store, yui.id, { provider, fetch: m.fetch });
  assert.match(String(lastUser(m.calls[1]).content), /\[yui\] handoff from=yui note="She just finished leg day, wants dinner ideas"/);
  const y = store.data.rows.filter((x) => x.agent_id === yui.id && x.sender === "agent").pop()!;
  assert.equal(y.body.match(/url=yui:\/\/agent\/basil/g)!.length, 1, "no second card");
  assert.match(store.data.rows.filter((x) => x.agent_id === basil.id && x.sender === "agent").pop()!.body, /salmon/);
});

test("a hand-off to no one in the crew hands nothing off and adds no card", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const m = fakeModel(() => 'Passing you on.\n```handoff\nnobody "x"\n```');
  store.say(yui.id, "hi");
  await runAgent(store, yui.id, { provider, fetch: m.fetch });
  assert.equal(m.calls.length, 1);
  assert.doesNotMatch(store.data.rows.filter((x) => x.agent_id === yui.id && x.sender === "agent").pop()!.body, /card/);
});

test("connected agents: listed by handle, reached by @mention, never handed to (YUI-144)", async () => {
  const { store, byHandle } = await freshYui();
  store.data.others = [{ handle: "urza", name: "Urza" }];
  store.data.memory.push({ id: "m1", userId: USER, agentId: null, kind: "about", key: "knee", body: "bad left knee", updatedAt: "t" } as any);
  const yui = await byHandle("yui");
  const m = fakeModel(() => "I'll ask @urza about the server. `@notme` stays code.\n```handoff\nurza \"server is down\"\n```");
  store.say(yui.id, "is the server ok?");
  await runAgent(store, yui.id, { provider, fetch: m.fetch });
  assert.match(system(m.calls[0]), /Connected \(reach with @handle, no hand-off\): Urza \(@urza\)/);
  assert.equal(m.calls.length, 1, "a connected agent is not handed to");
  const y = store.data.rows.filter((x) => x.agent_id === yui.id && x.sender === "agent").pop()!;
  assert.deepEqual(y.meta.mentions, ["urza"], "the database routes the @ as a mention");
  assert.doesNotMatch(y.body, /yui:\/\/agent/);
  assert.doesNotMatch(JSON.stringify(y.meta), /knee/, "memory never rides along");
});

test("a turn another agent started answers but never passes the person on", async () => {
  const { store, byHandle } = await freshYui();
  const basil = await byHandle("basil");
  const m = fakeModel(() => 'Sure. Ask @gouda too.\n```handoff\ngouda "more"\n```');
  store.say(basil.id, "[yui] mention from=urza by=agent msg=x\nwhat's for dinner?");
  await runAgent(store, basil.id, { provider, fetch: m.fetch });
  assert.equal(m.calls.length, 1);
  const b = store.data.rows.filter((x) => x.agent_id === basil.id && x.sender === "agent").pop()!;
  assert.equal(b.meta.mentions, undefined);
  assert.doesNotMatch(b.body, /yui:\/\/agent/);
});

test("groups: a native agent answers a group row in the group, apart from its own thread (YUI-144)", async () => {
  const { store, byHandle } = await freshYui();
  const arnold = await byHandle("arnold");
  const G = "g-race-week";
  const push = (body: string, thread?: string, sender = "user") => {
    const id = store.id("row");
    store.data.rows.push({ id, agent_id: arnold.id, sender, kind: "text", body, meta: thread ? { group: { thread: G } } : {},
                           created_at: new Date().toISOString(), ...(thread ? { thread_id: thread } : {}) });
    return id;
  };
  push("solo secret: I skipped Tuesday", undefined, "user");
  store.data.rows[store.data.rows.length - 1].handled_at = "t";
  push('[yui] group "Race week" thread=g-race-week members=@arnold,@sage lead=@sage hop=0 from=person\n> Person: plan Saturday\nplan Saturday', G);
  const solo = push("and my own plan?");
  const m = fakeModel((c) => /\[yui\] group/.test(String(lastUser(c).content))
    ? "Easy 5k Saturday. @sage can you do the fuel?\n```handoff\nbasil \"x\"\n```" : "Your plan: rest.");
  const r = await runAgent(store, arnold.id, { provider, fetch: m.fetch });
  assert.equal(r.turns, 2, "one turn for the group, one for the solo thread");
  const groupCall = m.calls.find((c) => /\[yui\] group/.test(String(lastUser(c).content)))!;
  assert.doesNotMatch(JSON.stringify(groupCall.messages.slice(1)), /solo secret|my own plan/, "the group turn reads the group only");
  const soloCall = m.calls.find((c) => c !== groupCall)!;
  assert.doesNotMatch(JSON.stringify(soloCall.messages.slice(1)), /Race week/, "the solo turn reads its own thread only");
  const out = store.data.rows.filter((x) => x.agent_id === arnold.id && x.sender === "agent" && x.meta?.turn);
  const inGroup = out.find((x) => x.thread_id === G)!;
  assert.match(inGroup.body, /Easy 5k/);
  assert.deepEqual(inGroup.meta.mentions, ["sage"], "an @ in a group is an ask on its hop budget");
  assert.doesNotMatch(inGroup.body, /yui:\/\/agent/, "no hand-off out of a group");
  assert.equal(out.find((x) => !x.thread_id)!.meta.turn[0], solo);
  assert.equal(m.calls.length, 2, "no hand-off turn for Basil");
});

test("a person's own key: their provider, their model, no monthly cap", async () => {
  const { store, byHandle } = await freshYui({ freeTurns: 0 });
  store.data.keys = { [USER]: { provider: "groq", baseUrl: "https://api.groq.test/openai/v1", model: "qwen/qwen3.8-27b", key: "gsk-own" } };
  const penny = await byHandle("penny");
  const seen: string[] = [];
  const m = fakeModel(() => "Your week, sorted.");
  const spy = (async (url: string, init: any) => {
    seen.push(`${url} ${init.headers.authorization}`);
    return m.fetch(url, init);
  }) as unknown as typeof fetch;
  store.say(penny.id, "any tips for a busy week?");
  await runAgent(store, penny.id, { provider, fetch: spy });
  assert.equal(m.calls[0].model, "qwen/qwen3.8-27b");
  assert.deepEqual(seen, ["https://api.groq.test/openai/v1/chat/completions Bearer gsk-own"]);
  assert.equal(m.calls[0].body.provider, undefined, "OpenRouter's rules only go to OpenRouter");
  assert.equal(store.data.rows.filter((r) => r.agent_id === penny.id).pop()!.body, "Your week, sorted.");
});

test("an own OpenRouter key keeps Yui's routes", async () => {
  const { store, byHandle } = await freshYui();
  store.data.keys = { [USER]: { provider: "openrouter", baseUrl: "https://openrouter.ai/api/v1", model: null, key: "sk-own" } };
  const basil = await byHandle("arnold");
  const m = fakeModel(() => "ok");
  store.say(basil.id, "[yui] c1 camera photo=https://img.test/p.jpg", "event");
  await runAgent(store, basil.id, { provider, fetch: m.fetch });
  assert.equal(m.calls[0].model, "z-ai/glm-5v-turbo");
  assert.equal(m.calls[0].body.provider.data_collection, "deny");
});
