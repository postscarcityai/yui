// YUI-185: Penny's tools. Plan my week by voice, the today list, reminders, the evening review and her default
// screens (Today, This week), all answered by the runtime from her tables with no model turn. Every test goes
// through runAgent on the store a person's rows go through (not a demo memory), every reply is read by the real
// Yui Lines parser, and a relaunch reads everything back from the saved data.
import { test } from "node:test";
import assert from "node:assert/strict";
import { runAgent } from "../src/turn.ts";
import { LocalStore } from "../src/store.ts";
import { clock, fromSeeds } from "../src/tables.ts";
import { homeLines } from "../src/home.ts";
import { crew } from "../src/profiles.ts";
import { PACE_OPTS, REMIND_OPTS, applyFirst, firstLines, planAsks, readDump, readTask, todayScreen, weekScreen } from "../src/planner.ts";
import { fakeModel, freshYui, provider } from "./helpers.ts";
// @ts-ignore: the parser the app and the site share, as the MCP server ships it
import { parse } from "../../supabase/functions/yui-mcp/yl.mjs";

const MON = Date.parse("2026-09-28T16:00:00Z"); // Monday, noon in New York
const now = () => MON;
const clk = clock(MON, "America/New_York");
const noModel = () => fakeModel(() => {
  throw new Error("no model call expected");
});
const agentRows = (store: any, id: string) => store.data.rows.filter((r: any) => r.agent_id === id && r.sender === "agent");
const lastReply = (store: any, id: string) => agentRows(store, id).at(-1);
const fence = (body: string) => body.match(/```yui\n([\s\S]*?)\n```/)![1];
const turnsUsed = (store: any) => Object.values(store.data.users?.u1?.turns ?? {}).reduce((a: number, b: any) => a + b, 0);
const words = (body: string) => body.replace(/```yui[\s\S]*$/, "").trim();

/** The ids a home leaves on its pages, as the app hands them to the parser. */
function homeIds(): Record<string, string> {
  const ops = parse(homeLines(crew().penny.home!).join("\n"), {});
  return Object.fromEntries(ops.filter((o: any) => o.op === "add" && o.id && !/^n\d+$/.test(o.id)).map((o: any) => [o.id, o.preset]));
}
const idsOf = (ops: any[]) => Object.fromEntries(ops.filter((o: any) => o.op === "add" && o.id && !/^n\d+$/.test(o.id)).map((o: any) => [o.id, o.preset]));

/** The ids that last on her pages after every reply so far but the newest, as the app keeps them. */
function pageIds(store: any, agentId: string): Record<string, string> {
  let known = homeIds();
  for (const r of agentRows(store, agentId).slice(0, -1)) {
    const f = r.body.match(/```yui\n([\s\S]*?)\n```/);
    if (!f) continue;
    const ops = parse(f[1], known);
    if (ops.some((o: any) => o.op === "add" && o.screen === "3" && o.preset === "timeline")) {
      known = Object.fromEntries(Object.entries(known).filter(([k]) => !/^wk-|^start$/.test(k)));
    }
    known = { ...known, ...Object.fromEntries(ops.filter((o: any) => o.op === "add" && o.id && o.screen && o.screen !== "1" && !/^n\d+$/.test(o.id)).map((o: any) => [o.id, o.preset])) };
  }
  return known;
}

/** Parses a reply's lines as the app would, with lasting ids known; fails on any error line. */
function lines(body: string, known: Record<string, string> = homeIds()) {
  const ops = parse(fence(body), known);
  const bad = ops.filter((o: any) => o.op === "error" || o.error);
  assert.deepEqual(bad, [], `parses clean:\n${fence(body)}`);
  return ops;
}

/** An event row as the app sends it: the line, and {id, preset, value} in its meta. */
function tap(store: any, agentId: string, id: string, preset: string, value: Record<string, unknown>) {
  const rowId = store.say(agentId, `[yui] ${id} ${preset}`, "event");
  store.data.rows.find((r: any) => r.id === rowId)!.meta = { id, preset, value };
  return rowId;
}

async function pennyYui() {
  const y = await freshYui();
  y.store.data.timezones = { u1: "America/New_York" };
  const penny = await y.byHandle("penny");
  return { ...y, penny };
}
async function run(store: any, id: string, m = noModel()) {
  await runAgent(store, id, { provider, fetch: m.fetch, now });
  assert.equal(m.calls.length, 0, "no model turn");
  return lastReply(store, id);
}
const taskRows = async (store: any, id: string) => {
  const t = (await store.tables(id)).tables.tasks;
  return t.order.map((k: string) => ({ key: k, ...t.rows[k] }));
};

const DUMP = "I need to call the dentist Tuesday at 9. Groceries, and then finish the report by Friday. "
  + "Pick up the dry cleaning, book a haircut, pay the water bill, it's urgent. Gym at 6pm tomorrow";
const PLAN = { dump: DUMP, busy: ["Wednesday"], pace: "2 or 3", remind: "10 minutes before" };

async function planned() {
  const y = await pennyYui();
  tap(y.store, y.penny.id, "weekplan", "plan", { plan: PLAN });
  const reply = await run(y.store, y.penny.id);
  return { ...y, reply };
}

test("Penny's home draws exactly what her tools draw from her starter tables: Today and This week", () => {
  const home = homeLines(crew().penny.home!);
  const s = fromSeeds(crew().penny.tables);
  const pages = home.slice(home.indexOf(">2"));
  assert.deepEqual(pages, [">2", ...todayScreen(s, clk), "save today", ">3", ...weekScreen(s, clk), "save this week"]);
  assert.deepEqual(home.filter((l) => l.startsWith("menu")).map((l) => l.match(/"([^"]+)"/)![1]).reverse(),
                   ["Plan my week", "Add a to-do", "What's next?", "Evening review"]);
  const ops = parse(home.join("\n"), {});
  assert.deepEqual(ops.filter((o: any) => o.op === "error"), []);
  assert.equal(idsOf(ops)["next-task"], "card", "the next task, big on Today");
  assert.equal(idsOf(ops).week, "timeline");
});

test("Plan my week: the words open one full-screen flow, how it works first, the brain dump by mic, the questions last, one Send", async () => {
  const { store, penny } = await pennyYui();
  store.say(penny.id, "Plan my week");
  const ops = lines((await run(store, penny.id)).body);
  const plan = ops.find((o: any) => o.preset === "plan");
  assert.equal(plan.id, "weekplan");
  assert.equal(plan.props.submit, "Plan my week");
  assert.ok(!plan.props.inline, "full screen");
  const steps = ops.filter((o: any) => o.in === "weekplan");
  assert.equal(steps[0].preset, "page", "what it does first");
  assert.match(steps[0].props.body, /Talk it out/);
  assert.equal(steps[1].preset, "mic", "the brain dump by voice");
  assert.equal(steps[1].id, "dump");
  assert.deepEqual(steps.slice(2).map((o: any) => o.id), ["busy", "pace", "remind"], "the questions last; nothing to carry yet");
  assert.deepEqual(steps.find((o: any) => o.id === "busy").props.options, ["Today", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]);
  assert.deepEqual(steps.find((o: any) => o.id === "pace").props.options, PACE_OPTS);
  assert.deepEqual(steps.find((o: any) => o.id === "remind").props.options, REMIND_OPTS);
  for (const w of ["plan my week", "Can you plan out my week?", "help me plan the week", "Let's sort my week."]) {
    assert.equal(planAsks([{ id: "x", sender: "user", kind: "text", body: w, meta: {}, created_at: "" } as any]).asks[0]?.kind, "plan", w);
  }
  for (const w of ["plan my week around the conference and the kids", "what should I plan for dinner?"]) {
    assert.equal(planAsks([{ id: "x", sender: "user", kind: "text", body: w, meta: {}, created_at: "" } as any]).asks.length, 0, w);
  }
});

test("a brain dump reads as tasks: the day and time they said, fillers off, urgent is high", () => {
  const said = readDump(DUMP, clk);
  assert.deepEqual(said.map((s) => s.task), ["Call the dentist", "Groceries", "Finish the report", "Pick up the dry cleaning", "Book a haircut", "Pay the water bill", "Gym"]);
  assert.deepEqual(said[0], { task: "Call the dentist", day: "2026-09-29", time: "09:00" });
  assert.equal(said[2].day, "2026-10-02", "by Friday");
  assert.equal(said[5].priority, "High");
  assert.deepEqual([said[6].day, said[6].time], ["2026-09-29", "18:00"]);
  assert.equal(readTask("dinner with Sam tonight at 7:30", clk)!.time, "19:30");
  assert.equal(readTask("dinner with Sam tonight at 7:30", clk)!.day, "2026-09-28");
  assert.equal(readTask("standup at noon", clk)!.time, "12:00");
  assert.equal(readTask("run for 30 minutes", clk)!.time, undefined, "a length is not a time");
  assert.equal(readTask("um", clk), null);
  assert.deepEqual(readDump("that's it, thanks", clk), []);
});

test("the Send sorts the dump into days, keeps full days clear and the pace, sets reminders and lands as This week", async () => {
  const { store, penny, reply } = await planned();
  const rows = await taskRows(store, penny.id);
  const by = Object.fromEntries(rows.map((r: any) => [r.Task, r]));
  assert.equal(by["Tell Penny what's on your mind this week"].Done, true, "her starter to-do is done: she heard");
  assert.deepEqual([by["Call the dentist"].Due, by["Call the dentist"].Time], ["2026-09-29", "09:00"]);
  assert.equal(by["Finish the report"].Due, "2026-10-02");
  assert.equal(by["Pay the water bill"].Priority, "High");
  const loose = ["Groceries", "Pick up the dry cleaning", "Book a haircut", "Pay the water bill"].map((t) => by[t].Due);
  assert.ok(!loose.includes("2026-09-30"), "Wednesday is full: nothing sorted onto it");
  const perDay: Record<string, number> = {};
  for (const r of rows.filter((r: any) => r.Done !== true)) perDay[r.Due] = (perDay[r.Due] ?? 0) + 1;
  assert.ok(Object.values(perDay).every((n) => n <= 3), `2 or 3 a day: ${JSON.stringify(perDay)}`);
  assert.equal(by["Pay the water bill"].Due, "2026-09-28", "the urgent one goes first, today");
  // Tuesday: the dentist at 9 comes before the gym at 6.
  assert.ok(by["Call the dentist"].Order < by.Gym.Order);

  const t = await store.tables(penny.id);
  assert.deepEqual(t.tables.week_prefs.rows.last, { Busy: "Wednesday", Pace: "2 or 3", Carry: "Bring them in", Remind: "10 minutes before", Planned: "2026-09-28" });
  const rem = t.tables.reminders;
  assert.deepEqual(rem.order.map((k: string) => rem.rows[k].At).sort(), ["2026-09-29T08:50", "2026-09-29T17:50"]);
  assert.deepEqual(reply.meta.native.reminders.map((r: any) => r.text), ["Call the dentist, 9:00 am", "Gym, 6:00 pm"], "the app gets them to schedule");

  assert.match(words(reply.body), /^Your week is planned: 7 things over \d days\. Drag to reorder on This week\. The 2 timed ones get a reminder\. First up: pay the water bill\.$/);
  const ops = lines(reply.body, pageIds(store, penny.id));
  const f = fence(reply.body);
  assert.match(f, /^~next-task "Pay the water bill"/m, "Today is a patch: the next task, big");
  assert.match(f, />3 clear\n>3\ntimeline@week "This week" mark=Today fold=12 \+reorder/, "This week drawn again: new rows");
  const week = ops.filter((o: any) => o.in === ops.find((x: any) => x.preset === "timeline").id);
  assert.equal(week.filter((o: any) => o.preset === "next").length, 7);
  assert.equal(week.find((o: any) => o.id === "wk-call-the-dentist").props.at, "Tomorrow");
  assert.equal(week.find((o: any) => o.id === "wk-call-the-dentist").props.sub, "9:00 am");
  assert.ok(!week.some((o: any) => o.id === "wk-t1"), "her starter to-do leaves the week once they plan");
});

test("Today: the next task big with Done, a tick on the list is quiet and patches, What's next is answered from the table", async () => {
  const { store, penny } = await planned();
  store.say(penny.id, "What's next today?");
  let r = await run(store, penny.id);
  assert.match(words(r.body), /^Next: Pay the water bill\. Then /);
  assert.doesNotMatch(fence(r.body), />\d/, "patches only");

  const today = (await taskRows(store, penny.id)).filter((x: any) => x.Due === "2026-09-28" && x.Done !== true);
  tap(store, penny.id, "today", "list", { item: "Pay the water bill", checked: true });
  r = await run(store, penny.id);
  assert.equal(words(r.body), "", "a tick says nothing");
  assert.doesNotMatch(fence(r.body), /^>/m, "patches only: a quiet reply that never moves them");
  lines(r.body, pageIds(store, penny.id));
  assert.equal((await taskRows(store, penny.id)).find((x: any) => x.key === "pay-the-water-bill").Done, true);
  assert.match(fence(r.body), new RegExp(`^~next-task ${JSON.stringify(today.find((x: any) => x.Task !== "Pay the water bill").Task)}`, "m"));

  tap(store, penny.id, "next-task", "card", { cta: "Done" });
  r = await run(store, penny.id);
  assert.match(words(r.body), /^Done: /);
  for (const w of ["what's next?", "What is next today?", "what do I have today?"]) {
    assert.equal(planAsks([{ id: "x", sender: "user", kind: "text", body: w, meta: {}, created_at: "" } as any]).asks[0]?.kind, "next", w);
  }
});

test("Add a to-do: words with a time set a reminder; the empty shortcut opens a form with a mic", async () => {
  const { store, penny } = await pennyYui();
  store.say(penny.id, "Add a to-do: call mom tomorrow at 5");
  let r = await run(store, penny.id);
  assert.equal(words(r.body), "Added call mom for tomorrow at 5:00 pm. I'll remind you.");
  assert.deepEqual(r.meta.native.reminders, [{ key: "call-mom", text: "Call mom, 5:00 pm", at: "2026-09-29T16:50" }]);
  lines(r.body, pageIds(store, penny.id));
  store.say(penny.id, "Add a to-do: ");
  r = await run(store, penny.id);
  assert.match(fence(r.body), /^form@todo-add "Add a to-do" task:voice! submit=Add$/);
  tap(store, penny.id, "todo-add", "form", { form: { task: "water the plants" } });
  r = await run(store, penny.id);
  assert.equal(words(r.body), "Added water the plants for today.");
  assert.equal(r.meta.native.reminders, undefined, "no time, no reminder change");
  store.say(penny.id, "put renew passport on my list");
  r = await run(store, penny.id);
  assert.match(words(r.body), /^Added renew passport for today/);
});

test("Edit order on This week: a task dragged up takes that place's day; its reminder follows", async () => {
  const { store, penny } = await planned();
  const before = await taskRows(store, penny.id);
  const queue = weekScreen((await store.tables(penny.id)), clk).filter((l) => l.startsWith("next@")).map((l) => l.match(/key=(\S+)/)![1]);
  // The gym (Tuesday evening) dragged to the very top: it takes today's first place.
  const order = ["gym", ...queue.filter((k) => k !== "gym")];
  tap(store, penny.id, "week", "timeline", { order });
  const r = await run(store, penny.id);
  const after = await taskRows(store, penny.id);
  assert.equal(after.find((x: any) => x.key === "gym").Due, "2026-09-28");
  assert.equal(after.find((x: any) => x.key === "gym").Order, 1);
  assert.match(words(r.body), /^Moved gym to today/);
  assert.ok(r.meta.native.reminders.some((x: any) => x.key === "gym" && x.at === "2026-09-28T17:50"), "the reminder moved with it");
  assert.equal(before.length, after.length);
  lines(r.body, pageIds(store, penny.id));
  // This week is drawn again in the saved order (YUI-185b), so another device reads the same week.
  assert.match(r.body, />3 clear\n>3\ntimeline@week "This week"/, "This week drawn again, not patched");
  const drawn = r.body.split("\n").filter((l: string) => l.startsWith("next@")).map((l: string) => l.match(/key=(\S+)/)![1]);
  assert.deepEqual(drawn, order, "the rows in the saved order");
  assert.ok(!/^~wk-/m.test(r.body), "no row patches");
});

test("Move a task: a card opens a short plan, which one then which day, one Send", async () => {
  const { store, penny } = await planned();
  tap(store, penny.id, "week-move", "card", { cta: "Move a task" });
  let r = await run(store, penny.id);
  const ops = lines(r.body, pageIds(store, penny.id));
  assert.equal(ops[0].id, "move");
  assert.deepEqual(ops.filter((o: any) => o.in === "move").map((o: any) => o.id), ["task", "day"]);
  const pick = ops.find((o: any) => o.id === "task").props.options.find((x: string) => x.startsWith("Book a haircut"));
  tap(store, penny.id, "move", "plan", { plan: { task: pick, day: "Saturday" } });
  r = await run(store, penny.id);
  assert.equal(words(r.body), "Book a haircut is on Saturday now.");
  assert.equal((await taskRows(store, penny.id)).find((x: any) => x.key === "book-a-haircut").Due, "2026-10-03");
});

test("Evening review: what got done first, each open task done / tomorrow / drop, one Send; the day is kept", async () => {
  const { store, penny } = await planned();
  tap(store, penny.id, "today", "list", { item: "Pay the water bill", checked: true });
  await run(store, penny.id);
  store.say(penny.id, "Evening review");
  let r = await run(store, penny.id);
  const ops = lines(r.body, pageIds(store, penny.id));
  assert.equal(ops[0].id, "review");
  assert.equal(ops[0].props.submit, "Wrap up the day");
  const steps = ops.filter((o: any) => o.in === "review");
  assert.equal(steps[0].preset, "page");
  assert.equal(steps[0].props.title, "1 done today");
  const open = steps.filter((o: any) => /^r-/.test(o.id));
  assert.ok(open.length >= 1);
  assert.deepEqual(open[0].props.options, ["Done", "Tomorrow", "Drop"]);
  assert.equal(steps.at(-1).id, "feel", "how it went, last");
  const answers: Record<string, string> = { feel: "Okay" };
  const [a, b] = open;
  answers[a.id] = "Tomorrow";
  if (b) answers[b.id] = "Drop";
  tap(store, penny.id, "review", "plan", { plan: answers });
  r = await run(store, penny.id);
  assert.match(words(r.body), /^Day wrapped: 1 to tomorrow( and 1 dropped)?\. First up tomorrow: /);
  lines(r.body, pageIds(store, penny.id));
  const rows = await taskRows(store, penny.id);
  assert.equal(rows.find((x: any) => x.key === a.id.slice(2)).Due, "2026-09-29");
  if (b) assert.equal(rows.find((x: any) => x.key === b.id.slice(2)).Status, "Dropped", "dropped stays in the table, off the lists");
  const rev = (await store.tables(penny.id)).tables.reviews.rows["2026-09-28"];
  assert.deepEqual(rev, { Day: "2026-09-28", Done: 1, Moved: 1, Dropped: b ? 1 : 0, Felt: "Okay" });
  for (const w of ["review my day", "wrap up the day", "let's do my evening review"]) {
    assert.equal(planAsks([{ id: "x", sender: "user", kind: "text", body: w, meta: {}, created_at: "" } as any]).asks[0]?.kind, "review", w);
  }
});

test("kill and relaunch: the week, the reminders and the page shape live in the store, and a new process picks them up", async () => {
  const { store, penny } = await planned();
  const again = new LocalStore(JSON.parse(JSON.stringify(store.data)), { guide: "GUIDE", freeTurns: 100 });
  again.say(penny.id, "What's next today?");
  const r = await run(again, penny.id);
  assert.match(words(r.body), /^Next: Pay the water bill\./, "the week came through the relaunch");
  tap(again, penny.id, "today", "list", { item: "Pay the water bill", checked: true });
  const t = await run(again, penny.id);
  assert.doesNotMatch(fence(t.body), /^>\d clear/m, "patched, not drawn again: the shape was kept");
  // Switching away and back five times: every agent is still there, Penny's rows still hers.
  for (let i = 0; i < 5; i++) {
    for (const h of ["arnold", "penny"]) assert.ok((await again.agents("u1")).some((a) => a.profile.handle === h));
  }
  assert.equal((await taskRows(again, penny.id)).find((x: any) => x.key === "pay-the-water-bill").Done, true);
});

test("a Penny from before YUI-185 gets her new tables and task columns once, keeps her own rows, and her pages are drawn once", async () => {
  const { store, penny } = await pennyYui();
  const t = store.data.tables![penny.id] ?? (await store.tables(penny.id));
  store.data.tables = { ...(store.data.tables ?? {}), [penny.id]: t };
  // Her tables as they were: tasks with four columns, no reminders, reviews or week_prefs.
  t.tables = { ...fromSeeds(crew().penny.tables).tables };
  for (const n of ["reminders", "reviews", "week_prefs"]) delete t.tables[n];
  t.tables.tasks.cols = [{ name: "Task", type: "text" }, { name: "Due", type: "date" }, { name: "Priority", type: "text" }, { name: "Done", type: "bool" }];
  t.tables.tasks.rows = { t1: { Task: "Renew passport", Due: "2026-09-28", Priority: "High" } };
  t.tables.tasks.order = ["t1"];
  const agent = (await store.agent(penny.id))!;
  agent.profile = { ...agent.profile, home: agent.profile.home!.replace(/card@next-task[^\n]*\n/, ""), seeded: true };
  await store.updateAgent(penny.id, agent.profile);
  store.say(penny.id, "What's next today?");
  const r = await run(store, penny.id);
  assert.equal(words(r.body), "Next: Renew passport. That's the last one today.");
  const f = fence(r.body);
  assert.match(f, /^>2 clear\n>2\ncard@next-task "Renew passport"/m, "both pages drawn once");
  assert.match(f, />3 clear\n>3\n/);
  lines(r.body, {});
  const after = (await store.tables(penny.id)).tables;
  assert.deepEqual(after.tasks.cols.map((c: any) => c.name), ["Task", "Due", "Time", "Priority", "Done", "Status", "Order"]);
  assert.ok(after.reminders && after.reviews && after.week_prefs);
  store.say(penny.id, "What's next?");
  assert.doesNotMatch(fence((await run(store, penny.id)).body), /clear/, "then patches");
});

test("a model turn that writes a task with a time gets its reminder and patches her pages", async () => {
  const { store, penny } = await pennyYui();
  const m = fakeModel(() => "On it.\n```yui\nput tasks call-vet Task=\"Call the vet\" Due=2026-09-29 Time=10:30 Done=false Status=Open\n```");
  store.say(penny.id, "remind me to call the vet tomorrow morning around 10:30, they open late");
  await runAgent(store, penny.id, { provider, fetch: m.fetch, now });
  assert.equal(m.calls.length, 1);
  const r = lastReply(store, penny.id);
  assert.deepEqual(r.meta.native.reminders, [{ key: "call-vet", text: "Call the vet, 10:30 am", at: "2026-09-29T10:20" }]);
  assert.match(r.body, /timeline@week|~wk-/, "This week follows");
  assert.equal((await store.tables(penny.id)).tables.reminders.rows["call-vet"].At, "2026-09-29T10:20");
});

// ---------- YUI-223: Penny's first routine ----------

const FIRSTW = { busy: ["Wed", "Fri"], plan: "Monday morning", remind: "The night before" };
const dueOf = (rows: any[], day: string) => rows.filter((r) => r.Due === day && r.Status !== "Done");

test("first.yui carries the intake: one plan, three questions, Not sure and Skip on each; matches firstLines", async () => {
  const { readFileSync } = await import("node:fs");
  const first = readFileSync(new URL("../profiles/penny/first.yui", import.meta.url), "utf8");
  assert.equal(fence(first), firstLines().join("\n"), "first.yui and firstLines drifted");
  const qs = parse(fence(first), {}).filter((o: any) => o.op === "add" && o.in === "first");
  assert.deepEqual(qs.map((o: any) => o.id), ["busy", "plan", "remind"], "the saved first-week flow's ids");
  for (const o of qs) assert.ok(o.props.options.includes("Not sure") && o.props.options.includes("Skip"), `${o.id} has Not sure and Skip`);
});

test("the planning slot lands on the day and time picked", () => {
  const cases: [string, string, string, string][] = [
    ["Sunday night", "routine-plan-week", "2026-10-04", "19:00"],
    ["Monday morning", "routine-plan-week", "2026-10-05", "08:00"], // Monday noon: this morning has gone, so next Monday
  ];
  for (const [plan, key, day, time] of cases) {
    const r = applyFirst(fromSeeds(crew().penny.tables), { busy: ["None"], plan, remind: "At the time" }, clk);
    const row = r.store.tables.tasks.rows[key];
    assert.equal(row.Due, day, plan);
    assert.equal(row.Time, time, plan);
    assert.equal(row.Task, "Plan your week");
  }
  const night = applyFirst(fromSeeds(crew().penny.tables), { plan: "Each night" }, clk);
  const days = Object.entries(night.store.tables.tasks.rows).filter(([k]) => k.startsWith("routine-plan-")).map(([, r]: any) => r.Due);
  assert.deepEqual(days, weekDaysOf(clk), "a daily slot on each of the next seven days");
});
const weekDaysOf = (c: typeof clk) => Array.from({ length: 7 }, (_, i) => shiftDay(c.today, i));
const shiftDay = (d: string, n: number) => new Date(Date.parse(`${d}T00:00:00Z`) + n * 86400000).toISOString().slice(0, 10);

test("a busy day never gets more than one item placed on it, then or on a plan after", async () => {
  const { store, penny } = await pennyYui();
  tap(store, penny.id, "first", "plan", { plan: { busy: ["Tue", "Wed", "Thu"], plan: "Each morning", remind: "None" } });
  await run(store, penny.id);
  let rows = await taskRows(store, penny.id);
  for (const day of ["2026-09-29", "2026-09-30", "2026-10-01"]) assert.ok(dueOf(rows, day).length <= 1, `${day} holds ${dueOf(rows, day).length}`);
  // A brain dump with no days in it: the busy days the routine kept stay light.
  tap(store, penny.id, "weekplan", "plan", { plan: { dump: "Groceries. Call the bank. Fix the fence. Email the landlord. Book the dentist. Wash the car. Clean the garage", pace: "As many as fit", remind: "At the time" } });
  await run(store, penny.id);
  rows = await taskRows(store, penny.id);
  for (const day of ["2026-09-29", "2026-09-30", "2026-10-01"]) assert.ok(dueOf(rows, day).length <= 1, `${day} holds ${dueOf(rows, day).length} after a dump`);
  assert.equal(rows.filter((r: any) => !r.key.startsWith("routine-") && r.Due).length, 7, "the dump still got placed");
});

test("Skip on everything, and nothing at all, still build a routine: Sunday evening, no busy days, a morning nudge", async () => {
  for (const a of [{ busy: ["Skip"], plan: "Skip", remind: "Skip" }, { busy: ["Not sure"], plan: "Not sure", remind: "Not sure" }, {}]) {
    const { store, penny } = await pennyYui();
    tap(store, penny.id, "first", "plan", { plan: a });
    const r = await run(store, penny.id);
    const t = await store.tables(penny.id);
    const slot = t.tables.tasks.rows["routine-plan-week"];
    assert.equal(slot.Due, "2026-10-04");
    assert.equal(slot.Time, "19:00");
    assert.equal(t.tables.routine.rows.week.Busy, "None");
    assert.equal(t.tables.week_prefs.rows.last.Remind, "A morning nudge");
    const rem = Object.values(t.tables.reminders.rows) as any[];
    assert.ok(rem.length >= 1 && rem.every((x) => x.At.endsWith("T08:00") || x.At > "2026-09-28"), "a reminder is set");
    assert.equal(rem.find((x) => x.Task === "Plan your week").At, "2026-10-04T08:00", "one nudge that morning");
    assert.match(r.body, /^Your routine is set\. Planning is Sunday at 7:00 pm\./);
  }
});

test("the first Send answers with the routine and ends on a card to tap; no model turn, no turn used; all parses", async () => {
  const { store, penny } = await pennyYui();
  tap(store, penny.id, "first", "plan", { plan: FIRSTW });
  const r = await run(store, penny.id);
  assert.match(r.body, /^Your routine is set\. Planning is Monday at 8:00 am\. Wed and Fri stay light\. Reminders go the night before\./);
  assert.ok(!/\?/.test(r.body.split("\n```yui")[0]), "no question on top");
  const ops = lines(r.body);
  assert.ok(ops.some((o: any) => o.preset === "card" && o.id === "first-start" && o.props.cta === "Add a to-do"), "a card to tap");
  assert.equal(turnsUsed(store), 0);
  const t = await store.tables(penny.id);
  assert.equal(t.tables.routine.rows.week.Busy, "Wednesday, Friday");
  assert.equal(t.tables.tasks.rows["routine-plan-week"].Due, "2026-10-05");
  // The reminder for the plan slot goes the evening before, and the app is told.
  assert.equal(t.tables.reminders.rows["routine-plan-week"].At, "2026-10-04T20:00");
  assert.ok((r.meta as any).native.reminders.some((x: any) => x.key === "routine-plan-week"));
  // The tap on the card opens the add form.
  tap(store, penny.id, "first-start", "card", { cta: "Add a to-do" });
  assert.match((await run(store, penny.id)).body, /form@todo-add/);
});

test("the {flow} event of the saved first-week flow builds the same routine", async () => {
  const { store, penny } = await pennyYui();
  const id = store.say(penny.id, "[yui] firstweek flow", "event");
  store.data.rows.find((r: any) => r.id === id)!.meta = { id: "firstweek", preset: "flow", value: { flow: FIRSTW, path: ["busy", "plan", "remind"] } };
  const r = await run(store, penny.id);
  assert.match(r.body, /^Your routine is set\. Planning is Monday at 8:00 am/);
  assert.equal((await store.tables(penny.id)).tables.routine.rows.week.When, "Monday morning");
});
