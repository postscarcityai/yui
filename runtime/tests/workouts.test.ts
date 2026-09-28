// YUI-182: Arnold's tools. Today's workout runner, the log, the day editor and his default screens, all answered by
// the runtime from his tables with no model turn. Every test goes through runAgent on the store a person's rows go
// through (not a demo memory), and every reply is read by the real Yui Lines parser.
import { test } from "node:test";
import assert from "node:assert/strict";
import { runAgent } from "../src/turn.ts";
import { clock } from "../src/tables.ts";
import { homeLines } from "../src/home.ts";
import { crew } from "../src/profiles.ts";
import { bestSet, dayKey, mainLifts, parseWorkout, progressScreen, readEvent, streak, weekStart, workoutAsks } from "../src/workouts.ts";
import { fakeModel, freshYui, provider } from "./helpers.ts";
// @ts-ignore: the parser the app and the site share, as the MCP server ships it
import { parse } from "../../supabase/functions/yui-mcp/yl.mjs";

const MON = Date.parse("2026-09-28T15:00:00Z"); // a Monday: Full body A on the starter week
const THU = Date.parse("2026-10-01T15:00:00Z"); // a rest day
const NEXT_MON = Date.parse("2026-10-05T15:00:00Z");

const noModel = () => fakeModel(() => {
  throw new Error("no model call expected");
});
const agentRows = (store: any, id: string) => store.data.rows.filter((r: any) => r.agent_id === id && r.sender === "agent");
const lastReply = (store: any, id: string) => agentRows(store, id).at(-1);
const fence = (body: string) => body.match(/```yui\n([\s\S]*?)\n```/)![1];

/** Parses a reply's lines as the app would, with the home's lasting ids known; fails on any error line. */
function lines(body: string, known: Record<string, string> = {}) {
  const ops = parse(fence(body), known);
  const bad = ops.filter((o: any) => o.op === "error" || o.error);
  assert.deepEqual(bad, [], `parses clean:\n${fence(body)}`);
  return ops;
}

/** The ids a home leaves on its pages, as the app hands them to the parser. */
function homeIds(): Record<string, string> {
  const ops = parse(homeLines(crew().arnold.home!).join("\n"), {});
  return Object.fromEntries(ops.filter((o: any) => o.op === "add" && o.id && !/^n\d+$/.test(o.id)).map((o: any) => [o.id, o.preset]));
}

/** An event row as the app sends it: the line, and {id, preset, value} in its meta. */
function tap(store: any, agentId: string, id: string, preset: string, value: Record<string, unknown>, line = `[yui] ${id} ${preset}`) {
  const rowId = store.say(agentId, line, "event");
  store.data.rows.find((r: any) => r.id === rowId)!.meta = { id, preset, value };
  return rowId;
}

test("a split row reads as moves: sets x reps, seconds, each side, a weight", () => {
  assert.deepEqual(parseWorkout("Goblet squat 3x10, push-up 3x8, dumbbell row 3x10, plank 3x30s"), [
    { name: "Goblet squat", sets: 3, reps: 10 }, { name: "Push-up", sets: 3, reps: 8 },
    { name: "Dumbbell row", sets: 3, reps: 10 }, { name: "Plank", sets: 3, reps: 0, secs: 30 },
  ]);
  assert.deepEqual(parseWorkout("reverse lunge 3x8 each; squat 5x5 @135 and bench 3x5 at 115 lb"), [
    { name: "Reverse lunge", sets: 3, reps: 8, each: true }, { name: "Squat", sets: 5, reps: 5, lb: 135 }, { name: "Bench", sets: 3, reps: 5, lb: 115 },
  ]);
  assert.deepEqual(parseWorkout("Brisk walk or easy bike"), []);
  assert.deepEqual(parseWorkout("Rest"), []);
  assert.equal(dayKey("2026-09-28"), "mon");
  assert.equal(weekStart("2026-10-04"), "2026-09-28");
});

test("an event reads from its meta, or from its line when there is none", () => {
  const e = readEvent({ id: "r", sender: "user", kind: "event", created_at: "", meta: {},
                        body: '[yui] wk-20260928-mon plan plan.e1-lb=30 plan.e1-reps=10 plan.e1-sets="Set 1"|"Set 2" plan.feel="Just right"' });
  assert.deepEqual(e, { id: "wk-20260928-mon", preset: "plan", value: { plan: { "e1-lb": 30, "e1-reps": 10, "e1-sets": ["Set 1", "Set 2"], feel: "Just right" } } });
  assert.deepEqual(readEvent({ id: "r", sender: "user", kind: "event", created_at: "", body: "[yui] edit-day choose choice=Wed" })!.value, { choice: "Wed" });
  const { asks, rest } = workoutAsks([
    { id: "a", sender: "user", kind: "text", created_at: "", body: "Start today's workout" },
    { id: "b", sender: "user", kind: "text", created_at: "", body: "Log today's workout" },
    { id: "c", sender: "user", kind: "text", created_at: "", body: "can I swap squats for lunges?" },
    { id: "d", sender: "user", kind: "event", created_at: "", body: "[yui] today card cta=Start" },
  ]);
  assert.deepEqual(asks.map((a) => a.kind), ["start", "log", "start"]);
  assert.deepEqual(rest.map((r) => r.id), ["c"], "anything else is the model's");
});

test("Arnold's home: four shortcuts, This week with a day picker, Today, Progress; every line parses", () => {
  const home = homeLines(crew().arnold.home!).join("\n");
  const ops = parse(home, {});
  assert.deepEqual(ops.filter((o: any) => o.op === "error"), []);
  const ids = homeIds();
  for (const id of ["week-done", "days", "edit-day", "split", "today", "sets", "streak", "best", "lifts"]) assert.ok(ids[id], id);
  assert.equal(ids["edit-day"], "choose");
  assert.match(home, /save progress/);
  assert.ok(crew().arnold.tables!.find((t) => t.name === "workouts"), "the log ships empty with him");
});

test("Start: the runner is one full-screen plan, a step per move, how it felt last, one Send; no model, no free turn", async () => {
  const { store, byHandle } = await freshYui({ freeTurns: 1 });
  const arnold = await byHandle("arnold");
  const m = noModel();
  const row = store.say(arnold.id, "Start today's workout");
  await runAgent(store, arnold.id, { provider, fetch: m.fetch, now: () => MON });
  assert.equal(m.calls.length, 0);
  const r = lastReply(store, arnold.id);
  assert.deepEqual(r.meta.turn, [row]);
  assert.ok(store.data.rows.find((x: any) => x.id === row)!.handled_at);
  assert.match(r.body, /^Full body A\. 4 moves, one set at a time\. Let's go\./);
  const ops = lines(r.body);
  const plan = ops.find((o: any) => o.preset === "plan");
  assert.equal(plan.id, "wk-20260928-mon");
  assert.equal(plan.props.submit, "Finish workout");
  const members = ops.filter((o: any) => o.in === plan.id);
  assert.deepEqual(members.map((o: any) => `${o.preset}@${o.id}`), [
    "page@n1",
    "pick@e1-sets", "slide@e1-reps", "slide@e1-lb", // goblet squat: a dumbbell, 20 lb to start
    "pick@e2-sets", "slide@e2-reps", // push-up: bodyweight
    "pick@e3-sets", "slide@e3-reps", "slide@e3-lb",
    "pick@e4-sets", "slide@e4-secs", // plank: seconds
    "choose@feel",
  ], "questions last, all in the one flow");
  const squat = members.find((o: any) => o.id === "e1-sets");
  assert.deepEqual(squat.props.options, ["Set 1", "Set 2", "Set 3"]);
  assert.equal(squat.props.title, "Goblet squat");
  assert.match(squat.props.body, /Hold the bell at your chest/, "the how-to cue from his exercises table");
  assert.equal(members.find((o: any) => o.id === "e1-lb").props.value, 20);
  assert.equal(members.find((o: any) => o.id === "e4-secs").props.value, 30);
  assert.equal(r.meta.native.workout.id, "wk-20260928-mon", "the session rides with the reply");
  // The free turn is still there: a plain message after it reaches the model.
  const m2 = fakeModel(() => "Sure.\n```yui\nsay Sure\n```");
  store.say(arnold.id, "can I swap squats for lunges?");
  await runAgent(store, arnold.id, { provider, fetch: m2.fetch, now: () => MON });
  assert.equal(m2.calls.length, 1);
});

test("Finish writes a row per move, ticks the day, and draws the pages once; the next session patches and starts from the new weight", async () => {
  const { store, byHandle } = await freshYui();
  const arnold = await byHandle("arnold");
  const m = noModel();
  store.say(arnold.id, "Start today's workout");
  await runAgent(store, arnold.id, { provider, fetch: m.fetch, now: () => MON });
  const done = tap(store, arnold.id, "wk-20260928-mon", "plan", {
    plan: { "e1-sets": ["Set 1", "Set 2", "Set 3"], "e1-reps": 12, "e1-lb": 25, "e2-sets": ["Set 1", "Set 2"], "e2-reps": 8,
            "e3-sets": ["Set 1", "Set 2", "Set 3"], "e3-lb": 30, "e4-sets": [], feel: "Easy" },
  });
  await runAgent(store, arnold.id, { provider, fetch: m.fetch, now: () => MON });
  assert.equal(m.calls.length, 0);
  const t = (await store.tables(arnold.id)).tables;
  const log = t.workouts.order.map((k: string) => ({ key: k, ...t.workouts.rows[k] }));
  assert.deepEqual(log, [
    { key: "2026-09-28-goblet-squat", Day: "2026-09-28", Session: "Full body A", Exercise: "Goblet squat", Sets: 3, Reps: 12, Weight: 25, Feel: "Easy", Source: "runner" },
    { key: "2026-09-28-push-up", Day: "2026-09-28", Session: "Full body A", Exercise: "Push-up", Sets: 2, Reps: 8, Feel: "Easy", Source: "runner" },
    { key: "2026-09-28-dumbbell-row", Day: "2026-09-28", Session: "Full body A", Exercise: "Dumbbell row", Sets: 3, Reps: 10, Weight: 30, Feel: "Easy", Source: "runner" },
  ], "unticked plank is left out; untouched reps keep the target");
  assert.equal(t.this_week.rows.mon.Done, true);

  const r = lastReply(store, arnold.id);
  assert.deepEqual(r.meta.turn, [done]);
  assert.match(r.body, /^Logged Full body A: 3 moves, 8 sets\. Nice work\. Felt easy\? Add 5 lb next time\./);
  const first = fence(r.body);
  assert.match(first, /^>2 clear\n>2\nstat@week-done "1 of 5"/m, "the first time the pages are drawn again");
  assert.match(first, /list@days title="This week" "✓ Mon Full body A" "Tue Easy cardio"/);
  assert.match(first, /^card@today "Done: Full body A"/m);
  assert.match(first, /^>4 clear\n>4\nstat@streak "1 week" "Streak"/m);
  assert.match(first, /^stat@best 30lb "Best set" sub="Dumbbell row x 10, Sep 28"$/m);
  assert.match(first, /^chart@lift-dumbbell-row line "Dumbbell row, top set" x="Sep 28" y=30 unit=lb$/m);
  assert.match(first, /save this week\n[\s\S]*save today\n[\s\S]*save progress/);
  lines(r.body, homeIds());
  assert.equal((await store.agent(arnold.id))!.profile.workoutScreens, "dumbbell-row,goblet-squat");

  // A week later: the runner starts from the weight they lifted, and Finish only patches.
  store.say(arnold.id, "Start today's workout");
  await runAgent(store, arnold.id, { provider, fetch: m.fetch, now: () => NEXT_MON });
  const runner = lines(lastReply(store, arnold.id).body);
  assert.equal(runner.find((o: any) => o.id === "e1-lb").props.value, 25);
  assert.equal(runner.find((o: any) => o.id === "e3-lb").props.value, 30);
  tap(store, arnold.id, "wk-20261005-mon", "plan", { plan: { "e1-lb": 30, "e3-lb": 35, feel: "Just right" } });
  await runAgent(store, arnold.id, { provider, fetch: m.fetch, now: () => NEXT_MON });
  const second = lastReply(store, arnold.id).body;
  assert.doesNotMatch(second, /clear|^>\d/m, "patches only: nothing moves the person");
  assert.match(fence(second), /^~week-done "1 of 5"/m);
  assert.match(fence(second), /^~days title="This week" "✓ Mon Full body A"/m);
  assert.match(fence(second), /^~streak "2 weeks"/m);
  assert.match(fence(second), /^~lift-goblet-squat line "Goblet squat, top set" x="Sep 28"\|"Oct 5" y=25\|30 unit=lb$/m);
  assert.match(second, /^Logged Full body A: 4 moves, 12 sets\. Nice work\.$/m, "an untouched plan counts every set");
  lines(second, { ...homeIds(), "lift-dumbbell-row": "chart", "lift-goblet-squat": "chart" }); // the ids the first Finish left on page 4
  assert.equal(m.calls.length, 0);
});

test("the Send from an older app (its line only, no meta) logs the same", async () => {
  const { store, byHandle } = await freshYui();
  const arnold = await byHandle("arnold");
  store.say(arnold.id, '[yui] wk-20260928-mon plan plan.e1-lb=35 plan.e1-reps=8 plan.e1-sets="Set 1"|"Set 2" plan.feel=Hard', "event");
  await runAgent(store, arnold.id, { provider, fetch: noModel().fetch, now: () => MON });
  const t = (await store.tables(arnold.id)).tables.workouts;
  assert.deepEqual(t.rows["2026-09-28-goblet-squat"], { Day: "2026-09-28", Session: "Full body A", Exercise: "Goblet squat", Sets: 2, Reps: 8, Weight: 35, Feel: "Hard", Source: "runner" });
  assert.match(lastReply(store, arnold.id).body, /Felt hard\? Next time we keep the weight and own the reps\./);
});

test("Log today's workout: a short plan; their own words log each move, yesterday lands on yesterday", async () => {
  const { store, byHandle } = await freshYui();
  const arnold = await byHandle("arnold");
  const m = noModel();
  store.say(arnold.id, "Log today's workout");
  await runAgent(store, arnold.id, { provider, fetch: m.fetch, now: () => MON });
  const ops = lines(lastReply(store, arnold.id).body);
  assert.deepEqual(ops.filter((o: any) => o.in === "wlog").map((o: any) => o.id), ["when", "what", "minutes", "feel"]);
  assert.deepEqual(ops.find((o: any) => o.id === "what").props.options, ["Full body A as planned", "Something else"]);
  assert.equal(ops.find((o: any) => o.id === "what").props.other, true);

  tap(store, arnold.id, "wlog", "plan", { plan: { when: "Yesterday", what: "Squat 5x5 @135, bench 3x5 at 115", minutes: 50, feel: "Hard" } });
  await runAgent(store, arnold.id, { provider, fetch: m.fetch, now: () => MON });
  const t = (await store.tables(arnold.id)).tables;
  assert.deepEqual(t.workouts.rows["2026-09-27-squat"], { Day: "2026-09-27", Session: "Workout", Exercise: "Squat", Sets: 5, Reps: 5, Weight: 135, Minutes: 50, Feel: "Hard", Source: "logged" });
  assert.equal(t.workouts.rows["2026-09-27-bench"].Weight, 115);
  assert.equal(t.this_week.rows.sun.Done, undefined, "last week's Sunday is not this week's");
  const body = lastReply(store, arnold.id).body;
  assert.match(body, /^Logged Workout: 2 moves, 8 sets\./);
  assert.match(fence(body), /stat@best 135lb "Best set" sub="Squat x 5, Sep 27"/);
  lines(body, homeIds());

  // As planned: today's moves at their weights.
  tap(store, arnold.id, "wlog", "plan", { plan: { when: "Today", what: "Full body A as planned", feel: "Just right" } });
  await runAgent(store, arnold.id, { provider, fetch: m.fetch, now: () => MON });
  const w = (await store.tables(arnold.id)).tables;
  assert.equal(w.workouts.rows["2026-09-28-goblet-squat"].Sets, 3);
  assert.equal(w.this_week.rows.mon.Done, true);
  assert.match(fence(lastReply(store, arnold.id).body), /^~days title="This week" "✓ Mon Full body A"/m);
  assert.equal(m.calls.length, 0);
});

test("a day tapped on This week: its focus and length, one Save; the row and the week change", async () => {
  const { store, byHandle } = await freshYui();
  const arnold = await byHandle("arnold");
  const m = noModel();
  tap(store, arnold.id, "edit-day", "choose", { choice: "Thu" });
  await runAgent(store, arnold.id, { provider, fetch: m.fetch, now: () => MON });
  const ops = lines(lastReply(store, arnold.id).body);
  assert.equal(ops[0].id, "day-thu");
  assert.equal(ops[0].props.title, "Thursday");
  assert.match(ops.find((o: any) => o.id === "focus").props.body, /^Now: Rest/);

  tap(store, arnold.id, "day-thu", "plan", { plan: { focus: "Legs", minutes: 45 } });
  await runAgent(store, arnold.id, { provider, fetch: m.fetch, now: () => MON });
  const t = (await store.tables(arnold.id)).tables;
  assert.deepEqual(t.this_week.rows.thu, { Day: "Thu", Focus: "Legs", Workout: "Squat 3x8, Romanian deadlift 3x10, reverse lunge 3x8 each, glute bridge 3x12", Minutes: 45 });
  const body = lastReply(store, arnold.id).body;
  assert.match(body, /^Thursday is Legs now\./);
  assert.match(fence(body), /"Wed Full body B" "Thu Legs" "Fri Full body A"/);
  assert.match(fence(body), /stat@week-done "0 of 6"/);

  // Their own words keep the focus; the model fills in the moves later.
  tap(store, arnold.id, "day-sat", "plan", { plan: { focus: "Swim" } });
  await runAgent(store, arnold.id, { provider, fetch: m.fetch, now: () => MON });
  assert.match(lastReply(store, arnold.id).body, /^Saturday is Swim now\. Tell me what goes in it and I'll fill it in\./);
  assert.equal((await store.tables(arnold.id)).tables.this_week.rows.sat.Minutes, 45, "the length stays when they don't move it");
  assert.equal(m.calls.length, 0);
});

test("a rest day offers the next session; Yes runs it today, dated today", async () => {
  const { store, byHandle } = await freshYui();
  const arnold = await byHandle("arnold");
  const m = noModel();
  store.say(arnold.id, "start workout");
  await runAgent(store, arnold.id, { provider, fetch: m.fetch, now: () => THU });
  const body = lastReply(store, arnold.id).body;
  assert.match(body, /^Rest day today\./);
  assert.equal(lines(body)[0].id, "anyway-fri");
  tap(store, arnold.id, "anyway-fri", "ask", { answer: "Yes, let's go" });
  await runAgent(store, arnold.id, { provider, fetch: m.fetch, now: () => THU });
  assert.equal(lines(lastReply(store, arnold.id).body).find((o: any) => o.preset === "plan").id, "wk-20261001-fri");
  tap(store, arnold.id, "anyway-fri", "ask", { answer: "Rest today" });
  await runAgent(store, arnold.id, { provider, fetch: m.fetch, now: () => THU });
  assert.equal(lastReply(store, arnold.id).body, "Rest it is. See you next session.");
  assert.equal(m.calls.length, 0);
});

test("the Start button on Today opens the runner; with no split it asks for one", async () => {
  const { store, byHandle } = await freshYui();
  const arnold = await byHandle("arnold");
  tap(store, arnold.id, "today", "card", { cta: "Start" });
  await runAgent(store, arnold.id, { provider, fetch: noModel().fetch, now: () => MON });
  assert.ok(lines(lastReply(store, arnold.id).body).find((o: any) => o.id === "wk-20260928-mon"));
  const t = await store.tables(arnold.id);
  delete t.tables.this_week;
  await store.saveTables(arnold, { tables: [], rows: [], dropRows: [], dropTables: ["this_week"] } as any, t);
  store.say(arnold.id, "Start today's workout");
  await runAgent(store, arnold.id, { provider, fetch: noModel().fetch, now: () => MON });
  assert.match(lastReply(store, arnold.id).body, /cta="Build my split"/);
});

test("Progress: a streak of weeks, the best set, a chart per main lift (three at most)", () => {
  const clk = clock(NEXT_MON, "UTC");
  const rows: Record<string, any> = {};
  const add = (day: string, ex: string, lb: number, reps = 5) => (rows[`${day}-${ex}`] = { Day: day, Exercise: ex, Sets: 3, Reps: reps, Weight: lb });
  add("2026-09-21", "Squat", 135); add("2026-09-28", "Squat", 145); add("2026-10-05", "Squat", 150);
  add("2026-09-28", "Bench", 115); add("2026-10-05", "Bench", 120, 6);
  add("2026-10-05", "Row", 60); add("2026-10-05", "Curl", 25);
  const store = { tables: { workouts: { name: "workouts", cols: [], rows, order: Object.keys(rows), next: 1 } } };
  assert.equal(streak(store as any, clk), 3);
  assert.deepEqual(bestSet(store as any), { exercise: "Squat", lb: 150, reps: 5, day: "2026-10-05" });
  assert.deepEqual(mainLifts(store as any).map((l) => l.name), ["Squat", "Bench", "Row"]);
  const screen = progressScreen(store as any, clk);
  assert.equal(screen.length, 5);
  assert.equal(screen[2], 'chart@lift-squat line "Squat, top set" x="Sep 21"|"Sep 28"|"Oct 5" y=135|145|150 unit=lb');
  assert.deepEqual(parse(">4\n" + screen.join("\n"), {}).filter((o: any) => o.op === "error"), []);
  // A gap week breaks the streak; this week with nothing yet still counts last week's run.
  assert.equal(streak(store as any, clock(Date.parse("2026-10-07T12:00:00Z"), "UTC")), 3);
  assert.equal(streak(store as any, clock(Date.parse("2026-10-20T12:00:00Z"), "UTC")), 0);
});
