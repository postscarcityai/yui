// Log a meal without weighing (YUI-103, yuigui spec/MEAL.md): snap and say,
// the macros are worked out in the background, one breakdown screen, and a
// food memory per person.
//
// Chris (TestFlight notes, build 244): "I don't wanna make the user weigh that
// much. It should go as a separate task in a queue, analyze behind the scenes,
// and then update your screens when ready." / "It should give me a full
// breakdown of all the calories and all the macros, and I don't need eight
// screens for that."
//
// 1. A photo (and any words with it) to a meal agent (Basil) is answered at
//    once, with no model call: "Got it, working out the macros." A meal job is
//    queued. A normal turn can queue one too, with a ```meal block
//    (`log "two eggs and toast"`), for meals said in words.
// 2. The job asks the model that sees for the items on the plate as JSON,
//    portions in plain words, never grams to weigh. It reuses the person's
//    own foods (the `myfoods` table) and the agent's starter `foods`.
// 3. The runtime does the arithmetic: rows in `meals`, each food kept in
//    `myfoods` (how often, last time), and ONE breakdown reply: a line and a
//    table of every item with its calories and macros, then today so far and
//    one chart. At most one short question (oil, butter, portion), answered
//    by a tap the runtime applies itself, with no model turn.
import type { Store } from "./store.ts";
import type { NativeAgent, Row } from "./types.ts";
import { type Cell, type Clock, type TableStore, changed, clock, diff, write } from "./tables.ts";
import { validZone } from "./schedule.ts";

/** A meal to work out: the photo (a storage path or a link) and what the person said. */
export interface MealInput {
  photo?: string;
  words: string;
  rowId?: string; // the person's row it came from
  said?: string; // the person's own words, when the agent's log line is shorter (the meal they named: "for breakfast")
}

/** A job the runtime runs behind the scenes (yui_native_jobs). */
export interface JobItem {
  id: string;
  userId: string;
  agentId: string;
  kind: "meal";
  input: MealInput;
  status: "queued" | "running" | "done" | "failed";
  tries: number;
  createdAt: string;
  result?: Record<string, unknown>;
}

/** One food the model saw, as it answers. */
export interface MealItem {
  food: string;
  portion: string; // plain words: "1 fillet", "about a cup", "2 slices"
  cal: number;
  protein: number;
  carbs: number;
  fat: number;
  memory?: string; // a myfoods or foods key it matched
  servings?: number; // of that remembered portion, 1 when absent
}

export interface MealOption { label: string; cal: number; protein: number; carbs: number; fat: number }

/** What the model answers for a meal. */
export interface MealEstimate {
  food: boolean; // false: not a meal (a menu, a fridge, a person)
  title: string; // "Salmon bowl"
  items: MealItem[];
  sure: string; // one plain line: what is clear, what is a guess
  question?: { text: string; options: MealOption[] } | null;
}

export const MEALS_TABLE = "meals";
export const MEMORY_TABLE = "myfoods";
const MEALS_COLS = [
  { name: "Day", type: "date" as const }, { name: "Meal", type: "text" as const }, { name: "Food", type: "text" as const },
  { name: "Portion", type: "text" as const }, { name: "Cal", type: "number" as const, unit: "kcal" },
  { name: "Protein", type: "number" as const, unit: "g" }, { name: "Carbs", type: "number" as const, unit: "g" },
  { name: "Fat", type: "number" as const, unit: "g" },
];
const MEMORY_COLS = [
  { name: "Food", type: "text" as const }, { name: "Portion", type: "text" as const }, { name: "Cal", type: "number" as const, unit: "kcal" },
  { name: "Protein", type: "number" as const, unit: "g" }, { name: "Carbs", type: "number" as const, unit: "g" },
  { name: "Fat", type: "number" as const, unit: "g" }, { name: "Times", type: "number" as const }, { name: "Last", type: "date" as const },
];

/** Agents that log meals: Basil and any copy of him (a person's fork keeps base basil), or a profile that says so. */
export function logsMeals(agent: NativeAgent): boolean {
  return agent.profile.base === "basil" || !!agent.profile.meals;
}

// Words that make a photo a question, not a log: "what can I cook with this?", "is this healthy".
const ASKING = /\?|\b(?:what|how|can i|should|which|why|recipe|ideas?|cook with|make with|healthy|is (?:this|it)|are (?:these|they)|compare|menu|plan)\b/i;

/** The words the person said with a photo, without the event's own tokens. */
export function spoken(rows: Row[]): string {
  return rows.map((r) => {
    let b = r.body ?? "";
    if (/^\[yui\]/.test(b)) {
      // "[yui] c1 camera photo=/p.jpg note="butter on the toast"" : keep a note= or said= or text=, drop the rest.
      const said = b.match(/\b(?:note|said|text|words|transcript)="((?:[^"\\]|\\.)*)"/)?.[1];
      b = said ?? "";
    }
    b = b.replace(/\bphotos?=("[^"]*"|\S+)/g, "").trim();
    // A photo with no caption comes as the body "Photo" (Attachments.swift): no words.
    return r.meta?.photos?.length && /^photos?$/i.test(b) ? "" : b;
  }).filter(Boolean).join(" ").replace(/\s+/g, " ").trim().slice(0, 600);
}

/** A turn that is a meal to log: a meal agent, a photo, and words that don't ask anything. Null otherwise. */
export function mealTurn(agent: NativeAgent, rows: Row[], photos: string[]): MealInput | null {
  if (!logsMeals(agent) || !photos.length) return null;
  // A tap or another event in the same turn (a form, a fix) needs the agent itself.
  if (rows.some((r) => /^\[yui\]/.test(r.body ?? "") && !/\bphotos?=/.test(r.body ?? "") && !r.meta?.photos?.length)) return null;
  const words = spoken(rows);
  if (ASKING.test(words)) return null;
  const real = rows.filter((r) => !r.id.startsWith("synthetic:"));
  return { photo: photos[photos.length - 1], words, ...(real.length ? { rowId: real[real.length - 1].id } : {}) };
}

export const ACK = "Got it, working out the macros.";

// ---------- the model's part ----------

export const MEAL_PROMPT = `You work out the calories and macros of one meal for a food log. The person does not weigh anything: judge portions from the photo and their words.

Answer with JSON only, no other words:
{"food": true, "title": "Salmon bowl", "sure": "Sure on the salmon and rice. Less sure on the dressing.",
 "items": [{"food": "Salmon, grilled", "portion": "1 fillet", "cal": 310, "protein": 33, "carbs": 0, "fat": 19, "memory": null, "servings": 1}],
 "question": null}

Rules:
- One item per food you can see or they named. Portions in plain words (1 fillet, about a cup, 2 slices, a handful). Never grams or ounces in a portion: nobody weighs.
- Numbers are for the portion shown: whole kcal, whole grams. Count what cooking usually adds only when you can see it (a sheen of oil, a pat of butter).
- Their words win over the photo: "with butter" adds butter, "half of it" halves it, "no dressing" leaves the dressing out entirely, even when you can see it.
- Their own foods and the common foods are listed below with a key. When an item is one of them, set "memory" to its key and "servings" to how many of that portion (0.5, 1, 2), and copy its numbers times servings. "My usual" means one of their own foods.
- "sure" is one or two short plain sentences, under 25 words: what you can see clearly and what is a guess (hidden oil, sauce, what sits under the toppings). Never a percentage.
- "question": at most one, only when one answer would move the total by about 100 kcal or more (cooked in butter or oil, a hidden sauce, a portion you can't judge). Then {"text": "Cooked in oil or butter?", "options": [{"label": "None", "cal": 0, "protein": 0, "carbs": 0, "fat": 0}, {"label": "A little", "cal": 60, "protein": 0, "carbs": 0, "fat": 7}, {"label": "A lot", "cal": 180, "protein": 0, "carbs": 0, "fat": 20}]}: two to four options, each what it adds (or takes away, negative) to the meal. Otherwise null. The question is under 8 words, each label one to three words. Never ask about something they already told you ("no mayo" means no mayo: don't ask about it).
- Not a meal or a drink (a menu, a fridge, a person, a screenshot), or too blurry to tell: {"food": false, "title": "", "sure": "why, in a few words", "items": [], "question": null}.`;

/** The person's own foods first, then the agent's starter foods, one line each, for the prompt. */
export function memoryLines(tables: TableStore, most = 80): string {
  const lines: string[] = [];
  for (const [name, head] of [[MEMORY_TABLE, "Their own foods"], ["foods", "Common foods"]] as const) {
    const t = tables.tables[name];
    if (!t?.order.length) continue;
    const keys = name === MEMORY_TABLE
      ? [...t.order].sort((a, b) => Number(t.rows[b].Times ?? 0) - Number(t.rows[a].Times ?? 0)).slice(0, most)
      : t.order.slice(0, most);
    lines.push(`${head}:`);
    for (const k of keys) {
      const r = t.rows[k];
      lines.push(`- ${k}: ${r.Food} (${r.Portion ?? "1 portion"}) ${num(r.Cal)} kcal, P ${num(r.Protein)} g, C ${num(r.Carbs)} g, F ${num(r.Fat)} g`);
    }
  }
  return lines.join("\n") || "No foods kept yet.";
}

/** A portion in plain words: weights the model slipped in ("about 3 oz / small fillet", "1 fillet (170g)") come out. */
export function plainPortion(p: string): string {
  const W = String.raw`(?:about |around |~)?\d+(?:[.,]\d+)?\s*(?:g|grams?|oz|ounces?|lbs?|kg)\b`;
  const out = p
    .replace(new RegExp(String.raw`\(\s*${W}[^)]*\)`, "gi"), "")
    .replace(new RegExp(String.raw`${W}\s*(?:/|or|,)\s*`, "gi"), "")
    .replace(new RegExp(String.raw`\s*(?:/|,|or)\s*${W}`, "gi"), "")
    .replace(new RegExp(W, "gi"), "")
    .replace(/\s{2,}/g, " ").replace(/^[\s,/]+|[\s,/(]+$/g, "").trim();
  return out || "1 portion";
}

/** Cut at a word, never mid-word. */
export function clip(t: string, n: number): string {
  if (t.length <= n) return t;
  const cut = t.slice(0, n + 1).replace(/\s+\S*$/, "").replace(/[\s,;:(]+$/, "");
  return cut || t.slice(0, n);
}

const num = (v: Cell | undefined) => (typeof v === "number" ? v : Number(v) || 0);
const whole = (n: unknown) => Math.max(0, Math.round(Number(n) || 0));

/** The model's JSON, read loosely (a fence, words around it), checked and cleaned. Null when it isn't one. */
export function parseEstimate(text: string): MealEstimate | null {
  const s = text.replace(/```(?:json)?/gi, "");
  const a = s.indexOf("{"), b = s.lastIndexOf("}");
  if (a < 0 || b <= a) return null;
  let d: any;
  try {
    d = JSON.parse(s.slice(a, b + 1));
  } catch {
    return null;
  }
  if (!d || typeof d !== "object") return null;
  const items: MealItem[] = (Array.isArray(d.items) ? d.items : []).slice(0, 12).flatMap((x: any) => {
    const food = String(x?.food ?? "").trim().slice(0, 80);
    if (!food) return [];
    const servings = Number(x?.servings);
    return [{ food, portion: plainPortion(clip(String(x?.portion ?? "").trim(), 60)), cal: whole(x?.cal), protein: whole(x?.protein),
              carbs: whole(x?.carbs), fat: whole(x?.fat), ...(x?.memory ? { memory: String(x.memory).slice(0, 64) } : {}),
              ...(Number.isFinite(servings) && servings > 0 && servings <= 10 ? { servings } : {}) }];
  });
  const food = d.food !== false && items.length > 0;
  let question: MealEstimate["question"] = null;
  const q = d.question;
  if (food && q && typeof q.text === "string" && Array.isArray(q.options) && q.options.length >= 2) {
    const options = q.options.slice(0, 4).map((o: any) => ({ label: clip(String(o?.label ?? "").trim(), 28), cal: Math.round(Number(o?.cal) || 0),
      protein: Math.round(Number(o?.protein) || 0), carbs: Math.round(Number(o?.carbs) || 0), fat: Math.round(Number(o?.fat) || 0) }))
      .filter((o: MealOption) => o.label);
    if (options.length >= 2) question = { text: clip(q.text.trim().replace(/\s*\([^)]*\)?\s*$/, ""), 80), options };
  }
  return { food, title: String(d.title ?? "").trim().slice(0, 60) || items[0]?.food || "Meal", items: food ? items : [],
           sure: clip(String(d.sure ?? "").trim(), 200), question };
}

/** What they said no to: "no mayo on mine", "without the dressing", "skipped the rice" -> ["mayo", "dressing", "rice"]. */
export function saidNo(words: string): string[] {
  const out: string[] = [];
  for (const m of words.toLowerCase().matchAll(/\b(?:no|without|skip(?:ped)?|minus|hold(?: the)?|didn'?t (?:eat|have))\s+(?:the |any |my )?([a-z][a-z-]{2,})/g)) {
    const w = m[1].replace(/(?:es|s)$/, "");
    if (!["more", "idea", "one", "thank", "problem", "clue"].includes(w)) out.push(w);
  }
  return out;
}

// What cooks add and people mention: a question about one they already named asks what they told us.
const EXTRAS = /\b(butter|ghee|oil|olive|lard|sauce|dressing|mayo|mayonnaise|aioli|syrup|honey|sugar|cream|cheese|gravy|ketchup|glaze)\b/gi;

/** The estimate without what they said no to (those items go, and a question about one of them), and without a
 *  question about something they already named ("cooked in a little butter" -> no "Cooked in butter?"). */
export function honour(est: MealEstimate, words: string): MealEstimate {
  const named = new Set([...words.matchAll(EXTRAS)].map((m) => m[1].toLowerCase()));
  if (est.question && [...est.question.text.matchAll(EXTRAS)].some((m) => named.has(m[1].toLowerCase()))) est = { ...est, question: null };
  const no = saidNo(words);
  if (!no.length) return est;
  const hit = (t: string) => no.some((w) => new RegExp(`\\b${w}`, "i").test(t));
  const items = est.items.filter((it) => !hit(it.food));
  const question = est.question && (hit(est.question.text) || est.question.options.some((o) => hit(o.label))) ? null : est.question;
  return { ...est, items: items.length ? items : est.items, question };
}

/** An item that matched a remembered food takes that food's numbers (times servings): the memory wins over a fresh guess. */
export function remembered(items: MealItem[], tables: TableStore): MealItem[] {
  return items.map((it) => {
    if (!it.memory) return it;
    const t = tables.tables[MEMORY_TABLE]?.rows[it.memory] ? tables.tables[MEMORY_TABLE] : tables.tables.foods;
    const r = t?.rows[it.memory];
    if (!r) return { ...it, memory: undefined };
    const x = it.servings ?? 1;
    return { ...it, cal: whole(num(r.Cal) * x), protein: whole(num(r.Protein) * x), carbs: whole(num(r.Carbs) * x), fat: whole(num(r.Fat) * x) };
  });
}

// ---------- writing it down ----------

/** Breakfast, lunch, snack or dinner: the one they named, or from the person's local time. */
export function mealName(now: string, words = ""): string {
  const said = words.match(/\b(breakfast|brunch|lunch|dinner|supper|snack|dessert)\b/i)?.[1].toLowerCase();
  if (said) return said === "supper" ? "Dinner" : said === "brunch" ? "Breakfast" : said[0].toUpperCase() + said.slice(1);
  const [h, m] = now.slice(11, 16).split(":").map(Number);
  const t = h * 60 + m;
  if (t < 4 * 60) return "Snack";
  if (t < 10 * 60 + 30) return "Breakfast";
  if (t < 15 * 60) return "Lunch";
  if (t < 17 * 60) return "Snack";
  if (t < 21 * 60 + 30) return "Dinner";
  return "Snack";
}

export const slug = (s: string) => s.toLowerCase().replace(/&/g, " and ").replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 48) || "food";

/** Makes sure the meals log and the food memory exist (a blank agent, or one made before tables). */
export function ensureTables(store: TableStore): TableStore {
  let s = store;
  if (!s.tables[MEALS_TABLE]) s = write(s, { op: "table", name: MEALS_TABLE, cols: MEALS_COLS }).store;
  if (!s.tables[MEMORY_TABLE]) s = write(s, { op: "table", name: MEMORY_TABLE, cols: MEMORY_COLS }).store;
  return s;
}

/** The meal's rows in the log and each food in the person's memory. Returns the new store and the meal's row keys. */
export function logMeal(store: TableStore, est: MealEstimate, id: string, clk: Clock, words = ""): { store: TableStore; keys: string[]; meal: string } {
  let s = ensureTables(store);
  const meal = mealName(clk.now, words);
  const keys: string[] = [];
  est.items.forEach((it, i) => {
    const key = `${id}-${i + 1}`;
    const r = write(s, { op: "put", table: MEALS_TABLE, key, values: { Day: clk.today, Meal: meal, Food: it.food, Portion: it.portion,
                                                                     Cal: it.cal, Protein: it.protein, Carbs: it.carbs, Fat: it.fat } }, clk);
    if (!r.error) {
      s = r.store;
      keys.push(key);
    }
    // The food memory: a remembered food counts once more; a new one is kept for one serving of what was seen.
    const mem = s.tables[MEMORY_TABLE];
    const k = it.memory && mem.rows[it.memory] ? it.memory : slug(it.food);
    const had = mem.rows[k];
    const x = it.servings ?? 1;
    const values: Record<string, unknown> = had
      ? { Times: num(had.Times) + 1, Last: clk.today }
      : { Food: it.food, Portion: x === 1 ? it.portion : `${it.portion} (per ${x})`, Cal: whole(it.cal / x), Protein: whole(it.protein / x),
          Carbs: whole(it.carbs / x), Fat: whole(it.fat / x), Times: 1, Last: clk.today };
    const m = write(s, { op: "put", table: MEMORY_TABLE, key: k, values }, clk);
    if (!m.error) s = m.store;
  });
  return { store: s, keys, meal };
}

export interface Totals { cal: number; protein: number; carbs: number; fat: number }

export function total(items: { cal: number; protein: number; carbs: number; fat: number }[]): Totals {
  return items.reduce((a, b) => ({ cal: a.cal + b.cal, protein: a.protein + b.protein, carbs: a.carbs + b.carbs, fat: a.fat + b.fat }),
                      { cal: 0, protein: 0, carbs: 0, fat: 0 });
}

/** Today's rows in the log, added up. */
export function today(store: TableStore, clk: Clock): Totals & { meals: number } {
  const t = store.tables[MEALS_TABLE];
  const rows = t ? t.order.map((k) => t.rows[k]).filter((r) => r.Day === clk.today) : [];
  const sum = total(rows.map((r) => ({ cal: num(r.Cal), protein: num(r.Protein), carbs: num(r.Carbs), fat: num(r.Fat) })));
  return { ...sum, meals: new Set(rows.map((r) => r.Meal)).size };
}

const q = (s: string) => `"${s.replace(/\\/g, "").replace(/"/g, "'").replace(/\|/g, "/").replace(/[–—]/g, ",")}"`;
const kcal = (n: number) => n.toLocaleString("en-US");
/** One table row: each cell without quotes or pipes, joined by pipes, quoted once. */
const tr = (...cells: (string | number)[]) => `"${cells.map((c) => String(c).replace(/["\\|]/g, "").replace(/[\u2013\u2014]/g, ",")).join("|")}"`;

/**
 * The breakdown, one reply, two pages on the stage at most: the meal (a line and
 * a table of every item with its calories and macros, a total row last), then
 * today so far (a line and one chart). The question, when there is one, waits
 * after the last page as a `choose`.
 */
export function breakdown(est: MealEstimate, id: string, meal: string, day: Totals & { meals: number }): string {
  const sum = total(est.items);
  const head = `${est.title}, about ${kcal(sum.cal)} kcal. ${est.sure}`.trim();
  // Five columns on a phone: the food's name only (its portion stays in the log), cut short, so every macro shows.
  const rows = est.items.map((it) => tr(short(it.food), it.cal, it.protein, it.carbs, it.fat));
  rows.push(tr("Total", sum.cal, sum.protein, sum.carbs, sum.fat));
  const lines = [
    `say ${q(head)}`,
    `table@meal-${id} name=${q(`${meal}: ${est.title}`)} Food|Cal|Prot|Carb|Fat ${rows.join(" ")} units=|kcal|g|g|g`,
    `say ${q(`Today so far: ${kcal(day.cal)} kcal, ${day.protein} g protein, ${day.carbs} g carbs, ${day.fat} g fat.`)}`,
    `chart donut "Today's macros, grams" x=Protein|Carbs|Fat y=${day.protein}|${day.carbs}|${day.fat}`,
  ];
  if (est.question) lines.push(`choose@fix-${id} ${q(est.question.text)} ${est.question.options.map((o) => q(o.label)).join("|")}`);
  return `${"```yui"}\n${lines.join("\n")}\n${"```"}`;
}

/** A food's name for a narrow table, 12 characters at most so every macro column shows: before any comma, bracket,
 *  slash, "and" or "with"; then the last words, where the food's own name sits ("Whole wheat toast" -> "Wheat toast",
 *  "Cherry tomatoes" -> "Tomatoes"), never a word cut in half unless one word is all there is. */
export function short(food: string): string {
  const head = food.split(/[,(/]|\s+(?:and|with|&)\s+/i)[0].trim() || food.trim();
  const words = head.split(/\s+/);
  while (words.length > 1 && words.join(" ").length > 12) words.shift();
  const name = words.join(" ");
  return (name.length > 12 ? name.slice(0, 12) : name).replace(/^./, (c) => c.toUpperCase());
}

/** Not a meal: say so, and offer the camera again. */
export function notFood(est: MealEstimate | null): string {
  const why = est?.sure ? ` ${est.sure.replace(/\.?$/, ".")}` : "";
  return "```yui\n" + `say ${q(`That doesn't look like a meal to log.${why}`)}\n` + `camera@plate "Snap your meal" +inline\n` + "```";
}

// ---------- the one question, answered with no model turn ----------

const FIX_TAP = /^\[yui\]\s+fix-([A-Za-z0-9]+)\s+choose\b.*?\bchoice=(?:"((?:[^"\\]|\\.)*)"|(\S+))/i;

export interface MealFix { id: string; meal: string; title: string; question: string; options: MealOption[]; keys: string[] }

/** A tap on a meal's question: finds the question in the thread, adds what the answer adds to the log. */
export function applyFix(store: TableStore, fix: MealFix, choice: string, clk: Clock): { store: TableStore; body: string } {
  const o = fix.options.find((x) => x.label.toLowerCase() === choice.toLowerCase());
  if (!o) return { store, body: "That question has changed. Tell me what to fix and I'll update the log." };
  const t = store.tables[MEALS_TABLE];
  const rows = t ? fix.keys.map((k) => t.rows[k]).filter(Boolean) : [];
  let s = store;
  if (o.cal || o.protein || o.carbs || o.fat) {
    const r = write(s, { op: "put", table: MEALS_TABLE, key: `${fix.id}-fix`, values: {
      Day: rows[0]?.Day ?? clk.today, Meal: rows[0]?.Meal ?? mealName(clk.now), Food: `${fix.question.replace(/\?$/, "")}: ${o.label}`,
      Portion: o.label, Cal: o.cal, Protein: o.protein, Carbs: o.carbs, Fat: o.fat } }, clk);
    if (!r.error) s = r.store;
  } else if (t?.rows[`${fix.id}-fix`]) {
    const r = write(s, { op: "put", table: MEALS_TABLE, key: `${fix.id}-fix`, delete: true });
    if (!r.error) s = r.store;
  }
  const meal = s.tables[MEALS_TABLE];
  const now = meal ? [...fix.keys, `${fix.id}-fix`].map((k) => meal.rows[k]).filter(Boolean) : [];
  const sum = total(now.map((r) => ({ cal: num(r.Cal), protein: num(r.Protein), carbs: num(r.Carbs), fat: num(r.Fat) })));
  const day = today(s, clk);
  const said = o.cal ? `${o.label}: ${o.cal > 0 ? "+" : ""}${o.cal} kcal.` : `${o.label}. Nothing to add.`;
  const body = "```yui\n" + [
    `say ${q(`${said} ${fix.title} is ${kcal(sum.cal)} kcal.`)}`,
    `table@meal-${fix.id} name=${q(`${fix.meal}: ${fix.title}`)} Food|Cal|Prot|Carb|Fat ${tr("Meal", sum.cal, sum.protein, sum.carbs, sum.fat)} ${tr("Today", day.cal, day.protein, day.carbs, day.fat)} units=|kcal|g|g|g`,
  ].join("\n") + "\n```";
  return { store: s, body };
}

/** The meal-question taps in a turn, and the rest of the rows. */
export function fixTaps(rows: Row[]): { taps: { row: Row; id: string; choice: string }[]; rest: Row[] } {
  const taps: { row: Row; id: string; choice: string }[] = [];
  const rest: Row[] = [];
  for (const r of rows) {
    const m = (r.body ?? "").match(FIX_TAP);
    if (m) taps.push({ row: r, id: m[1], choice: (m[2] ?? m[3]).replace(/\\(.)/g, "$1") });
    else rest.push(r);
  }
  return { taps, rest };
}

// ---------- the job ----------

export interface JobDeps {
  ask: (req: Record<string, unknown>) => Promise<{ text: string }>;
  route: (hasPhoto: boolean) => string; // the model id
  inline?: (messages: any[]) => Promise<any[] | null>; // photo bytes, when the provider can't fetch the link
  log: (m: string) => void;
  now: () => number;
  say: (agent: NativeAgent, body: string, meta: Record<string, unknown>) => Promise<string>;
  budget: (userId: string) => Promise<boolean>; // takes a turn from the free month; false when used up
}

/** Runs one meal job: estimate, log, one breakdown reply. Returns the reply ids. */
export async function runMealJob(store: Store, job: JobItem, deps: JobDeps): Promise<{ replies: string[]; result: Record<string, unknown> }> {
  const agent = await store.agent(job.agentId);
  if (!agent) return { replies: [], result: { gone: true } };
  const tz = validZone(await store.timezone(agent.userId));
  const clk = clock(deps.now(), tz);
  const tables0 = await store.tables(agent.id);
  const replies: string[] = [];
  if (!(await deps.budget(agent.userId))) {
    replies.push(await deps.say(agent, "That's your free turns for this month, so I couldn't work out that meal. Add your own model key in Settings to keep going.",
                                { native: { meal: job.id, limit: true } }));
    return { replies, result: { limit: true } };
  }
  const ms: Record<string, number> = {};
  let t = deps.now();
  const lap = (k: string) => { const n = deps.now(); ms[k] = (ms[k] ?? 0) + n - t; t = n; };
  const image = job.input.photo ? await store.signMedia(job.input.photo) : null;
  lap("sign");
  const words = job.input.words ? `They said: "${job.input.words.replace(/"/g, "'")}"` : "They said nothing with it.";
  const user: any = image
    ? [{ type: "text", text: `The meal is in the photo. ${words}` }, { type: "image_url", image_url: { url: image } }]
    : `No photo: the meal is in their words. ${words}`;
  const messages = [{ role: "system", content: `${MEAL_PROMPT}\n\n${memoryLines(tables0)}` }, { role: "user", content: user }];
  const model = deps.route(!!image);
  let est: MealEstimate | null = null;
  let tries = 0;
  let msgs = messages;
  while (!est && tries < 2) {
    tries++;
    let text: string;
    try {
      text = (await deps.ask({ model, messages: msgs, max_tokens: 1200 })).text;
    } catch (e) {
      const inlined = image && deps.inline ? await deps.inline(msgs) : null;
      if (!inlined) throw e;
      deps.log(`meal: the model couldn't fetch the photo (${(e as Error)?.message ?? e}), sending it inline`);
      ms.inline = 1;
      msgs = inlined;
      text = (await deps.ask({ model, messages: msgs, max_tokens: 1200 })).text;
    }
    lap(`model${tries}`);
    est = parseEstimate(text);
    if (!est) msgs = [...msgs, { role: "assistant", content: text }, { role: "user", content: "That wasn't the JSON. Answer with the JSON object only." }];
  }
  if (!est || !est.food) {
    replies.push(await deps.say(agent, notFood(est), { native: { meal: job.id, model, food: false } }));
    return { replies, result: { food: false, ms } };
  }
  est = honour({ ...est, items: remembered(est.items, tables0) }, job.input.words);
  const id = job.id.replace(/[^A-Za-z0-9]/g, "").slice(-10); // the random end of the id: meal row keys never collide
  const logged = logMeal(tables0, est, id, clk, `${job.input.words} ${job.input.said ?? ""}`);
  const ch = diff(tables0, logged.store);
  if (changed(ch)) await store.saveTables(agent, ch, logged.store);
  const day = today(logged.store, clk);
  const body = breakdown(est, id, logged.meal, day);
  const fix: MealFix | undefined = est.question
    ? { id, meal: logged.meal, title: est.title, question: est.question.text, options: est.question.options, keys: logged.keys } : undefined;
  replies.push(await deps.say(agent, body, { native: { model, meal: job.id, ...(fix ? { mealfix: fix } : {}) },
                                             ...(job.input.rowId ? { turn: [job.input.rowId] } : {}) }));
  const sum = total(est.items);
  deps.log(`meal ${id}: ${est.items.length} item(s), ${sum.cal} kcal, ${est.question ? "one question" : "no question"}`);
  lap("write");
  return { replies, result: { items: est.items.length, cal: sum.cal, question: !!est.question, ms } };
}
