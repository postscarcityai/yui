// Copied from runtime/src/planner.ts by runtime/scripts/build.mjs. Do not edit here.
// Penny's tools (YUI-185): plan my week by voice, the today list, reminders,
// the evening review, and her default screens (Today, This week), kept current
// with patches.
//
// Chris (Sep 28): "we should focus the next stories on getting the crew more
// tools up with detailed flows... i want the agents to have default screens."
//
// Every tool here is answered by the runtime itself, with no model turn and no
// free turn spent, because the data is already in Penny's tables:
//
// 1. Plan my week: the shortcut, "Plan my week" or the Plan again button. One
//    full-screen `plan`: how it works and what is already on the week, then a
//    brain dump by mic (talk it out, or type), then the questions last (full
//    days, how many things a day, what is still open, reminders), one Send. The
//    Send reads the dump into tasks (a day and a time when they said one),
//    sorts the rest into the lightest days, and lands as the This week timeline.
// 2. The today list: today's open tasks, the next one big on Today with a Done
//    button. A tick on the list sets Done and patches the pages; "What's next
//    today?" is answered from the table.
// 3. Reminders: a task with a time keeps a row in `reminders` (at the time, or
//    a few minutes before), which the app turns into a local notification. The
//    reply that changes them carries them in meta.native.reminders.
// 4. The evening review: a short plan, what got done, then each task still
//    open today: done, tomorrow or drop, and how the day went, one Send.
// 5. The screens: >2 Today (the next task, the list, the review) and >3 This
//    week (a timeline by day with Edit order, Move a task, Plan again).
import type { NativeAgent, Row } from "./types.ts";
import { type Cell, type Clock, type TableSeed, type TableStore, write } from "./tables.ts";
import { readEvent, shift } from "./workouts.ts";

/** Agents with these tools: Penny and any copy of her (a fork keeps base penny). */
export function plansWeeks(agent: NativeAgent): boolean {
  return agent.profile.base === "penny";
}

export const TASKS = "tasks";
export const REMINDERS = "reminders";
export const REVIEWS = "reviews";
export const PREFS = "week_prefs";
export const TOOL_TABLES = [TASKS, REMINDERS, REVIEWS, PREFS];

const WEEKDAY = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

/** The plan's questions: the options each shows. The full days are the coming week's day names. */
export const PACE_OPTS = ["2 or 3", "3 to 5", "As many as fit"];
export const CARRY_OPTS = ["Bring them in", "Leave them"];
export const REMIND_OPTS = ["10 minutes before", "At the time", "No reminders"];
export const REVIEW_OPTS = ["Done", "Tomorrow", "Drop"];
export const FEEL_OPTS = ["Great", "Okay", "Rough"];
const PACE_CAP: Record<string, number> = { "2 or 3": 3, "3 to 5": 5, "As many as fit": 8 };

// ---------- small helpers ----------

const q = (s: string) => `"${String(s).replace(/\\/g, "").replace(/"/g, "'").replace(/\|/g, "/").replace(/[–—]/g, ",").replace(/\n/g, " ")}"`;
const opts = (xs: string[]) => xs.map(q).join("|");
const num = (v: Cell | undefined | unknown) => (typeof v === "number" ? v : Number(v) || 0);
export const slug = (s: string) => s.toLowerCase().normalize("NFKD").replace(/&/g, " and ").replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 32).replace(/-$/, "") || "task";
const rowsOf = (store: TableStore, name: string) => {
  const t = store.tables[name];
  return t ? t.order.map((key) => ({ key, row: t.rows[key] })) : [];
};
const list = (v: unknown): string[] => (Array.isArray(v) ? v.map(String) : typeof v === "string" && v ? v.split("|") : []);
function weekday(day: string): string {
  const [y, m, d] = day.split("-").map(Number);
  return WEEKDAY[new Date(Date.UTC(y, m - 1, d)).getUTCDay()];
}
const minutesOf = (hhmm: string) => {
  const [h, m] = hhmm.split(":").map(Number);
  return (h || 0) * 60 + (m || 0);
};
const nowMinutes = (clk: Clock) => minutesOf(clk.now.slice(11, 16));
/** "09:30" as "9:30 am". */
export function clockText(hhmm: string): string {
  const [h, m] = hhmm.split(":").map(Number);
  const ap = h >= 12 ? "pm" : "am";
  const h12 = h % 12 || 12;
  return `${h12}:${String(m || 0).padStart(2, "0")} ${ap}`;
}
/** A day as the week shows it: Today, Tomorrow, then Wed. */
export function dayLabel(day: string, clk: Clock): string {
  if (!day) return "Any day";
  if (day === clk.today) return "Today";
  if (day === shift(clk.today, 1)) return "Tomorrow";
  return weekday(day).slice(0, 3);
}
/** A day in a sentence: today, tomorrow, or Wednesday. */
export function dayWord(day: string, clk: Clock): string {
  return day === clk.today ? "today" : day === shift(clk.today, 1) ? "tomorrow" : day ? weekday(day) : "any day";
}
const joinWords = (xs: string[]) => (xs.length < 2 ? xs.join("") : `${xs.slice(0, -1).join(", ")} and ${xs[xs.length - 1]}`);

// ---------- the tables ----------

const TASK_COLS = [{ name: "Task", type: "text" }, { name: "Due", type: "date" }, { name: "Time", type: "text" }, { name: "Priority", type: "text" },
                   { name: "Done", type: "bool" }, { name: "Status", type: "text" }, { name: "Order", type: "number" }] as const;

/**
 * Makes sure Penny's tool tables exist and `tasks` has its Time, Status and Order columns. A Penny added before
 * YUI-185 has `tasks` with Task, Due, Priority and Done: those rows stay as they are, the new columns are added.
 */
export function ensureTools(store: TableStore, seeds: TableSeed[] | undefined, always = false): TableStore {
  // On a plain turn only a Penny who still has her tasks is brought up to date: tables they deleted stay deleted
  // until they use one of her tools.
  if (!always && !store.tables[TASKS]) return store;
  let out = store;
  for (const name of TOOL_TABLES) {
    const seed = seeds?.find((s) => s.name === name);
    const cols = seed?.cols ?? (name === TASKS ? TASK_COLS.map((c) => ({ ...c })) : undefined);
    if (!cols) continue;
    const had = out.tables[name];
    if (had && cols.every((c) => had.cols.some((h) => h.name === c.name))) continue;
    // Their own columns stay after ours, so nothing they wrote is lost.
    const merged = had ? [...cols, ...had.cols.filter((h) => !cols.some((c) => c.name === h.name))].slice(0, 12) : cols;
    const r = write(out, { op: "table", name, cols: merged as any });
    if (!r.error) out = r.store;
  }
  return out;
}

export interface Task { key: string; task: string; due: string; time: string; priority: string; done: boolean; dropped: boolean; order: number }

export function tasks(store: TableStore): Task[] {
  return rowsOf(store, TASKS).filter(({ row }) => row?.Task).map(({ key, row }, i) => ({
    key, task: String(row.Task), due: String(row.Due ?? "").slice(0, 10), time: /^\d{2}:\d{2}$/.test(String(row.Time ?? "")) ? String(row.Time) : "",
    priority: String(row.Priority ?? ""), done: row.Done === true, dropped: /^dropped$/i.test(String(row.Status ?? "")),
    order: row.Order == null ? 1000 + i : num(row.Order),
  }));
}
const open = (t: Task) => !t.done && !t.dropped;
/** Within a day: their order, and a timed task at its time among the untimed ones. */
const byOrder = (a: Task, b: Task) => a.order - b.order || a.time.localeCompare(b.time);
const byDay = (a: Task, b: Task) => (a.due || "9999").localeCompare(b.due || "9999") || byOrder(a, b);

/** Today's open tasks, in order; what's left over from earlier days comes first. */
export function todayTasks(store: TableStore, clk: Clock): Task[] {
  return tasks(store).filter((t) => open(t) && t.due && t.due <= clk.today).sort(byDay);
}

/** The next thing to do today: the first open task whose time hasn't gone by more than an hour. */
export function nextTask(store: TableStore, clk: Clock): Task | undefined {
  const at = nowMinutes(clk);
  const today = todayTasks(store, clk);
  return today.find((t) => !t.time || t.due < clk.today || minutesOf(t.time) + 60 >= at) ?? today[0];
}

/** The week from today: open tasks by day (no day last), and what got done in it. */
export function weekTasks(store: TableStore, clk: Clock): { done: Task[]; queue: Task[] } {
  const all = tasks(store);
  const end = shift(clk.today, 6);
  const done = all.filter((t) => t.done && t.due && t.due >= shift(clk.today, -6) && t.due <= end).sort(byDay).slice(-5);
  const queue = all.filter((t) => open(t) && (!t.due || t.due <= end)).sort(byDay);
  return { done, queue };
}

// ---------- the brain dump ----------

export interface Said { task: string; day?: string; time?: string; priority?: string }

const DAY_RE = /\b(?:(?:on|by|this|next|for)\s+)?(today|tonight|tomorrow|tmrw|(?:this\s+)?weekend|mon(?:day)?|tue(?:s(?:day)?)?|wed(?:nesday)?|thu(?:r(?:s(?:day)?)?)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?)\b/i;
const TIME_RE = /\b(?:at\s+|@\s*|around\s+|by\s+)?(\d{1,2})(?::(\d{2}))?\s*(a\.?m\.?|p\.?m\.?)(?=\s|$|[,.!?])|\b(?:at|around|@)\s*(\d{1,2})(?::(\d{2}))?\b(?!\s*(?:minutes?|hours?|mins?|%))|\b(?:at\s+)?(noon|midnight)\b/i;
const FILLER = /^(?:(?:and|also|then|so|oh|um+|uh+|okay|ok|well|plus|like|first|second|third|finally|next|after that|i guess|i think|maybe|probably)[\s,]+|(?:i|we)\s+(?:need|have|gotta|got|want|should|must|ought|'?d like|would like)\s+(?:to\s+)?|(?:i|we)'?ll\s+|(?:i|we)'?m\s+(?:going\s+to\s+|gonna\s+)?|gotta\s+|gonna\s+|remember\s+to\s+|don'?t\s+forget\s+(?:to\s+)?|need\s+to\s+|have\s+to\s+|got\s+to\s+|should\s+|must\s+|to\s+)+/i;
const NOT_TASKS = /^(?:that'?s it|that is it|thanks?|thank you|nothing|done|hmm+|yeah|yes|no|ok(?:ay)?|so|and|the|a|this week|my week)$/i;

/** The next date for a day word, from today (today counts): "tuesday" on a Monday is tomorrow. */
export function dayOf(word: string, clk: Clock): string | undefined {
  const w = word.toLowerCase().replace(/^(?:on|by|this|next|for)\s+/, "").trim();
  if (w === "today" || w === "tonight") return clk.today;
  if (w === "tomorrow" || w === "tmrw") return shift(clk.today, 1);
  const idx = /weekend/.test(w) ? 6 : WEEKDAY.findIndex((d) => d.toLowerCase().startsWith(w.slice(0, 3)));
  if (idx < 0) return undefined;
  for (let i = 0; i < 7; i++) {
    const d = shift(clk.today, i);
    if (WEEKDAY.indexOf(weekday(d)) === idx) return d;
  }
  return undefined;
}

/** "3", "3:30 pm", "noon" as "15:00". A bare hour reads as the waking day: 7 to 11 morning, 12 to 6 afternoon. */
function timeOf(m: RegExpMatchArray): string | undefined {
  if (m[6]) return m[6].toLowerCase() === "noon" ? "12:00" : "00:00";
  let h = Number(m[1] ?? m[4]);
  const mi = Number(m[2] ?? m[5] ?? 0);
  if (!(h >= 0 && h <= 23) || mi > 59) return undefined;
  const ap = (m[3] ?? "").toLowerCase().replace(/\./g, "");
  if (ap === "pm" && h < 12) h += 12;
  else if (ap === "am" && h === 12) h = 0;
  else if (!ap && h >= 1 && h <= 6) h += 12;
  return `${String(h).padStart(2, "0")}:${String(mi).padStart(2, "0")}`;
}

/** One thing said, as a task: its day and time taken out of the words. */
export function readTask(words: string, clk: Clock): Said | null {
  let w = ` ${words.trim()} `;
  const out: Said = { task: "" };
  const d = w.match(DAY_RE);
  if (d) {
    out.day = dayOf(d[1], clk);
    w = w.replace(d[0], " ");
  }
  const t = w.match(TIME_RE);
  if (t) {
    let at = timeOf(t);
    // "tonight at 7:30", "7 in the evening": the evening one.
    if (at && !t[3] && !t[6] && Number(at.slice(0, 2)) < 12 && /\b(?:tonight|evening|night|afternoon)\b/i.test(`${words} ${d?.[0] ?? ""}`)) {
      at = `${String(Number(at.slice(0, 2)) + 12).padStart(2, "0")}${at.slice(2)}`;
    }
    if (at) {
      out.time = at;
      w = w.replace(t[0], " ");
    }
  }
  if (/\b(?:urgent|asap|important|top priority|first thing)\b|!$/i.test(w)) {
    out.priority = "High";
    w = w.replace(/\b(?:it'?s\s+)?(?:urgent|asap|important|top priority)\b/gi, " ");
  }
  let task = w.replace(/\s+/g, " ").trim().replace(FILLER, "").replace(/\b(?:in the (?:morning|afternoon|evening)|this (?:morning|afternoon|evening))\b/gi, "")
    .replace(/\s+/g, " ").replace(/^[\s,.;:!?-]+|[\s,.;:!?-]+$/g, "").trim();
  task = task.replace(FILLER, "").trim();
  if (task.length < 3 || NOT_TASKS.test(task)) return null;
  out.task = (task[0].toUpperCase() + task.slice(1)).slice(0, 80);
  return out;
}

/** A brain dump as things to do: one a sentence, a line, a comma or an "and then". */
export function readDump(text: string, clk: Clock): Said[] {
  const parts = String(text ?? "").replace(/\s+(?:and\s+)?then\s+/gi, "\n").replace(/\s+also\s+/gi, "\n")
    .split(/\s*(?:\n|;|,\s*(?:and\s+)?|(?<=[a-z0-9)])[.!?]+(?:\s+|$)|\s+and\s+(?=(?:i\s+|call|email|text|buy|get|pick|drop|book|pay|send|finish|clean|fix|go|do|make|write|schedule|cancel|return|order|renew|take|meet|see|visit)\b))\s*/i)
    .map((p) => p.trim()).filter(Boolean);
  const out: Said[] = [];
  const seen = new Set<string>();
  for (const p of parts.slice(0, 30)) {
    // "..., it's urgent" is about the thing before it.
    if (/^(?:(?:it'?s|that'?s|this is)\s+)?(?:really\s+)?(?:urgent|asap|important|top priority)[.!]*$/i.test(p)) {
      if (out.length) out[out.length - 1].priority = "High";
      continue;
    }
    const s = readTask(p, clk);
    if (!s || seen.has(slug(s.task))) continue;
    seen.add(slug(s.task));
    out.push(s);
  }
  return out;
}

// ---------- what they asked for ----------

export interface Prefs { busy: string[]; pace: number; carry: boolean; remind: number | null; words: Record<string, string> }

/** The day names the week plan offers as full days: the next seven, from today. */
export function weekDays(clk: Clock): string[] {
  return Array.from({ length: 7 }, (_, i) => shift(clk.today, i));
}
const busyLabel = (day: string, clk: Clock) => (day === clk.today ? "Today" : weekday(day));

/** The plan's answers as what the planner needs. Unanswered questions take the easy default. */
export function readPrefs(a: Record<string, unknown>, clk: Clock): Prefs {
  const busyWords = list(a.busy).map((x) => x.trim().toLowerCase()).filter((x) => x && x !== "none");
  const busy = weekDays(clk).filter((d) => busyWords.includes(busyLabel(d, clk).toLowerCase()) || busyWords.includes(weekday(d).toLowerCase()));
  const pw = String(a.pace ?? "3 to 5");
  const pace = PACE_CAP[pw] ?? 5;
  const carry = !/leave/i.test(String(a.carry ?? ""));
  const r = String(a.remind ?? "10 minutes before");
  const remind = /no reminder/i.test(r) ? null : /at the time/i.test(r) ? 0 : parseInt(r, 10) || 10;
  return { busy, pace, carry, remind,
           words: { busy: busy.map((d) => weekday(d)).join(", ") || "None", pace: PACE_CAP[pw] ? pw : "3 to 5", carry: carry ? CARRY_OPTS[0] : CARRY_OPTS[1],
                    remind: remind == null ? REMIND_OPTS[2] : remind === 0 ? REMIND_OPTS[1] : `${remind} minutes before` } };
}

/** How early a reminder goes, from the last plan's answer: 10 minutes when they never said, null for none. */
export function remindLead(store: TableStore): number | null {
  const r = store.tables[PREFS]?.rows.last?.Remind;
  if (r == null) return 10;
  const s = String(r);
  return /no reminder/i.test(s) ? null : /at the time/i.test(s) ? 0 : parseInt(s, 10) || 10;
}

/** The brain dump from the plan's answer: a mic's words, a form's text box, or plain words. */
function dumpText(v: unknown): string {
  if (v && typeof v === "object") return Object.values(v as Record<string, unknown>).map(String).join("\n");
  return v == null ? "" : String(v);
}

// ---------- writing ----------

function putTask(store: TableStore, key: string, values: Record<string, unknown>, clk: Clock): TableStore {
  const w = write(store, { op: "put", table: TASKS, key, values }, clk);
  return w.error ? store : w.store;
}

/** A new key for a task, from its words; the same words again find the open task already there. */
function keyFor(store: TableStore, task: string): { key: string; had: boolean } {
  const base = slug(task);
  const all = tasks(store);
  const same = all.find((t) => t.key === base || slug(t.task) === base);
  if (same && open(same)) return { key: same.key, had: true };
  let key = base;
  for (let i = 2; store.tables[TASKS]?.rows[key]; i++) key = `${base.slice(0, 28)}-${i}`;
  return { key, had: false };
}

/** The first day with room: not a full day, under the day's cap, not tonight when the evening's here. Once every
 *  day is at the cap, the lightest one. */
function lightest(load: Map<string, number>, days: string[], p: Prefs, clk: Clock): string {
  const late = nowMinutes(clk) >= 18 * 60;
  const ok = days.filter((d) => !p.busy.includes(d) && !(late && d === clk.today));
  const under = ok.find((d) => (load.get(d) ?? 0) < p.pace);
  if (under) return under;
  const pool = ok.length ? ok : days;
  return [...pool].sort((a, b) => (load.get(a) ?? 0) - (load.get(b) ?? 0) || a.localeCompare(b))[0];
}

/**
 * The Send: the brain dump read into tasks, a day for each (the day they said, else the lightest day that fits),
 * what's still open from before brought in when they said so, the answers kept, the reminders rebuilt.
 */
export function applyPlan(store: TableStore, answers: Record<string, unknown>, clk: Clock): { store: TableStore; added: Task[]; carried: number; prefs: Prefs } {
  const prefs = readPrefs(answers, clk);
  const days = weekDays(clk);
  let out = store;
  // Her starter to-do was "tell Penny what's on your mind": a plan does that.
  const starter = out.tables[TASKS]?.rows.t1;
  if (starter && /tell penny what'?s on your mind/i.test(String(starter.Task)) && starter.Done !== true) out = putTask(out, "t1", { Done: true, Status: "Done" }, clk); // no day: off every list
  const load = new Map<string, number>();
  for (const t of tasks(out)) if (open(t) && t.due >= clk.today) load.set(t.due, (load.get(t.due) ?? 0) + 1);
  const said = readDump(dumpText(answers.dump), clk);
  const added: string[] = [];
  // High first, then the order they said them in; a day they named is kept whatever the load.
  const ranked = [...said].sort((a, b) => (a.priority === "High" ? 0 : 1) - (b.priority === "High" ? 0 : 1));
  for (const s of ranked) {
    const { key } = keyFor(out, s.task);
    const day = s.day ?? lightest(load, days, prefs, clk);
    load.set(day, (load.get(day) ?? 0) + 1);
    // Order 500: after what the day already holds, timed ones by their time (renumber).
    const values: Record<string, unknown> = { Task: s.task, Due: day, Done: false, Status: "Open", Order: 500 };
    if (s.time) values.Time = s.time;
    if (s.priority) values.Priority = s.priority;
    out = putTask(out, key, values, clk);
    added.push(key);
  }
  let carried = 0;
  if (prefs.carry) {
    for (const t of tasks(out)) {
      if (!open(t) || added.includes(t.key) || (t.due && t.due >= clk.today)) continue;
      const day = lightest(load, days, prefs, clk);
      load.set(day, (load.get(day) ?? 0) + 1);
      out = putTask(out, t.key, { Due: day, Status: "Open" }, clk);
      carried++;
    }
  }
  out = renumber(out, clk);
  const w = write(out, { op: "put", table: PREFS, key: "last", values: { Busy: prefs.words.busy, Pace: prefs.words.pace, Carry: prefs.words.carry,
                                                                        Remind: prefs.words.remind, Planned: clk.today } }, clk);
  if (!w.error) out = w.store;
  out = syncReminders(out, clk);
  const byKey = new Map(tasks(out).map((t) => [t.key, t]));
  return { store: out, added: added.map((k) => byKey.get(k)!).filter(Boolean).sort(byDay), carried, prefs };
}

/** Order numbers 1, 2, 3 ... within each day: their order first; where that ties, timed tasks by their time, then the rest. */
export function renumber(store: TableStore, clk: Clock): TableStore {
  let out = store;
  const by: Record<string, Task[]> = {};
  for (const t of tasks(out)) if (open(t) && t.due >= clk.today) (by[t.due] ??= []).push(t);
  for (const day of Object.keys(by)) {
    const ts = by[day].map((t, i) => ({ t, i })).sort((a, b) => a.t.order - b.t.order || (a.t.time ? 0 : 1) - (b.t.time ? 0 : 1)
      || a.t.time.localeCompare(b.t.time) || a.i - b.i).map((x) => x.t);
    ts.forEach((t, i) => {
      if (t.order !== i + 1) out = putTask(out, t.key, { Order: i + 1 }, clk);
    });
  }
  return out;
}

/** Things added in words ("call mom tomorrow at 5"): on the day they said, else today (tomorrow once it's late). */
export function addTasks(store: TableStore, words: string, clk: Clock): { store: TableStore; added: Task[] } {
  let out = store;
  const keys: string[] = [];
  const late = nowMinutes(clk) >= 20 * 60;
  for (const s of readDump(words, clk)) {
    const { key } = keyFor(out, s.task);
    const day = s.day ?? (late ? shift(clk.today, 1) : clk.today);
    const last = tasks(out).filter((t) => open(t) && t.due === day).reduce((a, t) => Math.max(a, t.order < 1000 ? t.order : 0), 0);
    const values: Record<string, unknown> = { Task: s.task, Due: day, Done: false, Status: "Open", Order: last + 1 };
    if (s.time) values.Time = s.time;
    if (s.priority) values.Priority = s.priority;
    out = putTask(out, key, values, clk);
    keys.push(key);
  }
  out = syncReminders(renumber(out, clk), clk);
  const byKey = new Map(tasks(out).map((t) => [t.key, t]));
  return { store: out, added: keys.map((k) => byKey.get(k)!).filter(Boolean) };
}

/** A task as the today list shows it, which is also what its tick sends back. */
export const taskLabel = (t: Task) => (t.time ? `${t.task}, ${clockText(t.time)}` : t.task);
const findTask = (store: TableStore, label: string) => {
  const want = label.toLowerCase().trim();
  return tasks(store).find((t) => taskLabel(t).toLowerCase() === want || t.task.toLowerCase() === want || t.key === label);
};

/** A tick on the today list (or Done on the next task): Done on, or off again. */
export function tickTask(store: TableStore, label: string, done: boolean, clk: Clock): { store: TableStore; task?: Task } {
  const t = findTask(store, label);
  if (!t) return { store };
  const out = syncReminders(putTask(store, t.key, { Done: done, Status: done ? "Done" : "Open", ...(done && !t.due ? { Due: clk.today } : {}) }, clk), clk);
  return { store: out, task: t };
}

/**
 * Edit order saved on the timeline: the queue in its new order. Each place in the line keeps its day, so a task
 * dragged up among Tuesday's takes a Tuesday place and the day's last one moves on to the next.
 */
export function applyOrder(store: TableStore, order: string[], clk: Clock): { store: TableStore; moved: Task[] } {
  const queue = weekTasks(store, clk).queue;
  const slots = queue.map((t) => t.due);
  const byKey = new Map(queue.map((t) => [t.key, t]));
  const keys = [...order.map(String).filter((k) => byKey.has(k)), ...queue.map((t) => t.key).filter((k) => !order.map(String).includes(k))];
  let out = store;
  const moved: Task[] = [];
  keys.forEach((k, i) => {
    const t = byKey.get(k)!;
    const day = slots[i] ?? t.due;
    if (day !== t.due) moved.push({ ...t, due: day });
    out = putTask(out, k, { ...(day ? { Due: day } : { Due: null }), Order: i + 1 }, clk);
  });
  return { store: syncReminders(out, clk), moved };
}

/** Move a task (the Move flow's Send): to the day picked, at the end of that day. */
export function applyMove(store: TableStore, answers: Record<string, unknown>, clk: Clock): { store: TableStore; task?: Task; day?: string } {
  const label = String(answers.task ?? "");
  const t = weekTasks(store, clk).queue.find((x) => moveLabel(x, clk) === label) ?? findTask(store, label.split(",")[0]);
  const dayWord = String(answers.day ?? "");
  const day = weekDays(clk).find((d) => moveDay(d, clk) === dayWord) ?? dayOf(dayWord, clk);
  if (!t || !day) return { store };
  const last = tasks(store).filter((x) => open(x) && x.due === day && x.key !== t.key).reduce((a, x) => Math.max(a, x.order < 1000 ? x.order : 0), 0);
  const out = syncReminders(renumber(putTask(store, t.key, { Due: day, Order: last + 1, Status: "Open" }, clk), clk), clk);
  return { store: out, task: t, day };
}

/** The evening review's Send: each task done, moved to tomorrow or dropped; the day kept in `reviews`. */
export function applyReview(store: TableStore, answers: Record<string, unknown>, clk: Clock): { store: TableStore; done: number; moved: number; dropped: number; felt: string } {
  let out = store;
  let done = 0, moved = 0, dropped = 0;
  const tomorrow = shift(clk.today, 1);
  for (const t of todayTasks(out, clk)) {
    const a = String(answers[`r-${t.key}`] ?? "");
    if (/^done$/i.test(a)) {
      out = putTask(out, t.key, { Done: true, Status: "Done", Due: clk.today }, clk);
      done++;
    } else if (/^tomorrow$/i.test(a)) {
      out = putTask(out, t.key, { Due: tomorrow, Order: 0, Status: "Open" }, clk);
      moved++;
    } else if (/^drop$/i.test(a)) {
      // Dropped stays in the table (she remembers it), off every list.
      out = putTask(out, t.key, { Status: "Dropped" }, clk);
      dropped++;
    }
  }
  const felt = FEEL_OPTS.includes(String(answers.feel)) ? String(answers.feel) : "";
  const finished = tasks(out).filter((t) => t.done && t.due === clk.today).length;
  const w = write(out, { op: "put", table: REVIEWS, key: clk.today, values: { Day: clk.today, Done: finished, Moved: moved, Dropped: dropped, ...(felt ? { Felt: felt } : {}) } }, clk);
  if (!w.error) out = w.store;
  out = syncReminders(renumber(out, clk), clk);
  return { store: out, done, moved, dropped, felt };
}

// ---------- reminders ----------

export interface Reminder { key: string; task: string; at: string; day: string; time: string }

/**
 * The reminders from the tasks: every open task with a time still to come, at the time or a few minutes before
 * (the last plan's answer). Done, dropped and moved tasks take theirs with them. The app schedules them.
 */
export function syncReminders(store: TableStore, clk: Clock): TableStore {
  let out = store;
  if (!out.tables[REMINDERS]) {
    out = write(out, { op: "table", name: REMINDERS, cols: [{ name: "Task", type: "text" }, { name: "Day", type: "date" }, { name: "Time", type: "text" },
                                                              { name: "At", type: "text" }, { name: "Lead", type: "number" }] }).store;
  }
  const lead = remindLead(out);
  const want = new Map<string, Record<string, unknown>>();
  if (lead != null) {
    for (const t of tasks(out)) {
      if (!open(t) || !t.due || !t.time) continue;
      const at = atMinus(t.due, t.time, lead);
      if (at <= clk.now) continue;
      want.set(t.key, { Task: t.task, Day: t.due, Time: t.time, At: at, Lead: lead });
    }
  }
  for (const { key } of rowsOf(out, REMINDERS)) if (!want.has(key)) out = write(out, { op: "put", table: REMINDERS, key, delete: true }).store;
  for (const [key, values] of want) {
    const had = out.tables[REMINDERS].rows[key];
    if (had && Object.entries(values).every(([k, v]) => had[k] === v)) continue;
    const w = write(out, { op: "put", table: REMINDERS, key, values }, clk);
    if (!w.error) out = w.store;
  }
  return out;
}

/** "2026-09-29" "09:00" less 10 minutes, as a local "2026-09-29T08:50". */
function atMinus(day: string, hhmm: string, lead: number): string {
  let m = minutesOf(hhmm) - lead;
  let d = day;
  while (m < 0) {
    m += 24 * 60;
    d = shift(d, -1);
  }
  return `${d}T${String(Math.floor(m / 60)).padStart(2, "0")}:${String(m % 60).padStart(2, "0")}`;
}

export function reminders(store: TableStore): Reminder[] {
  return rowsOf(store, REMINDERS).filter(({ row }) => row?.At).map(({ key, row }) => ({
    key, task: String(row.Task ?? ""), at: String(row.At), day: String(row.Day ?? "").slice(0, 10), time: String(row.Time ?? ""),
  })).sort((a, b) => a.at.localeCompare(b.at));
}

// ---------- the flows ----------

/** Plan my week: how it works and what's on the week first, the brain dump, the questions last, one Send. */
export function planBody(store: TableStore, clk: Clock): string {
  const { queue } = weekTasks(store, clk);
  const real = queue.filter((t) => !/tell penny what'?s on your mind/i.test(t.task));
  const older = tasks(store).filter((t) => open(t) && t.due && t.due < clk.today).length;
  const on = real.length ? `Already on it: ${joinWords(real.slice(0, 4).map((t) => t.task.toLowerCase()))}${real.length > 4 ? ` and ${real.length - 4} more` : ""}.` : "Nothing's on it yet.";
  const lines = [
    `plan@weekplan "Plan my week" submit="Plan my week"`,
    `page "Your week, out of your head" body=${q(`Talk it out: everything on your plate, in any order. Say a day or a time when there is one. I'll sort the rest into days, never more a day than you pick, and put it on a timeline you can drag around. ${on}`)}`,
    `mic@dump "Everything on your plate this week"`,
    `pick@busy "Any days already full?" ${opts(weekDays(clk).map((d) => busyLabel(d, clk)))} submit=Next`,
    `choose@pace "How many things a day?" ${opts(PACE_OPTS)}`,
    ...(older || real.length ? [`choose@carry ${q(older ? `${older} still open from before. Bring them in?` : "Keep what's already on the week?")} ${opts(CARRY_OPTS)}`] : []),
    `choose@remind "Remind you of timed things?" ${opts(REMIND_OPTS)}`,
  ];
  return `Let's get your week out of your head.\n\`\`\`yui\n${lines.join("\n")}\n\`\`\``;
}

/** The evening review: what got done first, then each task still open today, how the day went, one Send. */
export function reviewBody(store: TableStore, clk: Clock): string {
  const done = tasks(store).filter((t) => t.done && t.due === clk.today);
  const left = todayTasks(store, clk).slice(0, 8);
  const head = done.length
    ? `page ${q(`${done.length} done today`)} body=${q(left.length ? `Nice. ${left.length} still open: done, tomorrow or drop each one.` : "Everything on today is done. Nice.")} points=${opts(done.slice(0, 8).map((t) => t.task))}`
    : `page "Today" body=${q(left.length ? `${left.length} on today. Done, tomorrow or drop each one, and tomorrow starts clean.` : "Nothing was on today. Tell me how it went and I'll keep it.")}`;
  const lines = [
    `plan@review "Evening review" submit="Wrap up the day"`,
    head,
    ...left.map((t) => `choose@r-${t.key} ${q(taskLabel(t))} ${opts(REVIEW_OPTS)}`),
    `choose@feel "How did today go?" ${opts(FEEL_OPTS)}`,
  ];
  return `\`\`\`yui\n${lines.join("\n")}\n\`\`\``;
}

const moveLabel = (t: Task, clk: Clock) => `${t.task}, ${dayLabel(t.due, clk)}`;
const moveDay = (d: string, clk: Clock) => (d === clk.today ? "Today" : d === shift(clk.today, 1) ? "Tomorrow" : weekday(d));

/** Move a task: which one, then to which day, one Send. */
export function moveBody(store: TableStore, clk: Clock): string {
  const queue = weekTasks(store, clk).queue.slice(0, 10);
  if (!queue.length) return "Nothing's on your week to move yet. Tell me what's on it and I'll sort it into days.";
  const lines = [
    `plan@move "Move a task" submit="Move it"`,
    `choose@task "Which one?" ${opts(queue.map((t) => moveLabel(t, clk)))}`,
    `choose@day "To which day?" ${opts(weekDays(clk).map((d) => moveDay(d, clk)))}`,
  ];
  return `\`\`\`yui\n${lines.join("\n")}\n\`\`\``;
}

/** "Add a to-do" with nothing after it: a text box with a mic. */
export const ADD_BODY = "What is it? Say a day or a time if there is one.\n```yui\nform@todo-add \"Add a to-do\" task:voice! submit=Add\n```";

/** "What's next today?", answered from the table. */
export function nextText(store: TableStore, clk: Clock): string {
  const n = nextTask(store, clk);
  const today = todayTasks(store, clk);
  if (!n) {
    const done = tasks(store).filter((t) => t.done && t.due === clk.today).length;
    const tomorrow = tasks(store).filter((t) => open(t) && t.due === shift(clk.today, 1)).sort(byOrder)[0];
    if (done) return `Nothing left today, ${done} done. ${tomorrow ? `First up tomorrow: ${tomorrow.task.toLowerCase()}.` : "Enjoy the evening."}`;
    return `Nothing on today.${tomorrow ? ` First up tomorrow: ${tomorrow.task.toLowerCase()}.` : " Tell me what's on your mind and I'll sort your week."}`;
  }
  const rest = today.filter((t) => t.key !== n.key);
  const when = n.time ? ` at ${clockText(n.time)}` : "";
  const late = n.due < clk.today ? " (left over from before)" : "";
  return `Next: ${n.task}${when}${late}.${rest.length ? ` Then ${joinWords(rest.slice(0, 3).map((t) => t.task.toLowerCase()))}${rest.length > 3 ? ` and ${rest.length - 3} more` : ""}.` : " That's the last one today."}`;
}

// ---------- the screens ----------

const EMPTY_TODAY = "Nothing on today";

/** Today, as its page: the next task big with Done, the list with ticks, the evening review. */
export function todayScreen(store: TableStore, clk: Clock): string[] {
  const today = todayTasks(store, clk);
  const n = nextTask(store, clk);
  const done = tasks(store).filter((t) => t.done && t.due === clk.today).length;
  const hasPlan = planned(store);
  const rest = n ? today.filter((t) => t.key !== n.key).length : 0;
  const card = n
    ? `card@next-task ${q(n.task)} ${q(`${n.time ? `At ${clockText(n.time)}. ` : ""}${rest ? `${rest} more today after this.` : "The last one today."}`)} sub="Up next" cta="Done"`
    : hasPlan
      ? `card@next-task ${q(done ? "All done for today" : "Nothing on today")} ${q(done ? `${done} done. Wrap up the day and tomorrow starts clean.` : "Enjoy it, or add a to-do.")} sub="Up next" cta=${q(done ? "Evening review" : "Add a to-do")}`
      : `card@next-task "Nothing on today yet" "Tell me what's on your mind and I'll sort your week into days." sub="Up next" cta="Plan my week"`;
  const items = today.length ? today.map(taskLabel) : [done ? "Nothing left today" : EMPTY_TODAY];
  return [
    card,
    `list@today title=Today ${opts(items)} +check`,
    `card@wrap "Evening review" ${q(done ? `${done} done so far. Two minutes: done, tomorrow or drop.` : "Two minutes at the end of the day: done, tomorrow or drop.")} cta="Wrap up the day"`,
  ];
}

const rowId = (t: Task) => `wk-${t.key}`;
/** They have planned, or put a day on something. */
const planned = (store: TableStore) => !!store.tables[PREFS]?.rows.last || tasks(store).some((t) => t.due);

/** This week, as its page: a timeline by day (done, the Today mark, then what's queued), Move a task, Plan again. */
export function weekScreen(store: TableStore, clk: Clock): string[] {
  const { done, queue } = weekTasks(store, clk);
  const row = (kind: string, t: Task) => `${kind}@${rowId(t)} ${q(t.task)} at=${q(dayLabel(t.due, clk))}${t.time ? ` sub=${q(clockText(t.time))}` : ""} key=${t.key}`;
  const rows = [...done.map((t) => row("done", t)), ...queue.map((t) => row("next", t))];
  if (!queue.length) rows.push(`next@start "Your week goes here once you tell Penny what's on it" key=start`);
  return [
    `timeline@week "This week" mark=Today fold=12${queue.length > 1 ? " +reorder" : ""}`,
    ...rows,
    `card@week-move "Move a task" "Drag with Edit order, or pick a task and a day." cta="Move a task"`,
    planned(store) ? `card@week-plan "Plan again" "More on your plate? Talk it out and I'll fit it in." cta="Plan my week"`
      : `card@week-plan "Plan my week" "Talk it out: everything on your plate. I'll sort it into days." cta="Plan my week"`,
  ];
}

/** This week's shape: which rows it holds (and Edit order or not). A new or gone row redraws it; a row done, renamed
 *  or given another day is a patch in place (kind=done moves the Today mark on the phone). */
export function weekShape(store: TableStore, clk: Clock): string {
  return shapeOf(weekScreen(store, clk).join("\n"));
}
function shapeOf(text: string): string {
  const flag = /^timeline@week\b.*\+reorder/m.test(text) ? "R" : "T";
  return [flag, ...[...text.matchAll(/^(?:done|next)@([\w-]+)/gm)].map((m) => m[1]).sort()].join(",");
}
const shapeText = (week: string) => `v1;${week}`;

/**
 * The pages as the phone has them: the shape the runtime last drew, or for a Penny whose home is this one (YUI-185,
 * the next-task card is its mark) the pages that home drew. A home from before gets both pages drawn again once.
 */
export function drawnShape(p: { plannerScreens?: string; home?: string }): string | undefined {
  if (p.plannerScreens) return p.plannerScreens;
  if (!/\bcard@next-task\b/.test(p.home ?? "")) return undefined;
  return shapeText(shapeOf(p.home ?? ""));
}

export type Page = "today" | "week";

/**
 * The lines that keep Penny's pages current. The first time (a home from before YUI-185) both pages are drawn again;
 * after that This week is drawn again only when its rows changed, and otherwise only patches go, which never move
 * the person. Today's lines are always the same three, so Today is always a patch.
 */
export function screenLines(store: TableStore, clk: Clock, was: string | undefined, only: Page[] = ["today", "week"], redraw = false): { lines: string[]; shape: string } {
  const first = !was?.startsWith("v1;");
  const now = weekShape(store, clk);
  const patch = (lines: string[]) => lines.map((l) => l.replace(/^[a-z]+@/, "~"));
  const out: string[] = [];
  if (first || only.includes("today")) out.push(...(first ? [">2 clear", ">2", ...todayScreen(store, clk), "save today"] : patch(todayScreen(store, clk))));
  let kept = first ? now : was!.slice(3);
  if (first || only.includes("week")) {
    if (first || redraw || kept !== now) out.push(">3 clear", ">3", ...weekScreen(store, clk), "save this week");
    // A row's patch: its words, day, time and kind; the cards' words. The timeline line holds nothing that changes.
    else {
      out.push(...weekScreen(store, clk).filter((l) => /^(?:done|next|card)@/.test(l))
        .map((l) => { const k = l.match(/^(done|next)@/)?.[1]; return l.replace(/^[a-z]+@/, "~") + (k ? ` kind=${k}` : ""); }));
    }
    kept = now;
  }
  return { lines: out, shape: shapeText(kept) };
}

// ---------- taps and words ----------

export type PlanAsk =
  | { kind: "plan"; row: Row }
  | { kind: "planned"; row: Row; answers: Record<string, unknown> }
  | { kind: "next"; row: Row }
  | { kind: "add"; row: Row }
  | { kind: "added"; row: Row; words: string }
  | { kind: "tick"; row: Row; item: string; done: boolean }
  | { kind: "donenext"; row: Row }
  | { kind: "review"; row: Row }
  | { kind: "reviewed"; row: Row; answers: Record<string, unknown> }
  | { kind: "move"; row: Row }
  | { kind: "moved"; row: Row; answers: Record<string, unknown> }
  | { kind: "order"; row: Row; order: string[] };

const PLAN_WORDS = /^\s*(?:(?:please|can you|could you|help me|let'?s|i want to|i need to)\s+)?(?:plan|sort|organi[sz]e|map)\s+(?:out\s+)?(?:my|the|this|a)\s+week(?:\s+(?:out|ahead))?\s*(?:please|for me)?\s*[.!?]*\s*$/i;
const NEXT_WORDS = /^\s*(?:what'?s|what\s+is|whats)\s+(?:next|up\s+next|on|left)(?:\s+(?:for\s+)?(?:today|for\s+me(?:\s+today)?))?\s*\??\s*$|^\s*what\s+(?:do\s+i\s+have|should\s+i\s+do)\s+(?:next|today)(?:\s+today)?\s*\??\s*$|^\s*what'?s\s+on\s+my\s+(?:plate|list)\s+today\s*\??\s*$/i;
const ADD_COLON = /^\s*(?:please\s+)?add\s+(?:a\s+)?(?:to-?\s?do|task)\s*:?\s*(.*)$/is;
const ADD_WORDS = /^\s*(?:please\s+)?(?:add|put)\s+(.+?)\s+(?:to|on)\s+(?:my|the)\s+(?:to-?\s?dos?|to-?\s?do\s+list|list|tasks?|week|today)\s*[.!]*\s*$/i;
const REVIEW_WORDS = /^\s*(?:(?:let'?s\s+)?(?:do\s+(?:my|the|an?)\s+)?evening\s+review|review\s+(?:my|the)\s+day|wrap\s+up\s+(?:my|the)\s+day|end\s+of\s+(?:the\s+)?day\s+review|how\s+did\s+(?:my|the)\s+day\s+go)\s*[.!?]*\s*$/i;

/** The rows in a turn the runtime answers itself (planner words and taps), and the rest for the model. */
export function planAsks(rows: Row[]): { asks: PlanAsk[]; rest: Row[] } {
  const asks: PlanAsk[] = [];
  const rest: Row[] = [];
  for (const r of rows) {
    const body = r.body ?? "";
    const e = /^\[yui\]\s/.test(body) ? readEvent(r) : null;
    let a: PlanAsk | null = null;
    if (!e && r.kind !== "event") {
      const col = body.match(ADD_COLON);
      const add = body.match(ADD_WORDS);
      if (PLAN_WORDS.test(body)) a = { kind: "plan", row: r };
      else if (NEXT_WORDS.test(body)) a = { kind: "next", row: r };
      else if (REVIEW_WORDS.test(body)) a = { kind: "review", row: r };
      else if (col) a = col[1].trim() ? { kind: "added", row: r, words: col[1].trim() } : { kind: "add", row: r };
      else if (add) a = { kind: "added", row: r, words: add[1] };
    } else if (e) {
      const v = e.value;
      const plan = v.plan && typeof v.plan === "object" ? (v.plan as Record<string, unknown>) : null;
      if (e.preset === "plan" && e.id === "weekplan" && plan) a = { kind: "planned", row: r, answers: plan };
      else if (e.preset === "plan" && e.id === "review" && plan) a = { kind: "reviewed", row: r, answers: plan };
      else if (e.preset === "plan" && e.id === "move" && plan) a = { kind: "moved", row: r, answers: plan };
      else if (e.preset === "timeline" && e.id === "week" && Array.isArray(v.order)) a = { kind: "order", row: r, order: v.order.map(String) };
      else if (e.preset === "list" && e.id === "today" && typeof v.item === "string") {
        a = { kind: "tick", row: r, item: v.item, done: !(v.checked === false || v.checked === "false" || v.checked === "off") };
      } else if (e.preset === "form" && e.id === "todo-add" && v.form && typeof v.form === "object") {
        const words = String((v.form as Record<string, unknown>).task ?? "").trim();
        a = words ? { kind: "added", row: r, words } : { kind: "add", row: r };
      } else if (e.preset === "card" && v.cta != null) {
        const cta = String(v.cta);
        if (e.id === "next-task" && /^done$/i.test(cta)) a = { kind: "donenext", row: r };
        else if (/plan my week|plan again/i.test(cta) || e.id === "week-plan") a = { kind: "plan", row: r };
        else if (/evening review|wrap up/i.test(cta) || e.id === "wrap") a = { kind: "review", row: r };
        else if (/add a to-?do/i.test(cta)) a = { kind: "add", row: r };
        else if (e.id === "week-move" || /move a task/i.test(cta)) a = { kind: "move", row: r };
      }
    }
    if (a) asks.push(a);
    else rest.push(r);
  }
  return { asks, rest };
}

/** What the app needs to schedule: the upcoming reminders, soonest first. */
export function reminderMeta(store: TableStore): { key: string; text: string; at: string }[] {
  return reminders(store).slice(0, 60).map((r) => ({ key: r.key, text: r.time ? `${r.task}, ${clockText(r.time)}` : r.task, at: r.at }));
}
