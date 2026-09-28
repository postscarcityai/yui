// YUI-170: every native agent keeps its own little database (tables.ts), from the store up to a whole turn.
import { test } from "node:test";
import assert from "node:assert/strict";
import { applyTables, clock, diff, draw, emptyStore, parseSeeds, query, queryLine, write, writeLine } from "../src/tables.ts";
import { answerControl } from "../src/controls.ts";
import { runAgent } from "../src/turn.ts";
import { crew } from "../src/profiles.ts";
import { LocalStore } from "../src/store.ts";
import { fakeModel, freshYui, lastUser, provider, system, USER } from "./helpers.ts";

const CTX = { today: "2026-09-27", now: "2026-09-27T12:30" };
const ids = () => { let n = 0; return () => `id${n++}`; };

function store(lines: string[]) {
  let s = emptyStore();
  for (const l of lines) {
    const op = writeLine(l);
    assert.ok(op && !("error" in op), l);
    const r = write(s, op as any, CTX);
    assert.equal(r.error, undefined, `${l}: ${r.error}`);
    s = r.store;
  }
  return s;
}

test("the store: create, upsert by key, append without one, all or nothing", () => {
  let s = store(["table create meals Day:date Food:text Cal:number:kcal", "put meals Day=today Food=\"Chicken bowl\" Cal=640",
                 "put meals Day=today-1 Food=Oats Cal=300", "put meals oats Food=Oats", "put meals oats Cal=310"]);
  const t = s.tables.meals;
  assert.deepEqual(t.order, ["r1", "r2", "oats"]);
  assert.deepEqual(t.rows.r1, { Day: "2026-09-27", Food: "Chicken bowl", Cal: 640 });
  assert.deepEqual(t.rows.oats, { Food: "Oats", Cal: 310 });
  const bad = write(s, writeLine("put meals Cal=lots") as any, CTX);
  assert.match(bad.error!, /not a number/);
  assert.equal(bad.store, s);
  assert.match(write(s, writeLine("put meals Nope=1") as any, CTX).error!, /no column/);
  // The same table create again changes nothing; a new column keeps every row.
  assert.equal(write(s, writeLine("table create meals Day:date Food:text Cal:number:kcal") as any).store, s);
  s = write(s, writeLine("table create meals Day:date Food:text Cal:number:kcal Protein:number:g") as any).store;
  assert.equal(s.tables.meals.order.length, 3);
  // Keys are loose with case, as a model writes them.
  s = write(s, writeLine("put meals OATS Protein=10") as any, CTX).store;
  assert.equal(s.tables.meals.rows.oats.Protein, 10);
});

test("query: where, sort, totals by day and by week", () => {
  const s = store(["table create lifts Day:date Lift:text Weight:number:lb Reps:number",
    "put lifts Day=2026-09-14 Lift=Bench Weight=135 Reps=8", "put lifts Day=2026-09-16 Lift=Bench Weight=140 Reps=8",
    "put lifts Day=2026-09-21 Lift=Bench Weight=145 Reps=6", "put lifts Day=2026-09-27 Lift=Squat Weight=225 Reps=5"]);
  const bench = query(s, queryLine("query lifts where=Lift=bench sort=-Weight")!, CTX);
  assert.deepEqual(bench.rows!.map((r) => r[2]), [145, 140, 135]);
  const weeks = query(s, queryLine("query lifts where=Lift=Bench group=Day:week max=Weight +count")!, CTX);
  assert.deepEqual(weeks.cols!.map((c) => c.name), ["Week", "Weight", "Count"]);
  assert.deepEqual(weeks.rows, [["2026-09-14", 140, 2], ["2026-09-21", 145, 1]]);
  const recent = query(s, queryLine("query lifts where=Day>=today-6")!, CTX);
  assert.equal(recent.count, 2);
  assert.match(query(s, { table: "lifts", group: "Lift:week" }, CTX).error!, /date column/);
});

test("views draw with presets the app already has, real rows and no query words", () => {
  const s = store(["table create groceries Item:text Qty:text Got:bool", "put groceries milk Item=Milk Qty=\"1 gallon\"",
                   "put groceries eggs Item=Eggs Qty=12 +Got"]);
  assert.deepEqual(draw(s, queryLine("query groceries where=Got=off as list \"Still to get\"")!, CTX), ['list title="Still to get" "Milk · 1 gallon"']);
  assert.equal(draw(s, queryLine("query groceries")!, CTX)[0], 'table name="Groceries" Item|Qty|Got "Milk|1 gallon|" "Eggs|12|yes"');
  const m = store(["table create meals Day:date Cal:number:kcal", "put meals Day=2026-09-26 Cal=1900", "put meals Day=2026-09-27 Cal=2100"]);
  assert.equal(draw(m, queryLine("query meals group=Day sum=Cal as chart bar \"Calories\"")!, CTX)[0],
    'chart bar "Calories" x=2026-09-26|2026-09-27 y=1900|2100 unit=kcal');
  assert.equal(draw(m, queryLine("query meals as stat y=Cal label=\"Today\" good=down")!, CTX)[0],
    'stat 2100kcal "Today" delta=200 spark=1900|2100 good=down');
  assert.match(draw(m, queryLine("query nope")!, CTX)[0], /^card "Nope" body="No table called nope yet."/);
});

test("an answer: writes land, lines leave the screen, a delete waits for a tap", () => {
  const s = store(["table create groceries Item:text Got:bool", "put groceries milk Item=Milk", "put groceries eggs Item=Eggs"]);
  const a = applyTables('Added.\n```yui\nput groceries bread Item=Bread\nput groceries eggs +delete\nquery groceries as list\n```', s, CTX, ids());
  assert.deepEqual(a.store.tables.groceries.order, ["milk", "eggs", "bread"]); // the delete is held
  assert.equal(a.held!.lines[0], "put groceries eggs +delete");
  assert.match(a.text, /^Added\.\n```yui\nlist title="Groceries" "Milk" "Eggs" "Bread"\nchoose@del-id0 "Delete Eggs from groceries\?" Delete\|Keep\n```$/);
  assert.doesNotMatch(a.text, /\bput |query /);
  const bad = applyTables("```yui\nput groceries Nope=1\nsay Hi\n```", s, CTX, ids());
  assert.equal(bad.problems.length, 1);
  assert.equal(bad.store, s);
});

test("seeds: every starter ships its tables; blank ships none; seeds use no date words", () => {
  const c = crew();
  const names = (b: string) => (c[b].tables ?? []).map((t) => t.name);
  assert.deepEqual(names("yui"), ["todos", "groceries", "notes"]);
  assert.deepEqual(names("basil"), ["foods", "meals", "recipes", "goal", "meal_plan", "plan_prefs", "groceries"]);
  assert.deepEqual(names("arnold"), ["exercises", "this_week", "workouts"]);
  assert.deepEqual(names("penny"), ["tasks", "errands", "bills"]);
  assert.deepEqual(names("quill"), ["decks", "review"]);
  assert.deepEqual(names("gouda"), ["loops", "songs", "practice", "sessions", "studio"]);
  assert.equal(c.blank.tables, undefined);
  assert.ok(c.basil.tables![0].rows.length >= 40);
  assert.ok(c.arnold.tables![0].rows.every((r) => String(r.values.Cue).length > 30), "every exercise has a how-to cue");
  assert.throws(() => parseSeeds("x", "table create t Day:date\nput t Day=today"), /no today or now/);
  assert.throws(() => parseSeeds("x", "table create t A:text\nput t k +delete"), /no deletes/);
});

test("a new crew starts with its tables; the saved profile never carries them", async () => {
  const { store, byHandle } = await freshYui();
  const basil = await byHandle("basil");
  assert.equal(basil.profile.tables, undefined);
  assert.equal(basil.profile.seeded, true);
  const t = await store.tables(basil.id);
  assert.ok(t.tables.foods.order.length >= 40);
  assert.equal(t.tables.meals.order.length, 0);
  assert.deepEqual(Object.keys((await store.tables((await byHandle("yui")).id)).tables), ["todos", "groceries", "notes"]);
});

test("a whole turn: add milk to my groceries, and the answer shows the list", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const m = fakeModel(() => "Added milk.\n```yui\nput groceries milk Item=Milk Qty=\"2 gallons\" Aisle=Dairy\nput groceries oat-milk Item=\"Oat milk\" Aisle=Dairy\nquery groceries where=Got=off sort=Aisle as list \"Still to get\"\n```");
  store.say(yui.id, "add oat milk to my groceries, and make the milk 2 gallons");
  await runAgent(store, yui.id, { provider, fetch: m.fetch, newId: ids() });
  assert.match(system(m.calls[0]), /## Your tables\n- todos \(3 rows\)/);
  assert.match(system(m.calls[0]), /### Your tables/);
  const g = (await store.tables(yui.id)).tables.groceries;
  assert.equal(g.rows.milk.Qty, "2 gallons");
  assert.equal(g.order[g.order.length - 1], "oat-milk");
  const reply = store.data.rows.filter((r) => r.agent_id === yui.id && r.sender === "agent").pop()!;
  assert.match(reply.body, /^Added milk\.\n```yui\nlist title="Still to get" "Bread · 1 loaf · Bakery" .*"Milk · 2 gallons · Dairy" "Oat milk · Dairy"/);
  assert.doesNotMatch(reply.body, /\bput |\bquery /);
});

test("what did I eat this week: the agent reads its table, then answers on a screen", async () => {
  const { store, byHandle } = await freshYui();
  const basil = await byHandle("basil");
  const t0 = await store.tables(basil.id);
  const today = clock(Date.now(), "UTC").today;
  let s = t0;
  for (const l of [`put meals Day=${today} Meal=Lunch Food="Chicken bowl" Cal=640 Protein=52`, `put meals Day=${today} Meal=Dinner Food=Pasta Cal=700 Protein=25`]) {
    s = write(s, writeLine(l) as any).store;
  }
  await store.saveTables(basil, diff(t0, s), s);
  let n = 0;
  const m = fakeModel(() => (n++ === 0
    ? "```tables\nquery meals where=Day>=today-6 group=Day sum=Cal|Protein\n```"
    : "1340 kcal today, 77 g protein.\n```yui\nquery meals where=Day>=today-6 group=Day sum=Cal|Protein as table \"This week\"\n```"));
  store.say(basil.id, "what did I eat this week?");
  await runAgent(store, basil.id, { provider, fetch: m.fetch });
  assert.equal(m.calls.length, 2);
  assert.match(String(lastUser(m.calls[1]).content), new RegExp(`Your tables:[\\s\\S]*${today} \\| 1340 \\| 77`));
  const reply = store.data.rows.filter((r) => r.agent_id === basil.id && r.sender === "agent").pop()!;
  assert.match(reply.body, new RegExp(`table name="This week" Day\\|Cal\\|Protein "${today}\\|1340\\|77" units=\\|kcal\\|g`));
});

test("deletes ask first: Keep keeps it, Delete deletes it", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  let n = 0;
  const m = fakeModel(() => (n++ === 0 ? "Sure.\n```yui\nput groceries coffee +delete\n```" : "Done.\n```yui\nquery groceries as list\n```"));
  store.say(yui.id, "take coffee off my groceries");
  await runAgent(store, yui.id, { provider, fetch: m.fetch, newId: ids() });
  let reply = store.data.rows.filter((r) => r.agent_id === yui.id && r.sender === "agent").pop()!;
  assert.match(reply.body, /choose@del-id\d+ "Delete Coffee from groceries\?" Delete\|Keep/);
  const id = reply.body.match(/choose@(del-\w+)/)![1];
  assert.ok((await store.tables(yui.id)).tables.groceries.rows.coffee, "nothing is deleted before the tap");
  store.say(yui.id, `[yui] ${id} choose choice=Keep`, "event");
  await runAgent(store, yui.id, { provider, fetch: m.fetch, newId: ids() });
  assert.ok((await store.tables(yui.id)).tables.groceries.rows.coffee);
  assert.match(String(lastUser(m.calls[1]).content), /They kept it/);
  store.say(yui.id, `[yui] ${id} choose choice=Delete`, "event");
  await runAgent(store, yui.id, { provider, fetch: m.fetch, newId: ids() });
  assert.equal((await store.tables(yui.id)).tables.groceries.rows.coffee, undefined);
  assert.match(String(lastUser(m.calls[2]).content), /Deleted, as they asked/);
  reply = store.data.rows.filter((r) => r.agent_id === yui.id && r.sender === "agent").pop()!;
  assert.doesNotMatch(reply.body, /Coffee/);
});

test("make me a table for my reading list; a write with no view still shows it", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const m = fakeModel(() => "```yui\ntable create reading Title:text Author:text Done:bool\nput reading dune Title=Dune Author=\"Frank Herbert\"\n```");
  store.say(yui.id, "make me a table for my reading list, start with Dune");
  await runAgent(store, yui.id, { provider, fetch: m.fetch });
  const reply = store.data.rows.filter((r) => r.agent_id === yui.id && r.sender === "agent").pop()!;
  assert.equal(reply.body, 'Saved.\n```yui\ntable name="Reading" Title|Author|Done "Dune|Frank Herbert|"\n```');
});

test("log today's bench: Arnold's session lands with today's date in the person's zone", async () => {
  const { store, byHandle } = await freshYui();
  const arnold = await byHandle("arnold");
  store.data.timezones = { [USER]: "Pacific/Kiritimati" }; // UTC+14: never UTC's date late in the UTC day
  const m = fakeModel(() => "Logged.\n```yui\nput workouts Day=today Exercise=\"Bench press\" Sets=3 Reps=8 Weight=135\nquery workouts where=Exercise~bench sort=-Day limit=5\n```");
  store.say(arnold.id, "log today's bench: 3x8 at 135");
  await runAgent(store, arnold.id, { provider, fetch: m.fetch });
  const s = (await store.tables(arnold.id)).tables.workouts;
  assert.equal(s.rows.r1.Day, clock(Date.now(), "Pacific/Kiritimati").today);
});

test("an agent from before tables gets its starter tables once, on its next turn", async () => {
  const store = new LocalStore({}, { guide: "G" });
  const { tables: _t, ...old } = crew().penny;
  const penny = await store.createAgent(USER, old); // no seeds, no `seeded`, like a crew made before YUI-170
  assert.deepEqual((await store.tables(penny.id)).tables, {});
  const m = fakeModel(() => "Hi.\n```yui\nsay Hi\n```");
  store.say(penny.id, "hi");
  await runAgent(store, penny.id, { provider, fetch: m.fetch });
  assert.deepEqual(Object.keys((await store.tables(penny.id)).tables), ["tasks", "errands", "bills"]);
  assert.equal((await store.agent(penny.id))!.profile.seeded, true);
  await store.saveTables(penny, diff((await store.tables(penny.id)), emptyStore()), emptyStore()); // they deleted them all
  store.say(penny.id, "hi again");
  await runAgent(store, penny.id, { provider, fetch: m.fetch });
  assert.deepEqual((await store.tables(penny.id)).tables, {}, "never seeded twice");
});

test("controls: the agent's tables with row counts, read one, delete one with a confirm", async () => {
  const { store, byHandle } = await freshYui();
  const basil = await byHandle("basil");
  const ask = async (req: Record<string, unknown>) => {
    const id = store.say(basil.id, "controls", "control");
    store.data.rows.find((r: any) => r.id === id)!.meta = { v: 1, req: "c-1", ...req };
    await answerControl(store, id);
    return store.data.rows.filter((r: any) => r.kind === "control" && r.sender === "agent").pop()!.meta;
  };
  const list = await ask({ op: "list", section: "tables" });
  assert.deepEqual(list.items.map((i: any) => [i.id, i.sub]), [["foods", "44 rows"], ["meals", "0 rows"], ["recipes", "38 rows"], ["goal", "1 row"],
                                                               ["meal_plan", "0 rows"], ["plan_prefs", "0 rows"], ["groceries", "6 rows"]]);
  const got = await ask({ op: "get", section: "tables", id: "foods" });
  assert.match(got.item.text, /Chicken breast, cooked \| 100 g \| 165 \| 31/);
  assert.equal((await ask({ op: "delete", section: "tables", id: "meals", rev: got.rev })).error, "confirm");
  const meals = await ask({ op: "get", section: "tables", id: "meals" });
  assert.equal((await ask({ op: "delete", section: "tables", id: "meals", rev: meals.rev, confirmed: true })).ok, true);
  assert.deepEqual(Object.keys((await store.tables(basil.id)).tables), ["foods", "recipes", "goal", "meal_plan", "plan_prefs", "groceries"]);
  assert.equal((await ask({ op: "put", section: "tables", id: "foods", rev: got.rev, value: {} })).error, "not_allowed");
});

test("table words outside a yui block still land, and never reach the phone as text", () => {
  const s = store(["table create sessions Day:date Exercise:text Sets:number"]);
  const a = applyTables('```\nput sessions Day=today Exercise="Bench press" Sets=3\n```\nBench logged.', s, CTX, ids());
  assert.equal(a.store.tables.sessions.order.length, 1);
  assert.equal(a.text, "Bench logged.");
  const b = applyTables('Logged.\nput sessions Day=today Exercise=Squat Sets=5\n```yui\nquery sessions as list\n```', s, CTX, ids());
  assert.equal(b.store.tables.sessions.order.length, 1);
  assert.equal(b.text, 'Logged.\n```yui\nlist title="Sessions" "2026-09-27 · Squat · Sets 5"\n```');
  const c = applyTables("Here's code:\n```\nconst x = 1;\n```", s, CTX, ids());
  assert.equal(c.text, "Here's code:\n```\nconst x = 1;\n```", "other fences are left alone");
});

test("a write with words but no screen gets the table under the words", async () => {
  const { store, byHandle } = await freshYui();
  const arnold = await byHandle("arnold");
  const m = fakeModel(() => "```\nput workouts Day=2026-09-27 Exercise=\"Bench press\" Sets=3 Reps=8 Weight=135\n```\nBench logged. 3x8 at 135.");
  store.say(arnold.id, "log today's bench");
  await runAgent(store, arnold.id, { provider, fetch: m.fetch });
  const reply = store.data.rows.filter((r) => r.agent_id === arnold.id && r.sender === "agent").pop()!;
  assert.equal(reply.body, 'Bench logged. 3x8 at 135.\n```yui\ntable name="Workouts" Day|Session|Exercise|Sets|Reps|Seconds|Weight|Minutes|Feel|Source "2026-09-27||Bench press|3|8||135|||" units=||||||lb|||\n```');
});

test("a held delete never reads as done", () => {
  const s = store(["table create groceries Item:text", "put groceries coffee Item=Coffee"]);
  const a = applyTables("Gone.\n```yui\nput groceries coffee +delete\nquery groceries as list\n```", s, CTX, ids());
  assert.equal(a.text, 'Tap Delete to confirm.\n```yui\nlist title="Groceries" "Coffee"\nchoose@del-id0 "Delete Coffee from groceries?" Delete|Keep\n```');
  const b = applyTables("Tap Delete to take coffee off.\n```yui\nput groceries coffee +delete\n```", s, CTX, ids());
  assert.match(b.text, /^Tap Delete to take coffee off\./);
});

test("a list labels its numbers; a table header with spaces is mended", async () => {
  const m = store(["table create meals Day:date Food:text Cal:number:kcal Protein:number:g", "put meals Day=2026-09-27 Food=Oats Cal=300 Protein=10"]);
  assert.equal(draw(m, queryLine("query meals as list")!, CTX)[0], 'list title="Meals" "2026-09-27 · Oats · Cal 300 kcal · Protein 10 g"');
  const { unsprawl } = await import("../src/turn.ts");
  assert.equal(unsprawl('Hi.\n```yui\ntable name="Week" Day|Cal (kcal)|Protein (g)|Meal type "Fri|300|10|Lunch"\n```'),
    'Hi.\n```yui\ntable name="Week" Day|Cal|Protein|Meal-type "Fri|300|10|Lunch" units=|kcal|g|\n```');
});
