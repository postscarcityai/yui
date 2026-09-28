// Copied from runtime/src/study.ts by runtime/scripts/build.mjs. Do not edit here.
// Quill's tools (YUI-186): learn a topic, cards with spaced review, walk me
// through a problem, and his default screens (What you're studying, Next review,
// Progress), kept current with patches.
//
// Chris (Sep 28): "we should focus the next stories on getting the crew more
// tools up with detailed flows... i want the agents to have default screens."
//
// The flows are answered by the runtime from Quill's tables. The model is asked
// once for the thing only a model can write (a lesson, a problem's steps), as
// JSON; the runtime draws it, keeps it and walks the person through it:
//
// 1. Learn a topic: the shortcut, "Teach me <topic>" or a Learn button. One
//    full-screen `plan`: what happens, then the topic, how much time and what
//    they know, one Send. The Send asks the model for the lesson and lands as a
//    deck on the stage, one idea a page, ending in a graded quiz. What it taught
//    becomes rows in `review`, first due tomorrow; the deck in `decks`.
// 2. Cards and spaced review: the cards due today (Next review shows the count).
//    Review is one plan: each card's front, then its answer with Again, Hard,
//    Good or Easy, one Send. Each rating moves the card's box and next day
//    (again: today, hard: tomorrow, good and easy: further out each time).
// 3. Walk me through a problem: a plan asks for the problem; the model breaks it
//    into steps kept in `steps`. One step a reply, one page each, with a graded
//    question; the next step shows only once they answer.
// 4. The screens: >2 What you're studying, >3 Next review, >4 Progress.
import type { NativeAgent, Row } from "./types.ts";
import { type Cell, type Clock, type TableSeed, type TableStore, write } from "./tables.ts";
import { readEvent, shift } from "./workouts.ts";

/** Agents with these tools: Quill and any copy of him (a fork keeps base quill). */
export function studies(agent: NativeAgent): boolean {
  return agent.profile.base === "quill";
}

export const DECKS = "decks";
export const CARDS = "review";
export const SESSIONS = "sessions";
export const PROBLEMS = "problems";
export const STEPS = "steps";
export const TOOL_TABLES = [DECKS, CARDS, SESSIONS, PROBLEMS, STEPS];

/** The plans' questions: the options each shows. */
export const TIME_OPTS = ["5 minutes", "10 minutes", "20 minutes"];
export const KNOW_OPTS = ["Nothing yet", "The basics", "Quite a bit"];
export const RATE_OPTS = ["Again", "Hard", "Good", "Easy"];
export const HELP_OPTS = ["Small steps", "Bigger steps"];
/** How big a lesson is, by the time they have: pages, quiz questions, cards. */
const SIZE: Record<string, { pages: number; quiz: number; cards: number }> = {
  "5 minutes": { pages: 4, quiz: 3, cards: 5 }, "10 minutes": { pages: 6, quiz: 4, cards: 7 }, "20 minutes": { pages: 9, quiz: 5, cards: 10 },
};
/** Days until a card comes back, by the box it lands in. Box 1 is today again. */
const BOX_DAYS = [0, 0, 1, 3, 7, 16, 35];
export const TOP_BOX = 6;
/** A card in this box or higher counts as learned on Progress. */
export const LEARNED_BOX = 4;
/** Cards in one review, at most: a long queue is two short reviews. */
export const REVIEW_MAX = 12;
const WEEK = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

// ---------- small helpers ----------

const q = (s: string) => `"${String(s).replace(/\\/g, "").replace(/"/g, "'").replace(/\|/g, "/").replace(/[–—]/g, ",").replace(/\n/g, " ")}"`;
const opts = (xs: string[]) => xs.map(q).join("|");
const num = (v: Cell | undefined | unknown) => (typeof v === "number" ? v : Number(v) || 0);
const plain = (s: unknown, n = 400) => String(s ?? "").replace(/[–—]/g, ",").replace(/\s+/g, " ").trim().slice(0, n);
export const slug = (s: string) => s.toLowerCase().normalize("NFKD").replace(/&/g, " and ").replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 28).replace(/-$/, "") || "topic";
const rowsOf = (store: TableStore, name: string) => {
  const t = store.tables[name];
  return t ? t.order.map((key) => ({ key, row: t.rows[key] })) : [];
};
const joinWords = (xs: string[]) => (xs.length < 2 ? xs.join("") : `${xs.slice(0, -1).join(", ")} and ${xs[xs.length - 1]}`);
const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;
function weekday(day: string): string {
  const [y, m, d] = day.split("-").map(Number);
  return WEEK[new Date(Date.UTC(y, m - 1, d)).getUTCDay()];
}
/** A day in a sentence: today, tomorrow, or Wed. */
export function dayWord(day: string, clk: Clock): string {
  return day <= clk.today ? "today" : day === shift(clk.today, 1) ? "tomorrow" : weekday(day);
}

// ---------- the tables ----------

const COLS: Record<string, { name: string; type: "text" | "number" | "date" | "bool" }[]> = {
  [DECKS]: [{ name: "Deck", type: "text" }, { name: "Subject", type: "text" }, { name: "Cards", type: "number" }, { name: "Last", type: "date" },
            { name: "Score", type: "text" }],
  [CARDS]: [{ name: "Front", type: "text" }, { name: "Back", type: "text" }, { name: "Deck", type: "text" }, { name: "Box", type: "number" },
            { name: "Due", type: "date" }, { name: "Rated", type: "text" }, { name: "Reviewed", type: "date" }, { name: "Reps", type: "number" }],
  [SESSIONS]: [{ name: "Day", type: "date" }, { name: "Kind", type: "text" }, { name: "Deck", type: "text" }, { name: "Cards", type: "number" },
               { name: "Right", type: "number" }, { name: "Of", type: "number" }],
  [PROBLEMS]: [{ name: "Problem", type: "text" }, { name: "Subject", type: "text" }, { name: "Steps", type: "number" }, { name: "At", type: "number" },
               { name: "Right", type: "number" }, { name: "Done", type: "bool" }, { name: "Day", type: "date" }, { name: "Result", type: "text" }],
  [STEPS]: [{ name: "Problem", type: "text" }, { name: "N", type: "number" }, { name: "Title", type: "text" }, { name: "Body", type: "text" },
            { name: "Tex", type: "text" }, { name: "Ask", type: "text" }, { name: "Options", type: "text" }, { name: "Answer", type: "text" },
            { name: "Why", type: "text" }, { name: "Given", type: "text" }, { name: "Right", type: "bool" }],
};

/**
 * Makes sure Quill's tool tables exist with their columns. A Quill added before YUI-186 has `decks` and `review`
 * with fewer columns: those rows stay as they are, the new columns and tables are added.
 */
export function ensureTools(store: TableStore, seeds: TableSeed[] | undefined, always = false): TableStore {
  // On a plain turn only a Quill who still has his cards is brought up to date: tables they deleted stay deleted
  // until they use one of his tools.
  if (!always && !store.tables[CARDS]) return store;
  let out = store;
  for (const name of TOOL_TABLES) {
    const cols = seeds?.find((s) => s.name === name)?.cols ?? COLS[name];
    const had = out.tables[name];
    if (had && cols.every((c) => had.cols.some((h) => h.name === c.name))) continue;
    // Their own columns stay after ours, so nothing they wrote is lost.
    const merged = had ? [...cols, ...had.cols.filter((h) => !cols.some((c) => c.name === h.name))].slice(0, 12) : cols;
    const r = write(out, { op: "table", name, cols: merged.map((c) => ({ ...c })) as any });
    if (!r.error) out = r.store;
  }
  return out;
}

function put(store: TableStore, table: string, key: string, values: Record<string, unknown>, clk: Clock): TableStore {
  const w = write(store, { op: "put", table, key, values }, clk);
  return w.error ? store : w.store;
}

export interface Card { key: string; front: string; back: string; deck: string; box: number; due: string; reviewed: string; reps: number }

export function cards(store: TableStore): Card[] {
  return rowsOf(store, CARDS).filter(({ row }) => row?.Front && row?.Back).map(({ key, row }) => ({
    key, front: String(row.Front), back: String(row.Back), deck: String(row.Deck ?? ""), box: Math.max(1, num(row.Box) || 1),
    due: String(row.Due ?? "").slice(0, 10), reviewed: String(row.Reviewed ?? "").slice(0, 10), reps: num(row.Reps),
  }));
}

/** Cards due today: no day yet (new) or a day that has come. Lowest box first, then the oldest due. */
export function dueCards(store: TableStore, clk: Clock): Card[] {
  return cards(store).filter((c) => !c.due || c.due <= clk.today)
    .sort((a, b) => a.box - b.box || (a.due || "0").localeCompare(b.due || "0"));
}

/** The next day with cards due after today, and how many. */
export function nextDue(store: TableStore, clk: Clock): { day: string; n: number } | undefined {
  const later = cards(store).filter((c) => c.due > clk.today).map((c) => c.due).sort();
  if (!later.length) return undefined;
  return { day: later[0], n: later.filter((d) => d === later[0]).length };
}

export interface Deck { key: string; deck: string; subject: string; cards: number; last: string; score: string }

export function decks(store: TableStore): Deck[] {
  return rowsOf(store, DECKS).filter(({ row }) => row?.Deck).map(({ key, row }) => ({
    key, deck: String(row.Deck), subject: String(row.Subject ?? ""), cards: num(row.Cards), last: String(row.Last ?? "").slice(0, 10), score: String(row.Score ?? ""),
  }));
}
/** What they're studying now: the deck they last worked on, else the newest. */
export function current(store: TableStore): Deck | undefined {
  const ds = decks(store);
  return [...ds].sort((a, b) => (b.last || "").localeCompare(a.last || ""))[0] ?? ds[ds.length - 1];
}

// ---------- spaced review ----------

/** Where a card goes after a rating: its box and the day it comes back. */
export function schedule(box: number, rating: string, clk: Clock): { box: number; due: string } {
  const r = rating.toLowerCase();
  const b = r === "again" ? 1 : r === "hard" ? Math.max(2, box) : r === "easy" ? Math.min(TOP_BOX, box + 2) : Math.min(TOP_BOX, box + 1);
  // Hard stays where it was but never comes back the same day.
  const days = r === "again" ? 0 : r === "hard" ? Math.max(1, Math.floor(BOX_DAYS[b] / 2)) : BOX_DAYS[b];
  return { box: b, due: shift(clk.today, days) };
}

/** The review's Send: each card rated moves to its box and day; the review kept in `sessions`. */
export function applyReview(store: TableStore, answers: Record<string, unknown>, clk: Clock): { store: TableStore; rated: number; right: number; again: number; left: number } {
  let out = store;
  let rated = 0, right = 0, again = 0;
  const byKey = new Map(cards(out).map((c) => [c.key, c]));
  for (const [id, v] of Object.entries(answers)) {
    const c = byKey.get(id.replace(/^c-/, ""));
    const rating = RATE_OPTS.find((o) => o.toLowerCase() === String(v).toLowerCase());
    if (!c || !rating || !id.startsWith("c-")) continue;
    const s = schedule(c.box, rating, clk);
    out = put(out, CARDS, c.key, { Box: s.box, Due: s.due, Rated: rating, Reviewed: clk.today, Reps: c.reps + 1 }, clk);
    rated++;
    if (rating === "Again") again++;
    else right++;
  }
  if (rated) {
    const decksHit = [...new Set([...byKey.values()].filter((c) => answers[`c-${c.key}`] != null).map((c) => c.deck).filter(Boolean))];
    out = logSession(out, { Kind: "Review", Deck: decksHit.join(", ").slice(0, 200), Cards: rated, Right: right, Of: rated }, clk);
    for (const d of decks(out)) if (decksHit.includes(d.deck)) out = put(out, DECKS, d.key, { Last: clk.today }, clk);
  }
  return { store: out, rated, right, again, left: dueCards(out, clk).length };
}

function logSession(store: TableStore, values: Record<string, unknown>, clk: Clock): TableStore {
  let key = `${clk.today}-${slug(String(values.Kind))}`;
  for (let i = 2; store.tables[SESSIONS]?.rows[key]; i++) key = `${clk.today}-${slug(String(values.Kind))}-${i}`;
  return put(store, SESSIONS, key, { Day: clk.today, ...values }, clk);
}

// ---------- the flows ----------

/** Learn a topic: what happens first, then the questions (topic, time, what they know), one Send. */
export function learnBody(store: TableStore, topic = ""): string {
  const has = decks(store).length;
  const lines = [
    `plan@learn "Learn a topic" submit="Teach me"`,
    `page "Five minutes, then a quiz" body=${q(`Tell me what you want to learn, how long you have and what you know already. I'll make a short lesson, one idea a page, with a quick quiz at the end. What you learn becomes cards you review later${has ? `, next to your ${plural(has, "deck")}` : ""}.`)}`,
    ...(topic ? [] : [`form@topic "What do you want to learn?" topic:voice! submit=Next`]),
    `choose@time "How much time do you have?" ${opts(TIME_OPTS)}`,
    `choose@know ${q(topic ? `What do you know about ${topic} already?` : "What do you know about it already?")} ${opts(KNOW_OPTS)}`,
  ];
  return `${topic ? `Let's learn ${topic}.` : "Let's learn something."}\n\`\`\`yui\n${lines.join("\n")}\n\`\`\``;
}

/** The learn plan's answers as what the lesson needs. */
export function readLearn(a: Record<string, unknown>, said = ""): { topic: string; time: string; know: string } {
  const f = a.topic;
  const topic = plain(f && typeof f === "object" ? Object.values(f as Record<string, unknown>).join(" ") : f ?? said, 120);
  const time = TIME_OPTS.includes(String(a.time)) ? String(a.time) : TIME_OPTS[0];
  const know = KNOW_OPTS.includes(String(a.know)) ? String(a.know) : KNOW_OPTS[0];
  return { topic, time, know };
}

/** Review: the cards due today, each its front then its answer with a rating, one Send. */
export function reviewBody(store: TableStore, clk: Clock): string {
  const due = dueCards(store, clk);
  if (!due.length) {
    const n = nextDue(store, clk);
    return `Nothing to review today.${n ? ` Next review: ${dayWord(n.day, clk)}, ${plural(n.n, "card")}.` : ""} Want to learn something new?\n\`\`\`yui\ncard "All caught up" "Learn a topic and it joins your review." cta="Learn something new"\n\`\`\``;
  }
  const now = due.slice(0, REVIEW_MAX);
  const more = due.length - now.length;
  const lines = [
    `plan@review ${q(`Review ${plural(now.length, "card")}`)} submit="Save my review"`,
    `page ${q(`${plural(now.length, "card")} due`)} body=${q(`Think of the answer before you look. Then tap how it went: Again brings it back today, Easy sends it furthest.${more ? ` ${more} more after these.` : ""}`)}`,
    ...now.map((c) => `choose@c-${c.key} ${q(c.back)} ${opts(RATE_OPTS)} title=${q(c.front)}${c.deck ? ` tag=${q(c.deck)}` : ""}`),
  ];
  return `\`\`\`yui\n${lines.join("\n")}\n\`\`\``;
}

/** Walk me through a problem: how it goes first, then the problem and how big the steps are, one Send. */
export function problemBody(): string {
  const lines = [
    `plan@problem "Walk me through a problem" submit="Start"`,
    `page "One step at a time" body="Type or say the problem. I'll break it into steps, one a page. You answer each step before the next one shows, so you do the thinking."`,
    `form@question "What's the problem?" problem:voice! submit=Next`,
    `choose@size "How big should the steps be?" ${opts(HELP_OPTS)}`,
  ];
  return `\`\`\`yui\n${lines.join("\n")}\n\`\`\``;
}

export function readProblem(a: Record<string, unknown>): { problem: string; small: boolean } {
  const f = a.question ?? a.problem;
  const problem = plain(f && typeof f === "object" ? Object.values(f as Record<string, unknown>).join(" ") : f, 600);
  return { problem, small: String(a.size ?? HELP_OPTS[0]) !== HELP_OPTS[1] };
}

// ---------- the model's part ----------

export const LESSON_PROMPT = `You write short lessons for a study app. Answer with ONE JSON object and nothing else:
{"title": "...", "subject": "...", "pages": [{"title": "...", "body": "...", "points": ["..."], "tex": "..."}],
 "quiz": [{"q": "...", "options": ["...", "...", "..."], "answer": "...", "why": "..."}],
 "cards": [{"front": "...", "back": "..."}]}
Rules: one idea a page, a body of one to three short sentences, points optional (at most 4, a few words each), tex only
when a formula helps (plain LaTeX, no dollar signs). Quiz: 3 or 4 options, "answer" is exactly one of them, "why" one
short sentence. Cards: a question on the front, a short answer on the back (a word or a phrase), about what the lesson
taught. Plain words, friendly, no em dashes, no markdown. Fit the level they said.`;

export const PROBLEM_PROMPT = `You break a problem into steps for a study app, so the person solves it themselves. Answer with ONE JSON object
and nothing else:
{"title": "...", "subject": "...", "steps": [{"title": "...", "body": "...", "tex": "...", "ask": "...", "options": ["...", "...", "..."], "answer": "...", "why": "..."}],
 "result": "..."}
Rules: each step is one move toward the answer. "body" says what to do in one or two short sentences (never the
step's answer). "tex" is optional plain LaTeX for the expression the step works on. "ask" is one question whose answer
is that step's result; 3 or 4 short options, "answer" exactly one of them, "why" one short sentence. "result" is the
final answer in a few words. Plain words, no em dashes, no markdown. If it is graded work to hand in, still teach it
step by step; never write an essay for them.`;

export interface Lesson {
  title: string; subject: string;
  pages: { title: string; body: string; points: string[]; tex: string }[];
  quiz: { q: string; options: string[]; answer: string; why: string }[];
  cards: { front: string; back: string }[];
}
export interface Problem {
  title: string; subject: string; result: string;
  steps: { title: string; body: string; tex: string; ask: string; options: string[]; answer: string; why: string }[];
}

/** The first JSON object in the model's answer, or null. */
function jsonOf(text: string): any {
  const s = String(text ?? "").replace(/^```(?:json)?\s*|\s*```$/g, "");
  const a = s.indexOf("{"), b = s.lastIndexOf("}");
  if (a < 0 || b <= a) return null;
  try {
    return JSON.parse(s.slice(a, b + 1));
  } catch {
    return null;
  }
}
const texOf = (v: unknown) => String(v ?? "").replace(/^\$+|\$+$/g, "").trim().slice(0, 300);
function question(x: any): { q: string; options: string[]; answer: string; why: string } | null {
  const options = (Array.isArray(x?.options) ? x.options : []).map((o: unknown) => plain(o, 80)).filter(Boolean).slice(0, 4);
  const answer = plain(x?.answer, 80);
  const q0 = plain(x?.q ?? x?.ask ?? x?.question, 200);
  if (!q0 || options.length < 2 || !options.includes(answer)) return null;
  return { q: q0, options, answer, why: plain(x?.why, 200) };
}

export function parseLesson(text: string, time = TIME_OPTS[0]): Lesson | null {
  const j = jsonOf(text);
  if (!j || !Array.isArray(j.pages)) return null;
  const size = SIZE[time] ?? SIZE[TIME_OPTS[0]];
  const pages = j.pages.map((p: any) => ({ title: plain(p?.title, 80), body: plain(p?.body, 400),
                                           points: (Array.isArray(p?.points) ? p.points : []).map((x: unknown) => plain(x, 80)).filter(Boolean).slice(0, 4),
                                           tex: texOf(p?.tex) }))
    .filter((p: { title: string }) => p.title).slice(0, size.pages + 2);
  const quiz = (Array.isArray(j.quiz) ? j.quiz : []).map(question).filter(Boolean).slice(0, size.quiz + 1) as Lesson["quiz"];
  const cards = (Array.isArray(j.cards) ? j.cards : []).map((c: any) => ({ front: plain(c?.front, 200), back: plain(c?.back, 200) }))
    .filter((c: { front: string; back: string }) => c.front && c.back).slice(0, size.cards + 2);
  if (!pages.length) return null;
  return { title: plain(j.title, 60) || pages[0].title, subject: plain(j.subject, 40), pages, quiz, cards };
}

export function parseProblem(text: string): Problem | null {
  const j = jsonOf(text);
  if (!j || !Array.isArray(j.steps)) return null;
  const steps = j.steps.map((s: any) => {
    const qq = question({ ...s, q: s?.ask });
    return qq ? { title: plain(s?.title, 80) || "Next step", body: plain(s?.body, 400), tex: texOf(s?.tex), ask: qq.q, options: qq.options, answer: qq.answer, why: qq.why } : null;
  }).filter(Boolean).slice(0, 8) as Problem["steps"];
  if (!steps.length) return null;
  return { title: plain(j.title, 60) || "Your problem", subject: plain(j.subject, 40), result: plain(j.result, 200), steps };
}

/** The ask for the model: the lesson they want, at their level and length. */
export function lessonAsk(l: { topic: string; time: string; know: string }): string {
  const size = SIZE[l.time] ?? SIZE[TIME_OPTS[0]];
  return `Topic: ${l.topic}\nTime: ${l.time} (${size.pages} pages, ${size.quiz} quiz questions, ${size.cards} cards)\nWhat they know: ${l.know}`;
}
export function problemAsk(p: { problem: string; small: boolean }): string {
  return `The problem: ${p.problem}\nSteps: ${p.small ? "small ones, 3 to 6" : "bigger ones, 2 to 4"}`;
}

// ---------- keeping what the model wrote ----------

const keyIn = (store: TableStore, table: string, base: string) => {
  let key = base;
  for (let i = 2; store.tables[table]?.rows[key]; i++) key = `${base.slice(0, 24)}-${i}`;
  return key;
};

/** A lesson kept: its deck (or the same deck again, a lesson on it once more) and its cards, first due tomorrow. */
export function keepLesson(store: TableStore, l: Lesson, clk: Clock): { store: TableStore; key: string; added: number } {
  let out = store;
  const same = decks(out).find((d) => d.deck.toLowerCase() === l.title.toLowerCase());
  const key = same?.key ?? keyIn(out, DECKS, slug(l.title));
  const have = new Set(cards(out).map((c) => c.front.toLowerCase()));
  let added = 0;
  for (const c of l.cards) {
    if (have.has(c.front.toLowerCase())) continue;
    have.add(c.front.toLowerCase());
    out = put(out, CARDS, keyIn(out, CARDS, `${key.slice(0, 20)}-${added + 1}`), { Front: c.front, Back: c.back, Deck: l.title, Box: 1, Due: shift(clk.today, 1), Reps: 0 }, clk);
    added++;
  }
  const total = cards(out).filter((c) => c.deck === l.title).length;
  out = put(out, DECKS, key, { Deck: l.title, Subject: l.subject || same?.subject || "", Cards: total, Last: clk.today }, clk);
  return { store: out, key, added };
}

/** The lesson as one deck on the stage: a page an idea (its formula as its picture), then the quiz. */
export function lessonBody(l: Lesson, key: string, added: number, time: string): string {
  const lines = [`deck@lesson-${key} ${q(l.title)} +full`];
  for (const p of l.pages) {
    lines.push(`page ${q(p.title)}${p.body ? ` body=${q(p.body)}` : ""}${p.points.length ? ` points=${opts(p.points)}` : ""}`);
    if (p.tex) lines.push(`math ${p.tex.replace(/\n/g, " ")}`);
  }
  l.quiz.forEach((x, i) => lines.push(`choose@quiz-${key}-${i + 1} ${q(x.q)} ${opts(x.options)} answer=${q(x.answer)}${x.why ? ` why=${q(x.why)}` : ""}`));
  const mins = time.replace(" minutes", " minute");
  const head = `Here's ${l.title} in a ${mins} lesson.${l.quiz.length ? ` A ${l.quiz.length} question quiz at the end.` : ""}`
    + `${added ? ` ${plural(added, "card")} go in your review, first one tomorrow.` : ""}`;
  return `${head}\n\`\`\`yui\n${lines.join("\n")}\n\`\`\``;
}

/** A problem kept: the problem and one row a step, at step 1. */
export function keepProblem(store: TableStore, p: Problem, words: string, clk: Clock): { store: TableStore; key: string } {
  let out = store;
  const key = keyIn(out, PROBLEMS, `${slug(p.title).slice(0, 20)}-${clk.today.slice(5).replace("-", "")}`);
  out = put(out, PROBLEMS, key, { Problem: plain(words || p.title, 600), Subject: p.subject, Steps: p.steps.length, At: 1, Right: 0, Done: false, Day: clk.today, Result: p.result }, clk);
  p.steps.forEach((s, i) => {
    out = put(out, STEPS, `${key}-${i + 1}`, { Problem: key, N: i + 1, Title: s.title, Body: s.body, Tex: s.tex, Ask: s.ask, Options: s.options.join("|"),
                                              Answer: s.answer, Why: s.why }, clk);
  });
  return { store: out, key };
}

export interface Step { key: string; n: number; title: string; body: string; tex: string; ask: string; options: string[]; answer: string; why: string; given: string; right: boolean }
export interface ProblemRow { key: string; problem: string; subject: string; steps: number; at: number; right: number; done: boolean; day: string; result: string }

export function problems(store: TableStore): ProblemRow[] {
  return rowsOf(store, PROBLEMS).filter(({ row }) => row).map(({ key, row }) => ({
    key, problem: String(row.Problem ?? ""), subject: String(row.Subject ?? ""), steps: num(row.Steps), at: num(row.At) || 1, right: num(row.Right),
    done: row.Done === true, day: String(row.Day ?? "").slice(0, 10), result: String(row.Result ?? ""),
  }));
}
export function stepsOf(store: TableStore, problem: string): Step[] {
  return rowsOf(store, STEPS).filter(({ row }) => row?.Problem === problem).map(({ key, row }) => ({
    key, n: num(row.N), title: String(row.Title ?? ""), body: String(row.Body ?? ""), tex: String(row.Tex ?? ""), ask: String(row.Ask ?? ""),
    options: String(row.Options ?? "").split("|").filter(Boolean), answer: String(row.Answer ?? ""), why: String(row.Why ?? ""),
    given: String(row.Given ?? ""), right: row.Right === true,
  })).sort((a, b) => a.n - b.n);
}

/** One step as its own page: the step's words and expression, then its question. The next shows once it's answered. */
export function stepLines(p: ProblemRow, s: Step): string[] {
  return [
    `page ${q(`Step ${s.n} of ${p.steps}: ${s.title}`)}${s.body ? ` body=${q(s.body)}` : ""}`,
    ...(s.tex ? [`math ${s.tex.replace(/\n/g, " ")}`] : []),
    `choose@step-${p.key}-${s.n} ${q(s.ask)} ${opts(s.options)} answer=${q(s.answer)}${s.why ? ` why=${q(s.why)}` : ""}`,
  ];
}

/** An answer to a step: kept, and the problem moves on to the next step (or is done). Answers to old steps change nothing. */
export function answerStep(store: TableStore, problem: string, n: number, choice: string, clk: Clock):
  { store: TableStore; p?: ProblemRow; step?: Step; right?: boolean; next?: Step; stale?: boolean } {
  const p = problems(store).find((x) => x.key === problem);
  if (!p) return { store };
  const steps = stepsOf(store, problem);
  const step = steps.find((s) => s.n === n);
  if (!step) return { store, p };
  if (p.done || n !== p.at) return { store, p, step, stale: true };
  const right = choice.trim().toLowerCase() === step.answer.trim().toLowerCase();
  let out = put(store, STEPS, step.key, { Given: choice, Right: right }, clk);
  const next = steps.find((s) => s.n === n + 1);
  const score = p.right + (right ? 1 : 0);
  out = put(out, PROBLEMS, p.key, { At: next ? n + 1 : n, Right: score, Done: !next }, clk);
  if (!next) out = logSession(out, { Kind: "Problem", Deck: p.subject || "Problem", Cards: 0, Right: score, Of: p.steps }, clk);
  const after = problems(out).find((x) => x.key === problem)!;
  return { store: out, p: after, step, right, next };
}

/** A quiz finished: its score on the deck and in `sessions`. */
export function applyQuiz(store: TableStore, deckKey: string, score: number, of: number, clk: Clock): { store: TableStore; deck?: Deck } {
  const d = decks(store).find((x) => x.key === deckKey);
  if (!d) return { store };
  let out = put(store, DECKS, d.key, { Score: `${score} of ${of}`, Last: clk.today }, clk);
  out = logSession(out, { Kind: "Quiz", Deck: d.deck, Cards: 0, Right: score, Of: of }, clk);
  return { store: out, deck: d };
}

/** "What should I review next?", from the table. */
export function nextText(store: TableStore, clk: Clock): string {
  const due = dueCards(store, clk);
  if (due.length) {
    const ds = [...new Set(due.map((c) => c.deck).filter(Boolean))];
    return `${plural(due.length, "card")} due today${ds.length ? `, from ${joinWords(ds.slice(0, 2))}` : ""}. Here's the review.`;
  }
  const n = nextDue(store, clk);
  return n ? `Nothing due today. Next review: ${dayWord(n.day, clk)}, ${plural(n.n, "card")}.` : "Nothing to review yet. Learn a topic and I'll make cards from it.";
}

// ---------- the screens ----------

/** Days in a row with a review, quiz or problem, up to today (yesterday counts while today has none yet). */
export function streak(store: TableStore, clk: Clock): number {
  const days = new Set(rowsOf(store, SESSIONS).map(({ row }) => String(row?.Day ?? "").slice(0, 10)));
  let d = days.has(clk.today) ? clk.today : shift(clk.today, -1);
  let n = 0;
  while (days.has(d)) {
    n++;
    d = shift(d, -1);
  }
  return n;
}

/** What you're studying, as its page: the deck now, every deck, learn something new, walk me through a problem. */
export function studyingScreen(store: TableStore, clk: Clock): string[] {
  const d = current(store);
  const due = dueCards(store, clk);
  const ds = decks(store);
  const dueIn = d ? due.filter((c) => c.deck === d.deck).length : 0;
  const card = d
    ? `card@studying ${q(d.deck)} ${q(`${plural(d.cards, "card")}. ${dueIn ? `${dueIn} due today.` : "None due today."}${d.score ? ` Last quiz: ${d.score}.` : ""}`)} sub=${q(d.subject || "What you're studying")} cta=${q(dueIn ? "Review now" : "Learn more")}`
    : `card@studying "Nothing yet" "Pick a topic and I'll teach it in five minutes." sub="What you're studying" cta="Learn something new"`;
  const items = ds.length ? ds.slice(-8).reverse().map((x) => `${x.deck}, ${plural(x.cards, "card")}`) : ["No decks yet"];
  return [
    card,
    `list@decks title="Your decks" ${opts(items)}`,
    `card@learn-new "Learn something new" "A topic, how long you have, what you know. A short lesson, then a quiz." cta="Learn a topic"`,
    `card@walk "Stuck on a problem?" "I'll break it into steps. You answer each one before the next." cta="Walk me through it"`,
  ];
}

/** Next review, as its page: the due count and Start, or when the next one is. */
export function reviewScreen(store: TableStore, clk: Clock): string[] {
  const due = dueCards(store, clk);
  const n = nextDue(store, clk);
  const ds = [...new Set(due.map((c) => c.deck).filter(Boolean))];
  if (due.length) {
    return [
      `stat@due ${due.length} "Cards due today" sub=${q(ds.length ? joinWords(ds.slice(0, 2)) : "Ready now")}`,
      `card@review-start ${q(`Review ${plural(Math.min(due.length, REVIEW_MAX), "card")}`)} "Think of the answer, then tap again, hard, good or easy." cta="Start review"`,
    ];
  }
  return [
    `stat@due 0 "Cards due today" sub=${q(n ? `Next review: ${dayWord(n.day, clk)}, ${plural(n.n, "card")}` : "No cards yet")}`,
    `card@review-start "All caught up" "Learn a topic and its cards join your review." cta="Learn something new"`,
  ];
}

/** Progress, as its page: the streak, cards reviewed each day this week, cards learned. */
export function progressScreen(store: TableStore, clk: Clock): string[] {
  const days = Array.from({ length: 7 }, (_, i) => shift(clk.today, i - 6));
  const per = new Map<string, number>();
  for (const { row } of rowsOf(store, SESSIONS)) if (row?.Kind === "Review") per.set(String(row.Day).slice(0, 10), (per.get(String(row.Day).slice(0, 10)) ?? 0) + num(row.Cards));
  const all = cards(store);
  const learned = all.filter((c) => c.box >= LEARNED_BOX).length;
  const s = streak(store, clk);
  const quizzes = rowsOf(store, SESSIONS).filter(({ row }) => row?.Kind === "Quiz" || row?.Kind === "Problem");
  const lastQ = quizzes[quizzes.length - 1]?.row;
  return [
    `stat@streak ${s} "Day streak" sub=${q(s ? "Keep it going today" : "Review today to start one")}`,
    // Before the first review a plain week (the home draws it on any day); after, the last seven days to today.
    per.size ? `chart@studied bar "Cards reviewed" x=${days.map((d) => (d === clk.today ? "Today" : weekday(d))).join("|")} y=${days.map((d) => per.get(d) ?? 0).join("|")}`
      : `chart@studied bar "Cards reviewed" x=Mon|Tue|Wed|Thu|Fri|Sat|Sun y=0|0|0|0|0|0|0`,
    `stat@learned ${learned} "Cards learned" sub=${q(`of ${plural(all.length, "card")}, box ${LEARNED_BOX} or higher`)}`,
    `stat@last-quiz ${q(lastQ ? `${num(lastQ.Right)}/${num(lastQ.Of)}` : "None")} "Last quiz" sub=${q(lastQ ? `${lastQ.Deck || lastQ.Kind}` : "Finish a lesson's quiz")}`,
  ];
}

export type Page = "studying" | "review" | "progress";
const PAGES: { page: Page; screen: string; name: string; lines: (s: TableStore, c: Clock) => string[] }[] = [
  { page: "studying", screen: "2", name: "studying", lines: studyingScreen },
  { page: "review", screen: "3", name: "next review", lines: reviewScreen },
  { page: "progress", screen: "4", name: "progress", lines: progressScreen },
];
export const SHAPE = "v1";

/**
 * The pages as the phone has them: drawn by the runtime already, or a home that is this one (YUI-186, its Start
 * review card is the mark). A home from before gets every page drawn again once.
 */
export function drawnShape(p: { studyScreens?: string; home?: string }): string | undefined {
  if (p.studyScreens) return p.studyScreens;
  return /\bcard@review-start\b/.test(p.home ?? "") ? SHAPE : undefined;
}

/**
 * The lines that keep Quill's pages current. The first time (a home from before YUI-186) every page is drawn again;
 * after that only patches go, which never move the person: every page keeps the same components, so a patch
 * rewrites each in place.
 */
export function screenLines(store: TableStore, clk: Clock, was: string | undefined, only: Page[] = ["studying", "review", "progress"]): { lines: string[]; shape: string } {
  const out: string[] = [];
  const first = was !== SHAPE;
  for (const p of PAGES) {
    if (first) out.push(`>${p.screen} clear`, `>${p.screen}`, ...p.lines(store, clk), `save ${p.name}`);
    else if (only.includes(p.page)) out.push(...p.lines(store, clk).map((l) => l.replace(/^[a-z]+@/, "~")));
  }
  return { lines: out, shape: SHAPE };
}

/** Which of Quill's pages a table change touches (a model turn that wrote his tables). */
export function studyPages(ch: { rows: { table: string }[]; dropRows: { table: string }[]; tables: { name: string }[] }): Page[] {
  const names = new Set([...ch.rows.map((r) => r.table), ...ch.dropRows.map((r) => r.table), ...ch.tables.map((t) => t.name)]);
  const out: Page[] = [];
  if (names.has(DECKS) || names.has(CARDS)) out.push("studying", "review");
  if (names.has(SESSIONS) || names.has(CARDS)) out.push("progress");
  return out;
}

// ---------- taps and words ----------

export type StudyAsk =
  | { kind: "learn"; row: Row; topic: string }
  | { kind: "learned"; row: Row; answers: Record<string, unknown> }
  | { kind: "review"; row: Row }
  | { kind: "next"; row: Row }
  | { kind: "reviewed"; row: Row; answers: Record<string, unknown> }
  | { kind: "problem"; row: Row; words: string }
  | { kind: "posed"; row: Row; answers: Record<string, unknown> }
  | { kind: "step"; row: Row; problem: string; n: number; choice: string }
  | { kind: "quizdone"; row: Row; deck: string; score: number; of: number }
  | { kind: "quiet"; row: Row };

const LEARN_WORDS = /^\s*(?:(?:please|can you|could you|let'?s)\s+)?(?:teach\s+me(?:\s+about)?|i\s+(?:want|would like|'?d like)\s+to\s+learn(?:\s+about)?|help\s+me\s+learn(?:\s+about)?|learn\s+about)\s+(.{2,80}?)\s*(?:please)?\s*[.!?]*\s*$/i;
const LEARN_NEW = /^\s*(?:(?:please|can you|let'?s)\s+)?(?:teach\s+me\s+something(?:\s+new)?|learn\s+(?:something(?:\s+new)?|a\s+(?:new\s+)?topic)|new\s+lesson)\s*[.!?]*\s*$/i;
const REVIEW_WORDS = /^\s*(?:(?:let'?s|please|can you)\s+)?(?:review(?:\s+my)?\s+(?:cards|flashcards|deck)|start\s+(?:my\s+|the\s+)?review|quiz\s+me|review(?:\s+time)?|flashcards)\s*[.!?]*\s*$/i;
const NEXT_WORDS = /^\s*what\s+(?:should|do)\s+i\s+(?:review|study)(?:\s+next|\s+today)?\s*\??\s*$|^\s*what'?s\s+(?:due|next\s+to\s+review)(?:\s+today)?\s*\??\s*$|^\s*(?:any\s+)?cards\s+due(?:\s+today)?\s*\??\s*$/i;
const PROBLEM_NEW = /^\s*(?:(?:please|can you|could you)\s+)?(?:walk\s+me\s+through\s+(?:a\s+)?problem|help\s+me\s+(?:solve|with)\s+a\s+problem|step\s+by\s+step\s+problem)\s*[.!?]*\s*$/i;
const PROBLEM_WORDS = /^\s*(?:(?:please|can you|could you)\s+)?(?:walk\s+me\s+through|help\s+me\s+solve|solve\s+with\s+me)\s*:?\s+(.{3,})$/is;
const TOPIC_NOT = /^(?:it|this|that|something(?:\s+new)?|a\s+(?:new\s+)?topic|me)$/i;

/** The rows in a turn the runtime answers itself (Quill's words and taps), and the rest for the model. */
export function studyAsks(rows: Row[]): { asks: StudyAsk[]; rest: Row[] } {
  const asks: StudyAsk[] = [];
  const rest: Row[] = [];
  for (const r of rows) {
    const body = r.body ?? "";
    const e = /^\[yui\]\s/.test(body) || r.kind === "event" ? readEvent(r) : null;
    let a: StudyAsk | null = null;
    if (!e && r.kind !== "event") {
      const topic = body.match(LEARN_WORDS)?.[1]?.trim();
      const prob = body.match(PROBLEM_WORDS)?.[1]?.trim();
      if (LEARN_NEW.test(body)) a = { kind: "learn", row: r, topic: "" };
      else if (topic && !TOPIC_NOT.test(topic)) a = { kind: "learn", row: r, topic: plain(topic, 80) };
      else if (NEXT_WORDS.test(body)) a = { kind: "next", row: r };
      else if (REVIEW_WORDS.test(body)) a = { kind: "review", row: r };
      else if (PROBLEM_NEW.test(body)) a = { kind: "problem", row: r, words: "" };
      else if (prob && !/^(?:a\s+)?problem[.!?]*$/i.test(prob)) a = { kind: "problem", row: r, words: plain(prob, 600) };
    } else if (e) {
      const v = e.value;
      const plan = v.plan && typeof v.plan === "object" ? (v.plan as Record<string, unknown>) : null;
      const step = e.id.match(/^step-(.+)-(\d+)$/);
      if (e.preset === "plan" && e.id === "learn" && plan) a = { kind: "learned", row: r, answers: plan };
      else if (e.preset === "plan" && e.id === "review" && plan) a = { kind: "reviewed", row: r, answers: plan };
      else if (e.preset === "plan" && e.id === "problem" && plan) a = { kind: "posed", row: r, answers: plan };
      else if (e.preset === "choose" && step && v.choice != null) a = { kind: "step", row: r, problem: step[1], n: Number(step[2]), choice: String(v.choice) };
      // A quiz page's own answer: the deck's done event carries the score, so this one needs nothing.
      else if (e.preset === "choose" && /^quiz-/.test(e.id)) a = { kind: "quiet", row: r };
      else if (e.preset === "deck" && /^lesson-/.test(e.id)) {
        a = v.done && num(v.of) ? { kind: "quizdone", row: r, deck: e.id.slice(7), score: num(v.score), of: num(v.of) } : { kind: "quiet", row: r };
      } else if (e.preset === "choose" && e.id === "learn-subject" && v.choice != null) {
        a = { kind: "learn", row: r, topic: v.other ? plain(v.choice, 80) : /something else/i.test(String(v.choice)) ? "" : plain(v.choice, 80) };
      } else if (e.preset === "card" && v.cta != null) {
        const cta = String(v.cta);
        if (/start review|review now/i.test(cta)) a = { kind: "review", row: r };
        else if (/walk me through/i.test(cta)) a = { kind: "problem", row: r, words: "" };
        else if (/learn/i.test(cta)) a = { kind: "learn", row: r, topic: "" };
      }
    }
    if (a) asks.push(a);
    else rest.push(r);
  }
  return { asks, rest };
}
