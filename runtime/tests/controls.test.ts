// The drawer's Controls tab against a native agent: the same rows the Hermes plugin answers.
import { test } from "node:test";
import assert from "node:assert/strict";
import { answerControl, handleControl, REPORT } from "../src/controls.ts";
import { runAgent } from "../src/turn.ts";
import { fakeModel, freshYui, provider, system, USER } from "./helpers.ts";

async function ask(store: any, agentId: string, req: Record<string, unknown>) {
  const id = store.say(agentId, "controls", "control");
  store.data.rows.find((r: any) => r.id === id).meta = { v: 1, req: `c-${id.slice(-4)}`, ...req };
  assert.equal(await answerControl(store, id), true);
  const ans = store.data.rows.filter((r: any) => r.kind === "control" && r.sender === "agent").pop();
  assert.equal(ans.meta.for, id);
  assert.ok(store.data.rows.find((r: any) => r.id === id).handled_at);
  return ans.meta;
}

test("the report matches what is served", () => {
  assert.deepEqual(REPORT, { v: 1, sections: { soul: "rw", memory: "rwd", schedules: "rwd", model: "r" } });
});

test("personality: read, edit with the current rev, conflict on a stale one, never delete", async () => {
  const { store, byHandle } = await freshYui();
  const gouda = await byHandle("gouda");
  const [row] = (await ask(store, gouda.id, { op: "list", section: "soul" })).items;
  assert.equal(row.id, "SOUL.md");
  const got = await ask(store, gouda.id, { op: "get", section: "soul", id: "SOUL.md" });
  assert.match(got.item.text, /You are Gouda/);
  const put = await ask(store, gouda.id, { op: "put", section: "soul", id: "SOUL.md", rev: got.rev, value: { text: "You are Gouda. Jazz only." } });
  assert.equal(put.ok, true);
  assert.equal((await store.agent(gouda.id))!.profile.soul, "You are Gouda. Jazz only.");
  const stale = await ask(store, gouda.id, { op: "put", section: "soul", id: "SOUL.md", rev: got.rev, value: { text: "x" } });
  assert.equal(stale.error, "conflict");
  assert.equal(stale.item.text, "You are Gouda. Jazz only.");
  assert.equal((await ask(store, gouda.id, { op: "put", section: "soul", id: "SOUL.md", rev: put.rev, value: { text: "  " } })).error, "empty");
  assert.equal((await ask(store, gouda.id, { op: "delete", section: "soul", id: "SOUL.md", rev: put.rev, confirmed: true })).error, "keep_soul");
  // The next turn runs on the edited soul.
  const m = fakeModel(() => "Swing time.");
  store.say(gouda.id, "beat please");
  await runAgent(store, gouda.id, { provider, fetch: m.fetch });
  assert.match(system(m.calls[0]), /Jazz only/);
});

test("memory: about you and the agent's notes, edit and forget", async () => {
  const { store, byHandle } = await freshYui();
  const basil = await byHandle("basil");
  store.say(basil.id, "I'm allergic to peanuts, I want more energy");
  await runAgent(store, basil.id, { provider, fetch: fakeModel(() => "Noted.\n```remember\nme: allergies = peanuts\nnote: goal is more energy\n```").fetch });
  const list = (await ask(store, basil.id, { op: "list", section: "memory" })).items;
  assert.deepEqual(list.map((i: any) => [i.group, i.title]).sort(), [["remembers", "goal is more energy"], ["you", "allergies: peanuts"]]);
  const fact = list.find((i: any) => i.group === "you");
  const got = await ask(store, basil.id, { op: "get", section: "memory", id: fact.id });
  const put = await ask(store, basil.id, { op: "put", section: "memory", id: fact.id, rev: got.rev, value: { text: "peanuts and shellfish" } });
  assert.equal(put.item.text, "peanuts and shellfish");
  const note = list.find((i: any) => i.group === "remembers");
  const noConfirm = await ask(store, basil.id, { op: "delete", section: "memory", id: note.id, rev: note.rev });
  assert.equal(noConfirm.error, "confirm");
  assert.equal((await ask(store, basil.id, { op: "delete", section: "memory", id: note.id, rev: note.rev, confirmed: true })).deleted, true);
  // Arnold reads the edited card; Basil's note is gone.
  const arnold = await byHandle("arnold");
  const m = fakeModel(() => "ok");
  store.say(arnold.id, "hi");
  await runAgent(store, arnold.id, { provider, fetch: m.fetch });
  assert.match(system(m.calls[0]), /allergies: peanuts and shellfish/);
  assert.equal(store.data.memory.some((x) => x.body === "goal is more energy"), false);
});

test("check-ins: list, pause, resume, run now, edit the time, delete", async () => {
  const { store, byHandle } = await freshYui();
  store.data.timezones = { [USER]: "America/New_York" };
  const arnold = await byHandle("arnold");
  store.say(arnold.id, "check in weekdays at 7");
  await runAgent(store, arnold.id, { provider, fetch: fakeModel(() => 'Done.\n```schedule\nevery weekday 07:00 "Workout check-in"\n```').fetch });
  const [row] = (await ask(store, arnold.id, { op: "list", section: "schedules" })).items;
  assert.equal(row.title, "Workout check-in");
  assert.equal(row.when, "every mon,tue,wed,thu,fri 07:00");
  const paused = await ask(store, arnold.id, { op: "act", section: "schedules", id: row.id, verb: "pause" });
  assert.equal(paused.item.paused, true);
  assert.equal(store.due(Date.now() + 7 * 86400000).length, 0, "a paused check-in never comes due");
  const resumed = await ask(store, arnold.id, { op: "act", section: "schedules", id: row.id, verb: "resume" });
  assert.ok(resumed.item.next_run);
  const run = await ask(store, arnold.id, { op: "act", section: "schedules", id: row.id, verb: "run" });
  assert.equal(run.item.running_soon, true);
  assert.equal(store.due(Date.now() + 1000).length, 1);
  const edited = await ask(store, arnold.id, { op: "put", section: "schedules", id: row.id, rev: run.rev, value: { schedule: "every sat 09:30" } });
  assert.equal(edited.item.when, "every sat 09:30");
  const bad = await ask(store, arnold.id, { op: "put", section: "schedules", id: row.id, rev: edited.rev, value: { schedule: "whenever" } });
  assert.equal(bad.error, "bad_schedule");
  assert.equal((await ask(store, arnold.id, { op: "delete", section: "schedules", id: row.id, rev: edited.rev, confirmed: true })).deleted, true);
  assert.deepEqual(await store.schedules(arnold.id), []);
});

test("model is read only and names the provider, never a key", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const got = await ask(store, yui.id, { op: "get", section: "model", id: "model" });
  assert.equal(got.item.provider, "OpenRouter, on Yui");
  assert.ok(got.item.toolsets.some((t: any) => t.name === "Makes agents"));
  assert.equal((await ask(store, yui.id, { op: "put", section: "model", id: "model", rev: got.rev, value: {} })).error, "not_allowed");
  store.data.keys = { [USER]: { provider: "groq", baseUrl: "https://api.groq.com/openai/v1", model: "m", key: "gsk-secret-value" } };
  const own = await ask(store, yui.id, { op: "get", section: "model", id: "model" });
  assert.equal(own.item.provider, "your own Groq key");
  assert.doesNotMatch(JSON.stringify(store.data.rows.filter((r) => r.kind === "control")), /gsk-secret/);
});

test("refusals: not the owner, an old version, a path for an id, an unknown section", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const ctx = { store, agent: yui, owner: false, provider: "x" };
  assert.equal((await handleControl({ v: 1, op: "list", section: "soul" }, ctx)).error, "not_owner");
  assert.equal((await handleControl({ v: 2, op: "list", section: "soul" }, { ...ctx, owner: true })).error, "version");
  assert.equal((await handleControl({ v: 1, op: "get", section: "soul", id: "../etc" }, { ...ctx, owner: true })).error, "bad_id");
  assert.equal((await handleControl({ v: 1, op: "list", section: "skills" }, { ...ctx, owner: true })).error, "bad_section");
  // A control row never starts a turn.
  const m = fakeModel(() => "should not run");
  const id = store.say(yui.id, "controls", "control");
  await runAgent(store, yui.id, { provider, fetch: m.fetch });
  assert.equal(m.calls.length, 0);
  assert.equal(await answerControl(store, store.say(yui.id, "plain text")), false);
  void id;
});
