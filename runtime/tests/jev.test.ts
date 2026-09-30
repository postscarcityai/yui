// YUI-215: Jev as the crew's tool router, shadow only. A turn no pattern caught still goes to the model exactly as
// before; Jev is asked in parallel and only a log line comes of it. No network: the Jev side is a fake fetch.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { runAgent } from "../src/turn.ts";
import { JEV_TOOLS, jevLine, jevRoute } from "../src/jev.ts";
import { fakeModel, freshYui, provider } from "./helpers.ts";

const MON = Date.parse("2026-09-28T16:00:00Z");
const now = () => MON;

function fakeJev(tool: string, confidence = 0.93) {
  const calls: any[] = [];
  const f = (async (_url: string, init: any) => {
    calls.push(JSON.parse(init.body));
    return new Response(JSON.stringify({ answers: { tool: { type: "choice", choice: tool, confidence, probabilities: { [tool]: confidence } } },
                                         usage: { input_tokens: 400, output_tokens: 20, cost: 0.000017 } }), { status: 200 });
  }) as unknown as typeof fetch;
  return { calls, fetch: f };
}
const settle = () => new Promise((r) => setTimeout(r, 20));

test("the tool table matches the eval's tools.json, the one the measurements ran on", () => {
  const json = JSON.parse(readFileSync(new URL("../../hermes-plugin/jev_eval/tools.json", import.meta.url), "utf8"));
  assert.deepEqual(JEV_TOOLS, json);
});

test("a miss goes to the model as before and Jev's pick is only logged", async () => {
  const { store, byHandle } = await freshYui();
  store.data.timezones = { u1: "America/New_York" };
  const penny = await byHandle("penny");
  store.say(penny.id, "Could you get my week into some kind of order?"); // no pattern says this
  const m = fakeModel(() => "Sure. Tell me what is on it.");
  const j = fakeJev("plan_week");
  const logs: string[] = [];
  await runAgent(store, penny.id, { provider, fetch: m.fetch, now, log: (l) => logs.push(l), jev: { key: "k", fetch: j.fetch } });
  await settle();
  assert.equal(m.calls.length, 1, "the model still answers: nothing was routed");
  assert.equal(j.calls.length, 1);
  assert.equal(j.calls[0].model, "typesafe/jev-1.13");
  assert.equal(j.calls[0].state.message, "Could you get my week into some kind of order?");
  assert.deepEqual(Object.keys(j.calls[0].questions.tool.criteria), ["plan_week", "whats_next", "evening_review", "add_todo", "none"]);
  const line = logs.find((l) => l.includes("jev shadow"));
  assert.match(line!, /Penny: jev shadow plan_week 0\.93 \(would route\)/);
  assert.ok(!line!.includes("get my week"), "never the words");
});

test("a pattern that catches the words means no Jev call at all", async () => {
  const { store, byHandle } = await freshYui();
  store.data.timezones = { u1: "America/New_York" };
  const penny = await byHandle("penny");
  store.say(penny.id, "Plan my week");
  const j = fakeJev("plan_week");
  await runAgent(store, penny.id, { provider, fetch: fakeModel(() => { throw new Error("no model"); }).fetch, now, jev: { key: "k", fetch: j.fetch } });
  assert.equal(j.calls.length, 0);
});

test("no key, no tools or a failed call: no route and no error", async () => {
  const { store, byHandle } = await freshYui();
  const penny = await byHandle("penny");
  const j = fakeJev("none");
  assert.equal(await jevRoute(undefined, penny, "hello"), null);
  assert.equal(await jevRoute({ key: "", fetch: j.fetch }, penny, "hello"), null);
  assert.equal(await jevRoute({ key: "k", fetch: j.fetch }, { ...penny, profile: { ...penny.profile, handle: "someone" } }, "hello"), null);
  assert.equal(j.calls.length, 0);
  const down = (async () => { throw new Error("offline"); }) as unknown as typeof fetch;
  assert.equal(await jevRoute({ key: "k", fetch: down }, penny, "hello"), null);
  const bad = (async () => new Response("no", { status: 500 })) as unknown as typeof fetch;
  assert.equal(await jevRoute({ key: "k", fetch: bad }, penny, "hello"), null);
});

test("a low confidence pick reads as no route", async () => {
  const { byHandle } = await freshYui();
  const penny = await byHandle("penny");
  const r = await jevRoute({ key: "k", fetch: fakeJev("add_todo", 0.55).fetch }, penny, "buy milk maybe");
  assert.match(jevLine(penny, r!), /add_todo 0\.55 \(no route\)/);
});
