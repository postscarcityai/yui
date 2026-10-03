// Copied from runtime/src/mealplan.ts by runtime/scripts/build.mjs. Do not edit here.
// Basil's tools (YUI-183): today's macros board, plan my meals, the grocery
// list, and his default screens (Today, This week's meals, Groceries), kept
// current with patches.
//
// Chris (Sep 28): "we should focus the next stories on getting the crew more
// tools up with detailed flows... i want the agents to have default screens."
//
// Every tool here is answered by the runtime itself, with no model turn and no
// free turn spent, because the data is already in Basil's tables:
//
// 1. Plan my meals: the shortcut, "Plan my meals" or the Plan button. One
//    full-screen `plan`: what the week will aim for first, then how many days,
//    meals a day, likes, no-gos, budget and time to cook, one Send. The Send
//    picks a week from `recipes` (the no-gos never bend; the rest ease off when
//    nothing fits), writes `meal_plan`, keeps the answers in `plan_prefs` and
//    lands as a deck: a page a day, each meal a button that swaps it.
// 2. The grocery list: the plan's ingredients added up by aisle (From=plan),
//    plus what they add in words or by voice (From=you). A tick sets Got and
//    says nothing; ticked items leave the list the next time it is drawn.
// 3. Today: calories and macros against `goal`, filled by every meal logged
//    (snap and say, YUI-103/166), the next planned meal with an I ate it
//    button, and each meal logged today as a button that opens its fix.
// 4. The screens: >2 Today, >3 This week's meals (a day a card, each meal a
//    swap button), >4 Groceries (a list per aisle). Answers patch them.
import type { NativeAgent, Row } from "./types.ts";
import { type Cell, type Clock, type TableSeed, type TableStore, write } from "./tables.ts";
import { readEvent, shift } from "./workouts.ts";

/** Agents with these tools: Basil and any copy of him (a fork keeps base basil). */
export function plansMeals(agent: NativeAgent): boolean {
  return agent.profile.base === "basil";
}

export const RECIPES = "recipes";
export const GOAL = "goal";
export const PLAN = "meal_plan";
export const PREFS = "plan_prefs";
export const GROCERIES = "groceries";
export const MEALS = "meals";
export const TOOL_TABLES = [RECIPES, GOAL, PLAN, PREFS, GROCERIES];

export const SLOTS = ["Breakfast", "Lunch", "Dinner", "Snack"] as const;
export const AISLES = ["Produce", "Meat and fish", "Dairy and eggs", "Bakery", "Pantry", "Frozen", "Other"] as const;
const WEEKDAY = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

/** The plan's questions: the options each shows, and what each means. */
export const DAYS_OPTS = ["3 days", "5 days", "7 days"];
export const MEALS_OPTS = ["2 meals", "3 meals", "3 and a snack"];
export const LIKE_OPTS = ["Chicken", "Fish", "Beef", "Veggie", "Eggs", "Pasta", "Rice bowls", "Mexican", "Asian", "Italian"];
export const AVOID_OPTS = ["None", "Dairy", "Gluten", "Nuts", "Shellfish", "Fish", "Meat", "Pork", "Eggs", "Soy"];
export const BUDGET_OPTS = ["Keep it cheap", "In between", "Treat me"];
export const COOK_OPTS = ["15 minutes", "30 minutes", "45 or more"];

// A no-go leaves out every recipe with one of these tags; a like pulls in recipes with one.
const AVOID_TAGS: Record<string, string[]> = {
  dairy: ["dairy"], gluten: ["gluten"], nuts: ["nuts"], shellfish: ["shellfish"], fish: ["fish", "shellfish"],
  meat: ["chicken", "beef", "pork", "turkey"], pork: ["pork"], eggs: ["eggs"], soy: ["soy"],
};
const LIKE_TAGS: Record<string, string[]> = {
  chicken: ["chicken"], fish: ["fish", "shellfish"], beef: ["beef"], veggie: ["veggie"], eggs: ["eggs"], pasta: ["pasta"],
  "rice bowls": ["rice", "bowl"], mexican: ["mexican"], asian: ["asian"], italian: ["italian"],
};
// How the day's calories split across its meals.
const SHARES: Record<string, Record<string, number>> = {
  "2": { Lunch: 0.45, Dinner: 0.55 },
  "3": { Breakfast: 0.27, Lunch: 0.33, Dinner: 0.4 },
  "4": { Breakfast: 0.24, Lunch: 0.3, Dinner: 0.34, Snack: 0.12 },
};

// ---------- small helpers ----------

const q = (s: string) => `"${String(s).replace(/\\/g, "").replace(/"/g, "'").replace(/\|/g, "/").replace(/[–—]/g, ",").replace(/\n/g, " ")}"`;
const opts = (xs: string[]) => xs.map(q).join("|");
const num = (v: Cell | undefined | unknown) => (typeof v === "number" ? v : Number(v) || 0);
const kcal = (n: number) => Math.round(n).toLocaleString("en-US");
const ymd = (day: string) => day.replace(/-/g, "");
const fromYmd = (s: string) => `${s.slice(0, 4)}-${s.slice(4, 6)}-${s.slice(6, 8)}`;
export const slug = (s: string) => s.toLowerCase().normalize("NFKD").replace(/&/g, " and ").replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 48) || "item";
const utcDay = (day: string) => {
  const [y, m, d] = day.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d)).getUTCDay();
};
function weekday(day: string): string {
  return WEEKDAY[utcDay(day)];
}
const rowsOf = (store: TableStore, name: string) => {
  const t = store.tables[name];
  return t ? t.order.map((key) => ({ key, row: t.rows[key] })) : [];
};
const list = (v: unknown): string[] => (Array.isArray(v) ? v.map(String) : typeof v === "string" && v ? v.split("|") : []);
/** A small stable number from text, so the same week always plans the same way. */
function hash(s: string): number {
  let h = 2166136261;
  for (const c of s) h = Math.imul(h ^ c.charCodeAt(0), 16777619);
  return (h >>> 0) / 4294967296;
}

// ---------- the tables ----------

/**
 * Makes sure Basil's tool tables exist. A Basil added before YUI-183 has only `foods` and `meals`: the missing
 * tables come from his starter seeds (the recipes, the goal), and never overwrite a table the person already has.
 */
export function ensureTools(store: TableStore, seeds: TableSeed[] | undefined): TableStore {
  let out = store;
  for (const name of [...TOOL_TABLES, MEALS]) {
    if (out.tables[name]) continue;
    const seed = seeds?.find((s) => s.name === name);
    if (!seed) continue;
    const r = write(out, { op: "table", name, cols: seed.cols });
    if (r.error) continue;
    out = r.store;
    // Only the recipes and the goal carry their starter rows over: a grocery list they never made stays empty.
    if (name !== RECIPES && name !== GOAL) continue;
    for (const row of seed.rows) {
      const w = write(out, { op: "put", table: name, key: row.key, values: row.values });
      if (!w.error) out = w.store;
    }
  }
  return out;
}

export interface Goal { cal: number; protein: number; carbs: number; fat: number }
export function goal(store: TableStore): Goal {
  const g = store.tables[GOAL]?.rows.daily ?? rowsOf(store, GOAL)[0]?.row;
  return { cal: num(g?.Cal) || 2100, protein: num(g?.Protein) || 140, carbs: num(g?.Carbs) || 210, fat: num(g?.Fat) || 70 };
}

export interface Recipe {
  key: string; name: string; meal: string; tags: string[]; minutes: number; cost: number;
  cal: number; protein: number; carbs: number; fat: number; ingredients: { item: string; qty: string }[];
}

/** "Greek yogurt:1 cup; Blueberries:1 cup" as items and amounts. */
export function ingredients(text: string): { item: string; qty: string }[] {
  return String(text ?? "").split(/;\s*/).map((p) => p.trim()).filter(Boolean).map((p) => {
    const i = p.lastIndexOf(":");
    return i > 0 ? { item: p.slice(0, i).trim(), qty: p.slice(i + 1).trim() } : { item: p, qty: "" };
  });
}

export function recipes(store: TableStore): Recipe[] {
  return rowsOf(store, RECIPES).filter(({ row }) => row.Name).map(({ key, row }) => ({
    key, name: String(row.Name), meal: String(row.Meal ?? "Dinner"),
    tags: String(row.Tags ?? "").toLowerCase().split(/\s*,\s*/).filter(Boolean),
    minutes: num(row.Minutes), cost: num(row.Cost) || 2, cal: num(row.Cal), protein: num(row.Protein), carbs: num(row.Carbs), fat: num(row.Fat),
    ingredients: ingredients(String(row.Ingredients ?? "")),
  }));
}

// ---------- what they asked for ----------

export interface Prefs { days: number; slots: string[]; likes: string[]; avoid: string[]; budget: number; cook: number; words: Record<string, string>;
                         /** The weekdays (0 = Sunday) a first plan was asked for: the week covers these days of the next seven, not the next n days. */
                         weekdays?: number[] }

/** The plan's answers as what the planner needs. Unanswered questions take the easy default. */
export function readPrefs(a: Record<string, unknown>): Prefs {
  const days = Math.max(1, Math.min(7, parseInt(String(a.days ?? "5"), 10) || 5));
  const m = String(a.meals ?? "3 meals");
  const slots = /snack/i.test(m) ? ["Breakfast", "Lunch", "Dinner", "Snack"] : /^2/.test(m) ? ["Lunch", "Dinner"] : ["Breakfast", "Lunch", "Dinner"];
  const likes = list(a.likes).map((x) => x.trim()).filter(Boolean);
  const avoid = list(a.avoid).map((x) => x.trim()).filter((x) => x && !/^none$/i.test(x));
  const b = String(a.budget ?? "");
  const budget = /cheap/i.test(b) ? 1 : /treat/i.test(b) ? 3 : 2;
  const c = String(a.cook ?? "");
  const cook = /15/.test(c) ? 15 : /30/.test(c) ? 30 : 999;
  return { days, slots, likes, avoid, budget, cook,
           words: { days: `${days} days`, meals: m, likes: likes.join(", ") || "Anything", avoid: avoid.join(", ") || "None", budget: b || "In between", cook: c || "45 or more" } };
}

/** Words that match a recipe: its tags, its name or an ingredient ("no mushrooms", "likes salmon"). */
function matches(r: Recipe, word: string, table: Record<string, string[]>): boolean {
  const w = word.toLowerCase().trim();
  const tags = table[w];
  if (tags) return tags.some((t) => r.tags.includes(t));
  const stem = w.replace(/(?:es|s)$/, "");
  if (stem.length < 3) return false;
  const re = new RegExp(`\\b${stem.replace(/[^a-z0-9 ]/g, "")}`, "i");
  return re.test(r.name) || r.tags.some((t) => re.test(t)) || r.ingredients.some((i) => re.test(i.item));
}
export const allowed = (r: Recipe, p: Prefs) => !p.avoid.some((a) => matches(r, a, AVOID_TAGS));

// ---------- the planner ----------

export interface Planned { day: string; slot: string; recipe: Recipe }

/** How well a recipe fits a slot: near its share of the day's calories, a like, no repeats close together. */
function score(r: Recipe, target: number, p: Prefs, used: Map<string, number>, seed: string): number {
  let s = -Math.abs(r.cal - target) / 100;
  s += p.likes.filter((l) => matches(r, l, LIKE_TAGS)).length * 1.5;
  s -= (used.get(r.key) ?? 0) * 3;
  return s + hash(`${seed}:${r.key}`) * 1.2;
}

/** Recipes for a slot that fit, easing off the budget, then the time a step at a time, then the slot's own kind; never a no-go.
 *  `keep` is what else must hold (not twice a day, not three times a week): easing off comes before breaking it. */
function candidates(all: Recipe[], slot: string, p: Prefs, keep: (r: Recipe) => boolean = () => true): Recipe[] {
  const ok = all.filter((r) => allowed(r, p));
  const tries: ((r: Recipe) => boolean)[] = [
    (r) => r.meal === slot && r.cost <= p.budget && r.minutes <= p.cook,
    (r) => r.meal === slot && r.minutes <= p.cook,
    // No slot recipe that quick: the next time step up that has one, before any time at all.
    ...[30, 45, 60].filter((m) => m > p.cook).map((m) => (r: Recipe) => r.meal === slot && r.minutes <= m),
    (r) => r.meal === slot,
    (r) => (slot === "Snack" ? r.meal === "Snack" : r.meal !== "Snack"),
  ];
  for (const t of tries) {
    const c = ok.filter((r) => t(r) && keep(r));
    if (c.length) return c;
  }
  return [];
}

/** A week of meals: a recipe per slot per day, from today. Nothing twice in a day, nothing more than twice a week. */
export function planWeek(store: TableStore, p: Prefs, clk: Clock): { planned: Planned[]; missing: string[] } {
  const all = recipes(store);
  const g = goal(store);
  const shares = SHARES[String(p.slots.length)] ?? SHARES["3"];
  const used = new Map<string, number>();
  const planned: Planned[] = [];
  const missing: string[] = [];
  for (let i = 0; i < (p.weekdays ? 7 : p.days); i++) {
    const day = shift(clk.today, i);
    if (p.weekdays && !p.weekdays.includes(utcDay(day))) continue;
    const today = new Set<string>();
    for (const slot of p.slots) {
      const pool = candidates(all, slot, p, (r) => !today.has(r.key) && (used.get(r.key) ?? 0) < 2);
      const from = pool.length ? pool : candidates(all, slot, p, (r) => !today.has(r.key));
      if (!from.length) {
        if (!missing.includes(slot)) missing.push(slot);
        continue;
      }
      const target = g.cal * (shares[slot] ?? 0.3);
      const best = [...from].sort((a, b) => score(b, target, p, used, `${day}-${slot}`) - score(a, target, p, used, `${day}-${slot}`))[0];
      planned.push({ day, slot, recipe: best });
      today.add(best.key);
      used.set(best.key, (used.get(best.key) ?? 0) + 1);
    }
  }
  return { planned, missing };
}

const planKey = (day: string, slot: string) => `${day}-${slot.toLowerCase()}`;

function putPlanned(store: TableStore, x: Planned, clk: Clock): TableStore {
  const r = x.recipe;
  const w = write(store, { op: "put", table: PLAN, key: planKey(x.day, x.slot), values: {
    Day: x.day, Slot: x.slot, Recipe: r.key, Name: r.name, Cal: r.cal, Protein: r.protein, Carbs: r.carbs, Fat: r.fat, Minutes: r.minutes } }, clk);
  return w.error ? store : w.store;
}

/** The Send: the week written (days from today on replaced), the answers kept, the grocery list rebuilt. */
export function applyPlan(store: TableStore, answers: Record<string, unknown>, clk: Clock, asked?: Prefs): { store: TableStore; planned: Planned[]; missing: string[]; prefs: Prefs } {
  const prefs = asked ?? readPrefs(answers);
  const { planned, missing } = planWeek(store, prefs, clk);
  let out = store;
  for (const { key, row } of rowsOf(out, PLAN)) {
    if (String(row.Day ?? "") >= clk.today) out = write(out, { op: "put", table: PLAN, key, delete: true }).store;
  }
  for (const x of planned) out = putPlanned(out, x, clk);
  const w = write(out, { op: "put", table: PREFS, key: "last", values: { Days: prefs.days, Meals: prefs.words.meals, Likes: prefs.words.likes,
                                                                       Avoid: prefs.words.avoid, Budget: prefs.words.budget, Cook: prefs.words.cook } }, clk);
  if (!w.error) out = w.store;
  out = rebuildGroceries(out, clk);
  return { store: out, planned, missing, prefs };
}

// ---------- the first plan (YUI-221, PROP-4) ----------

export const FIRST_ID = "first";
export const FIRST_TABLE = "first_meals";
export const NOT_SURE = "Not sure";
export const SKIP = "Skip";
const FIRST_GOALS = ["Eat better", "Lose weight", "Build muscle", "Save time"];
const FIRST_DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
const FIRST_MEALS = ["2", "3", "3 and a snack", "4 or more"];
const FIRST_AVOID = ["Meat", "Fish", "Dairy", "Gluten", "Nuts", "Eggs", "Nothing"];
const FIRST_COOK = ["15 minutes", "30 minutes", "An hour", "I like a project"];
const softer = (xs: string[]) => opts([...xs, NOT_SURE, SKIP]);

/** The intake, as first.yui and its test send it: five questions, Not sure and Skip on each, one Send. */
export function firstLines(): string[] {
  return [
    `plan@${FIRST_ID} "Your first meal plan" submit="Plan my week"`,
    `choose@goal "What's the goal?" ${softer(FIRST_GOALS)}`,
    `pick@days "Which days should I plan?" ${softer(FIRST_DAYS)}`,
    `choose@meals "How many meals a day?" ${softer(FIRST_MEALS)}`,
    `pick@avoid "What should I leave out? Allergies and conditions count." ${softer(FIRST_AVOID)} +other`,
    `choose@cook "How long can you cook?" ${softer(FIRST_COOK)}`,
    `end`,
  ];
}

const real = (xs: string[]) => xs.map((x) => x.trim()).filter((x) => x && !/^(?:not sure|skip)$/i.test(x));

/**
 * The first plan's answers as what the planner needs. Not sure and Skip (or no answer) fall back to every day,
 * three meals and 30 minutes; a leave-out the planner has no tag for still matches by name or ingredient.
 */
export function readFirstPrefs(a: Record<string, unknown>): Prefs {
  const picked = real(list(a.days)).map((d) => FIRST_DAYS.findIndex((x) => x.toLowerCase() === d.toLowerCase().slice(0, 3))).filter((i) => i >= 0);
  const weekdays = [...new Set(picked.map((i) => (i + 1) % 7))];
  const days = weekdays.length || 7;
  const m = real([String(a.meals ?? "")])[0] ?? "3";
  const slots = /snack|^4/i.test(m) ? ["Breakfast", "Lunch", "Dinner", "Snack"] : /^2/.test(m) ? ["Lunch", "Dinner"] : ["Breakfast", "Lunch", "Dinner"];
  const avoid = real(list(a.avoid)).filter((x) => !/^(?:nothing|none)$/i.test(x));
  const c = real([String(a.cook ?? "")])[0] ?? "30 minutes";
  const cook = /^15/.test(c) ? 15 : /^30/.test(c) ? 30 : /hour/i.test(c) ? 60 : /project/i.test(c) ? 999 : 30;
  return { days, slots, likes: [], avoid, budget: 2, cook, weekdays: weekdays.length ? weekdays : undefined,
           words: { days: `${days} days`, meals: slots.length === 4 ? "3 and a snack" : `${slots.length} meals`, likes: "Anything", avoid: avoid.join(", ") || "None",
                    budget: "In between", cook: c } };
}

/** The first plan's Send: the week built from the answers, the answers saved in first_meals and plan_prefs. */
export function applyMealFirst(store: TableStore, answers: Record<string, unknown>, clk: Clock): { store: TableStore; planned: Planned[]; missing: string[]; prefs: Prefs } {
  const prefs = readFirstPrefs(answers);
  const r = applyPlan(store, answers, clk, prefs);
  let out = r.store;
  if (!out.tables[FIRST_TABLE]) {
    const t = write(out, { op: "table", name: FIRST_TABLE, cols: [{ name: "Question", type: "text" }, { name: "Answer", type: "text" }] });
    if (!t.error) out = t.store;
  }
  const saved: [string, string][] = [["goal", "Goal"], ["days", "Days"], ["meals", "Meals a day"], ["avoid", "Leaving out"], ["cook", "Time to cook"]];
  for (const [k, label] of saved) {
    const v = list(answers[k]).join(", ") || NOT_SURE;
    const w = write(out, { op: "put", table: FIRST_TABLE, key: k, values: { Question: label, Answer: v } }, clk);
    if (!w.error) out = w.store;
  }
  return { ...r, store: out };
}

/** What Basil says on top of the week: what it holds, what it leaves out, that a tap swaps a meal. */
export function firstLine(r: { planned: Planned[]; missing: string[]; prefs: Prefs }): string {
  const days = new Set(r.planned.map((x) => x.day)).size;
  const out = r.prefs.avoid.length ? `, nothing with ${joinList(r.prefs.avoid.map((x) => x.toLowerCase()))}` : "";
  const gap = r.missing.length ? ` Nothing fit for ${r.missing.join(" or ").toLowerCase()}, so I left it out.` : "";
  return `Your week of meals is set: ${days} ${days === 1 ? "day" : "days"}, ${r.prefs.slots.length === 4 ? "3 meals and a snack" : `${r.prefs.slots.length} meals`} a day${out}. Tap any meal to swap it.${gap}`;
}
const joinList = (xs: string[]) => (xs.length < 2 ? xs.join("") : `${xs.slice(0, -1).join(", ")} or ${xs[xs.length - 1]}`);

/** The last answers, as Prefs: what a swap keeps to. */
export function lastPrefs(store: TableStore): Prefs {
  const r = store.tables[PREFS]?.rows.last;
  if (!r) return readPrefs({});
  return readPrefs({ days: r.Days, meals: r.Meals, likes: String(r.Likes ?? "").split(/,\s*/).filter((x) => x && x !== "Anything"),
                     avoid: String(r.Avoid ?? "").split(/,\s*/), budget: r.Budget, cook: r.Cook });
}

/** The plan from today on, day by day. */
export function planDays(store: TableStore, clk: Clock): { day: string; meals: { key: string; slot: string; name: string; cal: number; protein: number; minutes: number; recipe: string }[] }[] {
  const by: Record<string, { key: string; slot: string; name: string; cal: number; protein: number; minutes: number; recipe: string }[]> = {};
  for (const { key, row } of rowsOf(store, PLAN)) {
    const day = String(row.Day ?? "").slice(0, 10);
    if (day < clk.today) continue;
    (by[day] ??= []).push({ key, slot: String(row.Slot ?? ""), name: String(row.Name ?? ""), cal: num(row.Cal), protein: num(row.Protein),
                            minutes: num(row.Minutes), recipe: String(row.Recipe ?? "") });
  }
  const order = (s: string) => (SLOTS as readonly string[]).indexOf(s);
  return Object.keys(by).sort().map((day) => ({ day, meals: by[day].sort((a, b) => order(a.slot) - order(b.slot)) }));
}

/** One tap on a meal: the next best recipe for that slot, kept to their no-gos, not already on that day. */
export function applySwap(store: TableStore, day: string, label: string, clk: Clock): { store: TableStore; slot?: string; from?: string; to?: Recipe } {
  const d = planDays(store, { ...clk, today: day }).find((x) => x.day === day);
  const m = d?.meals.find((x) => x.name.toLowerCase() === label.toLowerCase() || `${x.slot}: ${x.name}`.toLowerCase() === label.toLowerCase());
  if (!d || !m) return { store };
  const p = lastPrefs(store);
  const all = recipes(store);
  const onDay = new Set(d.meals.map((x) => x.recipe));
  const week = new Map<string, number>();
  for (const x of planDays(store, clk).flatMap((y) => y.meals)) week.set(x.recipe, (week.get(x.recipe) ?? 0) + 1);
  const g = goal(store);
  const shares = SHARES[String(p.slots.length)] ?? SHARES["3"];
  const target = g.cal * (shares[m.slot] ?? 0.3);
  const pool = candidates(all, m.slot, p, (r) => !onDay.has(r.key));
  if (!pool.length) return { store, slot: m.slot, from: m.name };
  // A swap goes somewhere new: fewest uses this week first, then the best fit.
  const pick = [...pool].sort((a, b) => (week.get(a.key) ?? 0) - (week.get(b.key) ?? 0)
    || score(b, target, p, new Map(), `${day}-${m.slot}-swap-${m.recipe}`) - score(a, target, p, new Map(), `${day}-${m.slot}-swap-${m.recipe}`))[0];
  let out = putPlanned(store, { day, slot: m.slot, recipe: pick }, clk);
  out = rebuildGroceries(out, clk);
  return { store: out, slot: m.slot, from: m.name, to: pick };
}

// ---------- groceries ----------

// Where an item sits in a store. The first list that names it wins, so "peanut butter" is Pantry, not Dairy.
const AISLE_WORDS: [string, RegExp][] = [
  ["Dairy and eggs", /\b(?:oat|almond|soy) milk\b/i],
  ["Bakery", /\b(tortillas?|bread|pita|bagels?)\b/i],
  ["Pantry", /\b(peanut butter|coconut milk|tuna|beans?|chickpeas?|lentils?|rice|pasta|spaghetti|quinoa|oats?|granola|honey|maple|syrup|oil|vinegar|sauce|salsa|marinara|pesto|paste|soy|crushed tomatoes|breadcrumbs|crackers|almonds|nuts|trail mix|chia|seeds|flour|sugar|salt|spices?|cereal|coffee|tea|whey|protein powder|chips|canned)\b/i],
  ["Frozen", /\b(frozen|ice cream|edamame|peas)\b/i],
  ["Meat and fish", /\b(chicken|beef|steak|sirloin|pork|turkey|salmon|cod|shrimp|fish|bacon|sausage|ham|lamb|tilapia)\b/i],
  ["Dairy and eggs", /\b(eggs?|yog(?:h)?urt|milk|cheese|cheddar|feta|mozzarella|parmesan|butter|cream|cottage|hummus|tofu|kefir)\b/i],
  ["Bakery", /\b(bread|toast|tortillas?|pita|bagels?|buns?|wraps?|rolls?|muffins?|croissants?)\b/i],
  ["Produce", /\b(spinach|berries|blueberr\w*|strawberr\w*|bananas?|apples?|avocados?|lettuce|greens|tomato\w*|cucumbers?|peppers?|onions?|garlic|carrots?|celery|broccoli|zucchini|green beans|asparagus|cabbage|limes?|lemons?|potato\w*|peach\w*|kale|herbs|cilantro|basil|parsley|mushrooms?|oranges?|grapes|fruit|vegetables|veg|salad|corn)\b/i],
];
export function aisleOf(item: string): string {
  for (const [aisle, re] of AISLE_WORDS) if (re.test(item)) return aisle;
  return "Other";
}

const FRACTIONS: [number, string][] = [[0.25, "1/4"], [1 / 3, "1/3"], [0.5, "1/2"], [2 / 3, "2/3"], [0.75, "3/4"]];
function parseAmount(s: string): number | null {
  const m = s.match(/^(\d+)(?:\s+(\d+)\/(\d+))?$|^(\d+)\/(\d+)$|^(\d+(?:\.\d+)?)$/);
  if (!m) return null;
  if (m[4]) return Number(m[4]) / Number(m[5]);
  if (m[2]) return Number(m[1]) + Number(m[2]) / Number(m[3]);
  return Number(m[1] ?? m[6]);
}
function amount(n: number): string {
  const whole = Math.floor(n + 1e-9);
  const frac = n - whole;
  if (frac < 0.05) return String(whole);
  const f = FRACTIONS.reduce((a, b) => (Math.abs(b[0] - frac) < Math.abs(a[0] - frac) ? b : a));
  if (Math.abs(f[0] - frac) > 0.09) return String(Math.round(n * 10) / 10);
  return whole ? `${whole} ${f[1]}` : f[1];
}
const PLURAL: Record<string, string> = { cup: "cups", can: "cans", slice: "slices", scoop: "scoops", block: "blocks", box: "boxes", bunch: "bunches", stalk: "stalks", clove: "cloves", bag: "bags" };
const SINGULAR = Object.fromEntries(Object.entries(PLURAL).map(([a, b]) => [b, a]));

/** Amounts of one item added up: "1 cup" + "1/2 cup" = "1 1/2 cups"; different units stay side by side. */
export function addQty(qtys: string[]): string {
  const by = new Map<string, number>();
  const loose: string[] = [];
  for (const raw of qtys) {
    const m = raw.trim().match(/^(\d+\s+\d+\/\d+|\d+\/\d+|\d+(?:\.\d+)?)\s*(.*)$/);
    const n = m ? parseAmount(m[1]) : null;
    if (!m || n == null) {
      if (raw.trim()) loose.push(raw.trim());
      continue;
    }
    const unit = SINGULAR[m[2].toLowerCase()] ?? m[2].toLowerCase();
    by.set(unit, (by.get(unit) ?? 0) + n);
  }
  const parts = [...by.entries()].map(([u, n]) => {
    if (!u) return amount(n);
    // A can of tuna is still "1 can"; tablespoons and pounds never take an s.
    const unit = n > 1 && PLURAL[u] ? PLURAL[u] : u;
    return `${amount(n)} ${unit}`;
  });
  return [...parts, ...[...new Set(loose)]].join(" + ");
}

/** A grocery row's key: one item, whatever its plural ("Avocado" and "Avocados", "Berries" and "berry"). */
export const itemKey = (item: string) => slug(item).replace(/ies$/, "y").replace(/(?<![aeiou]s|s)s$/, "");

/** What the plan needs from today on, item by item. */
export function planNeeds(store: TableStore, clk: Clock): Map<string, { item: string; qtys: string[] }> {
  const byKey = new Map(recipes(store).map((r) => [r.key, r]));
  const need = new Map<string, { item: string; qtys: string[] }>();
  for (const d of planDays(store, clk)) {
    for (const m of d.meals) {
      for (const ing of byKey.get(m.recipe)?.ingredients ?? []) {
        const k = itemKey(ing.item);
        const e = need.get(k) ?? { item: ing.item, qtys: [] };
        e.qtys.push(ing.qty);
        need.set(k, e);
      }
    }
  }
  return need;
}

/**
 * The grocery list after the plan changed: every item the plan needs (its amount added up, a tick kept),
 * plan items it no longer needs taken off, and what the person added left alone.
 */
export function rebuildGroceries(store: TableStore, clk: Clock): TableStore {
  let out = store;
  if (!out.tables[GROCERIES]) {
    out = write(out, { op: "table", name: GROCERIES, cols: [{ name: "Item", type: "text" }, { name: "Qty", type: "text" }, { name: "Aisle", type: "text" },
                                                              { name: "Got", type: "bool" }, { name: "From", type: "text" }] }).store;
  }
  const need = planNeeds(out, clk);
  for (const { key, row } of rowsOf(out, GROCERIES)) {
    if (row.From === "plan" && !need.has(key)) out = write(out, { op: "put", table: GROCERIES, key, delete: true }).store;
  }
  for (const [key, e] of need) {
    const had = out.tables[GROCERIES].rows[key];
    if (had && had.From !== "plan") continue; // they put it on the list themselves: theirs stays as they wrote it
    const qty = addQty(e.qtys);
    const values: Record<string, unknown> = { Item: e.item, Qty: qty, Aisle: aisleOf(e.item), From: "plan" };
    if (!had) values.Got = false;
    const w = write(out, { op: "put", table: GROCERIES, key, values }, clk);
    if (!w.error) out = w.store;
  }
  return out;
}

/** Items said in words: "oat milk, 2 avocados and tortillas" -> three items. */
export function readItems(words: string): { item: string; qty?: string }[] {
  return words.replace(/[.!]+$/, "").split(/\s*,\s*|\s+and\s+|\s*\n\s*/i).map((w) => w.trim().replace(/^(?:some|a|an|the)\s+/i, "")).filter(Boolean).slice(0, 20)
    .map((w) => {
      const m = w.match(/^(\d+(?:\.\d+)?|\d+\/\d+)\s+(.+)$/);
      const item = (m ? m[2] : w).replace(/^\w/, (c) => c.toUpperCase()).slice(0, 60);
      return m ? { item, qty: m[1] } : { item };
    });
}

/** Items they asked for: on the list (a ticked one comes back), in its aisle. */
export function addGroceries(store: TableStore, items: { item: string; qty?: string }[], clk: Clock): { store: TableStore; added: string[] } {
  let out = rebuildGroceries(store, clk);
  const added: string[] = [];
  for (const it of items) {
    const key = itemKey(it.item);
    const had = out.tables[GROCERIES].rows[key];
    // Asked for: theirs now, so a change of plan never takes it off.
    const values: Record<string, unknown> = { Item: had?.Item ?? it.item, Aisle: had?.Aisle ?? aisleOf(it.item), Got: false, From: "you" };
    if (it.qty) values.Qty = it.qty;
    const w = write(out, { op: "put", table: GROCERIES, key, values }, clk);
    if (!w.error) {
      out = w.store;
      added.push(it.item);
    }
  }
  return { store: out, added };
}

/** An item as the list shows it, which is also what its tick sends back. */
const itemLabel = (row: Record<string, Cell>) => (row.Qty ? `${row.Item}, ${row.Qty}` : String(row.Item ?? ""));

/** A tick on the list: Got on (or off again) for the item it names. */
export function tickGrocery(store: TableStore, label: string, got: boolean, clk: Clock): { store: TableStore; key?: string } {
  const want = label.toLowerCase().trim();
  const hit = rowsOf(store, GROCERIES).find(({ row }) => itemLabel(row).toLowerCase() === want || String(row.Item ?? "").toLowerCase() === want);
  if (!hit) return { store };
  const w = write(store, { op: "put", table: GROCERIES, key: hit.key, values: { Got: got } }, clk);
  return { store: w.error ? store : w.store, key: hit.key };
}

/** What is still to get, by aisle in store order. */
export function toGet(store: TableStore): { aisle: string; items: string[] }[] {
  const by: Record<string, string[]> = {};
  for (const { row } of rowsOf(store, GROCERIES)) {
    if (row.Got === true || !row.Item) continue;
    const a = (AISLES as readonly string[]).includes(String(row.Aisle)) ? String(row.Aisle) : aisleOf(String(row.Item));
    (by[a] ??= []).push(itemLabel(row));
  }
  return AISLES.filter((a) => by[a]?.length).map((a) => ({ aisle: a, items: by[a] }));
}

/** The list as plain words, to copy or send on. */
export function groceryText(store: TableStore): string {
  const g = toGet(store);
  if (!g.length) return "Your grocery list is empty.";
  return ["Grocery list", ...g.map((x) => `${x.aisle}: ${x.items.join("; ")}`)].join("\n");
}

// ---------- today ----------

/** Today's meals in the log, one entry per meal (Breakfast, Lunch ...), with their rows. */
export function todayMeals(store: TableStore, clk: Clock): { meal: string; keys: string[]; cal: number; foods: string[] }[] {
  const by: Record<string, { meal: string; keys: string[]; cal: number; foods: string[] }> = {};
  for (const { key, row } of rowsOf(store, MEALS)) {
    if (String(row.Day ?? "").slice(0, 10) !== clk.today) continue;
    const meal = String(row.Meal ?? "Meal");
    const e = (by[meal] ??= { meal, keys: [], cal: 0, foods: [] });
    e.keys.push(key);
    e.cal += num(row.Cal);
    e.foods.push(`${row.Food}, ${Math.round(num(row.Cal))} kcal`);
  }
  const order = (s: string) => ((SLOTS as readonly string[]).indexOf(s) + 5) % 5;
  return Object.values(by).sort((a, b) => order(a.meal) - order(b.meal));
}

export function dayTotals(store: TableStore, clk: Clock): Goal {
  const out = { cal: 0, protein: 0, carbs: 0, fat: 0 };
  for (const { row } of rowsOf(store, MEALS)) {
    if (String(row.Day ?? "").slice(0, 10) !== clk.today) continue;
    out.cal += num(row.Cal);
    out.protein += num(row.Protein);
    out.carbs += num(row.Carbs);
    out.fat += num(row.Fat);
  }
  return { cal: Math.round(out.cal), protein: Math.round(out.protein), carbs: Math.round(out.carbs), fat: Math.round(out.fat) };
}

// When a planned meal stops being "up next", in minutes after midnight (meals.ts mealName uses the same hours).
const SLOT_ENDS: Record<string, number> = { Breakfast: 10 * 60 + 30, Lunch: 15 * 60, Snack: 17 * 60, Dinner: 24 * 60 };

/** The next planned meal today that isn't logged yet and whose time hasn't gone (breakfast at noon is past). */
export function nextPlanned(store: TableStore, clk: Clock) {
  const logged = new Set(todayMeals(store, clk).map((m) => m.meal));
  const [h, mi] = clk.now.slice(11, 16).split(":").map(Number);
  const at = (h || 0) * 60 + (mi || 0);
  return planDays(store, clk).find((d) => d.day === clk.today)?.meals.find((m) => !logged.has(m.slot) && at < (SLOT_ENDS[m.slot] ?? 24 * 60));
}

export const LOG_A_MEAL = "Log a meal";

/** Basil's own check-in just after midnight: no words, no model turn, only Today and the trend drawn for the new date. */
export const NEW_DAY = "yui:new-day";
export const NEW_DAY_RULE = { every: "day", at: "00:05" };
const NEW_DAY_LINE = /^\[yui\] check-in s\S+ "yui:new-day"/;
const mealLabel = (m: { meal: string; cal: number }) => `${m.meal}, ${kcal(m.cal)} kcal`;

/** A planned meal eaten as planned: its rows in the log, from the recipe's numbers. */
export function logPlanned(store: TableStore, key: string, clk: Clock): { store: TableStore; name?: string; slot?: string; cal?: number } {
  const p = store.tables[PLAN]?.rows[key];
  if (!p) return { store };
  const w = write(store, { op: "put", table: MEALS, key: `plan-${key}`, values: { Day: clk.today, Meal: p.Slot, Food: p.Name, Portion: "1 serving",
                                                                                   Cal: p.Cal, Protein: p.Protein, Carbs: p.Carbs, Fat: p.Fat } }, clk);
  return w.error ? { store } : { store: w.store, name: String(p.Name), slot: String(p.Slot), cal: num(p.Cal) };
}

/** A meal's fix sent: how much of it they ate (a percent), or taken off the log. */
export function applyMealFix(store: TableStore, day: string, meal: string, answers: Record<string, unknown>, clk: Clock): { store: TableStore; text: string } {
  const rows = rowsOf(store, MEALS).filter(({ row }) => String(row.Day ?? "").slice(0, 10) === day && String(row.Meal ?? "").toLowerCase() === meal.toLowerCase());
  if (!rows.length) return { store, text: `I can't find ${meal.toLowerCase()} in today's log any more.` };
  let out = store;
  if (/take it off|remove/i.test(String(answers.keep ?? ""))) {
    for (const { key } of rows) out = write(out, { op: "put", table: MEALS, key, delete: true }).store;
    return { store: out, text: `${meal} is off today's log.` };
  }
  const pct = num(answers.portion) || 100;
  if (pct === 100) return { store, text: `${meal} stays as it was.` };
  const x = pct / 100;
  for (const { key, row } of rows) {
    const w = write(out, { op: "put", table: MEALS, key, values: { Cal: Math.round(num(row.Cal) * x), Protein: Math.round(num(row.Protein) * x),
                                                                  Carbs: Math.round(num(row.Carbs) * x), Fat: Math.round(num(row.Fat) * x) } }, clk);
    if (!w.error) out = w.store;
  }
  const now = rows.reduce((a, { key }) => a + num(out.tables[MEALS].rows[key].Cal), 0);
  return { store: out, text: `${meal} is ${pct}% of what I had: ${kcal(now)} kcal now.` };
}

// ---------- the flows ----------

/** Plan my meals: what the week aims for first, then the questions, one Send. */
export function planBody(store: TableStore): string {
  const g = goal(store);
  const last = store.tables[PREFS]?.rows.last;
  const was = last ? ` Last time: ${last.Days} days, ${String(last.Meals).toLowerCase()}, leaving out ${String(last.Avoid).toLowerCase()}.` : "";
  const lines = [
    `plan@mealplan "Plan my meals" submit="Plan my week"`,
    `page "Your week of meals" body=${q(`I'll plan each day around your goal of ${kcal(g.cal)} kcal and ${g.protein} g protein, from meals you can cook. Tap any meal after to swap it, and your grocery list fills in by aisle.${was}`)}`,
    `choose@days "How many days?" ${opts(DAYS_OPTS)}`,
    `choose@meals "Meals a day?" ${opts(MEALS_OPTS)}`,
    `pick@likes "What do you like?" ${opts(LIKE_OPTS)} +other`,
    `pick@avoid "Anything to leave out?" ${opts(AVOID_OPTS)} +other`,
    `choose@budget "Budget?" ${opts(BUDGET_OPTS)}`,
    `choose@cook "Time to cook a meal?" ${opts(COOK_OPTS)}`,
  ];
  return `Let's plan your week.\n\`\`\`yui\n${lines.join("\n")}\n\`\`\``;
}

/** A day of the plan as a button card: the day's meals, each one a swap. */
function dayChoose(id: string, d: ReturnType<typeof planDays>[number]): string {
  const total = d.meals.reduce((a, m) => a + m.cal, 0);
  const body = d.meals.map((m) => `${m.slot}: ${m.name}, ${kcal(m.cal)} kcal`).join(". ");
  return `choose@${id}-${ymd(d.day)} "Tap a meal to swap it" ${opts(d.meals.map((m) => m.name))} tag=${q(weekday(d.day).slice(0, 3))} title=${q(`${weekday(d.day)}, ${kcal(total)} kcal`)} body=${q(body)}`;
}

/** The deck the Send lands as: the week in a line, then a page a day with its meals as swap buttons. */
export function weekDeck(store: TableStore, clk: Clock, prefs: Prefs): string[] {
  const days = planDays(store, clk);
  const g = goal(store);
  const avg = days.length ? days.reduce((a, d) => a + d.meals.reduce((x, m) => x + m.cal, 0), 0) / days.length : 0;
  const prot = days.length ? days.reduce((a, d) => a + d.meals.reduce((x, m) => x + m.protein, 0), 0) / days.length : 0;
  const n = toGet(store).reduce((a, x) => a + x.items.length, 0);
  const gap = g.cal - avg > 250 && !prefs.slots.includes("Snack") ? " Add a snack a day to close the gap." : "";
  const out = [
    `deck@week-deck "This week's meals"`,
    `page ${q(`${days.length} days planned`)} body=${q(`About ${kcal(avg)} kcal and ${Math.round(prot)} g protein a day, for a goal of ${kcal(g.cal)}.${gap} Leaving out: ${prefs.words.avoid.toLowerCase()}. ${n} things on your grocery list, by aisle.`)} points=${opts(days.map((d) => `${weekday(d.day)}: ${d.meals.map((m) => m.name).join(", ")}`))}`,
  ];
  for (const d of days) out.push(dayChoose("swap", d));
  out.push("end");
  return out;
}

/** Log a meal, from Today: the camera, or their words. */
export const LOG_BODY = "Snap it or say it. No weighing.\n```yui\ncamera@plate \"Snap your meal\" +inline\n```";

/** "Add to my groceries": a form with a text box and a mic. */
export const ADD_BODY = "What do you need? Say it or type it.\n```yui\nform@groc-add \"Add to your list\" items:voice! submit=Add\n```";

// ---------- the screens ----------

/** Today, as its page: calories against the goal, macros against the goal, what's next, today's meals to fix. */
export function todayScreen(store: TableStore, clk: Clock): string[] {
  const g = goal(store);
  const t = dayTotals(store, clk);
  const left = g.cal - t.cal;
  const meals = todayMeals(store, clk);
  const next = nextPlanned(store, clk);
  const hasPlan = planDays(store, clk).length > 0;
  const sub = t.cal ? (left >= 0 ? `of ${kcal(g.cal)}. ${kcal(left)} to go.` : `of ${kcal(g.cal)}. ${kcal(-left)} over, no stress.`) : `of ${kcal(g.cal)}. Log a meal to start.`;
  return [
    `stat@kcal ${kcal(t.cal)}kcal "Calories today" sub=${q(sub)}`,
    `chart@macros bar "Macros vs goal" x=Protein|Carbs|Fat y=${t.protein}|${t.carbs}|${t.fat} y2=${g.protein}|${g.carbs}|${g.fat} names=Today|Goal unit=g`,
    next ? `card@next-meal ${q(`Up next: ${next.slot}`)} ${q(`${next.name}. ${kcal(next.cal)} kcal, about ${next.minutes} minutes.`)} sub="From your plan" cta="I ate it"`
         : `card@next-meal ${q(hasPlan ? "All planned meals logged" : "No plan yet")} ${q(hasPlan ? "Nice. Anything else you eat, snap it or say it." : "Tell me what you like and I'll plan your week.")} cta=${q(hasPlan ? "Log a meal" : "Plan my meals")}`,
    `choose@eaten "Tap a meal to fix it" ${opts(meals.length ? meals.map(mealLabel) : [LOG_A_MEAL])} body=${q(meals.length ? meals.map((m) => `${m.meal}: ${m.foods.join("; ")}`).join(". ").slice(0, 380) : "Nothing logged yet today.")}`,
  ];
}

/** This week's meals, as its page: a card a day with a swap button per meal, and the plan again. */
export function weekScreen(store: TableStore, clk: Clock): string[] {
  const days = planDays(store, clk);
  if (!days.length) return [`card@week-plan "This week's meals" "Tell me what you like and I'll plan your week, with a grocery list." cta="Plan my meals"`];
  return [...days.map((d) => dayChoose("wk", d)), `card@week-plan "Want a new week?" "New likes, a new budget, or just a change." cta="Plan again"`];
}

/** Groceries, as its page: what's left, a list per aisle with ticks, and a way to add. */
export function groceryScreen(store: TableStore): string[] {
  const g = toGet(store);
  const n = g.reduce((a, x) => a + x.items.length, 0);
  const planned = rowsOf(store, GROCERIES).some(({ row }) => row.From === "plan");
  return [
    `stat@groc-left ${q(`${n} to get`)} "Grocery list" sub=${q(planned ? "From your meal plan and what you added" : "Plan your meals and this fills in")}`,
    ...g.map((x) => `list@aisle-${slug(x.aisle)} title=${q(x.aisle)} ${opts(x.items)} +check`),
    `card@groc-add "Need something else?" "Say it or type it, like: add oat milk to my groceries." cta="Add to the list"`,
  ];
}

/** The page shapes: a new day on the plan or a new aisle redraws that page; otherwise its lines are patches. `day` is the
 *  date Today was drawn for and `trend` that the calories-over-time page exists, so a new day or an older phone redraws them. */
export interface Shape { week: string; groceries: string; day?: string; trend?: boolean }
export function screenShape(store: TableStore, clk: Clock): Shape {
  return { week: planDays(store, clk).map((d) => ymd(d.day)).join(",") || "none", groceries: toGet(store).map((x) => slug(x.aisle)).join(",") || "none",
           day: clk.today, trend: true };
}
export const shapeText = (s: Shape) => `v1;${s.week};${s.groceries}${s.day || s.trend ? `;${s.day ?? ""}${s.trend ? ";t" : ""}` : ""}`;
export function readShape(t: string | undefined): Shape | null {
  const m = t?.match(/^v1;([^;]*);([^;]*)(?:;(\d{4}-\d{2}-\d{2})?(;t)?)?$/);
  return m ? { week: m[1], groceries: m[2], day: m[3], trend: !!m[4] } : null;
}

// ---------- calories over time ----------

/** Calories logged on each of the last `n` days, oldest first, today last. */
export function calorieDays(store: TableStore, clk: Clock, n: number): { day: string; cal: number }[] {
  const by: Record<string, number> = {};
  for (const { row } of rowsOf(store, MEALS)) {
    const d = String(row.Day ?? "").slice(0, 10);
    by[d] = (by[d] ?? 0) + num(row.Cal);
  }
  return Array.from({ length: n }, (_, i) => { const day = shift(clk.today, i - n + 1); return { day, cal: Math.round(by[day] ?? 0) }; });
}

/** Calories over time, as its page: the last 7 days against the goal, the last 30, and the average of the days that have a log. */
export function trendScreen(store: TableStore, clk: Clock): string[] {
  const g = goal(store);
  const w = calorieDays(store, clk, 7);
  const m = calorieDays(store, clk, 30);
  const logged = m.filter((d) => d.cal > 0);
  const avg = logged.length ? logged.reduce((a, d) => a + d.cal, 0) / logged.length : 0;
  return [
    `stat@trend-avg ${kcal(avg)}kcal "Daily average" sub=${q(logged.length ? `Over ${logged.length} logged ${logged.length === 1 ? "day" : "days"} of the last 30. Goal ${kcal(g.cal)}.` : "Log a meal and your days add up here.")}`,
    `chart@trend-week bar "Calories, last 7 days" x=${w.map((d) => weekday(d.day).slice(0, 3)).join("|")} y=${w.map((d) => d.cal).join("|")} y2=${w.map(() => g.cal).join("|")} names=Eaten|Goal unit=kcal`,
    `chart@trend-month area "Calories, last 30 days" x=${m.map((d) => Number(d.day.slice(8))).join("|")} y=${m.map((d) => d.cal).join("|")} unit=kcal`,
  ];
}

/**
 * The pages as the phone has them: the shape the runtime last drew, or for a Basil whose home is this one (YUI-183,
 * the Today picker is its mark) the pages that home drew. A home from before gets every page drawn again once.
 */
export function drawnShape(p: { mealScreens?: string; home?: string }): string | undefined {
  if (p.mealScreens) return p.mealScreens;
  if (!/\bchoose@eaten\b/.test(p.home ?? "")) return undefined;
  const aisles = [...(p.home ?? "").matchAll(/\blist@aisle-([a-z-]+)/g)].map((m) => m[1]);
  return shapeText({ week: /\bchoose@wk-/.test(p.home ?? "") ? "home" : "none", groceries: aisles.join(",") || "none", trend: /\bstat@trend-avg\b/.test(p.home ?? "") });
}

/**
 * The lines that keep Basil's pages current. The first time (a home from before YUI-183) every page is drawn again;
 * after that a page is drawn again only when its shape changed (a day, an aisle), and otherwise only patches go,
 * which never move the person.
 */
export function screenLines(store: TableStore, clk: Clock, was: string | undefined, only?: ("today" | "week" | "groceries")[]): { lines: string[]; shape: string } {
  const prev = readShape(was);
  const now = screenShape(store, clk);
  const want = new Set<string>(only ?? ["today", "week", "groceries"]);
  // Today is about the date: a page drawn on another day is patched to this one's, whatever the ask was about.
  if (prev?.day && prev.day !== clk.today) want.add("today");
  if (want.has("today")) want.add("trend");
  const patch = (lines: string[]) => lines.map((l) => l.replace(/^[a-z]+@/, "~"));
  // Sending to a page brings it forward, so the pages the ask is about are sent last (a meal log ends on Today, a
  // grocery add on Groceries, a plan on the week) and pages drawn only because the phone had none go first (YUI-183b).
  const chunks: Record<"today" | "week" | "groceries" | "trend", string[]> = { today: [], week: [], groceries: [], trend: [] };
  if (want.has("today") || !prev) chunks.today = !prev ? [">2 clear", ">2", ...todayScreen(store, clk), "save today"] : patch(todayScreen(store, clk));
  if (want.has("week") || !prev) {
    if (!prev || prev.week !== now.week) chunks.week = [">3 clear", ">3", ...weekScreen(store, clk), "save this week"];
    else chunks.week = patch(weekScreen(store, clk));
  }
  if (want.has("groceries") || !prev) {
    if (!prev || prev.groceries !== now.groceries) chunks.groceries = [">4 clear", ">4", ...groceryScreen(store), "save groceries"];
    else chunks.groceries = patch(groceryScreen(store));
  }
  // The trend page is drawn once for a phone that has none, then patched; it goes first so it never brings itself forward.
  if (want.has("trend") || !prev?.trend) chunks.trend = !prev?.trend ? [">5 clear", ">5", ...trendScreen(store, clk), "save calories over time"] : patch(trendScreen(store, clk));
  const asked = new Set(only ?? ["today", "week", "groceries"]);
  const order: ("trend" | "today" | "week" | "groceries")[] = ["trend", ...(["today", "week", "groceries"] as const).filter((k) => !asked.has(k)), ...(["today", "groceries", "week"] as const).filter((k) => asked.has(k))];
  const out = order.flatMap((k) => chunks[k]);
  // What wasn't redrawn keeps the old shape, so it is drawn again the next time it is touched.
  const kept: Shape = { week: want.has("week") || !prev ? now.week : prev.week, groceries: want.has("groceries") || !prev ? now.groceries : prev.groceries,
                        day: want.has("today") || !prev ? now.day : prev.day, trend: true };
  return { lines: out, shape: shapeText(kept) };
}

// ---------- taps and words ----------

export type MealAsk =
  | { kind: "plan"; row: Row }
  | { kind: "planned"; row: Row; answers: Record<string, unknown> }
  | { kind: "first"; row: Row; answers: Record<string, unknown> }
  | { kind: "swap"; row: Row; day: string; choice: string }
  | { kind: "add"; row: Row }
  | { kind: "added"; row: Row; words: string }
  | { kind: "tick"; row: Row; item: string; got: boolean }
  | { kind: "share"; row: Row }
  | { kind: "ate"; row: Row }
  | { kind: "logmeal"; row: Row }
  | { kind: "newday"; row: Row }
  | { kind: "fix"; row: Row; choice: string }
  | { kind: "fixed"; row: Row; day: string; meal: string; answers: Record<string, unknown> };

const PLAN_WORDS = /^\s*(?:(?:please|can you|could you|let'?s)\s+)?(?:plan|make|build)\s+(?:(?:my|me|a|the)\s+){0,2}(?:meals?|meal plan|week of meals|menu)(?:\s+(?:plan|for\s+(?:the|this)\s+week|this\s+week|for\s+the\s+week|a\s+week))?\s*(?:please)?\s*[.!?]*\s*$/i;
const ADD_WORDS = /^\s*(?:please\s+)?(?:add|put)\s+(.+?)\s+(?:to|on)\s+(?:my|the)\s+(?:grocery|groceries|shopping)(?:\s+list)?\s*[.!]*\s*$/i;
const ADD_COLON = /^\s*add\s+to\s+(?:my|the)\s+(?:grocery\s+list|groceries|shopping\s+list)\s*:?\s*(.*)$/is;
// Words that point back at what was just said ("put the goods on my grocery list", "add those to my groceries") are not
// an item: the model turn reads what they mean from the thread (YUI-188).
const POINTS_BACK = /^(?:(?:all|each|every|both)\s+(?:of\s+)?)?(?:it|them|that|this|those|these|everything|all|all that|the\s+(?:goods|stuff|things|items|ingredients|rest|lot|above|whole\s+thing|list)|(?:those|these|that|the|this|your|its)\s+(?:ones?|things|items|ingredients|foods?|goods|groceries|stuff|meals?|recipes?|plan))(?:\s+(?:too|as well|in|over|for me|please))*$/i;
const SHARE_WORDS = /^\s*(?:share|send|text|copy)\s+(?:me\s+)?(?:my|the)\s+(?:grocery|groceries|shopping)(?:\s+list)?\s*[.!?]*\s*$/i;
const ID = (re: RegExp, id: string) => re.test(id);

/** The rows in a turn the runtime answers itself (meal-plan words and taps), and the rest for the model. */
export function mealAsks(rows: Row[]): { asks: MealAsk[]; rest: Row[] } {
  const asks: MealAsk[] = [];
  const rest: Row[] = [];
  for (const r of rows) {
    const body = r.body ?? "";
    const e = /^\[yui\]\s/.test(body) ? readEvent(r) : null;
    let a: MealAsk | null = null;
    if (NEW_DAY_LINE.test(body)) a = { kind: "newday", row: r };
    else if (!e && r.kind !== "event") {
      const col = body.match(ADD_COLON);
      const add = body.match(ADD_WORDS);
      if (PLAN_WORDS.test(body)) a = { kind: "plan", row: r };
      else if (col) a = col[1].trim() ? { kind: "added", row: r, words: col[1].trim() } : { kind: "add", row: r };
      else if (add && !POINTS_BACK.test(add[1].trim())) a = { kind: "added", row: r, words: add[1] };
      else if (SHARE_WORDS.test(body)) a = { kind: "share", row: r };
    } else if (e) {
      const v = e.value;
      const plan = v.plan && typeof v.plan === "object" ? (v.plan as Record<string, unknown>) : null;
      if (e.preset === "plan" && e.id === "mealplan" && plan) a = { kind: "planned", row: r, answers: plan };
      else if (e.preset === "plan" && e.id === FIRST_ID && plan) a = { kind: "first", row: r, answers: plan };
      else if (e.preset === "plan" && ID(/^mfix-\d{8}-[a-z]+$/, e.id) && plan) {
        const [, d, meal] = e.id.split("-");
        a = { kind: "fixed", row: r, day: fromYmd(d), meal: meal[0].toUpperCase() + meal.slice(1), answers: plan };
      } else if (e.preset === "choose" && ID(/^(?:swap|wk)-\d{8}$/, e.id) && typeof v.choice === "string") {
        a = { kind: "swap", row: r, day: fromYmd(e.id.slice(-8)), choice: v.choice };
      } else if (e.preset === "choose" && e.id === "eaten" && typeof v.choice === "string") {
        // Not fix-...: meals.ts reads a fix- choose as the answer to a meal's one question.
        a = v.choice === LOG_A_MEAL ? { kind: "logmeal", row: r } : { kind: "fix", row: r, choice: v.choice };
      } else if (e.preset === "list" && ID(/^aisle-[a-z-]+$/, e.id) && typeof v.item === "string") {
        a = { kind: "tick", row: r, item: v.item, got: !(v.checked === false || v.checked === "false" || v.checked === "off") };
      } else if (e.preset === "form" && e.id === "groc-add" && v.form && typeof v.form === "object") {
        const words = String((v.form as Record<string, unknown>).items ?? "").trim();
        a = words ? { kind: "added", row: r, words } : { kind: "add", row: r };
      } else if (e.preset === "card" && v.cta != null) {
        const cta = String(v.cta);
        if (e.id === "week-plan" || /^plan (?:my meals|again)$/i.test(cta)) a = { kind: "plan", row: r };
        else if (e.id === "groc-add") a = { kind: "add", row: r };
        else if (e.id === "next-meal" && /ate it/i.test(cta)) a = { kind: "ate", row: r };
        else if (e.id === "next-meal" && /plan/i.test(cta)) a = { kind: "plan", row: r };
        else if (e.id === "next-meal") a = { kind: "logmeal", row: r };
      }
    }
    if (a) asks.push(a);
    else rest.push(r);
  }
  return { asks, rest };
}

/** A meal tapped on Today: its foods to read, then how much of it they ate and whether to keep it, one Save. */
export function fixBody(store: TableStore, choice: string, clk: Clock): string {
  const meal = choice.split(",")[0].trim();
  const m = todayMeals(store, clk).find((x) => x.meal.toLowerCase() === meal.toLowerCase());
  if (!m) return `I can't find ${meal.toLowerCase()} in today's log. Snap it or say it and I'll log it.`;
  const lines = [
    `plan@mfix-${ymd(clk.today)}-${slug(m.meal).replace(/-/g, "")} ${q(`Fix ${m.meal.toLowerCase()}`)} submit=Save`,
    `page ${q(`${m.meal}, ${kcal(m.cal)} kcal`)} points=${opts(m.foods.slice(0, 8))}`,
    `slide@portion "How much of it did you eat, in percent?" 25-200 value=100 step=25 unit=%`,
    `choose@keep "Keep it in today's log?" "Keep it"|"Take it off"`,
  ];
  return `\`\`\`yui\n${lines.join("\n")}\n\`\`\``;
}
