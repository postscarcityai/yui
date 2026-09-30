// Copied from runtime/src/workouts.ts by runtime/scripts/build.mjs. Do not edit here.
// Arnold's tools (YUI-182): today's workout runner, the log, and his default
// screens (This week, Today's workout, Progress), kept current with patches.
//
// Chris (Sep 28): "we should focus the next stories on getting the crew more
// tools up with detailed flows... i want the agents to have default screens."
//
// Every tool here is answered by the runtime itself, with no model turn and no
// free turn spent, because the data is already in Arnold's tables:
//
// 1. Start: the "Start a workout" shortcut, "Start today's workout", or a card's
//    Start button. Today's row of `this_week` becomes one full-screen `plan`:
//    what the session holds, then per move its sets to tick, reps and weight to
//    nudge (the last weight they lifted), and how it felt, with one Send.
// 2. The Send writes one row per move in `workouts` (the log) and ticks the day.
//    "Log today's workout" is a short plan for sessions done off the app: when,
//    what (the day's plan or their own words, "squat 3x5 @135"), how long, feel.
// 3. The screens: This week (the split, done days ticked, a day picker to edit
//    one), Today's workout, and Progress (a streak, the best set, a chart per
//    main lift). Answers patch them; nothing is sent twice.
// 4. A day tapped on This week opens a short plan: its focus and how long. The
//    Send rewrites that day's row and patches the week.
import type { NativeAgent, Row } from "./types.ts";
import { type Cell, type Clock, type TableStore, write } from "./tables.ts";

/** Agents that run workouts: Arnold and any copy of him (a fork keeps base arnold). */
export function trains(agent: NativeAgent): boolean {
  return agent.profile.base === "arnold";
}

export const WEEK_TABLE = "this_week";
export const LOG_TABLE = "workouts";
export const EXERCISES_TABLE = "exercises";
export const LOG_COLS = [
  { name: "Day", type: "date" as const }, { name: "Session", type: "text" as const }, { name: "Exercise", type: "text" as const },
  { name: "Sets", type: "number" as const }, { name: "Reps", type: "number" as const }, { name: "Seconds", type: "number" as const },
  { name: "Weight", type: "number" as const, unit: "lb" }, { name: "Minutes", type: "number" as const },
  { name: "Feel", type: "text" as const }, { name: "Source", type: "text" as const },
];

export const DAY_KEYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"] as const;
const DAY_NAMES: Record<string, string> = { mon: "Monday", tue: "Tuesday", wed: "Wednesday", thu: "Thursday", fri: "Friday", sat: "Saturday", sun: "Sunday" };
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
export const REST_SECONDS = 90;
export const SKIP = "Skip";

/** What each focus trains when a day is changed to it (from the starter exercises). */
export const FOCUS_WORKOUTS: Record<string, { workout: string; minutes: number }> = {
  "Full body": { workout: "Goblet squat 3x10, push-up 3x8, dumbbell row 3x10, plank 3x30s", minutes: 40 },
  Push: { workout: "Push-up 3x10, overhead press 3x8, bench press 3x8, plank 3x30s", minutes: 40 },
  Pull: { workout: "Dumbbell row 3x10, pull-up 3x5, lat pulldown 3x10, dead bug 3x10", minutes: 40 },
  Legs: { workout: "Squat 3x8, Romanian deadlift 3x10, reverse lunge 3x8 each, glute bridge 3x12", minutes: 45 },
  Upper: { workout: "Bench press 3x8, dumbbell row 3x10, overhead press 3x8, pull-up 3x5", minutes: 45 },
  Lower: { workout: "Deadlift 3x5, goblet squat 3x10, step-up 3x8 each, dead bug 3x10", minutes: 45 },
  Cardio: { workout: "Brisk walk, easy bike or a jog", minutes: 30 },
  Rest: { workout: "Rest", minutes: 0 },
};
export const FOCUSES = ["Full body", "Push", "Pull", "Legs", "Upper", "Lower", "Cardio", "Rest"];

// ---------- dates ----------

function utc(day: string): Date {
  const [y, m, d] = day.slice(0, 10).split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d));
}
export function shift(day: string, n: number): string {
  const t = utc(day);
  t.setUTCDate(t.getUTCDate() + n);
  return t.toISOString().slice(0, 10);
}
/** mon..sun for a date. */
export function dayKey(day: string): string {
  return DAY_KEYS[(utc(day).getUTCDay() + 6) % 7];
}
/** Monday of a date's week. */
export function weekStart(day: string): string {
  return shift(day, -((utc(day).getUTCDay() + 6) % 7));
}
const short = (day: string) => `${MONTHS[utc(day).getUTCMonth()]} ${utc(day).getUTCDate()}`;

// ---------- reading a workout ----------

/** One move as written in a split row: "Goblet squat 3x10", "plank 3x30s", "reverse lunge 3x8 each", "Squat 3x5 @135". */
export interface Written { name: string; sets: number; reps: number; secs?: number; each?: boolean; lb?: number }

const MOVE = /^(.+?)\s+(\d{1,2})\s*[x×]\s*(\d{1,3})\s*(s|sec|secs|seconds|m|min)?\b\s*(each(?: side| leg)?)?\s*(?:(?:@|at)\s*(\d{1,4}(?:\.\d+)?)\s*(?:lb|lbs|pounds)?)?\.?$/i;

/** A split row's Workout text as moves. Words that aren't sets (a walk, "Rest") give none. */
export function parseWorkout(text: string): Written[] {
  const out: Written[] = [];
  for (const part of String(text ?? "").split(/[,;\n]+|\s+(?:and|then)\s+/i)) {
    const m = part.trim().match(MOVE);
    if (!m) continue;
    const timed = !!m[4];
    const n = Number(m[3]);
    out.push({
      name: m[1].trim().replace(/^\w/, (c) => c.toUpperCase()), sets: Number(m[2]),
      reps: timed ? 0 : n, ...(timed ? { secs: /^m/i.test(m[4]) ? n * 60 : n } : {}),
      ...(m[5] ? { each: true } : {}), ...(m[6] ? { lb: Number(m[6]) } : {}),
    });
  }
  return out.filter((w) => w.sets > 0 && w.sets <= 10);
}

/** A slug for a key: "Goblet squat" -> goblet-squat. */
export function slug(s: string): string {
  return s.toLowerCase().normalize("NFKD").replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 40) || "move";
}

/** A move ready to run: what was written, how-to from the exercises table, and the weight they last used. */
export interface Move {
  n: number; // e1, e2 ... in the plan
  name: string;
  sets: number;
  reps: number;
  secs?: number;
  each?: boolean;
  lb?: number; // the weight to start from; none: bodyweight
  cue?: string;
}

/** A session as the runner shows it, kept in the runner's reply so its Send is read against it. */
export interface Session {
  id: string; // the plan's id: wk-<yyyymmdd>-<day key it came from>
  day: string; // the date it is done on
  from: string; // mon..sun: the split row
  focus: string;
  minutes: number;
  workout: string; // the row's words
  moves: Move[];
}

const rowsOf = (store: TableStore, name: string): { key: string; row: Record<string, Cell> }[] => {
  const t = store.tables[name];
  return t ? t.order.map((key) => ({ key, row: t.rows[key] })) : [];
};

/** A split row: Day, Focus, Workout, Minutes (from this_week). */
export interface SplitDay { key: string; label: string; focus: string; workout: string; minutes: number }

export function splitDays(store: TableStore): SplitDay[] {
  const byKey: Record<string, SplitDay> = {};
  for (const { key, row } of rowsOf(store, WEEK_TABLE)) {
    const k = DAY_KEYS.find((d) => d === key.toLowerCase() || d === String(row.Day ?? "").toLowerCase().slice(0, 3));
    if (!k) continue;
    byKey[k] = { key: k, label: DAY_NAMES[k].slice(0, 3), focus: String(row.Focus ?? "").trim() || "Rest",
                 workout: String(row.Workout ?? "").trim(), minutes: Number(row.Minutes ?? 0) || 0 };
  }
  return DAY_KEYS.filter((k) => byKey[k]).map((k) => byKey[k]);
}

const isRest = (d: SplitDay) => /^rest\b/i.test(d.focus) || (!d.minutes && /^rest\b/i.test(d.workout));

function exerciseInfo(store: TableStore, name: string): { cue?: string; gear?: string } {
  const want = slug(name);
  for (const { key, row } of rowsOf(store, EXERCISES_TABLE)) {
    if (key === want || slug(String(row.Exercise ?? "")) === want) return { cue: row.Cue ? String(row.Cue) : undefined, gear: row.Gear ? String(row.Gear) : undefined };
  }
  return {};
}

/** The newest weight they lifted on a move, from the log. */
export function lastWeight(store: TableStore, name: string): number | undefined {
  const want = slug(name);
  let best: { day: string; lb: number } | undefined;
  for (const { row } of rowsOf(store, LOG_TABLE)) {
    if (slug(String(row.Exercise ?? "")) !== want || typeof row.Weight !== "number" || !(row.Weight > 0)) continue;
    const day = String(row.Day ?? "");
    if (!best || day >= best.day) best = { day, lb: row.Weight };
  }
  return best?.lb;
}

/** Where a weight starts when they have never logged the move: from its gear. None: bodyweight. */
function startWeight(gear?: string): number | undefined {
  if (!gear || /^(none|bodyweight)\b/i.test(gear)) return undefined;
  if (/barbell/i.test(gear)) return 45;
  if (/cable|machine/i.test(gear)) return 40;
  if (/dumbbell|kettlebell/i.test(gear)) return 20;
  return undefined;
}

/** A split day as a session on a date. */
export function session(store: TableStore, from: SplitDay, day: string): Session {
  const moves = parseWorkout(from.workout).slice(0, 8).map((w, i): Move => {
    const info = exerciseInfo(store, w.name);
    const lb = w.lb ?? lastWeight(store, w.name) ?? (w.secs ? undefined : startWeight(info.gear));
    return { n: i + 1, name: w.name, sets: w.sets, reps: w.reps, ...(w.secs ? { secs: w.secs } : {}), ...(w.each ? { each: true } : {}),
             ...(lb != null ? { lb } : {}), ...(info.cue ? { cue: info.cue } : {}) };
  });
  return { id: `wk-${day.replace(/-/g, "")}-${from.key}`, day, from: from.key, focus: from.focus, minutes: from.minutes, workout: from.workout, moves };
}

// ---------- lines ----------

const q = (s: string) => `"${String(s).replace(/\\/g, "\\\\").replace(/"/g, "'").replace(/\n/g, " ")}"`;
const opts = (xs: string[]) => xs.map((x) => (/^[A-Za-z0-9_.-]+$/.test(x) ? x : q(x))).join("|");
const target = (m: Move) => `${m.sets} x ${m.secs ? `${m.secs}s` : m.reps}${m.each ? " each side" : ""}`;
const moveLine = (m: { name: string; sets: number; reps: number; secs?: number; each?: boolean }) =>
  `${m.name} ${m.sets}x${m.secs ? `${m.secs}s` : m.reps}${m.each ? " each" : ""}`;

/** The runner: one full-screen plan, what the session holds first, a step per move, how it felt last, one Send. */
export function runnerLines(s: Session): string[] {
  const out = [`plan@${s.id} ${q(s.focus)} submit="Finish workout"`];
  if (!s.moves.length) {
    // Cardio or a day in their own words: one page, then how long and how it felt.
    out.push(`page ${q(s.focus)} body=${q(`${s.workout || s.focus}. Go at a pace you can talk at.`)}`);
    out.push(`slide@minutes "How long did you go, in minutes?" 5-120 value=${Math.max(5, Math.min(120, s.minutes || 30))} step=5`);
  } else {
    out.push(`page ${q(s.focus)} body=${q(`${s.moves.length} moves, about ${s.minutes || s.moves.length * 10} minutes. Rest about ${REST_SECONDS} seconds between sets.`)} points=${opts(s.moves.map(moveLine))}`);
    s.moves.forEach((m) => {
      // "Skip" lets a move go by with nothing ticked (a pick with no answer holds the flow's Next).
      const sets = [...Array.from({ length: m.sets }, (_, i) => `Set ${i + 1}`), SKIP];
      const body = `${m.cue ? `${m.cue} ` : ""}Target ${target(m)}${m.lb ? ` at ${m.lb} lb` : ""}. Tick each set as you finish it, or Skip.`;
      out.push(`pick@e${m.n}-sets ${q(`${m.name}: sets done`)} ${opts(sets)} tag=${q(`${m.n} of ${s.moves.length}`)} title=${q(m.name)} body=${q(body.slice(0, 400))}`);
      if (m.secs) out.push(`slide@e${m.n}-secs ${q(`${m.name}: seconds per set`)} 5-180 value=${m.secs} step=5`);
      else out.push(`slide@e${m.n}-reps ${q(`${m.name}: reps per set`)} 1-30 value=${m.reps}`);
      if (m.lb != null) out.push(`slide@e${m.n}-lb ${q(`${m.name}: weight in lb`)} 0-${Math.max(300, Math.ceil((m.lb * 2) / 50) * 50)} value=${m.lb} step=5 unit=lb`);
    });
  }
  out.push(`choose@feel "How did it feel?" Easy|"Just right"|Hard`);
  return out;
}

/** The body of the runner's reply: a line, then the plan. */
export function runnerBody(s: Session): string {
  const words = s.moves.length ? `${s.focus}. ${s.moves.length} moves, one set at a time. Let's go.` : `${s.focus}. Let's go.`;
  return `${words}\n\`\`\`yui\n${runnerLines(s).join("\n")}\n\`\`\``;
}

/** Today's split day, or null when there is no split yet. */
export function today(store: TableStore, clk: Clock): SplitDay | null {
  return splitDays(store).find((d) => d.key === dayKey(clk.today)) ?? null;
}

/** The next training day after today, for a rest day's offer. */
function nextTraining(store: TableStore, clk: Clock): SplitDay | undefined {
  const days = splitDays(store);
  const from = DAY_KEYS.indexOf(dayKey(clk.today) as any);
  for (let i = 1; i <= 7; i++) {
    const d = days.find((x) => x.key === DAY_KEYS[(from + i) % 7]);
    if (d && !isRest(d)) return d;
  }
  return undefined;
}

/** What Start answers: the runner for today, or on a rest day an offer to do the next session now. */
export function startReply(store: TableStore, clk: Clock, from?: string): { body: string; session?: Session } {
  const days = splitDays(store);
  const d = from ? days.find((x) => x.key === from) : today(store, clk);
  if (!days.length) {
    return { body: "Let's build your split first, then I'll run it with you.\n```yui\ncard@split \"Make it yours\" \"Your days, your split, your gear.\" cta=\"Build my split\"\n```" };
  }
  if (!d || isRest(d)) {
    const n = nextTraining(store, clk);
    if (!n) return { body: "Every day on your split is a rest day. Tap a day on This week to give it a workout." };
    return { body: `Rest day today. Recovery counts too.\n\`\`\`yui\nask@anyway-${n.key} ${q(`Do ${n.label}'s ${n.focus} today instead?`)} "Yes, let's go"|"Rest today"\n\`\`\`` };
  }
  const s = session(store, d, clk.today);
  return { body: runnerBody(s), session: s };
}

/** "Log today's workout": a short plan for a session done off the app. */
export function logBody(store: TableStore, clk: Clock): string {
  const d = today(store, clk);
  const planned = d && !isRest(d) ? [`${d.focus} as planned`] : [];
  const lines = [
    `plan@wlog "Log a workout" submit="Log it"`,
    `choose@when "When was it?" Today|Yesterday`,
    `choose@what "What did you do?" ${opts([...planned, "Something else"])} +other`,
    `slide@minutes "How long, in minutes?" 5-120 value=${d?.minutes || 40} step=5`,
    `choose@feel "How did it feel?" Easy|"Just right"|Hard`,
  ];
  return `Tell me what you did. Moves like "squat 3x5 @135" log each set.\n\`\`\`yui\n${lines.join("\n")}\n\`\`\``;
}

/** A day tapped on This week: its focus and how long, one Save. */
export function editDayBody(store: TableStore, key: string): string {
  const d = splitDays(store).find((x) => x.key === key);
  const name = DAY_NAMES[key];
  const lines = [
    `plan@day-${key} ${q(name)} submit=Save`,
    `choose@focus ${q(`What does ${name} train?`)} ${opts(FOCUSES)} +other${d ? ` body=${q(`Now: ${d.focus}${d.workout && !isRest(d) ? `. ${d.workout}` : ""}`)}` : ""}`,
    `slide@minutes "How long, in minutes?" 0-90 value=${d?.minutes ?? 40} step=5`,
  ];
  return `\`\`\`yui\n${lines.join("\n")}\n\`\`\``;
}

// ---------- the first plan (YUI-217, PROP-4) ----------

export const PLAN_TABLE = "first_plan";
export const NOT_SURE = "Not sure";
export const FIRST_ID = "first";
export const FIRST_SKIP = "first-skip";

const GOALS = ["Lift heavy", "Lift and cardio", "Mostly cardio", "Just move more"];
const TIMES = ["30 min", "45 min", "60 min"];
const GEAR = ["Just me", "Bands", "Dumbbells", "Barbell", "A gym"];
const LEVELS = ["New to lifting", "Some experience", "Lifted for years"];

/** The intake, as first.yui and a rebuild send it: five steps, one Send. The days step is one tap, Not sure picks three. */
export function firstLines(): string[] {
  return [
    `plan@${FIRST_ID} "Your first plan" submit="Build my week"`,
    `choose@goal "What are we training for?" ${opts([...GOALS, NOT_SURE])}`,
    `choose@days "How many days a week?" ${opts(["2", "3", "4", "5", "6", NOT_SURE])}`,
    `choose@time "How long per session?" ${opts([...TIMES, NOT_SURE])}`,
    `pick@gear "What do you have?" ${opts(GEAR)}`,
    `choose@level "How much have you lifted?" ${opts([...LEVELS, NOT_SURE])} body="Heavy lifters finish the last set of each lift at failure with a safe stop. New lifters stop well short."`,
    `end`,
    `card@${FIRST_SKIP} "Not now" "Keep the starter week. Build yours any time from This week." cta="Skip for now"`,
  ];
}

/** The rebuild's reply: a line, then the intake. */
export function firstBody(): string {
  return `Five taps and you have a week you'll do. It's a rough draft, and you can change any day.\n\`\`\`yui\n${firstLines().join("\n")}\n\`\`\``;
}

/** What one goal trains across n days: a focus per training day, in order. */
function focuses(goal: string, n: number): string[] {
  const heavy: Record<number, string[]> = {
    2: ["Full body", "Full body"], 3: ["Full body", "Full body", "Full body"], 4: ["Upper", "Lower", "Upper", "Lower"],
    5: ["Push", "Pull", "Legs", "Upper", "Lower"], 6: ["Push", "Pull", "Legs", "Push", "Pull", "Legs"],
  };
  const mixed: Record<number, string[]> = {
    2: ["Full body", "Cardio"], 3: ["Full body", "Cardio", "Full body"], 4: ["Upper", "Cardio", "Lower", "Cardio"],
    5: ["Upper", "Cardio", "Lower", "Cardio", "Full body"], 6: ["Push", "Cardio", "Pull", "Cardio", "Legs", "Cardio"],
  };
  if (/^lift heavy$/i.test(goal)) return heavy[n];
  if (/^lift and cardio$/i.test(goal)) return mixed[n];
  // Mostly cardio and just move more: one lifting day, the rest on your feet.
  return Array.from({ length: n }, (_, i) => (i === 1 ? "Full body" : "Cardio"));
}

const DAYS_FOR: Record<number, string[]> = {
  2: ["mon", "thu"], 3: ["mon", "wed", "fri"], 4: ["mon", "tue", "thu", "fri"], 5: ["mon", "tue", "wed", "fri", "sat"],
  6: ["mon", "tue", "wed", "thu", "fri", "sat"],
};

/** The moves a focus holds with a full gym; smaller kits swap moves out of it. */
const MOVES: Record<string, string[]> = {
  "Full body": ["Squat", "Bench press", "Lat pulldown", "Romanian deadlift", "Plank"],
  Push: ["Bench press", "Overhead press", "Push-up", "Plank"],
  Pull: ["Lat pulldown", "Dumbbell row", "Pull-up", "Dead bug"],
  Legs: ["Squat", "Romanian deadlift", "Step-up", "Glute bridge"],
  Upper: ["Bench press", "Dumbbell row", "Overhead press", "Lat pulldown"],
  Lower: ["Deadlift", "Squat", "Step-up", "Dead bug"],
};
const SWAPS: Record<string, Record<string, string>> = {
  gym: {},
  barbell: { "Lat pulldown": "Pull-up", "Step-up": "Reverse lunge" },
  dumbbells: { Squat: "Goblet squat", "Bench press": "Dumbbell bench press", Deadlift: "Romanian deadlift", "Lat pulldown": "Dumbbell row",
               "Pull-up": "Dumbbell row", "Step-up": "Reverse lunge" },
  bands: { Squat: "Banded squat", "Bench press": "Push-up", Deadlift: "Glute bridge", "Romanian deadlift": "Glute bridge", "Lat pulldown": "Banded row",
           "Dumbbell row": "Banded row", "Pull-up": "Banded row", "Step-up": "Reverse lunge", "Overhead press": "Banded overhead press" },
  bodyweight: { Squat: "Air squat", "Bench press": "Push-up", Deadlift: "Glute bridge", "Romanian deadlift": "Glute bridge", "Lat pulldown": "Bird dog",
                "Dumbbell row": "Bird dog", "Pull-up": "Bird dog", "Step-up": "Reverse lunge", "Overhead press": "Pike push-up" },
};
const CORE = new Set(["Plank", "Dead bug", "Bird dog", "Glute bridge"]);

/** The kit that counts is the biggest one they picked. */
export function kit(answer: unknown): "gym" | "barbell" | "dumbbells" | "bands" | "bodyweight" {
  const have = (list(answer) ?? []).map((x) => x.toLowerCase());
  if (have.some((x) => /gym/.test(x))) return "gym";
  if (have.some((x) => /barbell/.test(x))) return "barbell";
  if (have.some((x) => /dumbbell/.test(x))) return "dumbbells";
  if (have.some((x) => /band/.test(x))) return "bands";
  return "bodyweight";
}

/** How hard the last set of a lift goes: from how much they have lifted. Not sure is the middle. */
export function effort(level: unknown): "failure" | "short" | "ease" {
  const l = String(level ?? "");
  if (/years/i.test(l)) return "failure";
  if (/^new/i.test(l)) return "ease";
  return "short";
}

/** The words a focus is written in on This week, moves as "Squat 3x8". */
export function firstWorkout(focus: string, tier: ReturnType<typeof kit>, eff: ReturnType<typeof effort>, heavy: boolean): string {
  const swaps = SWAPS[tier];
  const moves = (MOVES[focus] ?? MOVES["Full body"]).map((m) => swaps[m] ?? m).filter((m, i, a) => a.indexOf(m) === i);
  const [sets, reps] = heavy && eff === "failure" ? [4, 6] : eff === "ease" ? [2, 10] : heavy ? [3, 8] : [3, 10];
  return moves.map((m) => (m === "Plank" ? "Plank 3x30s" : CORE.has(m) ? `${m} 3x10` : `${m} ${sets}x${reps}`)).join(", ");
}

/** The split the intake builds, as This week's rows. */
export function firstSplit(answers: Record<string, unknown>): { key: string; focus: string; workout: string; minutes: number }[] {
  const goalRaw = String(answers.goal ?? "");
  const goal = GOALS.find((g) => g.toLowerCase() === goalRaw.toLowerCase()) ?? GOALS[0];
  const n = Math.max(2, Math.min(6, num(answers.days) ?? 3));
  const minutes = num(String(answers.time ?? "").replace(/\s*min.*/i, "")) ?? 45;
  const tier = kit(answers.gear);
  const eff = effort(answers.level);
  const heavy = /^lift/i.test(goal);
  const plan = new Map(DAYS_FOR[n].map((k, i) => [k, focuses(goal, n)[i]]));
  return DAY_KEYS.map((key) => {
    const focus = plan.get(key);
    if (!focus) return { key, focus: "Rest", workout: "Rest", minutes: 0 };
    if (focus === "Cardio") return { key, focus, workout: /^just move/i.test(goal) ? "A brisk walk, easy pace" : FOCUS_WORKOUTS.Cardio.workout, minutes };
    return { key, focus, workout: firstWorkout(focus, tier, eff, heavy), minutes };
  });
}

/** The intake's Send: This week rewritten, the answers saved in first_plan. */
export function applyFirst(store: TableStore, answers: Record<string, unknown>, clk: Clock): { store: TableStore; days: number; effort: ReturnType<typeof effort>; kit: ReturnType<typeof kit>; minutes: number } {
  let out = store;
  if (!out.tables[WEEK_TABLE]) {
    const r = write(out, { op: "table", name: WEEK_TABLE, cols: [{ name: "Day", type: "text" }, { name: "Focus", type: "text" }, { name: "Workout", type: "text" },
                                                                  { name: "Minutes", type: "number" }, { name: "Done", type: "bool" }] });
    if (!r.error) out = r.store;
  }
  const split = firstSplit(answers);
  for (const d of split) {
    const r = write(out, { op: "put", table: WEEK_TABLE, key: d.key, values: { Day: DAY_NAMES[d.key].slice(0, 3), Focus: d.focus, Workout: d.workout, Minutes: d.minutes, Done: false } }, clk);
    if (!r.error) out = r.store;
  }
  if (!out.tables[PLAN_TABLE]) {
    const r = write(out, { op: "table", name: PLAN_TABLE, cols: [{ name: "Question", type: "text" }, { name: "Answer", type: "text" }] });
    if (!r.error) out = r.store;
  }
  const eff = effort(answers.level);
  const saved: [string, string][] = [["goal", "Goal"], ["days", "Days a week"], ["time", "Session length"], ["gear", "Gear"], ["level", "Experience"]];
  for (const [k, label] of saved) {
    const v = list(answers[k])?.join(", ") ?? NOT_SURE;
    const r = write(out, { op: "put", table: PLAN_TABLE, key: k, values: { Question: label, Answer: v } }, clk);
    if (!r.error) out = r.store;
  }
  const r = write(out, { op: "put", table: PLAN_TABLE, key: "effort", values: { Question: "Last set", Answer: eff === "failure" ? "To failure, safe stop" : eff === "short" ? "One rep short" : "Ease in" } }, clk);
  if (!r.error) out = r.store;
  const days = split.filter((d) => d.focus !== "Rest");
  return { store: out, days: days.length, effort: eff, kit: kit(answers.gear), minutes: days[0]?.minutes ?? 45 };
}

/** What Arnold says when the week is built: what it is, how hard the last set goes, that it can change. */
export function firstLine(r: { days: number; effort: ReturnType<typeof effort>; kit: ReturnType<typeof kit>; minutes: number }): string {
  const gear = ({ gym: "a full gym", barbell: "a barbell", dumbbells: "dumbbells", bands: "bands", bodyweight: "just you" } as const)[r.kit];
  const hard = r.effort === "failure"
    ? "The last set of each lift goes to failure, with a safe stop: use the rack pins or a spotter on barbell work."
    : r.effort === "short" ? "The last set of each lift stops one rep short. Ask me to push it later."
    : "We ease in. Every set stays well short of failure.";
  return `Your week is built: ${r.days} days, about ${r.minutes} minutes, ${gear}. ${hard} It's a starting point. Tap any day to change it.`;
}

// ---------- taps ----------

/** A tap or words the runtime answers itself. */
export type WorkoutAsk =
  | { kind: "start"; row: Row; from?: string }
  | { kind: "rest"; row: Row }
  | { kind: "log"; row: Row }
  | { kind: "edit"; row: Row; day: string }
  | { kind: "runner"; row: Row; id: string; answers: Record<string, unknown> }
  | { kind: "logged"; row: Row; answers: Record<string, unknown> }
  | { kind: "day"; row: Row; day: string; answers: Record<string, unknown> }
  | { kind: "first"; row: Row; answers: Record<string, unknown> }
  | { kind: "again"; row: Row }
  | { kind: "planwords"; row: Row }
  | { kind: "skipfirst"; row: Row };

const START = /^\s*(?:let'?s\s+)?(?:start|begin|run)\s+(?:(?:today'?s|my|the|a)\s+)?(?:workout|session|training)(?:\s+today)?\s*[.!]*\s*$/i;
/** Asking for a plan in words ("build me a plan", "get fit, 4 days a week", "a weekly plan"). Short, and nothing about pain or a condition: that one is the model's to word. */
const PLAN_WORDS = [
  /\b(?:build|make|create|set\s*up|design|write|give|need|want|start)\b[^.?!]*\b(?:plan|split|program(?:me)?|routine|schedule)\b/i,
  /^\W*(?:a\s+|my\s+)?(?:(?:weekly|workout|training|first)\s+)*(?:plan|split|program(?:me)?|routine)\W*$/i,
  /\b(?:get\s+fit|get\s+in\s+shape|get\s+stronger|build\s+muscle|lose\s+weight)\b/i,
];
const CARE_WORDS = /\b(?:hurt|hurts|pain|painful|injur\w*|surgery|pregnan\w*|heart|asthma|doctor|condition|diagnos\w*|dizzy)\b/i;
const LOG = /^\s*log\s+(?:(?:today'?s|my|a|the)\s+)?(?:workout|session)(?:\s+today)?\s*[.!]*\s*$/i;

/** An event row as {id, preset, value}: from its meta when the app sent one, else read from its line. */
export function readEvent(r: Row): { id: string; preset: string; value: Record<string, unknown> } | null {
  const m = r.meta;
  if (m && typeof m.id === "string" && typeof m.preset === "string" && m.value && typeof m.value === "object") {
    return { id: m.id, preset: m.preset, value: m.value };
  }
  const head = (r.body ?? "").match(/^\[yui\]\s+([A-Za-z0-9_-]+)\s+([a-z]+)\b(.*)$/s);
  if (!head) return null;
  const value: Record<string, unknown> = {};
  const TOK = /([A-Za-z_][\w.-]*)=((?:"(?:[^"\\]|\\.)*"|[^\s|"]+)(?:\|(?:"(?:[^"\\]|\\.)*"|[^\s|"]+))*)|([A-Za-z_][\w-]*)/g;
  for (const t of head[3].matchAll(TOK)) {
    if (t[3]) {
      value[t[3]] = true;
      continue;
    }
    const parts = [...t[2].matchAll(/"((?:[^"\\]|\\.)*)"|([^|"]+)/g)].map((p) => (p[1] != null ? p[1].replace(/\\n/g, "\n").replace(/\\(.)/g, "$1") : p[2]));
    const v: unknown = parts.length > 1 ? parts : /^-?\d+(\.\d+)?$/.test(parts[0] ?? "") && t[2][0] !== '"' ? Number(parts[0]) : parts[0];
    // plan.e1-sets=... -> value.plan["e1-sets"]
    const path = t[1].split(".");
    let at: any = value;
    for (const k of path.slice(0, -1)) at = at[k] = typeof at[k] === "object" && at[k] ? at[k] : {};
    at[path[path.length - 1]] = v;
  }
  return { id: head[1], preset: head[2], value };
}

/** The rows in a turn the runtime answers itself (workout words and taps), and the rest for the model. */
export function workoutAsks(rows: Row[]): { asks: WorkoutAsk[]; rest: Row[] } {
  const asks: WorkoutAsk[] = [];
  const rest: Row[] = [];
  for (const r of rows) {
    const body = r.body ?? "";
    const e = /^\[yui\]\s/.test(body) ? readEvent(r) : null;
    let a: WorkoutAsk | null = null;
    if (!e && r.kind !== "event") {
      if (START.test(body)) a = { kind: "start", row: r };
      else if (LOG.test(body)) a = { kind: "log", row: r };
      else if (!/^\[yui\]/.test(body) && !r.thread_id && body.length <= 160 && PLAN_WORDS.some((w) => w.test(body)) && !CARE_WORDS.test(body)) a = { kind: "planwords", row: r };
    } else if (e) {
      const v = e.value;
      if (e.preset === "plan" && /^wk-\d{8}-(mon|tue|wed|thu|fri|sat|sun)$/.test(e.id) && v.plan && typeof v.plan === "object") {
        a = { kind: "runner", row: r, id: e.id, answers: v.plan as Record<string, unknown> };
      } else if (e.preset === "plan" && e.id === "wlog" && v.plan && typeof v.plan === "object") {
        a = { kind: "logged", row: r, answers: v.plan as Record<string, unknown> };
      } else if (e.preset === "plan" && /^day-(mon|tue|wed|thu|fri|sat|sun)$/.test(e.id) && v.plan && typeof v.plan === "object") {
        a = { kind: "day", row: r, day: e.id.slice(4), answers: v.plan as Record<string, unknown> };
      } else if (e.preset === "plan" && e.id === FIRST_ID && v.plan && typeof v.plan === "object") {
        a = { kind: "first", row: r, answers: v.plan as Record<string, unknown> };
      } else if (e.preset === "card" && e.id === FIRST_SKIP) {
        a = { kind: "skipfirst", row: r };
      } else if (e.preset === "card" && e.id === "split" && v.cta != null) {
        a = { kind: "again", row: r };
      } else if (e.preset === "choose" && e.id === "edit-day" && typeof v.choice === "string") {
        const day = DAY_KEYS.find((d) => d === v.choice.toString().toLowerCase().slice(0, 3));
        if (day) a = { kind: "edit", row: r, day };
      } else if (e.preset === "ask" && /^anyway-(mon|tue|wed|thu|fri|sat|sun)$/.test(e.id)) {
        a = /^yes/i.test(String(v.answer ?? "")) ? { kind: "start", row: r, from: e.id.slice(7) } : { kind: "rest", row: r };
      } else if (e.preset === "card" && v.cta != null && (e.id === "today" || /^start\b/i.test(String(v.cta)))) {
        a = { kind: "start", row: r };
      }
    }
    if (a) asks.push(a);
    else rest.push(r);
  }
  return { asks, rest };
}

// ---------- writing the log ----------

const num = (v: unknown): number | undefined => {
  const n = typeof v === "number" ? v : typeof v === "string" && /^-?\d+(\.\d+)?$/.test(v.trim()) ? Number(v) : NaN;
  return Number.isFinite(n) ? n : undefined;
};
const list = (v: unknown): string[] | undefined => (Array.isArray(v) ? v.map(String) : typeof v === "string" && v ? v.split("|") : undefined);

/** Makes sure the log exists: Arnold agents made before it get it on their first session. */
export function ensureLog(store: TableStore): TableStore {
  if (store.tables[LOG_TABLE]) return store;
  const r = write(store, { op: "table", name: LOG_TABLE, cols: LOG_COLS });
  return r.error ? store : r.store;
}

/** A logged move, as written to the log. */
export interface Logged { exercise: string; sets: number; reps?: number; secs?: number; lb?: number; minutes?: number }

function putLog(store: TableStore, day: string, sessionName: string, items: Logged[], feel: string | undefined, source: string, clk: Clock): TableStore {
  let out = ensureLog(store);
  for (const it of items) {
    const values: Record<string, unknown> = { Day: day, Session: sessionName, Exercise: it.exercise, Sets: it.sets, Source: source };
    if (it.reps != null) values.Reps = it.reps;
    if (it.secs != null) values.Seconds = it.secs;
    if (it.lb != null && it.lb > 0) values.Weight = it.lb;
    if (it.minutes != null) values.Minutes = it.minutes;
    if (feel) values.Feel = feel;
    // One row per move per day: sending the flow again (Edit answers) replaces it.
    const r = write(out, { op: "put", table: LOG_TABLE, key: `${day}-${slug(it.exercise)}`, values }, clk);
    if (!r.error) out = r.store;
  }
  return out;
}

function tickDay(store: TableStore, day: string, clk: Clock): TableStore {
  const key = dayKey(day);
  if (!store.tables[WEEK_TABLE]?.rows[key] || weekStart(day) !== weekStart(clk.today)) return store;
  const r = write(store, { op: "put", table: WEEK_TABLE, key, values: { Done: true } }, clk);
  return r.error ? store : r.store;
}

/** The runner's Send: a row per move they did, the day ticked. */
export function applyRunner(store: TableStore, s: Session, answers: Record<string, unknown>, clk: Clock): { store: TableStore; items: Logged[]; feel?: string } {
  const feel = typeof answers.feel === "string" ? answers.feel : undefined;
  const items: Logged[] = [];
  if (!s.moves.length) {
    items.push({ exercise: s.focus, sets: 1, minutes: num(answers.minutes) ?? s.minutes });
  }
  for (const m of s.moves) {
    const ticked = list(answers[`e${m.n}-sets`])?.filter((x) => x !== SKIP);
    // A step they moved past without ticking counts as done: they pressed Finish on the whole session.
    const sets = ticked ? ticked.length : m.sets;
    if (!sets) continue;
    items.push({ exercise: m.name, sets,
                 ...(m.secs ? { secs: num(answers[`e${m.n}-secs`]) ?? m.secs } : { reps: num(answers[`e${m.n}-reps`]) ?? m.reps }),
                 ...(m.lb != null ? { lb: num(answers[`e${m.n}-lb`]) ?? m.lb } : {}) });
  }
  let out = putLog(store, s.day, s.focus, items, feel, "runner", clk);
  if (items.length) out = tickDay(out, s.day, clk);
  return { store: out, items, feel };
}

/** "Log today's workout": the day's plan as done, or their own words read as moves. */
export function applyLogged(store: TableStore, answers: Record<string, unknown>, clk: Clock): { store: TableStore; items: Logged[]; day: string; name: string } {
  const day = /^yesterday$/i.test(String(answers.when ?? "")) ? shift(clk.today, -1) : clk.today;
  const what = String(answers.what ?? "").trim();
  const minutes = num(answers.minutes);
  const feel = typeof answers.feel === "string" ? answers.feel : undefined;
  const plannedDay = splitDays(store).find((d) => d.key === dayKey(clk.today));
  let name = what || "Workout";
  let items: Logged[];
  if (plannedDay && /\bas planned$/i.test(what)) {
    const s = session(store, plannedDay, day);
    name = s.focus;
    items = s.moves.length
      ? s.moves.map((m) => ({ exercise: m.name, sets: m.sets, ...(m.secs ? { secs: m.secs } : { reps: m.reps }), ...(m.lb != null ? { lb: m.lb } : {}) }))
      : [{ exercise: s.focus, sets: 1, minutes: minutes ?? s.minutes }];
  } else {
    const moves = parseWorkout(what);
    if (moves.length) name = "Workout";
    items = moves.length
      ? moves.map((w) => ({ exercise: w.name, sets: w.sets, ...(w.secs ? { secs: w.secs } : { reps: w.reps }), ...(w.lb != null ? { lb: w.lb } : {}) }))
      : [{ exercise: (what || "Workout").slice(0, 80), sets: 1, ...(minutes != null ? { minutes } : {}) }];
  }
  if (items.length && minutes != null && items[0].minutes == null) items[0] = { ...items[0], minutes };
  let out = putLog(store, day, name, items, feel, "logged", clk);
  out = tickDay(out, day, clk);
  return { store: out, items, day, name };
}

/** A day changed from This week: its focus, the moves for that focus, how long. */
export function applyDay(store: TableStore, key: string, answers: Record<string, unknown>, clk: Clock): { store: TableStore; focus: string; known: boolean } {
  const focus = String(answers.focus ?? "").trim().slice(0, 60);
  const cur = splitDays(store).find((d) => d.key === key);
  const minutes = num(answers.minutes);
  if (!focus) return { store, focus: cur?.focus ?? "", known: true };
  const preset = Object.entries(FOCUS_WORKOUTS).find(([f]) => f.toLowerCase() === focus.toLowerCase());
  const same = cur && cur.focus.toLowerCase() === focus.toLowerCase();
  // Their own words (Yoga, Swim) keep what the row said only when the focus didn't change.
  const workout = same ? cur!.workout : preset ? preset[1].workout : "";
  const values: Record<string, unknown> = { Day: DAY_NAMES[key].slice(0, 3), Focus: preset ? preset[0] : focus, Workout: workout,
                                            Minutes: minutes ?? (same ? cur!.minutes : preset ? preset[1].minutes : cur?.minutes || 30) };
  let out = store;
  if (!out.tables[WEEK_TABLE]) {
    const r = write(out, { op: "table", name: WEEK_TABLE, cols: [{ name: "Day", type: "text" }, { name: "Focus", type: "text" }, { name: "Workout", type: "text" },
                                                                  { name: "Minutes", type: "number" }, { name: "Done", type: "bool" }] });
    if (!r.error) out = r.store;
  }
  const r = write(out, { op: "put", table: WEEK_TABLE, key, values }, clk);
  return { store: r.error ? store : r.store, focus: String(values.Focus), known: !!preset || !!same };
}

// ---------- the screens ----------

/** Days of this week with a logged session. */
export function doneDays(store: TableStore, clk: Clock): Set<string> {
  const start = weekStart(clk.today);
  const end = shift(start, 6);
  const out = new Set<string>();
  for (const { row } of rowsOf(store, LOG_TABLE)) {
    const d = String(row.Day ?? "").slice(0, 10);
    if (d >= start && d <= end) out.add(dayKey(d));
  }
  return out;
}

/** Weeks in a row with a session, counting back from this week (or last week, when this one has none yet). */
export function streak(store: TableStore, clk: Clock): number {
  const weeks = new Set(rowsOf(store, LOG_TABLE).map(({ row }) => String(row.Day ?? "")).filter((d) => /^\d{4}-\d{2}-\d{2}/.test(d)).map((d) => weekStart(d)));
  let w = weekStart(clk.today);
  if (!weeks.has(w)) w = shift(w, -7);
  let n = 0;
  while (weeks.has(w)) {
    n++;
    w = shift(w, -7);
  }
  return n;
}

/** The heaviest set in the log (reps break a tie). */
export function bestSet(store: TableStore): { exercise: string; lb: number; reps?: number; day: string } | null {
  let best: { exercise: string; lb: number; reps?: number; day: string } | null = null;
  for (const { row } of rowsOf(store, LOG_TABLE)) {
    if (typeof row.Weight !== "number" || !(row.Weight > 0)) continue;
    const reps = typeof row.Reps === "number" ? row.Reps : undefined;
    if (!best || row.Weight > best.lb || (row.Weight === best.lb && (reps ?? 0) > (best.reps ?? 0))) {
      best = { exercise: String(row.Exercise ?? ""), lb: row.Weight, ...(reps != null ? { reps } : {}), day: String(row.Day ?? "") };
    }
  }
  return best;
}

/** The main lifts: weighted moves logged most, at most three, each with its top weight per day. */
export function mainLifts(store: TableStore, max = 3): { key: string; name: string; days: string[]; lb: number[] }[] {
  const by: Record<string, { name: string; count: number; last: string; max: number; top: Record<string, number> }> = {};
  for (const { row } of rowsOf(store, LOG_TABLE)) {
    if (typeof row.Weight !== "number" || !(row.Weight > 0)) continue;
    const name = String(row.Exercise ?? "");
    const k = slug(name);
    const day = String(row.Day ?? "").slice(0, 10);
    const e = (by[k] ??= { name, count: 0, last: "", max: 0, top: {} });
    e.count++;
    e.max = Math.max(e.max, row.Weight);
    if (day > e.last) e.last = day;
    e.top[day] = Math.max(e.top[day] ?? 0, row.Weight);
  }
  return Object.entries(by).sort((a, b) => b[1].count - a[1].count || b[1].last.localeCompare(a[1].last) || b[1].max - a[1].max || a[0].localeCompare(b[0])).slice(0, max)
    .map(([key, e]) => {
      const days = Object.keys(e.top).sort().slice(-12);
      return { key, name: e.name, days, lb: days.map((d) => e.top[d]) };
    });
}

function weekLines(store: TableStore, clk: Clock): { stat: string; days: string } {
  const days = splitDays(store).filter((d) => !isRest(d));
  const done = doneDays(store, clk);
  return {
    stat: `${days.filter((d) => done.has(d.key)).length} of ${days.length}`,
    days: days.map((d) => q(`${done.has(d.key) ? "✓ " : ""}${d.label} ${d.focus}`)).join(" ") || q("Build your split"),
  };
}

/** This week, as its page: the done count, the days (done ticked), a day picker to change one. */
export function weekScreen(store: TableStore, clk: Clock): string[] {
  const w = weekLines(store, clk);
  return [
    `stat@week-done ${q(w.stat)} "Workouts this week" sub=${q(weekSub(store, clk))}`,
    `list@days title="This week" ${w.days} check=off`, // done days carry a ✓; an empty box beside one read as not done
    `choose@edit-day "Change a day" ${DAY_KEYS.map((k) => DAY_NAMES[k].slice(0, 3)).join("|")} body="Tap a day to change what it trains."`,
    `card@split "Your split" ${q(`${splitDays(store).filter((d) => !isRest(d)).length} training days a week.`)} cta="Rebuild my split"`,
  ];
}

function weekSub(store: TableStore, clk: Clock): string {
  const days = splitDays(store).filter((d) => !isRest(d));
  const done = doneDays(store, clk);
  if (days.length && days.every((d) => done.has(d.key))) return "Every session done. Big week.";
  const next = days.find((d) => !done.has(d.key) && DAY_KEYS.indexOf(d.key as any) >= DAY_KEYS.indexOf(dayKey(clk.today) as any));
  return next ? `Next: ${next.label} ${next.focus}` : days.length ? "Rest up. New week Monday." : "Build your split and this fills in";
}

/** Today's workout, as its page. */
export function todayScreen(store: TableStore, clk: Clock): string[] {
  const d = today(store, clk);
  if (!d) return [`card@today "Today's workout" "Build your split and today's session shows here." cta="Start"`, `list@sets title="Today" "Your split first" +check`];
  const done = doneDays(store, clk).has(d.key);
  if (isRest(d)) {
    return [`card@today "Rest day" "Recovery counts. A walk or a stretch if you feel like it." sub=${q(done ? "Logged a session anyway" : "Today")} cta="Start"`,
            `list@sets title="Rest" "Walk 20 minutes" "Stretch 10 minutes" +check`];
  }
  const s = session(store, d, clk.today);
  const items = s.moves.length ? s.moves.map((m) => q(`${m.name} ${target(m)}${m.lb ? ` at ${m.lb} lb` : ""}`)).join(" ") : q(d.workout || d.focus);
  return [
    `card@today ${q(done ? `Done: ${d.focus}` : "Today's workout")} ${q(done ? "Logged. Rest up, you earned it." : `${d.focus}. About ${d.minutes || 40} minutes.`)} sub=${q(`${d.label}`)} cta=${q(done ? "Go again" : "Start")}`,
    `list@sets title=${q(d.focus)} ${items} +check`,
  ];
}

/** Progress, as its page: the streak, the best set, a chart per main lift. */
export function progressScreen(store: TableStore, clk: Clock): string[] {
  const n = streak(store, clk);
  const best = bestSet(store);
  const lifts = mainLifts(store);
  const out = [
    `stat@streak ${q(`${n} ${n === 1 ? "week" : "weeks"}`)} "Streak" sub=${q(n ? "weeks in a row with a workout" : "Finish a workout and this starts")}`,
    best ? `stat@best ${best.lb}lb "Best set" sub=${q(`${best.exercise}${best.reps ? ` x ${best.reps}` : ""}, ${short(best.day)}`)}`
         : `stat@best "None yet" "Best set" sub="Your heaviest set shows here"`,
  ];
  for (const l of lifts) {
    out.push(`chart@lift-${l.key} line ${q(`${l.name}, top set`)} x=${opts(l.days.map(short))} y=${l.lb.join("|")} unit=lb`);
  }
  if (!lifts.length) out.push(`card@lifts "Your lifts" "Every lift you log gets its own chart here."`);
  return out;
}

/** Which charts Progress holds, so a new lift redraws the page and the rest only patch. */
export const progressShape = (store: TableStore) => mainLifts(store).map((l) => l.key).join(",") || "none";

/**
 * The lines that keep the home current after a change. `full` redraws the pages (the first time after an update,
 * or when Progress gets a new chart); otherwise every line is a patch to a lasting id, which never moves the person.
 */
export function screenLines(store: TableStore, clk: Clock, redraw: { week?: boolean; progress?: boolean }): string[] {
  const out: string[] = [];
  const patch = (lines: string[]) => lines.map((l) => l.replace(/^[a-z]+@/, "~"));
  const week = weekScreen(store, clk);
  if (redraw.week) out.push(">2 clear", ">2", ...week, "save this week");
  else out.push(...patch(week.slice(0, 2)));
  const t = todayScreen(store, clk);
  out.push(...(redraw.week ? [">3 clear", ">3", ...t, "save today"] : patch(t)));
  const p = progressScreen(store, clk);
  if (redraw.progress) out.push(">4 clear", ">4", ...p, "save progress");
  else out.push(...patch(p));
  return out;
}

/** A line for what was logged: "Logged Full body A: 4 moves, 12 sets." */
export function loggedLine(name: string, items: Logged[]): string {
  const sets = items.reduce((a, b) => a + b.sets, 0);
  const moves = items.filter((i) => i.minutes == null || i.reps != null || i.secs != null);
  if (!moves.length || items.every((i) => i.minutes != null && i.reps == null && i.secs == null)) {
    const mins = items[0]?.minutes;
    return `Logged ${name}${mins ? `, ${mins} minutes` : ""}. Nice work.`;
  }
  return `Logged ${name}: ${items.length} ${items.length === 1 ? "move" : "moves"}, ${sets} ${sets === 1 ? "set" : "sets"}. Nice work.`;
}

