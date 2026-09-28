// Gouda's tools (YUI-184): learn a song and play along, the practice log,
// saved sessions, and his default screens (Looper, Chords, Keys, Practice),
// kept current with patches. The instruments are the music presets (YUI-116,
// yuigui spec/MUSIC.md): loop, chords, keys, metronome, drums.
//
// Chris (Sep 28): "we should focus the next stories on getting the crew more
// tools up with detailed flows... i want the agents to have default screens."
//
// Every tool here is answered by the runtime itself, with no model turn and no
// free turn spent, because the data is already in Gouda's tables:
//
// 1. Learn a song: the shortcut, "Learn a song" or a Learn button. One
//    full-screen `plan`: what happens first, then the song (his `songs`, or
//    their own chords pasted), the key and the speed, one Send. The Send keeps
//    the lesson in `studio` and lands on the Chords page: the chords as
//    buttons, the click counting in at the chosen speed, a speed picker and a
//    bar picker. Slow it down and loop the hard bar are patches; Keys follows
//    the song's key.
// 2. The practice log: `practice` (minutes, what, how it went). A short plan
//    ("Log practice"), words ("I practiced 20 minutes"), or the click itself:
//    a metronome stopped after 10 seconds or more logs its minutes. Practice
//    shows the streak, this week, a chart and one "what to practice next" line.
// 3. Sessions: the Looper's Send (or a drum take) opens a short plan to name
//    it; the Send keeps it in `sessions`, and "Open a beat" on the Looper, or
//    "open <name>", puts it back on the looper as they left it.
// 4. The screens: >2 Looper, >3 Chords, >4 Keys, >5 Practice. Answers patch them.
import type { NativeAgent, Row } from "./types.ts";
import { type Cell, type Clock, type TableSeed, type TableStore, write } from "./tables.ts";
import { readEvent, shift } from "./workouts.ts";

/** Agents with these tools: Gouda and any copy of him (a fork keeps base gouda). */
export function playsMusic(agent: NativeAgent): boolean {
  return agent.profile.base === "gouda";
}

export const LOOPS = "loops";
export const SONGS = "songs";
export const PRACTICE = "practice";
export const SESSIONS = "sessions";
export const STUDIO = "studio";
export const TOOL_TABLES = [PRACTICE, SESSIONS, STUDIO];

/** The plan's questions: the options each shows. */
export const OWN = "My own chords";
export const KEY_OPTS = ["As written", "Easiest on guitar", "Up a step", "Down a step"];
export const SPEED_OPTS = ["Half speed", "75%", "Full speed"];
export const PAGE_SPEEDS = ["Half", "75%", "90%", "Full"];
export const SCALE_OPTS = ["Major", "Minor", "Pentatonic", "Blues"];
export const MINUTES_OPTS = ["5 min", "10 min", "15 min", "20 min", "30 min", "45 min", "1 hour"];
export const WHAT_OPTS = ["Chords", "Scales", "Beats", "Ear training", "Theory"];
export const FEEL_OPTS = ["Rough", "Getting there", "Nailed it"];
export const THEN_OPTS = ["Keep it on my Looper", "Just save it"];
export const WHOLE = "Whole song";
const WEEK = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

// ---------- small helpers ----------

const q = (s: string) => `"${String(s).replace(/\\/g, "").replace(/"/g, "'").replace(/\|/g, "/").replace(/[–—]/g, ",").replace(/\n/g, " ")}"`;
const opts = (xs: string[]) => xs.map(q).join("|");
const num = (v: Cell | undefined | unknown) => (typeof v === "number" ? v : Number(v) || 0);
export const slug = (s: string) => s.toLowerCase().normalize("NFKD").replace(/&/g, " and ").replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 48) || "item";
const rowsOf = (store: TableStore, name: string) => {
  const t = store.tables[name];
  return t ? t.order.map((key) => ({ key, row: t.rows[key] })) : [];
};
const list = (v: unknown): string[] => (Array.isArray(v) ? v.map(String) : typeof v === "string" && v ? v.split("|") : []);
const put = (store: TableStore, table: string, key: string, values: Record<string, unknown>, clk?: Clock) => {
  const w = write(store, { op: "put", table, key, values }, clk);
  return w.error ? store : w.store;
};
const joinWords = (xs: string[]) => (xs.length < 2 ? xs.join("") : `${xs.slice(0, -1).join(", ")} and ${xs[xs.length - 1]}`);

// ---------- the tables ----------

/**
 * Makes sure Gouda's tool tables exist. A Gouda added before YUI-184 has only `loops` and `songs` (no chords): the
 * missing tables come from his starter seeds, `songs` gains its Chords column, and a starter song he still has gets
 * its chart. Nothing the person wrote is overwritten.
 */
export function ensureTools(store: TableStore, seeds: TableSeed[] | undefined): TableStore {
  let out = store;
  for (const name of [...TOOL_TABLES, SONGS, LOOPS]) {
    const seed = seeds?.find((s) => s.name === name);
    if (!seed) continue;
    const had = out.tables[name];
    if (had && seed.cols.every((c) => had.cols.some((h) => h.name === c.name))) continue;
    // A new table, or `songs` from before: the seed's columns (a column they added stays).
    const cols = had ? [...seed.cols, ...had.cols.filter((h) => !seed.cols.some((c) => c.name === h.name))] : seed.cols;
    const r = write(out, { op: "table", name, cols });
    if (r.error) continue;
    out = r.store;
    if (name !== SONGS && name !== LOOPS) continue;
    for (const row of seed.rows) {
      const now = out.tables[name].rows[row.key];
      if (!now && had) continue; // a starter song they took off stays off
      if (now && (name !== SONGS || now.Chords)) continue;
      out = put(out, name, row.key, now ? { Chords: row.values.Chords } : row.values);
    }
  }
  return out;
}

// ---------- chords and keys ----------

const PC: Record<string, number> = { C: 0, "B#": 0, "C#": 1, Db: 1, D: 2, "D#": 3, Eb: 3, E: 4, Fb: 4, F: 5, "E#": 5, "F#": 6, Gb: 6, G: 7,
                                     "G#": 8, Ab: 8, A: 9, "A#": 10, Bb: 10, B: 11, Cb: 11 };
const SHARPS = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];
const FLATS = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"];
const FLAT_KEYS = new Set(["F", "Bb", "Eb", "Ab", "Db", "Gb", "Dm", "Gm", "Cm", "Fm", "Bbm", "Ebm"]);
const CHORD = /^([A-G][#b]?)((?:m(?!aj)|min|maj7?|M7|m7|7|6|9|11|13|sus[24]?|dim7?|aug|add[29]|5|\+|°|ø)*)(?:\/([A-G][#b]?))?$/;

export const isChord = (s: string) => CHORD.test(s.trim());

/** A key as a root and whether it is minor: "A", "C minor", "Am", "F# minor". */
export function readKey(s: string): { root: string; minor: boolean } {
  const m = String(s ?? "").trim().match(/^([A-G][#b]?)\s*(m(?:in(?:or)?)?)?\b/);
  if (!m) return { root: "C", minor: false };
  return { root: m[1], minor: !!m[2] };
}
export const keyName = (k: { root: string; minor: boolean }) => `${k.root}${k.minor ? "m" : ""}`;

function spell(pc: number, flats: boolean): string {
  return (flats ? FLATS : SHARPS)[((pc % 12) + 12) % 12];
}

/** A chord moved n semitones: "F#m7" + 3 = "Am7"; slash bass notes move too. */
export function transpose(chord: string, n: number, flats: boolean): string {
  const m = chord.match(CHORD);
  if (!m || !n) return chord;
  const bass = m[3] ? `/${spell(PC[m[3]] + n, flats)}` : "";
  return `${spell(PC[m[1]] + n, flats)}${m[2]}${bass}`;
}

/** A key moved n semitones. */
export function moveKey(k: { root: string; minor: boolean }, n: number): { root: string; minor: boolean } {
  const flats = FLAT_KEYS.has(keyName({ root: spell(PC[k.root] + n, true), minor: k.minor }));
  return { root: spell(PC[k.root] + n, flats), minor: k.minor };
}

// Keys a beginner plays open chords in.
const EASY = { major: ["G", "C", "D", "A", "E"], minor: ["Em", "Am", "Dm"] };

/** How far to move for the key they picked. */
export function keyShift(from: { root: string; minor: boolean }, pick: string): number {
  if (/up a step/i.test(pick)) return 2;
  if (/down a step/i.test(pick)) return -2;
  if (/easiest|guitar/i.test(pick)) {
    const want = from.minor ? EASY.minor : EASY.major;
    if (want.includes(keyName(from))) return 0;
    let best = 0;
    let far = 99;
    for (const k of want) {
      const d = ((PC[readKey(k).root] - PC[from.root]) % 12 + 12) % 12;
      const s = d > 6 ? d - 12 : d;
      if (Math.abs(s) < far) {
        far = Math.abs(s);
        best = s;
      }
    }
    return best;
  }
  return 0;
}

/**
 * Chords as pasted: "Am F C G", "| C G | Am F |", "C - G - Am - F", one line a part. A bar holds one chord, or the
 * chords between two bar lines. Words that are not chords (lyrics, "Verse:") are left out.
 */
export function readChords(text: string): string[] {
  const clean = String(text ?? "").replace(/[,;]/g, " ").replace(/\s[-–—]+\s/g, " ").replace(/\r/g, "");
  const bars: string[] = [];
  for (const line of clean.split("\n")) {
    if (line.includes("|")) {
      for (const part of line.split("|")) {
        const cs = part.trim().split(/\s+/).filter(isChord);
        if (cs.length) bars.push(cs.join(" "));
      }
    } else {
      for (const w of line.trim().split(/\s+/)) if (isChord(w)) bars.push(w);
    }
  }
  return bars.slice(0, 64);
}

/** The chords a song uses, once each, in the order they first come. */
export const uniqueChords = (bars: string[]) => [...new Set(bars.flatMap((b) => b.split(/\s+/)).filter(Boolean))];

/** The key a list of chords is most likely in: its first chord (a minor first chord is a minor key). */
export function guessKey(bars: string[]): { root: string; minor: boolean } {
  const m = (bars[0] ?? "C").split(/\s+/)[0].match(CHORD);
  return m ? { root: m[1], minor: /^m(?!aj)|^min/.test(m[2]) } : { root: "C", minor: false };
}

// ---------- the song library ----------

export interface Song { key: string; title: string; artist: string; scale: string; bpm: number; bars: string[]; status: string }

export function songs(store: TableStore): Song[] {
  return rowsOf(store, SONGS).filter(({ row }) => row.Title).map(({ key, row }) => ({
    key, title: String(row.Title), artist: String(row.Artist ?? ""), scale: String(row.Scale ?? "C"), bpm: num(row.Bpm) || 90,
    bars: String(row.Chords ?? "").split("|").map((x) => x.trim()).filter(Boolean), status: String(row.Status ?? ""),
  }));
}
const findSong = (store: TableStore, title: string) => {
  const t = title.toLowerCase().trim();
  return songs(store).find((s) => s.title.toLowerCase() === t || s.key === slug(title));
};

// ---------- the lesson ----------

export interface Lesson { song: string; key: string; bpm: number; speed: number; bars: string[]; bar: number }

export function lesson(store: TableStore): Lesson | null {
  const r = store.tables[STUDIO]?.rows.now;
  if (!r?.Song) return null;
  return { song: String(r.Song), key: String(r.Tonic ?? "C"), bpm: num(r.Bpm) || 90, speed: num(r.Speed) || 100,
           bars: String(r.Chords ?? "").split("|").filter(Boolean), bar: num(r.Bar) };
}
export const playBpm = (l: Lesson) => Math.max(30, Math.round((l.bpm * l.speed) / 100));

export function readSpeed(s: unknown): number {
  const t = String(s ?? "");
  if (/half/i.test(t)) return 50;
  const m = t.match(/(\d+)\s*%/);
  if (m) return Math.max(25, Math.min(100, Number(m[1])));
  return 100;
}

/**
 * The learn plan's Send: the song (from `songs`, or chords they pasted), moved to the key they picked, kept in
 * `studio` as the lesson; the song marked Learning (a pasted one is added to `songs`).
 */
export function applyLearn(store: TableStore, answers: Record<string, unknown>, clk: Clock):
  { store: TableStore; lesson?: Lesson; missing?: string } {
  const own = answers.own && typeof answers.own === "object" ? (answers.own as Record<string, unknown>) : {};
  const pick = String(answers.song ?? "").trim();
  const pasted = readChords(String(own.chords ?? answers.chords ?? ""));
  const named = String(own.name ?? "").trim() || (pick && pick !== OWN ? pick : "");
  const known = named ? findSong(store, named) : undefined;
  let title: string;
  let bars: string[];
  let bpm: number;
  let from: { root: string; minor: boolean };
  if (pasted.length) {
    title = known?.title ?? (named || "My song");
    bars = pasted;
    bpm = num(own.bpm) || known?.bpm || 90;
    from = guessKey(pasted);
  } else if (known?.bars.length) {
    title = known.title;
    bars = known.bars;
    bpm = known.bpm;
    from = readKey(known.scale);
  } else {
    return { store, missing: named || "that song" };
  }
  const n = keyShift(from, String(answers.key ?? ""));
  const to = moveKey(from, n);
  const flats = FLAT_KEYS.has(keyName(to));
  const moved = bars.map((b) => b.split(/\s+/).map((c) => transpose(c, n, flats)).join(" "));
  const speed = readSpeed(answers.speed);
  let out = put(store, STUDIO, "now", { Song: title, Tonic: keyName(to), Bpm: bpm, Speed: speed, Chords: moved.join("|"), Bar: 0 }, clk);
  const key = known?.key ?? slug(title);
  out = put(out, SONGS, key, known ? { Status: "Learning", ...(pasted.length ? { Chords: bars.join("|") } : {}) }
                                   : { Title: title, Artist: "", Scale: keyName(from), Bpm: bpm, Status: "Learning", Chords: bars.join("|") }, clk);
  return { store: out, lesson: lesson(out)! };
}

/** A speed tapped on Chords: the click follows. */
export function applySpeed(store: TableStore, choice: string, clk: Clock): { store: TableStore; lesson?: Lesson } {
  const l = lesson(store);
  if (!l) return { store };
  const out = put(store, STUDIO, "now", { Speed: readSpeed(choice) }, clk);
  return { store: out, lesson: lesson(out)! };
}

/** A bar tapped on Chords: that bar and the next on the buttons, over and over; Whole song brings the rest back. */
export function applyBar(store: TableStore, choice: string, clk: Clock): { store: TableStore; lesson?: Lesson } {
  const l = lesson(store);
  if (!l) return { store };
  const m = choice.match(/^bar\s+(\d+)/i);
  const bar = m ? Math.max(0, Math.min(l.bars.length, Number(m[1]))) : 0;
  const out = put(store, STUDIO, "now", { Bar: bar }, clk);
  return { store: out, lesson: lesson(out)! };
}

/** The chord buttons for the lesson: the whole song's chords, or the looped bars' (two at least, so it moves). */
export function lessonChords(l: Lesson): { chords: string[]; title: string } {
  if (!l.bar) return { chords: uniqueChords(l.bars), title: l.song };
  const i = l.bar - 1;
  const loop = uniqueChords(l.bars.slice(i, i + 2));
  for (const c of uniqueChords([...l.bars.slice(i + 2), ...l.bars])) {
    if (loop.length >= 2) break;
    if (!loop.includes(c)) loop.push(c);
  }
  return { chords: loop.length >= 2 ? loop : [...loop, ...loop], title: `${l.song}, bar ${l.bar}` };
}

// ---------- the practice log ----------

export interface Practice { day: string; minutes: number; what: string; feel: string }

export function practice(store: TableStore): Practice[] {
  return rowsOf(store, PRACTICE).map(({ row }) => ({ day: String(row.Day ?? "").slice(0, 10), minutes: num(row.Minutes), what: String(row.What ?? ""),
                                                      feel: String(row.Feel ?? "") })).filter((p) => p.day && p.minutes > 0);
}

/** Days in a row with practice, up to today (or up to yesterday, when today has none yet). */
export function streak(store: TableStore, clk: Clock): number {
  const days = new Set(practice(store).map((p) => p.day));
  let d = days.has(clk.today) ? clk.today : shift(clk.today, -1);
  let n = 0;
  while (days.has(d)) {
    n++;
    d = shift(d, -1);
  }
  return n;
}

const monday = (day: string) => {
  const [y, m, d] = day.split("-").map(Number);
  return shift(day, -((new Date(Date.UTC(y, m - 1, d)).getUTCDay() + 6) % 7));
};

/** Minutes a day this week, Monday first. */
export function weekMinutes(store: TableStore, clk: Clock): number[] {
  const mon = monday(clk.today);
  const out = [0, 0, 0, 0, 0, 0, 0];
  for (const p of practice(store)) {
    const i = WEEK.findIndex((_, k) => shift(mon, k) === p.day);
    if (i >= 0) out[i] += p.minutes;
  }
  return out;
}

export function readMinutes(s: unknown): number {
  const t = String(s ?? "");
  const h = t.match(/(\d+(?:\.\d+)?)\s*(?:h|hour)/i);
  if (h) return Math.round(Number(h[1]) * 60);
  if (/an? hour/i.test(t)) return 60;
  return Math.round(Number(t.match(/\d+/)?.[0] ?? 0));
}

/** A practice written to the log, one row a session. */
export function logPractice(store: TableStore, p: { minutes: number; what: string; feel?: string; bpm?: number }, clk: Clock): TableStore {
  const n = rowsOf(store, PRACTICE).filter(({ key }) => key.startsWith(clk.today)).length + 1;
  return put(store, PRACTICE, `${clk.today}-${n}`, { Day: clk.today, Minutes: p.minutes, What: p.what.slice(0, 120) || "Practice",
                                                     ...(p.feel ? { Feel: p.feel } : {}), ...(p.bpm ? { Bpm: p.bpm } : {}) }, clk);
}

/** The log plan's Send. */
export function applyPracticed(store: TableStore, answers: Record<string, unknown>, clk: Clock): { store: TableStore; minutes: number; what: string } {
  const minutes = readMinutes(answers.minutes) || 15;
  const what = list(answers.what).map((x) => x.trim()).filter(Boolean).join(", ") || "Practice";
  const l = lesson(store);
  const bpm = l && what.includes(l.song) ? playBpm(l) : undefined;
  let out = logPractice(store, { minutes, what, feel: String(answers.feel ?? ""), bpm }, clk);
  // Nailed the song they're learning: the next time runs a notch faster.
  if (l && bpm && /nailed/i.test(String(answers.feel ?? "")) && l.speed < 100) out = put(out, STUDIO, "now", { Speed: Math.min(100, l.speed + 10) }, clk);
  return { store: out, minutes, what };
}

/** The one line on what to practice next. */
export function nextUp(store: TableStore, clk: Clock): { title: string; body: string } {
  const l = lesson(store);
  const today = practice(store).filter((p) => p.day === clk.today).reduce((a, p) => a + p.minutes, 0);
  if (l?.bar) return { title: `Next: bar ${l.bar} of ${l.song}`, body: `Loop it at ${playBpm(l)} until it feels easy, then play the whole song.` };
  if (l && l.speed < 100) return { title: `Next: ${l.song} at ${playBpm(l)}`, body: `Play it through twice. Nail it and I'll speed it up to ${Math.min(l.bpm, Math.round((l.bpm * (l.speed + 10)) / 100))}.` };
  if (l) return { title: `Next: ${l.song} at full speed`, body: `Play it through at ${l.bpm} without stopping, then learn another.` };
  if (today) return { title: "Next: learn a song", body: `${today} minutes today already. Pick a song on Chords and play along with the click.` };
  return { title: "Next: ten minutes", body: "Pick a song on Chords and play along with the click. It all counts toward your streak." };
}

// ---------- sessions ----------

export interface Session { key: string; name: string; kind: string; bpm: number; swing: number; steps: number; rows: string[]; p: string[] }

export function sessions(store: TableStore): Session[] {
  return rowsOf(store, SESSIONS).filter(({ key, row }) => key !== "draft" && row.Name).map(({ key, row }) => ({
    key, name: String(row.Name), kind: String(row.Kind ?? "beat"), bpm: num(row.Bpm) || 96, swing: num(row.Swing), steps: num(row.Steps) || 8,
    rows: String(row.Rows ?? "").split("|").filter(Boolean), p: String(row.Pattern ?? "").split("|"),
  })).reverse();
}

/** The starter loops, in the same shape (kick, snare, perc, hats). */
function starters(store: TableStore): Session[] {
  return rowsOf(store, LOOPS).filter(({ row }) => row.Name && row.Pattern).map(({ key, row }) => ({
    key: `loop-${key}`, name: String(row.Name), kind: "starter", bpm: num(row.Bpm) || 96, swing: 0, steps: 8, rows: [], p: String(row.Pattern).split("|"),
  }));
}

/** Everything the Looper can open: their sessions first, newest first, then the starter loops. Eight at most. */
export function openable(store: TableStore): Session[] {
  const mine = sessions(store);
  const names = new Set(mine.map((s) => s.name.toLowerCase()));
  return [...mine, ...starters(store).filter((s) => !names.has(s.name.toLowerCase()))].slice(0, 8);
}
export const findSession = (store: TableStore, name: string) => {
  const t = name.toLowerCase().trim().replace(/^["']|["']$/g, "");
  return openable(store).find((s) => s.name.toLowerCase() === t) ?? [...sessions(store), ...starters(store)].find((s) => s.name.toLowerCase() === t);
};

/** What the Looper holds now: the session they opened or saved last, else the first starter. */
export function onLooper(store: TableStore): Session {
  const was = String(store.tables[STUDIO]?.rows.looper?.Session ?? "");
  return (was && findSession(store, was)) || starters(store)[0] || { key: "none", name: "Looper", kind: "starter", bpm: 92, swing: 0, steps: 8, rows: [], p: ["x...x...", "..x...x.", "", "x.x.x.x."] };
}

/** A loop's Send or a drum take, as it came back: kept as the draft the save plan names. */
export function readTake(v: Record<string, unknown>): Omit<Session, "key" | "name"> | null {
  const p = list(v.p);
  if (!p.some((r) => /x/i.test(r))) return null;
  // The looper plays 16 steps at most: a longer take keeps its first 16.
  const steps = Math.max(4, Math.min(16, num(v.steps) || p[0]?.length || 8));
  return { kind: v.take ? "take" : "beat", bpm: Math.round(num(v.bpm)) || 96, swing: Math.round(num(v.swing)), steps,
           rows: list(v.rows), p: p.map((r) => r.slice(0, steps)) };
}

export function keepDraft(store: TableStore, take: Omit<Session, "key" | "name">, clk: Clock): TableStore {
  return put(store, SESSIONS, "draft", { Name: "", Kind: take.kind, Bpm: take.bpm, Swing: take.swing, Steps: take.steps, Rows: take.rows.join("|"),
                                         Pattern: take.p.join("|"), Saved: clk.today }, clk);
}
const draft = (store: TableStore): Omit<Session, "key" | "name"> | null => {
  const r = store.tables[SESSIONS]?.rows.draft;
  if (!r?.Pattern) return null;
  return { kind: String(r.Kind ?? "beat"), bpm: num(r.Bpm) || 96, swing: num(r.Swing), steps: num(r.Steps) || 8, rows: String(r.Rows ?? "").split("|").filter(Boolean),
           p: String(r.Pattern).split("|") };
};

/** The save plan's Send: the draft under its name (a name used before is replaced), on the Looper if they said so. */
export function applySave(store: TableStore, answers: Record<string, unknown>, clk: Clock): { store: TableStore; session?: Session; looper: boolean } {
  const d = draft(store);
  if (!d) return { store, looper: false };
  const form = answers.name && typeof answers.name === "object" ? (answers.name as Record<string, unknown>) : { name: answers.name };
  const name = String(form.name ?? "").trim().slice(0, 40) || `${d.kind === "take" ? "Take" : "Beat"} ${sessions(store).length + 1}`;
  const key = `s-${slug(name)}`;
  let out = put(store, SESSIONS, key, { Name: name, Kind: d.kind, Bpm: d.bpm, Swing: d.swing, Steps: d.steps, Rows: d.rows.join("|"), Pattern: d.p.join("|"), Saved: clk.today }, clk);
  out = write(out, { op: "put", table: SESSIONS, key: "draft", values: {}, delete: true }).store;
  const looper = !/just save/i.test(String(answers.then ?? ""));
  if (looper) out = put(out, STUDIO, "looper", { Session: name }, clk);
  return { store: out, session: sessions(out).find((s) => s.key === key), looper };
}

/** A session opened: on the Looper from now on. */
export function applyOpen(store: TableStore, name: string, clk: Clock): { store: TableStore; session?: Session } {
  const s = findSession(store, name);
  if (!s) return { store };
  return { store: put(store, STUDIO, "looper", { Session: s.name }, clk), session: s };
}

const KIT = ["kick", "snare", "clap", "hat", "open", "rim", "tom", "shaker"];
const sounds = (s: Omit<Session, "key" | "name">) => {
  const rows = s.rows.length ? s.rows : KIT;
  const hit = rows.filter((_, i) => /x/i.test(s.p[i] ?? ""));
  return joinWords(hit.slice(0, 5));
};

// ---------- the flows ----------

/** Learn a song: what happens first, then the song, the key and the speed, one Send. */
export function learnBody(store: TableStore, first?: string): string {
  const all = songs(store).filter((s) => s.bars.length);
  const pickFirst = first ? findSong(store, first) : undefined;
  const titles = [...(pickFirst ? [pickFirst.title] : []), ...all.map((s) => s.title).filter((t) => t !== pickFirst?.title)].slice(0, 7);
  const lines = [
    `plan@learn "Learn a song" submit="Let's play"`,
    `page "Play along" body=${q("Pick a song or paste its chords. The chords land on buttons, the click counts you in, and your keys stay in its key. Slow it down or loop the hard bar any time.")}`,
    `choose@song "Which song?" ${opts([...titles, OWN])} +other`,
    `form@own "Or paste the chords" name:text chords:long bpm:number`,
    `choose@key "What key?" ${opts(KEY_OPTS)}`,
    `choose@speed "How fast to start?" ${opts(SPEED_OPTS)}`,
  ];
  return `Let's learn one.\n\`\`\`yui\n${lines.join("\n")}\n\`\`\``;
}

/** A song they named that has no chords yet: a form for its chords, one Send. */
export function pasteBody(name: string): string {
  return `I don't have the chords for ${name} yet. Paste them, like G D Em C, and I'll set it up.\n\`\`\`yui\n` +
    `form@learn-paste ${q(`Chords for ${name}`)} chords:long! bpm:number submit="Set it up"\n\`\`\``;
}

/** Log practice: this week first, then how long, what and how it went, one Send. */
export function practiceBody(store: TableStore, clk: Clock): string {
  const mins = weekMinutes(store, clk).reduce((a, b) => a + b, 0);
  const s = streak(store, clk);
  const l = lesson(store);
  const lines = [
    `plan@practiced "Log practice" submit="Log it"`,
    `page "This week" body=${q(`${mins} minutes so far. ${s ? `A ${s} day streak.` : "Log today and your streak starts."}`)}`,
    `choose@minutes "How long?" ${opts(MINUTES_OPTS)}`,
    `pick@what "What did you play?" ${opts([...(l ? [l.song] : []), ...WHAT_OPTS])} +other`,
    `choose@feel "How did it go?" ${opts(FEEL_OPTS)}`,
  ];
  return `\`\`\`yui\n${lines.join("\n")}\n\`\`\``;
}

/** Save it: what they made first, then a name and where it goes, one Send. */
export function saveBody(take: Omit<Session, "key" | "name">): string {
  const what = take.kind === "take" ? "Your take" : "Your beat";
  const lines = [
    `plan@keep "Save it" submit=Save`,
    `page ${q(what)} body=${q(`${take.bpm} bpm${take.swing ? `, swing ${take.swing}` : ""}, ${take.steps} steps. ${sounds(take).replace(/^\w/, (c) => c.toUpperCase()) || "All yours"}.`)}`,
    `form@name "Name it" name:text!`,
    `choose@then "Then?" ${opts(THEN_OPTS)}`,
  ];
  return `\`\`\`yui\n${lines.join("\n")}\n\`\`\``;
}

// ---------- the screens ----------

const patternOf = (s: Session) => {
  const p = [...s.p];
  while (p.length && !p[p.length - 1]) p.pop();
  return p.join("|");
};

/** Looper, as its page: the looper as they left it, and every session to open. */
export function looperScreen(store: TableStore): string[] {
  const s = onLooper(store);
  const extra = `${s.swing ? ` swing=${s.swing}` : ""}${s.steps !== 8 ? ` steps=${s.steps}` : ""}${s.rows.length ? ` rows=${s.rows.join("|")}` : ""}`;
  const mine = sessions(store).length;
  return [
    `loop@looper ${s.bpm} ${q(s.name)} p=${patternOf(s)}${extra} +inline`,
    `choose@sessions "Open a beat" ${opts(openable(store).map((x) => x.name))} body=${q(mine ? `${mine} saved. Send on the looper saves another.` : "Send on the looper saves your version.")}`,
  ];
}

/** Chords, as its page: the song being learned (chords, click, speed, a bar to loop), or a way to start one. */
export function chordsScreen(store: TableStore): string[] {
  const l = lesson(store);
  if (!l) {
    return [
      `card@lesson "Learn a song" "Pick a song or paste its chords. The click counts you in and your keys stay in key." cta="Learn a song"`,
      `chords@chords C I-V-vi-IV "Chords" +inline`,
      `metronome@click 90 "Click"`,
    ];
  }
  const c = lessonChords(l);
  const bars = l.bars.slice(0, 16).map((b, i) => `Bar ${i + 1}: ${b}`);
  return [
    `card@lesson ${q(l.song)} ${q(`Key of ${l.key}, ${l.bars.length} bars. Click at ${playBpm(l)}${l.speed < 100 ? `, ${l.speed}% of ${l.bpm}` : ""}.`)} sub=${q(l.bar ? `Looping bar ${l.bar}` : "Learning now")} cta="Learn another"`,
    `chords@chords ${opts(c.chords)} ${q(c.title)} +inline`,
    `metronome@click ${playBpm(l)} ${q(l.song)}`,
    `choose@speed "Speed" ${opts(PAGE_SPEEDS)} body=${q(`Now ${playBpm(l)} bpm.`)}`,
    `choose@bar "Loop a bar" ${opts([WHOLE, ...bars])} body=${q(l.bar ? `Bar ${l.bar} and the next, over and over.` : "Tap the hard one to loop it.")}`,
  ];
}

/** Keys, as its page: the keyboard in the song's key, locked to a scale they pick. */
export function keysScreen(store: TableStore): string[] {
  const l = lesson(store);
  const k = readKey(l?.key ?? "C");
  const scale = String(store.tables[STUDIO]?.rows.keys?.Scale ?? (k.minor ? "minor" : "major")).toLowerCase();
  return [
    `keys@keys ${k.root} ${scale} ${q(l ? `Keys, in ${keyName(k)}` : "Keys")} +inline`,
    `choose@scale "Scale" ${opts(SCALE_OPTS)} body=${q(`${keyName(k)} ${scale}. Keys outside it stay quiet.`)}`,
  ];
}

/** Practice, as its page: the streak, this week, a chart of the week, what's next, the last few sessions. */
export function practiceScreen(store: TableStore, clk: Clock): string[] {
  const s = streak(store, clk);
  const week = weekMinutes(store, clk);
  const total = week.reduce((a, b) => a + b, 0);
  const n = nextUp(store, clk);
  const recent = practice(store).slice(-5).reverse().map((p) => `${p.day.slice(5).replace("-", "/")} ${p.minutes} min, ${p.what}`);
  return [
    `stat@streak ${q(`${s} ${s === 1 ? "day" : "days"}`)} "Streak" sub=${q(s ? "Days in a row. Keep it going." : "Practice today and this starts.")}`,
    `stat@week-min ${q(`${total} min`)} "This week" sub=${q(total ? `Over ${week.filter(Boolean).length} ${week.filter(Boolean).length === 1 ? "day" : "days"}` : "The click logs itself after 10 seconds")}`,
    `chart@practice-chart bar "Minutes a day" x=${WEEK.join("|")} y=${week.join("|")} unit=min`,
    `card@next-up ${q(n.title)} ${q(n.body)} cta="Log practice"`,
    `list@recent title="Lately" ${opts(recent.length ? recent : ["Nothing logged yet"])}`,
  ];
}

export type Page = "looper" | "chords" | "keys" | "practice";
export const PAGES: Page[] = ["looper", "chords", "keys", "practice"];
const PAGE_AT: Record<Page, { at: number; save: string; draw: (s: TableStore, c: Clock) => string[] }> = {
  looper: { at: 2, save: "looper", draw: (s) => looperScreen(s) },
  chords: { at: 3, save: "chords", draw: (s) => chordsScreen(s) },
  keys: { at: 4, save: "keys", draw: (s) => keysScreen(s) },
  practice: { at: 5, save: "practice", draw: (s, c) => practiceScreen(s, c) },
};

/** The page shape: which song Chords holds. A new song (or none) redraws Chords; the rest are always patches. */
export const shapeText = (store: TableStore) => `v1;${lesson(store) ? slug(lesson(store)!.song) : "none"}`;

/**
 * The shape as the phone has it: what the runtime last drew, or for a Gouda whose home is this one (YUI-184, the
 * practice chart is its mark) the empty Chords page that home drew. A home from before gets every page drawn once.
 */
export function drawnShape(p: { musicScreens?: string; home?: string }): string | undefined {
  if (p.musicScreens) return p.musicScreens;
  return /\bchart@practice-chart\b/.test(p.home ?? "") ? "v1;none" : undefined;
}

/**
 * The lines that keep Gouda's pages current. The first time (a home from before YUI-184) every page is drawn; after
 * that Chords is drawn again when the song changes, and everything else goes as patches, which never move the person.
 */
export function screenLines(store: TableStore, clk: Clock, was: string | undefined, only: Page[] = PAGES): { lines: string[]; shape: string } {
  const now = shapeText(store);
  const first = !was?.startsWith("v1;");
  const patch = (lines: string[]) => lines.map((l) => l.replace(/^[a-z]+@/, "~"));
  const out: string[] = [];
  for (const page of PAGES) {
    const { at, save, draw } = PAGE_AT[page];
    const redraw = first || (page === "chords" && was !== now);
    if (!redraw && !only.includes(page)) continue;
    if (redraw) out.push(`>${at} clear`, `>${at}`, ...draw(store, clk), `save ${save}`);
    else out.push(...patch(draw(store, clk)));
  }
  return { lines: out, shape: now };
}

// ---------- taps and words ----------

export type MusicAsk =
  | { kind: "learn"; row: Row; song?: string }
  | { kind: "learned"; row: Row; answers: Record<string, unknown> }
  | { kind: "speed"; row: Row; choice: string }
  | { kind: "bar"; row: Row; choice: string }
  | { kind: "scale"; row: Row; choice: string }
  | { kind: "log"; row: Row }
  | { kind: "practiced"; row: Row; answers: Record<string, unknown> }
  | { kind: "clicked"; row: Row; id: string; seconds: number; bpm: number }
  | { kind: "take"; row: Row; value: Record<string, unknown> }
  | { kind: "saved"; row: Row; answers: Record<string, unknown> }
  | { kind: "open"; row: Row; name: string };

const LEARN_WORDS = /^\s*(?:(?:please|can you|could you|let'?s|i want to|help me)\s+)?(?:learn|teach me)\s+(?:(?:a|the|my|this|new|another)\s+){0,2}song(?:'?s)?(?:\s+chords)?\s*[.!?]*\s*$/i;
const LEARN_TITLE = /^\s*(?:(?:please|can you|let'?s|i want to|help me)\s+)?(?:learn|teach me)\s+(?:to play\s+)?["']?(.+?)["']?\s*[.!?]*\s*$/i;
const LOG_WORDS = /^\s*(?:log|track|add)\s+(?:my\s+|some\s+|a\s+)?practice(?:\s+session)?\s*[.!]*\s*$/i;
const PRACTICED = /^\s*i\s+(?:just\s+)?practi[cs]ed\s+(?:for\s+)?(\d+\s*(?:min(?:ute)?s?|hours?|h)|an? hour|half an hour)(?:\s+(?:on|of)\s+(.+?))?\s*[.!]*\s*$/i;
const OPEN_WORDS = /^\s*(?:open|load|play|bring back)\s+(?:my\s+)?(?:beat\s+|session\s+|loop\s+)?["']?(.+?)["']?\s*[.!]*\s*$/i;

/** The rows in a turn the runtime answers itself (Gouda's words and taps), and the rest for the model. */
export function musicAsks(rows: Row[], store?: TableStore): { asks: MusicAsk[]; rest: Row[] } {
  const asks: MusicAsk[] = [];
  const rest: Row[] = [];
  for (const r of rows) {
    const body = r.body ?? "";
    const e = /^\[yui\]\s/.test(body) ? readEvent(r) : null;
    let a: MusicAsk | null = null;
    if (!e && r.kind !== "event") {
      const said = body.match(PRACTICED);
      const title = body.match(LEARN_TITLE);
      const open = body.match(OPEN_WORDS);
      if (LEARN_WORDS.test(body)) a = { kind: "learn", row: r };
      else if (title && store && findSong(store, title[1])) a = { kind: "learn", row: r, song: title[1] };
      else if (LOG_WORDS.test(body)) a = { kind: "log", row: r };
      else if (said) {
        const minutes = /half an hour/i.test(said[1]) ? 30 : readMinutes(said[1]);
        a = { kind: "practiced", row: r, answers: { minutes: `${minutes} min`, what: said[2] ? [said[2].replace(/^\w/, (c) => c.toUpperCase())] : ["Practice"] } };
      } else if (open && store && findSession(store, open[1])) a = { kind: "open", row: r, name: findSession(store, open[1])!.name };
    } else if (e) {
      const v = e.value;
      const plan = v.plan && typeof v.plan === "object" ? (v.plan as Record<string, unknown>) : null;
      const choice = typeof v.choice === "string" ? v.choice : null;
      if (e.preset === "plan" && e.id === "learn" && plan) a = { kind: "learned", row: r, answers: plan };
      else if (e.preset === "form" && e.id === "learn-paste" && v.form && typeof v.form === "object") {
        a = { kind: "learned", row: r, answers: { own: { ...(v.form as Record<string, unknown>), name: String((v.form as Record<string, unknown>).name ?? "") } } };
      } else if (e.preset === "plan" && e.id === "practiced" && plan) a = { kind: "practiced", row: r, answers: plan };
      else if (e.preset === "plan" && e.id === "keep" && plan) a = { kind: "saved", row: r, answers: plan };
      else if (e.preset === "choose" && e.id === "speed" && choice) a = { kind: "speed", row: r, choice };
      else if (e.preset === "choose" && e.id === "bar" && choice) a = { kind: "bar", row: r, choice };
      else if (e.preset === "choose" && e.id === "scale" && choice) a = { kind: "scale", row: r, choice };
      else if (e.preset === "choose" && e.id === "sessions" && choice) a = { kind: "open", row: r, name: choice };
      else if (e.preset === "metronome" && num(v.seconds) >= 10) a = { kind: "clicked", row: r, id: e.id, seconds: num(v.seconds), bpm: num(v.bpm) };
      // The Looper's Send, or a drum take: named and kept. A loop in the chat goes to Gouda, who can build on it.
      else if ((e.preset === "loop" && e.id === "looper") || (e.preset === "drums" && v.take)) a = { kind: "take", row: r, value: v };
      else if (e.preset === "card" && v.cta != null) {
        const cta = String(v.cta);
        if (e.id === "lesson" || /^learn (?:a song|another)$/i.test(cta)) a = { kind: "learn", row: r };
        else if (e.id === "next-up" || /^log practice$/i.test(cta)) a = { kind: "log", row: r };
      }
    }
    if (a) asks.push(a);
    else rest.push(r);
  }
  return { asks, rest };
}

/** Which of Gouda's pages a table change touches (a model turn that wrote his tables). */
export function musicPages(ch: { rows: { table: string }[]; dropRows: { table: string }[]; tables: { name: string }[] }): Page[] {
  const names = new Set([...ch.rows.map((r) => r.table), ...ch.dropRows.map((r) => r.table), ...ch.tables.map((t) => t.name)]);
  const out: Page[] = [];
  if (names.has(SESSIONS) || names.has(LOOPS) || names.has(STUDIO)) out.push("looper");
  if (names.has(STUDIO)) out.push("chords", "keys");
  if (names.has(PRACTICE) || names.has(STUDIO)) out.push("practice");
  return out;
}

/** The scale picked on Keys. */
export function applyScale(store: TableStore, choice: string, clk: Clock): TableStore {
  const s = SCALE_OPTS.find((x) => x.toLowerCase() === choice.toLowerCase().trim());
  return s ? put(store, STUDIO, "keys", { Scale: s.toLowerCase() }, clk) : store;
}
