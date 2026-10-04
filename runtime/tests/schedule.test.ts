// Check-ins end to end in the runtime (YUI-143): the ask sets a schedule in the
// person's zone, the tick fires it, the agent's turn lands in the thread, and
// yui-push's payload for that turn. The SQL side (tick, pause) runs on local
// Postgres: ~/.hermes/kanban/artifacts/t_8d47c676/.
import { test } from "node:test";
import assert from "node:assert/strict";
import { runAgent, runScheduled } from "../src/turn.ts";
import { apnsPayload } from "../../supabase/functions/yui-push/payload.ts";
import { fakeModel, freshYui, lastUser, provider, USER } from "./helpers.ts";

const NY = "America/New_York";
const SUNDAY_9AM = Date.parse("2026-09-27T13:00:00Z");

test("'Check in Monday at 7': the trainer sets it in the person's zone, it fires Monday and pushes", async () => {
  const { store, byHandle } = await freshYui();
  store.data.timezones = { [USER]: NY };
  const arnold = await byHandle("arnold");
  store.say(arnold.id, "Check in Monday at 7");
  await runAgent(store, arnold.id, { provider, now: () => SUNDAY_9AM,
    fetch: fakeModel(() => 'Monday, 7 sharp.\n```schedule\nonce 2026-09-28 07:00 "Monday workout check-in"\n```').fetch });
  const [s] = await store.schedules(arnold.id);
  assert.equal(s.tz, NY);
  assert.equal(s.nextAt, "2026-09-28T11:00:00.000Z", "7:00 in New York is 11:00 UTC");

  const fire = fakeModel(() => "Morning! Today is legs.\n```yui\ntimer 40/20x8 Tabata\n```");
  const r = await runScheduled(store, s.id, { provider, fetch: fire.fetch, now: () => Date.parse(s.nextAt!) + 20_000 });
  assert.match(String(lastUser(fire.calls[0]).content), /\[yui\] check-in s1 "Monday workout check-in"/, "a one-time check-in keeps its number");
  assert.equal(await store.schedule(s.id), null, "done once it fired");
  const reply = store.data.rows.find((x) => x.id === r.replies[0])!;
  assert.equal(reply.sender, "agent");
  assert.equal(reply.agent_id, arnold.id);
  assert.equal(reply.meta.checkin, true);

  const p = apnsPayload({ id: arnold.id, name: arnold.profile.name }, { id: reply.id, body: reply.body, meta: reply.meta });
  assert.deepEqual(p.aps.alert, { title: arnold.profile.name, body: "Morning! Today is legs." });
  assert.equal(p.aps["thread-id"], arnold.id);
  assert.equal(p.url, `yui://agent/${arnold.id}/thread`);
});

test("Basil asks about lunch every day at 12:30, and the next one is tomorrow", async () => {
  const { store, byHandle } = await freshYui();
  store.data.timezones = { [USER]: NY };
  const basil = await byHandle("basil");
  store.say(basil.id, "ask me what I'm having for lunch every day");
  await runAgent(store, basil.id, { provider, now: () => SUNDAY_9AM,
    fetch: fakeModel(() => 'On it.\n```schedule\nevery day 12:30 "Ask what they\'re having for lunch"\n```').fetch });
  const s = (await store.schedules(basil.id)).find((x) => x.note !== "yui:new-day")!;
  assert.equal(s.nextAt, "2026-09-27T16:30:00.000Z", "12:30 today in New York");

  const r = await runScheduled(store, s.id, { provider, now: () => Date.parse(s.nextAt!) + 5_000,
    fetch: fakeModel(() => "Lunch time! What's on the plate?\n```yui\nchoose \"Lunch\" Salad|Leftovers|Eating out\n```").fetch });
  assert.equal((await store.schedule(s.id))!.nextAt, "2026-09-28T16:30:00.000Z");
  const reply = store.data.rows.find((x) => x.id === r.replies[0])!;
  assert.equal(apnsPayload({ id: basil.id, name: "Basil" }, reply).aps.alert.body, "Lunch time! What's on the plate?");
});

test("a check-in that is only a screen pushes as the agent checking in", async () => {
  const { store, byHandle } = await freshYui();
  const basil = await byHandle("basil");
  store.say(basil.id, "in 1 hour ask me");
  await runAgent(store, basil.id, { provider, now: () => SUNDAY_9AM,
    fetch: fakeModel(() => 'Sure.\n```schedule\nin 1h "Lunch?"\n```').fetch });
  const [s] = await store.schedules(basil.id);
  const r = await runScheduled(store, s.id, { provider, now: () => SUNDAY_9AM + 3_601_000,
    fetch: fakeModel(() => '```yui\nchoose "Lunch?" Salad|Soup\n```').fetch });
  const reply = store.data.rows.find((x) => x.id === r.replies[0])!;
  assert.equal(apnsPayload({ id: basil.id, name: "Basil" }, reply).aps.alert.body, "Basil is checking in");
  // An ordinary reply that is only a screen keeps the old wording.
  assert.equal(apnsPayload({ id: basil.id, name: "Basil" }, { id: "m", body: '```yui\nchoose "x" a|b\n```' }).aps.alert.body,
               "Basil has something for you in Yui");
});

test("a paused check-in does nothing when it is due", async () => {
  const { store, byHandle } = await freshYui();
  const arnold = await byHandle("arnold");
  store.say(arnold.id, "every day at 7");
  await runAgent(store, arnold.id, { provider, now: () => SUNDAY_9AM,
    fetch: fakeModel(() => 'Done.\n```schedule\nevery day 07:00 "Workout?"\n```').fetch });
  const [s] = await store.schedules(arnold.id);
  await store.updateSchedule(s.id, { paused: true, nextAt: null });
  const m = fakeModel(() => "should not run");
  const r = await runScheduled(store, s.id, { provider, fetch: m.fetch, now: () => SUNDAY_9AM + 86_400_000 });
  assert.equal(r.replies.length, 0);
  assert.equal(m.calls.length, 0);
});
