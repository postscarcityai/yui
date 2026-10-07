// YUI-322: Yui's own OpenRouter key runs dry (402 "Insufficient credits"). A person on it sees a kind screen, never an error or silence;
// a film or hero that hits it fails quiet; an operator gets one "house-key-dry" line an hour. A person's own key keeps its plain wording.
import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { DRY_TAG, openRouter, resetDryLog, restingScreen, runAgent, runJob } from "../src/turn.ts";
import { freshYui, provider, USER } from "./helpers.ts";

const FILM = `String theory says everything is tiny loops. Watch.
\`\`\`yui
motion "How a skateboard turns: the metal trucks under the deck tilt when you lean, and the board curves."
\`\`\``;
const CHAT = "Hi there.";

/** The model behind a stub that answers 402 {"error":{"message":"Insufficient credits"}} to the calls `dry` picks. */
function dryModel(dry: (system: string, n: number) => boolean, chat = CHAT) {
  const seen: { system: string; n: number; url: string }[] = [];
  const fetchImpl = (async (url: string, init: any) => {
    const body = JSON.parse(init.body);
    const first = String(body.messages[0].content);
    const system = body.messages.length > 1 ? first : /^You are a motion designer/.test(first) ? "film" : "hero"; // film and hero are one user message
    seen.push({ system: system.slice(0, 30), n: body.messages.length, url: String(url) });
    if (dry(system, body.messages.length)) return new Response(JSON.stringify({ error: { message: "Insufficient credits" } }), { status: 402 });
    return new Response(JSON.stringify({ choices: [{ message: { role: "assistant", content: chat }, finish_reason: "stop" }], usage: { prompt_tokens: 1, completion_tokens: 1 } }),
                        { status: 200, headers: { "content-type": "application/json" } });
  }) as unknown as typeof fetch;
  return { seen, fetch: fetchImpl };
}
const all = () => true;
/** The strong film route (hero + film + opener models) is Chris's switch; on, the hero is drawn ahead of the reply. */
async function withStrongRoute<T>(f: () => Promise<T>): Promise<T> {
  const keys = { YUI_MOTION_HERO_MODEL: "m/hero", YUI_MOTION_FILM_MODEL: "m/film", YUI_MOTION_OPENER_MODEL: "m/opener" };
  const was = Object.fromEntries(Object.keys(keys).map((k) => [k, process.env[k]]));
  Object.assign(process.env, keys);
  try { return await f(); } finally { for (const [k, v] of Object.entries(was)) { if (v === undefined) delete process.env[k]; else process.env[k] = v; } }
}
const bodies = (store: any) => store.data.rows.filter((r: any) => r.sender === "agent").map((r: any) => r.body as string);
const dryLines = (log: string[]) => log.filter((l) => l.startsWith(DRY_TAG));

beforeEach(() => resetDryLog());

test("the resting screen is one line and a card whose button opens the key page", () => {
  const s = restingScreen();
  assert.match(s, /^Yui is resting for now\./);
  assert.match(s, /card "Yui is resting" .*cta="Add my key" url=yui:\/\/settings\/key/);
  assert.ok(!/[—–]/.test(s), "no dashes in the house voice");
});

test("a chat turn on the house key that gets 402 shows the resting screen, not an error", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const m = dryModel(all);
  const row = store.say(yui.id, "hello there");
  const log: string[] = [];
  const r = await runAgent(store, yui.id, { provider: openRouter("k"), fetch: m.fetch, log: (l) => log.push(l) });
  const reply = store.data.rows.find((x) => x.id === r.replies[0])!;
  assert.equal(reply.body, restingScreen());
  assert.ok(!/402|Insufficient|couldn't answer/i.test(reply.body));
  assert.equal(reply.meta.native.dry, true);
  assert.deepEqual(reply.meta.turn, [row]);
  assert.ok(store.data.rows.find((x) => x.id === row)!.handled_at, "the ask is handled, not retried forever");
  assert.equal(dryLines(log).length, 1);
});

test("the same 402 on a person's own key keeps the plain message naming their key", async () => {
  const { store, byHandle } = await freshYui();
  store.data.keys = { [USER]: { provider: "openai", baseUrl: "https://api.openai.com/v1", model: null, key: "sk-own-1234" } };
  const yui = await byHandle("yui");
  const m = dryModel(all);
  store.say(yui.id, "hello there");
  const log: string[] = [];
  const r = await runAgent(store, yui.id, { provider: openRouter("k"), fetch: m.fetch, log: (l) => log.push(l) });
  const body = store.data.rows.find((x) => x.id === r.replies[0])!.body;
  assert.match(body, /couldn't answer that: .*out of credits.*\(this is your own openai key\)/);
  assert.ok(!body.includes("Yui is resting"));
  assert.equal(dryLines(log).length, 0, "their dry key is not Yui's problem");
  assert.ok(m.seen.every((s) => s.url.startsWith("https://api.openai.com")), "never Yui's OpenRouter");
});

test("a film on a dry house key is skipped quietly: the reply lands, no error, no words row", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const m = dryModel((system, n) => n === 1 || system === "film", FILM);
  store.say(yui.id, "How does a skateboard turn when I lean?");
  const log: string[] = [];
  const r = await withStrongRoute(() => runAgent(store, yui.id, { provider: openRouter("k"), fetch: m.fetch, log: (l) => log.push(l) }));
  assert.ok(m.seen.some((s) => s.system === "hero"), "the hero was tried");
  assert.ok(m.seen.some((s) => s.system === "film"), "the film writer was tried");
  const out = bodies(store).join("\n");
  assert.ok(r.replies.length >= 1, "the reply still lands");
  assert.match(out, /String theory says everything/);
  assert.ok(!/Yui is resting|couldn't|402|Insufficient/i.test(out), "no error and no resting screen on a reply that worked");
  assert.ok(!/^```yui\nsay "/m.test(out), "no words row stands in for the film");
  assert.ok(!/motion "/.test(out), "no film rows");
  assert.equal(dryLines(log).length, 1, "one line, though the hero and the film both hit it");
});

test("the hero draw alone on a dry house key fails quiet", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const m = dryModel((_s, n) => n === 1, "A skateboard turns when you lean.");
  store.say(yui.id, "How does a skateboard turn when I lean?");
  const r = await withStrongRoute(() => runAgent(store, yui.id, { provider: openRouter("k"), fetch: m.fetch }));
  assert.ok(m.seen.some((s) => s.system === "hero"), "the hero was tried: " + JSON.stringify(m.seen));
  assert.equal(store.data.rows.find((x) => x.id === r.replies[0])!.body, "A skateboard turns when you lean.");
});

test("a meal job on a dry house key shows the resting screen", async () => {
  const { store, byHandle } = await freshYui();
  const basil = await byHandle("basil");
  const m = dryModel(all);
  store.say(basil.id, "[yui] c1 camera photo=https://img.test/bowl.jpg", "event");
  const r = await runAgent(store, basil.id, { provider: provider, fetch: m.fetch, now: () => Date.parse("2026-09-27T13:30:00Z") });
  assert.equal(r.jobs.length, 1);
  const done = await runJob(store, r.jobs[0], { provider, fetch: m.fetch, now: () => Date.parse("2026-09-27T13:30:00Z") });
  assert.equal(store.data.rows.find((x) => x.id === done.replies[0])!.body, restingScreen());
});

test("one house-key-dry line an hour, not one per turn", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const m = dryModel(all);
  const log: string[] = [];
  let t = Date.parse("2026-10-07T12:00:00Z");
  const opts = { provider: openRouter("k"), fetch: m.fetch, log: (l: string) => log.push(l), now: () => t };
  for (let i = 0; i < 3; i++) { store.say(yui.id, `hello ${i}`); await runAgent(store, yui.id, opts); }
  assert.equal(dryLines(log).length, 1, "three dry turns, one line");
  t += 61 * 60_000;
  store.say(yui.id, "hello again");
  await runAgent(store, yui.id, opts);
  assert.equal(dryLines(log).length, 2, "an hour later it speaks once more");
});
