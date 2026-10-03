// YUI-183: Basil's tools. Plan my meals, a swap, the grocery list by aisle, Today against the goal and a meal fixed
// from it, all answered by the runtime from his tables with no model turn. Every test goes through runAgent on the
// store a person's rows go through (not a demo memory), and every reply is read by the real Yui Lines parser.
import { test } from "node:test";
import assert from "node:assert/strict";
import { runAgent, runJob, runScheduled } from "../src/turn.ts";
import { LocalStore } from "../src/store.ts";
import { clock, fromSeeds } from "../src/tables.ts";
import { homeLines } from "../src/home.ts";
import { crew } from "../src/profiles.ts";
import { AVOID_OPTS, BUDGET_OPTS, COOK_OPTS, MEALS_OPTS, readFirstPrefs, addQty, aisleOf, allowed, itemKey, groceryScreen, calorieDays, mealAsks, planWeek, readItems, readPrefs,
         recipes, screenLines, todayScreen, trendScreen, weekScreen } from "../src/mealplan.ts";
import { fakeModel, freshYui, provider } from "./helpers.ts";
// @ts-ignore: the parser the app and the site share, as the MCP server ships it
import { parse } from "../../supabase/functions/yui-mcp/yl.mjs";

const MON = Date.parse("2026-09-28T16:00:00Z"); // noon in New York
const now = () => MON;
const noModel = () => fakeModel(() => {
  throw new Error("no model call expected");
});
const agentRows = (store: any, id: string) => store.data.rows.filter((r: any) => r.agent_id === id && r.sender === "agent");
const lastReply = (store: any, id: string) => agentRows(store, id).at(-1);
const fence = (body: string) => body.match(/```yui\n([\s\S]*?)\n```/)![1];

/** The ids a home leaves on its pages, as the app hands them to the parser. */
function homeIds(): Record<string, string> {
  const ops = parse(homeLines(crew().basil.home!).join("\n"), {});
  return Object.fromEntries(ops.filter((o: any) => o.op === "add" && o.id && !/^n\d+$/.test(o.id)).map((o: any) => [o.id, o.preset]));
}

/** Parses a reply's lines as the app would, with lasting ids known; fails on any error line. */
function lines(body: string, known: Record<string, string> = homeIds()) {
  const ops = parse(fence(body), known);
  const bad = ops.filter((o: any) => o.op === "error" || o.error);
  assert.deepEqual(bad, [], `parses clean:\n${fence(body)}`);
  return ops;
}
const idsOf = (ops: any[]) => Object.fromEntries(ops.filter((o: any) => o.op === "add" && o.id && !/^n\d+$/.test(o.id)).map((o: any) => [o.id, o.preset]));

/** An event row as the app sends it: the line, and {id, preset, value} in its meta. */
function tap(store: any, agentId: string, id: string, preset: string, value: Record<string, unknown>) {
  const rowId = store.say(agentId, `[yui] ${id} ${preset}`, "event");
  store.data.rows.find((r: any) => r.id === rowId)!.meta = { id, preset, value };
  return rowId;
}

async function basilYui() {
  const y = await freshYui();
  y.store.data.timezones = { u1: "America/New_York" };
  const basil = await y.byHandle("basil");
  return { ...y, basil };
}

const PLAN = { days: "5 days", meals: "3 meals", likes: ["Chicken", "Mexican"], avoid: ["Nuts", "Dairy"], budget: "In between", cook: "30 minutes" };

async function planned() {
  const y = await basilYui();
  const m = noModel();
  tap(y.store, y.basil.id, "mealplan", "plan", { plan: PLAN });
  await runAgent(y.store, y.basil.id, { provider, fetch: m.fetch, now });
  return { ...y, m };
}

test("Basil's home draws exactly what his tools draw from his starter tables: Today, This week's meals, Groceries", () => {
  const home = homeLines(crew().basil.home!);
  const s = fromSeeds(crew().basil.tables);
  const clk = clock(MON, "UTC");
  const pages = home.slice(home.indexOf(">2"));
  assert.deepEqual(pages.slice(0, pages.indexOf(">5")), [">2", ...todayScreen(s, clk), "save today", ">3", ...weekScreen(s, clk), "save this week",
                           ">4", ...groceryScreen(s), "save groceries"]);
  // The trend page ships empty: the same ids as the runtime draws, its day labels filled on the first log.
  const trend = pages.slice(pages.indexOf(">5"));
  assert.deepEqual(trend.map((l) => l.split(" ")[0]), [">5", ...trendScreen(s, clk).map((l) => l.split(" ")[0]), "save"]);
  assert.deepEqual(home.filter((l) => l.startsWith("menu")).map((l) => l.match(/"([^"]+)"/)![1]), ["Grocery list", "This week", "Log a meal", "Plan my meals"]);
  const ops = parse(home.join("\n"), {});
  assert.deepEqual(ops.filter((o: any) => o.op === "error"), []);
});

test("Plan my meals: the shortcut's words open one full-screen flow, what it aims for first, the questions last, one Send", async () => {
  const { store, basil } = await basilYui();
  const m = noModel();
  store.say(basil.id, "Plan my meals");
  await runAgent(store, basil.id, { provider, fetch: m.fetch, now });
  assert.equal(m.calls.length, 0, "no model turn");
  const ops = lines(lastReply(store, basil.id).body);
  const plan = ops.find((o: any) => o.preset === "plan");
  assert.equal(plan.id, "mealplan");
  assert.equal(plan.props.submit, "Plan my week");
  const steps = ops.filter((o: any) => o.in === "mealplan");
  assert.equal(steps[0].preset, "page", "what it aims for first");
  assert.match(steps[0].props.body, /2,100 kcal and 140 g protein/);
  assert.deepEqual(steps.slice(1).map((o: any) => o.id), ["days", "meals", "likes", "avoid", "budget", "cook"], "the questions last");
  assert.ok(steps.slice(1).every((o: any) => ["choose", "pick"].includes(o.preset)));
  for (const words of ["plan my meals for the week", "Make me a meal plan", "Plan my meals this week."]) {
    assert.equal(mealAsks([{ id: "x", sender: "user", kind: "text", body: words, meta: {}, created_at: "" } as any]).asks[0]?.kind, "plan", words);
  }
  assert.equal(mealAsks([{ id: "x", sender: "user", kind: "text", body: "what should I eat tonight?", meta: {}, created_at: "" } as any]).asks.length, 0);
  // Words that point back at the plan are the model's to read, never an item called "the goods" (YUI-188).
  const ask = (body: string) => mealAsks([{ id: "x", sender: "user", kind: "text", body, meta: {}, created_at: "" } as any]).asks[0];
  for (const words of ["Put the goods on my grocery list.", "add those to my groceries", "put all of that on the shopping list", "Add them to my grocery list please"]) {
    assert.equal(ask(words), undefined, words);
  }
  assert.equal((ask("put the oat milk on my grocery list") as any)?.words, "the oat milk");
});

test("the Send writes a week to meal_plan, keeps the answers, fills the grocery list by aisle and lands as a deck of swaps", async () => {
  const { store, basil, m } = await planned();
  assert.equal(m.calls.length, 0);
  const t = await store.tables(basil.id);
  const rows = t.tables.meal_plan.order.map((k: string) => t.tables.meal_plan.rows[k]);
  assert.equal(rows.length, 15, "5 days x 3 meals");
  assert.deepEqual([...new Set(rows.map((r: any) => r.Day))], ["2026-09-28", "2026-09-29", "2026-09-30", "2026-10-01", "2026-10-02"]);
  const byKey = Object.fromEntries(recipes(t).map((r) => [r.key, r]));
  for (const r of rows as any[]) {
    const tags = byKey[r.Recipe].tags;
    assert.ok(!tags.includes("dairy") && !tags.includes("nuts"), `${r.Name} holds a no-go`);
    assert.ok(byKey[r.Recipe].minutes <= 30, `${r.Name} takes too long`);
  }
  for (const day of new Set(rows.map((r: any) => r.Day))) {
    const names = rows.filter((r: any) => r.Day === day).map((r: any) => r.Recipe);
    assert.equal(new Set(names).size, names.length, "nothing twice in a day");
  }
  const counts: Record<string, number> = {};
  for (const r of rows as any[]) counts[r.Recipe] = (counts[r.Recipe] ?? 0) + 1;
  assert.ok(Object.values(counts).every((n) => n <= 2), "nothing more than twice a week");
  assert.ok(rows.filter((r: any) => /chicken|burrito|mexican/i.test(r.Name + byKey[r.Recipe].tags.join(","))).length >= 4, "the likes pull");
  assert.equal(t.tables.plan_prefs.rows.last.Avoid, "Nuts, Dairy");

  const g = t.tables.groceries;
  const plan = g.order.filter((k: string) => g.rows[k].From === "plan").map((k: string) => g.rows[k]);
  assert.ok(plan.length >= 8);
  assert.ok(plan.every((r: any) => r.Aisle && r.Got === false));
  assert.ok(!plan.some((r: any) => /cheddar|almond|peanut|yogurt/i.test(r.Item)), "no no-go shopping");
  assert.equal(g.rows["greek-yogurt"].From, "you", "what they had stays");

  const body = lastReply(store, basil.id).body;
  assert.match(body, /^Your 5 days are planned\. Tap any meal to swap it\./);
  const ops = lines(body);
  const deck = ops.find((o: any) => o.preset === "deck");
  assert.equal(deck.id, "week-deck");
  const pages = ops.filter((o: any) => o.in === "week-deck");
  assert.equal(pages[0].preset, "page");
  assert.equal(pages.length, 6, "a line, then a page a day");
  const mon = pages.find((o: any) => o.id === "swap-20260928");
  assert.equal(mon.preset, "choose");
  assert.equal(mon.props.title.split(",")[0], "Monday");
  assert.equal(mon.props.options.length, 3, "each meal a button");
  // The week and the grocery pages are drawn again (new days, new aisles); Today is a patch.
  const f = fence(body);
  assert.match(f, /\n>3 clear\n>3\nchoose@wk-20260928 /);
  assert.match(f, /\n>4 clear\n>4\nstat@groc-left "\d+ to get"/);
  assert.match(f, /\nlist@aisle-produce title="Produce" /);
  assert.match(f, /\n~next-meal "Up next: Lunch" /, "noon: lunch is next");
  assert.doesNotMatch(f, />2 clear/);
  assert.equal((await store.agents("u1")).find((a) => a.id === basil.id)!.profile.mealScreens?.startsWith("v1;20260928,"), true);
});

test("a tap on a meal swaps it: kept to the no-gos, the grocery list follows, the deck and the week patched", async () => {
  const { store, basil } = await planned();
  const deckIds = idsOf(parse(fence(lastReply(store, basil.id).body), homeIds()));
  const t0 = await store.tables(basil.id);
  const was = t0.tables.meal_plan.rows["2026-09-29-dinner"];
  const m = noModel();
  tap(store, basil.id, "wk-20260929", "choose", { choice: was.Name });
  await runAgent(store, basil.id, { provider, fetch: m.fetch, now });
  assert.equal(m.calls.length, 0);
  const t = await store.tables(basil.id);
  const now1 = t.tables.meal_plan.rows["2026-09-29-dinner"];
  assert.notEqual(now1.Recipe, was.Recipe);
  const r = recipes(t).find((x) => x.key === now1.Recipe)!;
  assert.ok(allowed(r, readPrefs(PLAN)));
  const day = ["breakfast", "lunch"].map((s) => t.tables.meal_plan.rows[`2026-09-29-${s}`].Recipe);
  assert.ok(!day.includes(now1.Recipe), "not already on that day");
  const body = lastReply(store, basil.id).body;
  assert.match(body, new RegExp(`^Dinner is ${now1.Name} now`));
  const ops = lines(body, { ...homeIds(), ...deckIds });
  const patched = ops.filter((o: any) => o.op === "patch").map((o: any) => o.target);
  assert.ok(patched.includes("swap-20260929") && patched.includes("wk-20260929"), "the deck's page and the week's card");
  assert.ok(patched.includes("groc-left"));
  assert.ok(!/>\d clear/.test(fence(body)), "nothing moves the person");
  // The list holds what the new dinner needs, and nothing only the old one did.
  const need = r.ingredients.map((i) => i.item.toLowerCase());
  const items = t.tables.groceries.order.map((k: string) => String(t.tables.groceries.rows[k].Item).toLowerCase());
  for (const n of need) assert.ok(items.includes(n), n);
});

test("the grocery list: a tick says nothing and the item leaves the list; words and the voice form add in the right aisle", async () => {
  const { store, basil } = await planned();
  const before = agentRows(store, basil.id).length;
  const t0 = await store.tables(basil.id);
  const produce = t0.tables.groceries.order.map((k: string) => t0.tables.groceries.rows[k]).find((r: any) => r.Aisle === "Produce" && r.From === "plan")!;
  const label = produce.Qty ? `${produce.Item}, ${produce.Qty}` : produce.Item;
  const m = noModel();
  const tick = tap(store, basil.id, "aisle-produce", "list", { item: label, checked: true });
  await runAgent(store, basil.id, { provider, fetch: m.fetch, now });
  assert.equal(agentRows(store, basil.id).length, before, "a tick says nothing");
  assert.ok(store.data.rows.find((r: any) => r.id === tick)!.handled_at);
  assert.equal((await store.tables(basil.id)).tables.groceries.rows[Object.keys(t0.tables.groceries.rows).find((k) => t0.tables.groceries.rows[k] === produce)!].Got, true);

  store.say(basil.id, "add oat milk, 2 avocados and tortillas to my groceries");
  await runAgent(store, basil.id, { provider, fetch: m.fetch, now });
  const g = (await store.tables(basil.id)).tables.groceries.rows;
  assert.deepEqual([g["oat-milk"].Aisle, g.avocado.Aisle, g.avocado.Qty, g.tortilla.Aisle, g["oat-milk"].From], ["Dairy and eggs", "Produce", "2", "Bakery", "you"]);
  const body = lastReply(store, basil.id).body;
  assert.match(body, /^Added oat milk, avocados and tortillas\./);
  const f = fence(body);
  assert.doesNotMatch(f, new RegExp(`"${label}"`), "the ticked item is off the list");
  assert.match(f, /"Oat milk(, [^"]+)?"/);
  lines(body, { ...homeIds(), ...idsOf(parse(fence(agentRows(store, basil.id).at(-2).body), homeIds())) });

  // The card's Add button opens a form with a mic; its Send adds what they said.
  tap(store, basil.id, "groc-add", "card", { cta: "Add to the list" });
  await runAgent(store, basil.id, { provider, fetch: m.fetch, now });
  assert.match(fence(lastReply(store, basil.id).body), /^form@groc-add "Add to your list" items:voice! submit=Add$/);
  tap(store, basil.id, "groc-add", "form", { form: { items: "coffee and bananas" } });
  await runAgent(store, basil.id, { provider, fetch: m.fetch, now });
  const g2 = (await store.tables(basil.id)).tables.groceries.rows;
  assert.deepEqual([g2.coffee.Aisle, g2.banana.Aisle], ["Pantry", "Produce"]);

  store.say(basil.id, "share my grocery list");
  await runAgent(store, basil.id, { provider, fetch: m.fetch, now });
  const text = lastReply(store, basil.id).body;
  assert.match(text, /^Grocery list\nProduce: /);
  assert.doesNotMatch(text, /```/, "plain words to copy");
  assert.equal(m.calls.length, 0);
});

test("Today: a meal logged patches calories and macros against the goal; I ate it logs the planned meal; a tap fixes one", async () => {
  const { store, basil } = await planned();
  // Snap and say: the job's breakdown carries Today's patches in the same reply.
  const est = { food: true, title: "Salmon bowl", sure: "Clear photo.", question: null,
                items: [{ food: "Salmon", portion: "1 fillet", cal: 310, protein: 33, carbs: 0, fat: 19 }, { food: "Rice", portion: "a cup", cal: 205, protein: 4, carbs: 45, fat: 0 }] };
  const vm = fakeModel(() => JSON.stringify(est));
  store.say(basil.id, "[yui] c1 camera photo=https://img.test/bowl.jpg", "event");
  const r = await runAgent(store, basil.id, { provider, fetch: vm.fetch, now });
  await runJob(store, r.jobs[0], { provider, fetch: vm.fetch, now });
  const bd = lastReply(store, basil.id).body;
  const f = fence(bd);
  assert.match(f, /\n~kcal 515kcal "Calories today" sub="of 2,100\. 1,585 to go\."/);
  assert.match(f, /\n~macros bar "Macros vs goal" x=Protein\|Carbs\|Fat y=37\|45\|19 y2=140\|210\|70/);
  assert.match(f, /\n~eaten "Tap a meal to fix it" "Lunch, 515 kcal"/);
  assert.match(f, /\n~next-meal "Up next: Dinner" /, "lunch is logged, dinner is next");
  assert.doesNotMatch(f, /^stat/m);
  lines(bd);

  const m = noModel();
  tap(store, basil.id, "next-meal", "card", { cta: "I ate it" });
  await runAgent(store, basil.id, { provider, fetch: m.fetch, now });
  const t = await store.tables(basil.id);
  const dinner = t.tables.meal_plan.rows["2026-09-28-dinner"];
  assert.equal(t.tables.meals.rows["plan-2026-09-28-dinner"].Cal, dinner.Cal);
  assert.match(lastReply(store, basil.id).body, new RegExp(`^Logged dinner: ${dinner.Name}`));
  assert.match(fence(lastReply(store, basil.id).body), /~next-meal "All planned meals logged"/);

  tap(store, basil.id, "eaten", "choose", { choice: "Lunch, 515 kcal" });
  await runAgent(store, basil.id, { provider, fetch: m.fetch, now });
  const fix = lines(lastReply(store, basil.id).body);
  const flow = fix.find((o: any) => o.preset === "plan");
  assert.equal(flow.id, "mfix-20260928-lunch");
  assert.deepEqual(fix.filter((o: any) => o.in === flow.id).map((o: any) => o.preset), ["page", "slide", "choose"], "read first, then the questions");

  tap(store, basil.id, "mfix-20260928-lunch", "plan", { plan: { portion: 50, keep: "Keep it" } });
  await runAgent(store, basil.id, { provider, fetch: m.fetch, now });
  assert.match(lastReply(store, basil.id).body, /^Lunch is 50% of what I had: 258 kcal now\./);
  const cal = (await store.tables(basil.id)).tables.meals;
  assert.equal(cal.order.filter((k: string) => cal.rows[k].Meal === "Lunch").reduce((a: number, k: string) => a + (cal.rows[k].Cal as number), 0), 258);

  tap(store, basil.id, "mfix-20260928-lunch", "plan", { plan: { portion: 100, keep: "Take it off" } });
  await runAgent(store, basil.id, { provider, fetch: m.fetch, now });
  const after = (await store.tables(basil.id)).tables.meals;
  assert.equal(after.order.filter((k: string) => after.rows[k].Meal === "Lunch").length, 0, "their tap takes it off");
  assert.match(fence(lastReply(store, basil.id).body), /~eaten "Tap a meal to fix it" "Dinner, [\d,]+ kcal"/);
  assert.equal(m.calls.length, 0);
});

test("kill and relaunch: the plan, the list and the page shapes live in the store, and a new process picks them up", async () => {
  const { store, basil } = await planned();
  const again = new LocalStore(JSON.parse(JSON.stringify(store.data)), { guide: "GUIDE", freeTurns: 100 });
  const m = noModel();
  const t = await again.tables(basil.id);
  const was = t.tables.meal_plan.rows["2026-09-30-lunch"];
  tap(again, basil.id, "swap-20260930", "choose", { choice: was.Name });
  await runAgent(again, basil.id, { provider, fetch: m.fetch, now });
  const body = lastReply(again, basil.id).body;
  assert.match(body, /^Lunch is .+ now/);
  assert.doesNotMatch(fence(body), />\d clear/, "the pages are patched, not drawn again: the shape was kept");
  assert.notEqual((await again.tables(basil.id)).tables.meal_plan.rows["2026-09-30-lunch"].Recipe, was.Recipe);
});

test("a Basil from before YUI-183 gets his recipes and goal once, keeps his own tables, and his pages are drawn again", async () => {
  const { store, basil } = await basilYui();
  // As he was: foods and meals only, the old home, a grocery list of his own.
  const t = store.data.tables![basil.id];
  for (const n of ["recipes", "goal", "meal_plan", "plan_prefs", "groceries"]) delete t.tables[n];
  const a = store.data.agents[basil.id];
  a.profile.home = 'menu shortcut@groceries "Grocery list" show=groceries\nmenu shortcut@log "Log a meal" say="Log a meal: "\n>2\nstat@kcal 0kcal "Calories today"\nsave today';
  const m = noModel();
  store.say(basil.id, "Plan my meals");
  await runAgent(store, basil.id, { provider, fetch: m.fetch, now });
  const t1 = await store.tables(basil.id);
  assert.equal(t1.tables.recipes.order.length, 38);
  assert.equal(t1.tables.goal.rows.daily.Cal, 2100);
  // His grocery list is a starter table he never had: it comes with its starter rows, once (YUI-188).
  assert.equal(t1.tables.groceries.order.length, 6);
  tap(store, basil.id, "mealplan", "plan", { plan: { days: "3 days", meals: "2 meals", avoid: ["Meat", "Fish"] } });
  await runAgent(store, basil.id, { provider, fetch: m.fetch, now });
  const f = fence(lastReply(store, basil.id).body);
  assert.match(f, /\n>2 clear\n>2\nstat@kcal /);
  assert.match(f, /\n>3 clear\n>3\n/);
  assert.match(f, /\n>4 clear\n>4\n/);
  const rows = Object.values((await store.tables(basil.id)).tables.meal_plan.rows) as any[];
  assert.equal(rows.length, 6);
  assert.deepEqual([...new Set(rows.map((r) => r.Slot))].sort(), ["Dinner", "Lunch"]);
  lines(lastReply(store, basil.id).body);
});

test("a model turn that writes his tables gets his pages patched under its answer", async () => {
  const { store, basil } = await basilYui();
  const m = fakeModel(() => "Goal set.\n```yui\nput goal daily Cal=1800 Protein=120\nput groceries lemons Item=Lemons Aisle=Produce\n```");
  store.say(basil.id, "my goal is 1800 calories and 120 g protein, and add lemons");
  await runAgent(store, basil.id, { provider, fetch: m.fetch, now });
  const body = lastReply(store, basil.id).body;
  const f = fence(body);
  assert.match(f, /~kcal 0kcal "Calories today" sub="of 1,800\. Log a meal to start\."/);
  assert.match(f, /~aisle-produce title="Produce" "Spinach"\|"Berries"\|"Lemons" \+check/);
  lines(body);
});

test("the planner never serves a no-go, whatever else they ask for", () => {
  const s = fromSeeds(crew().basil.tables);
  const clk = clock(MON, "UTC");
  const all = recipes(s);
  for (const avoid of AVOID_OPTS.slice(1)) {
    for (const budget of BUDGET_OPTS) {
      for (const cook of COOK_OPTS) {
        for (const meals of MEALS_OPTS) {
          const p = readPrefs({ days: "7 days", meals, avoid: [avoid, "mushrooms"], budget, cook, likes: ["Beef"] });
          const { planned } = planWeek(s, p, clk);
          for (const x of planned) assert.ok(allowed(x.recipe, p), `${avoid}: ${x.recipe.name}`);
          assert.ok(planned.length > 0, `${avoid}/${budget}/${cook}/${meals} plans something`);
        }
      }
    }
  }
  assert.ok(all.every((r) => r.ingredients.length && r.cal > 0 && r.minutes > 0), "every recipe is whole");
  assert.ok(all.every((r) => r.ingredients.every((i) => aisleOf(i.item) !== "Other")), "every ingredient has an aisle");
});

test("pieces: amounts add up, items read from words, aisles", () => {
  assert.equal(addQty(["1 cup", "1/2 cup"]), "1 1/2 cups");
  assert.equal(addQty(["1/2 can", "1/2 can", "1/2 can"]), "1 1/2 cans");
  assert.equal(addQty(["2", "1"]), "3");
  assert.equal(addQty(["1 tbsp", "2 tbsp", "1 tsp"]), "3 tbsp + 1 tsp");
  assert.equal(addQty(["1/3 lb", "1/3 lb", "1/3 lb"]), "1 lb");
  assert.deepEqual(readItems("oat milk, 2 avocados and the tortillas."), [{ item: "Oat milk" }, { item: "Avocados", qty: "2" }, { item: "Tortillas" }]);
  assert.deepEqual(["Peanut butter", "Butter", "Frozen peas", "Tuna", "Chicken thighs", "Pita", "Dish soap"].map(aisleOf),
                   ["Pantry", "Dairy and eggs", "Frozen", "Pantry", "Meat and fish", "Bakery", "Other"]);
  assert.deepEqual(["Avocados", "Avocado", "Berries", "Eggs", "Chicken thighs", "Hummus", "Swiss cheese", "Oats"].map(itemKey),
                   ["avocado", "avocado", "berry", "egg", "chicken-thigh", "hummu", "swiss-cheese", "oat"]);
  assert.deepEqual(readPrefs({}).slots, ["Breakfast", "Lunch", "Dinner"]);
  assert.deepEqual(readPrefs({ meals: "3 and a snack" }).slots, ["Breakfast", "Lunch", "Dinner", "Snack"]);
});

// YUI-183b: sending to a page brings it forward, so the page the ask is about is sent last.
test("a meal log on a stale shape ends on Today, a grocery add on Groceries, a plan on the week", () => {
  const store = fromSeeds(crew().basil.tables!);
  const clk = clock(MON, "America/New_York");
  const lastPage = (l: string[]) => l.filter((x) => /^>\d$/.test(x)).at(-1);
  assert.equal(lastPage(screenLines(store, clk, undefined, ["today"]).lines), ">2", "meal log, first redraw");
  assert.equal(lastPage(screenLines(store, clk, "v1;stale;stale;2026-09-28;t", ["today"]).lines), undefined, "meal log on a known shape moves nobody");
  assert.equal(lastPage(screenLines(store, clk, "v1;stale;stale;2026-09-28;t", ["today", "week", "groceries"]).lines), ">3", "plan on a changed shape");
  assert.equal(lastPage(screenLines(store, clk, undefined, ["groceries"]).lines), ">4");
  assert.equal(lastPage(screenLines(store, clk, undefined, ["today", "week", "groceries"]).lines), ">3");
});

// ---------- YUI-221: Basil's first plan ----------

const FIRST = { goal: "Build muscle", days: ["Mon", "Wed", "Fri"], meals: "2", avoid: ["Dairy", "Nuts", "mushrooms"], cook: "15 minutes" };

test("first.yui carries the intake: one plan, five questions, Not sure and Skip on each, the doctor line; matches firstLines", async () => {
  const { readFileSync } = await import("node:fs");
  const { firstLines } = await import("../src/mealplan.ts");
  const first = readFileSync(new URL("../profiles/basil/first.yui", import.meta.url), "utf8");
  assert.equal(fence(first), firstLines().join("\n"), "first.yui and firstLines drifted");
  assert.match(first, /Check with your doctor/);
  const ops = lines(`${first}`, {});
  assert.deepEqual(ops.filter((o: any) => o.op === "add" && o.in === "first").map((o: any) => o.id), ["goal", "days", "meals", "avoid", "cook"]);
  for (const o of ops.filter((o: any) => o.op === "add" && o.in === "first")) {
    assert.ok(o.props.options.includes("Not sure") && o.props.options.includes("Skip"), `${o.id} has Not sure and Skip`);
  }
  assert.ok(ops.find((o: any) => o.id === "avoid").props.other, "a condition or allergy can be typed");
});

test("readFirstPrefs: days are weekdays, meals a day and cook time read from the words; Not sure and Skip are the defaults", () => {
  const p = readFirstPrefs(FIRST);
  assert.deepEqual(p.weekdays!.sort(), [1, 3, 5]);
  assert.deepEqual(p.slots, ["Lunch", "Dinner"]);
  assert.deepEqual(p.avoid, ["Dairy", "Nuts", "mushrooms"]);
  assert.equal(p.cook, 15);
  for (const a of [{}, { goal: "Skip", days: ["Skip"], meals: "Skip", avoid: ["Skip"], cook: "Skip" }, { goal: "Not sure", days: ["Not sure"], meals: "Not sure", avoid: ["Not sure"], cook: "Not sure" }]) {
    const d = readFirstPrefs(a);
    assert.equal(d.weekdays, undefined);
    assert.equal(d.days, 7);
    assert.deepEqual(d.slots, ["Breakfast", "Lunch", "Dinner"]);
    assert.deepEqual(d.avoid, []);
    assert.equal(d.cook, 30);
  }
  assert.deepEqual(readFirstPrefs({ avoid: ["Nothing"], meals: "3 and a snack" }).slots, ["Breakfast", "Lunch", "Dinner", "Snack"]);
  assert.deepEqual(readFirstPrefs({ meals: "4 or more" }).slots, ["Breakfast", "Lunch", "Dinner", "Snack"]);
  assert.equal(readFirstPrefs({ cook: "An hour" }).cook, 60);
  assert.equal(readFirstPrefs({ cook: "I like a project" }).cook, 999);
});

test("the first Send builds only the chosen days and meals, leaves out the no-gos, keeps to the cook time, no model; answers saved", async () => {
  const { store, basil } = await basilYui();
  const m = noModel();
  tap(store, basil.id, "first", "plan", { plan: FIRST });
  await runAgent(store, basil.id, { provider, fetch: m.fetch, now });
  assert.equal(m.calls.length, 0, "no model turn");
  const t = await store.tables(basil.id);
  const rows = t.tables.meal_plan.order.map((k: string) => t.tables.meal_plan.rows[k]) as any[];
  // Monday 2026-09-28 is today: Mon, Wed, Fri of the next seven days, two meals each.
  assert.deepEqual([...new Set(rows.map((r) => r.Day))], ["2026-09-28", "2026-09-30", "2026-10-02"]);
  assert.equal(rows.length, 6, "3 days x 2 meals");
  assert.deepEqual([...new Set(rows.map((r) => r.Slot))].sort(), ["Dinner", "Lunch"]);
  const byKey = Object.fromEntries(recipes(t).map((r) => [r.key, r]));
  for (const r of rows) {
    const rec = byKey[r.Recipe];
    assert.ok(!rec.tags.includes("dairy") && !rec.tags.includes("nuts"), `${r.Name} holds a no-go`);
    assert.ok(!/mushroom/i.test(rec.name + rec.ingredients.map((i: any) => i.item).join(",")), `${r.Name} holds mushrooms`);
    // Nothing for dinner takes 15 minutes, and few lunches do once the no-gos are out: those ease to the next step up (30), never past it.
    assert.ok(rec.minutes <= 30, `${r.Name} takes ${rec.minutes} minutes`);
  }
  assert.equal(t.tables.first_meals.rows.avoid.Answer, "Dairy, Nuts, mushrooms");
  assert.equal(t.tables.first_meals.rows.days.Answer, "Mon, Wed, Fri");
  assert.equal(t.tables.first_meals.rows.goal.Answer, "Build muscle");
  assert.equal(t.tables.plan_prefs.rows.last.Meals, "2 meals");
  assert.equal(t.tables.plan_prefs.rows.last.Avoid, "Dairy, Nuts, mushrooms");
  assert.ok(Object.keys(t.tables.groceries.rows).length > 0, "the grocery list follows");
});

test("the first Send with Skip everywhere builds the defaults: every day, 3 meals, 30 minutes or less", async () => {
  const { store, basil } = await basilYui();
  tap(store, basil.id, "first", "plan", { plan: { goal: "Skip", days: ["Skip"], meals: "Skip", avoid: ["Skip"], cook: "Skip" } });
  await runAgent(store, basil.id, { provider, fetch: noModel().fetch, now });
  const t = await store.tables(basil.id);
  const rows = t.tables.meal_plan.order.map((k: string) => t.tables.meal_plan.rows[k]) as any[];
  assert.equal(new Set(rows.map((r) => r.Day)).size, 7);
  assert.equal(rows.length, 21);
  const byKey = Object.fromEntries(recipes(t).map((r) => [r.key, r]));
  assert.ok(rows.every((r) => byKey[r.Recipe].minutes <= 30));
  assert.equal(t.tables.first_meals.rows.cook.Answer, "Skip");
});

test("the reply lands on the week: one line on top, the pages after with the week last, no question, all parses", async () => {
  const { store, basil } = await basilYui();
  tap(store, basil.id, "first", "plan", { plan: FIRST });
  await runAgent(store, basil.id, { provider, fetch: noModel().fetch, now });
  const body = lastReply(store, basil.id).body;
  assert.match(body, /^Your week of meals is set: 3 days, 2 meals a day, nothing with dairy, nuts or mushrooms\. Tap any meal to swap it\.\n```yui/);
  assert.ok(!/\?/.test(body.split("\n```yui")[0]), "no question on top");
  const l = fence(body).split("\n");
  assert.ok(l.indexOf(">3") > l.indexOf(">4") || l.indexOf(">3") > l.indexOf(">2"), "the week is drawn after Today");
  const pages = l.filter((x) => /^>\d$/.test(x));
  assert.equal(pages.at(-1), ">3", "the week page is the last one sent, so it is the one in front");
  assert.ok(l.some((x) => /^choose@wk-20260928 /.test(x)) && l.some((x) => /^choose@wk-20260930 /.test(x)) && !l.some((x) => /^choose@wk-20260929 /.test(x)), "a card for each chosen day only");
  lines(body);
});

test("a swap after the first plan keeps to the no-gos and the cook time", async () => {
  const { store, basil } = await basilYui();
  tap(store, basil.id, "first", "plan", { plan: { ...FIRST, meals: "3" } });
  await runAgent(store, basil.id, { provider, fetch: noModel().fetch, now });
  const t = await store.tables(basil.id);
  const row = t.tables.meal_plan.rows["2026-09-28-dinner"];
  tap(store, basil.id, "wk-20260928", "choose", { choice: row.Name });
  await runAgent(store, basil.id, { provider, fetch: noModel().fetch, now });
  const after = await store.tables(basil.id);
  const now2 = after.tables.meal_plan.rows["2026-09-28-dinner"];
  assert.notEqual(now2.Name, row.Name);
  const rec = recipes(after).find((r) => r.key === now2.Recipe)!;
  assert.ok(!rec.tags.includes("dairy") && !rec.tags.includes("nuts"));
  assert.ok(rec.minutes <= 30, "dinner has nothing at 15: the next step up");
});

// ---------- t_7af94763: calories are by date ----------

const TUE = MON + 24 * 3600_000;

test("Today follows the date: a new day patches 0 kcal whatever the ask was about, and the day is kept in the shape", () => {
  const store = fromSeeds(crew().basil.tables!);
  const mon = clock(MON, "America/New_York");
  const tue = clock(TUE, "America/New_York");
  const logged = { ...store, tables: { ...store.tables, meals: { ...store.tables.meals, order: ["m1"], rows: { m1: { Day: mon.today, Meal: "Lunch", Food: "Bowl", Portion: "1", Cal: 390, Protein: 25, Carbs: 32, Fat: 18 } } } } };
  const a = screenLines(logged, mon, undefined, ["today"]);
  assert.match(a.lines.join("\n"), /stat@kcal 390kcal/);
  assert.match(a.shape, /;2026-09-28;t$/);
  const b = screenLines(logged, tue, a.shape, ["groceries"]);
  assert.match(b.lines.join("\n"), /~kcal 0kcal "Calories today" sub="of 2,100\. Log a meal to start\."/, "yesterday's 390 does not carry over");
  assert.match(b.lines.join("\n"), /~macros bar "Macros vs goal" x=Protein\|Carbs\|Fat y=0\|0\|0 /);
  assert.match(b.shape, /;2026-09-29;t$/);
  assert.equal(screenLines(logged, mon, a.shape, ["groceries"]).lines.some((l) => l.startsWith("~kcal")), false, "the same day patches nothing");
});

test("calories over time: the last 7 and 30 days by date, today last, the average of the days logged", () => {
  const store = fromSeeds(crew().basil.tables!);
  const tue = clock(TUE, "America/New_York");
  const rows: Record<string, any> = {};
  for (const [i, [day, cal]] of ([["2026-09-27", 1800], ["2026-09-28", 390], ["2026-08-31", 2000]] as [string, number][]).entries())
    rows[`m${i}`] = { Day: day, Meal: "Lunch", Food: "x", Portion: "1", Cal: cal, Protein: 0, Carbs: 0, Fat: 0 };
  const t = { ...store, tables: { ...store.tables, meals: { ...store.tables.meals, order: Object.keys(rows), rows } } };
  assert.deepEqual(calorieDays(t, tue, 7).map((d) => d.cal), [0, 0, 0, 0, 1800, 390, 0]);
  assert.equal(calorieDays(t, tue, 30)[0].day, "2026-08-31");
  assert.equal(calorieDays(t, tue, 30)[0].cal, 2000);
  const lines = trendScreen(t, tue);
  assert.match(lines[0], /^stat@trend-avg 1\,?397kcal "Daily average" sub="Over 3 logged days of the last 30\. Goal 2,100\."/);
  assert.match(lines[1], /^chart@trend-week bar .* x=Thu\|Fri\|Sat\|Sun\|Mon\|Tue\|Wed|x=/);
  assert.deepEqual(parse(lines.join("\n"), {}).filter((o: any) => o.op === "error"), []);
});

test("midnight: Basil's own check-in redraws Today for the new date with no model call and no push", async () => {
  const { store, basil } = await planned();
  const m = noModel();
  const est = { food: true, title: "Bowl", sure: "ok", question: null, items: [{ food: "Salmon", portion: "1", cal: 390, protein: 25, carbs: 32, fat: 18 }] };
  const vm = fakeModel(() => JSON.stringify(est));
  store.say(basil.id, "[yui] c1 camera photo=https://img.test/bowl.jpg", "event");
  const r = await runAgent(store, basil.id, { provider, fetch: vm.fetch, now });
  await runJob(store, r.jobs[0], { provider, fetch: vm.fetch, now });
  assert.match(fence(lastReply(store, basil.id).body), /~kcal 390kcal/);
  const sch = (await store.schedules(basil.id)).find((x: any) => x.note === "yui:new-day");
  assert.ok(sch, "the midnight check-in is set once");
  assert.deepEqual(sch.rule, { every: "day", at: "00:05" });
  assert.equal(sch.nextAt, "2026-09-29T04:05:00.000Z", "00:05 in New York");

  const out = await runScheduled(store, sch.id, { provider, fetch: m.fetch, now: () => TUE });
  assert.equal(m.calls.length, 0, "no model call");
  assert.deepEqual(out.replies, [], "no reply id handed to the push");
  const f = fence(lastReply(store, basil.id).body);
  assert.match(f, /\n?~kcal 0kcal "Calories today" sub="of 2,100\. Log a meal to start\."/);
  assert.match(f, /~eaten "Tap a meal to fix it" "Log a meal" body="Nothing logged yet today\."/);
  assert.match(f, /~trend-week bar/);
  assert.equal((await store.schedules(basil.id)).filter((x: any) => x.note === "yui:new-day").length, 1);
});
