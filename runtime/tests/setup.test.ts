// YUI-138, Start blank: a new empty agent opens on the setup flow; its answers become its profile with no model turn,
// the profile survives a reload, and its next reply is on the voice it was given.
import { test } from "node:test";
import assert from "node:assert/strict";
import { runAgent } from "../src/turn.ts";
import { LocalStore } from "../src/store.ts";
import { crew } from "../src/profiles.ts";
import { applySetup, setupAsks } from "../src/setup.ts";
import { fakeModel, provider, system, USER } from "./helpers.ts";
// @ts-ignore: the parser the app and the site share, as the MCP server ships it
import { parse } from "../../supabase/functions/yui-mcp/yl.mjs";

const blankStore = async () => {
  const store = new LocalStore({}, { guide: "GUIDE", freeTurns: 100 });
  const agent = await store.createAgent(USER, crew().blank);
  return { store, agent };
};
const rows = (store: any, id: string) => store.data.rows.filter((r: any) => r.agent_id === id && r.sender === "agent");
const ANSWERS = `[yui] setup plan plan.name="Nova" plan.voice=Short plan.look=Butter plan.screens=Lists|Timers plan.model="GLM 5.2"`;

test("its first message is one full-screen flow: five questions, Not sure and Skip on each", async () => {
  const { store, agent } = await blankStore();
  const first = rows(store, agent.id)[0].body as string;
  const ops = parse(first.match(/```yui\n([\s\S]*?)\n```/)![1], {});
  const ids = ops.filter((o: any) => o.op === "add").map((o: any) => `${o.preset}@${o.id}`);
  assert.deepEqual(ids, ["plan@setup", "choose@name", "choose@voice", "choose@look", "pick@screens", "choose@model"]);
  for (const o of ops.filter((o: any) => o.op === "add" && o.preset !== "plan")) {
    const opts = JSON.stringify(o.props);
    assert.match(opts, /Not sure/, `${o.id} has Not sure`);
    assert.match(opts, /Skip/, `${o.id} has Skip`);
  }
});

test("the answers become its profile with no model turn, and it greets as itself in that voice", async () => {
  const { store, agent } = await blankStore();
  const m = fakeModel(() => { throw new Error("no model call expected"); });
  store.say(agent.id, ANSWERS, "event");
  await runAgent(store, agent.id, { provider, fetch: m.fetch });
  const p = (await store.agents(USER)).find((a) => a.id === agent.id)!.profile;
  assert.equal(p.name, "Nova");
  assert.equal(p.color, "butter");
  assert.deepEqual(p.favorites, ["list", "timer"]);
  assert.equal(p.model, "z-ai/glm-5.2");
  assert.equal(p.blank, false);
  assert.equal(p.base, "custom");
  assert.match(p.soul, /^You are Nova/);
  assert.match(p.soul, /as few words as you can/);
  const hello = rows(store, agent.id).at(-1).body as string;
  assert.match(hello, /^Nova\. Ready\./);
  assert.match(hello, /choose "What should I help with\?"/);
  assert.equal(m.calls.length, 0);
});

test("it survives a reload, and its next reply runs on the new soul and model", async () => {
  const { store, agent } = await blankStore();
  store.say(agent.id, ANSWERS, "event");
  await runAgent(store, agent.id, { provider, fetch: fakeModel(() => "x").fetch });
  const again = new LocalStore(JSON.parse(JSON.stringify(store.data)), { guide: "GUIDE", freeTurns: 100 });
  const reloaded = (await again.agents(USER)).find((a) => a.id === agent.id)!;
  assert.equal(reloaded.profile.name, "Nova");
  const m = fakeModel(() => "Sure. Pasta?");
  again.say(agent.id, "something quick to cook", "text");
  await runAgent(again, agent.id, { provider, fetch: m.fetch });
  assert.match(system(m.calls[0]), /You are Nova/);
  assert.match(system(m.calls[0]), /as few words as you can/);
  assert.equal(m.calls[0].model, "z-ai/glm-5.2");
});

test("Not sure and Skip take plain defaults; a typed name and voice are kept", () => {
  const skipped = applySetup(crew().blank, { name: "Skip", voice: "Not sure", look: "Skip", screens: ["Not sure"], model: "Skip" });
  assert.equal(skipped.profile.name, "Kit");
  assert.deepEqual(skipped.profile.favorites, ["choose", "list", "card"]);
  assert.equal(skipped.profile.model, "default");
  assert.equal(skipped.profile.color, crew().blank.color);
  const typed = applySetup(crew().blank, { name: "Mo", voice: "like a pirate", screens: "Charts" });
  assert.equal(typed.profile.name, "Mo");
  assert.match(typed.profile.soul, /You talk like this: like a pirate\./);
  assert.deepEqual(typed.profile.favorites, ["chart"]);
});

test("only the setup plan is taken; other rows go to the model, and a set-up agent never re-runs it", async () => {
  const { store, agent } = await blankStore();
  const a = store.say(agent.id, "hello there", "text");
  const b = store.say(agent.id, ANSWERS, "event");
  const pending = store.data.rows.filter((r: any) => [a, b].includes(r.id));
  const { asks, rest } = setupAsks(pending);
  assert.equal(asks.length, 1);
  assert.equal(rest.length, 1);
  await runAgent(store, agent.id, { provider, fetch: fakeModel(() => "ok").fetch });
  store.say(agent.id, `[yui] setup plan plan.name="Other"`, "event");
  await runAgent(store, agent.id, { provider, fetch: fakeModel(() => "ok").fetch });
  assert.equal((await store.agents(USER)).find((x) => x.id === agent.id)!.profile.name, "Nova");
});
