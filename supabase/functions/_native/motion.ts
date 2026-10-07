// Copied from runtime/src/motion.ts by runtime/scripts/build.mjs. Do not edit here.
// Native agents make films (MOTION-27). Ported from hermes-plugin/yui/motion.py and motion_hero.py (the Hermes maker).
// The agent writes ONE line, `motion "<what to show, with the facts>"`, in a ```yui block. This module cuts the line out of
// the reply; the turn then has one model call write the film scene by scene and saves each scene as its own `motion` part
// row the app joins into one film (yuigui spec/MOTION.md 0.5), so scene 1 plays while the rest is written:
//
//     motion "How a heart pumps blood" film=m7 part=1
//     === scene hook 4 ===
//     <JavaScript body of (t, c, api)>
//     end
//
// Parts 2.. carry `part=<n>`; a last part with no scene carries `+last`. The hero object is picked from the ask by a word
// match and drawn by the app's kit (api.thing); a thing the kit lacks comes from the drawings shipped in motion.gen.ts.
// MOTION-29: the rest of the hero. A noun the kit and the seed lack is drawn on demand (`drawNew`, one call returning kit-shape
// parts), and after the film a background job draws it again for the judge (`learn`); a pass is kept in yui_motion_things under
// narrow word forms, so the next ask for that noun, from anyone, is a seed hit. The judge needs a browser, so it runs on a Mac
// (yuigui site/scripts/motion/judge_things.py), not here. Never inside a turn; YUI_MOTION_THINGS=off and YUI_MOTION_LEARN=off.
import { MOTION_PROMPT, MOTION_SEED } from "./motion.gen.ts";
import { COOK, SKIP, WEAK, WORDS } from "./motionwords.ts";

export const MAX_ASK = 700; // characters of ask the maker sees
export const MAX_SCENES = 12;
export const MAX_FILMS_PER_HOUR = 8;
export const FIRST_SCENE_SECONDS = 60;
/** MOTION-30: the models the maker was built for, on Yui's own OpenRouter route. Empty: the agent's chat model writes and draws, as before. Set
 *  YUI_MOTION_HERO_MODEL and YUI_MOTION_FILM_MODEL to anthropic/claude-sonnet-5.5 and YUI_MOTION_OPENER_MODEL to anthropic/claude-haiku-4.5 to turn the strong route
 *  on (about 20 times the cost of a film on the chat model, so it is Chris's switch, spec/MOTION.md): measured 76% of frames and a 3.1 s first scene. */
export const HERO_MODEL = "";
export const FILM_MODEL = "";
/** Scene 1 is written by a small fast model while the film model writes scenes 2+ (the plugin's split, MOTION-22). */
export const OPENER_MODEL = "";

const OPENER = "\n\nYOUR JOB: write ONLY scene 1, then `=== end ===`. A slower writer draws the rest. Scene 1 is SMALL (at most 10 lines, 3 s), opens on the hero "
  + "drawing of the ask and shows the subject at once. Name it with one word, no spaces. No words before the first header.";
const CONTINUE = "\n\nYOUR JOB: scene 1 is already written by someone else (it opens on the hero drawing with a title and a caption). Do NOT write it. Start at the next "
  + "scene and write 4 to 6 scenes of 4 to 7 s that carry on from it. Name your scenes s2, s3, ...; the first scene you write is s2.";

const LINE = /^\s*motion\s+(?<rest>\S.*?)\s*$/;
const FENCE = /(```yui[^\n]*\n)([\s\S]*?)(```|$)/g;
const SCENE_HEAD = /^=== ((?:scene )?(.+?) ([\d.]+)|end) ===[ \t]*$/gm;

export interface Scene { name: string; dur: number; code: string }

const PATS: [string, RegExp][] = Object.entries(WORDS).map(([n, w]) => [n, new RegExp(`\\b(?:${w})\\b`, "i")]);
const SEED_PATS: [string, RegExp][] = Object.entries(MOTION_SEED.words)
  .filter(([n]) => n in MOTION_SEED.things).map(([n, w]) => [n, new RegExp(`\\b(?:${w})\\b`, "i")]);

function askOf(rest: string): string | null {
  rest = rest.trim();
  if (/\b(film|part)=/.test(rest)) return null; // one of ours
  const m = rest.match(/^"(.*)"\s*(?:\w+=\S+\s*)*$/);
  const ask = (m ? m[1] : rest).trim();
  return ask.slice(0, MAX_ASK) || null;
}

/** The reply without the agent's motion line, and the ask. Only the first line counts; a block we wrote (it has `film=`)
 *  or a line with scenes under it is left alone. Never throws. */
export function split(body: string): { body: string; ask: string | null } {
  let found: string | null = null;
  try {
    const out = (body ?? "").replace(FENCE, (_all, open: string, inner: string, close: string) => {
      const lines = inner.split("\n");
      const keep: string[] = [];
      for (let i = 0; i < lines.length; i++) {
        const hit = LINE.exec(lines[i]);
        const next = lines.slice(i + 1).find((x) => x.trim()) ?? "";
        if (hit && !next.startsWith("===")) {
          const ask = askOf(hit.groups!.rest);
          if (ask && found === null) { found = ask; continue; }
        }
        keep.push(lines[i]);
      }
      const text = keep.join("\n");
      return text.trim() ? open + text + close : "";
    });
    return found === null ? { body, ask: null } : { body: out, ask: found };
  } catch {
    return { body, ask: null };
  }
}

const calls = new Map<string, number[]>();
/** A film this person may have now: at most MAX_FILMS_PER_HOUR an hour. Counts per process; a cold start forgets. */
export function allowed(who: string, now: number = Date.now()): boolean {
  const mine = (calls.get(who) ?? []).filter((t) => now - t < 3_600_000);
  const ok = mine.length < MAX_FILMS_PER_HOUR;
  if (ok) mine.push(now);
  calls.set(who, mine);
  return ok;
}

/** What a turn with no film gets: the ask as one line of words. */
export function words(ask: string): string {
  return "```yui\nsay " + JSON.stringify(ask.slice(0, 200)) + "\n```";
}

export function titleOf(ask: string): string {
  const t = ask.trim().split(/(?<=[.!?])\s/)[0].trim().replace(/\.$/, "");
  return t.length > 58 ? t.slice(0, 56) + "..." : t;
}

/** The working row's words while scene `n` is made: plain words, never an id. */
export const drawing = (n: number) => (n <= 1 ? "Drawing the first scene" : `Drawing scene ${n}`);

/** The row for one scene. Code never contains a line that is only `end`. */
export function block(film: string, title: string, part: number, scene: Scene, last = false): string {
  const code = scene.code.split("\n").filter((l) => l.trim() !== "end").join("\n");
  let head = part === 1 ? `motion ${JSON.stringify(title)} film=${film} part=${part}` : `motion film=${film} part=${part}`;
  if (last) head += " +last";
  return "```yui\n" + head + `\n=== scene ${scene.name} ${scene.dur} ===\n${code}\nend\n\`\`\``;
}

/** The row that says the film is whole: a head with no scene. */
export const close = (film: string, part: number) => `\`\`\`yui\nmotion film=${film} part=${part} +last\n\`\`\``;

function cleanScene(name: string, dur: string, code: string): Scene | null {
  code = code.trim().replace(/^```[a-z]*\n|\n```\s*$/g, "");
  if (!code) return null;
  const d = parseFloat(dur);
  if (!Number.isFinite(d)) return null;
  return { name: name.replace(/[^A-Za-z0-9_-]/g, "").slice(0, 24) || "scene", dur: Math.min(20, Math.max(0.5, d)), code };
}

/** Scenes complete in `text` (one is complete when the next header or the end marker has arrived), after the first `done`
 *  marks. Returns the new scenes and the marks consumed. */
export function harvest(text: string, done: number): { scenes: Scene[]; done: number } {
  const marks = [...text.matchAll(SCENE_HEAD)];
  const scenes: Scene[] = [];
  for (let i = 0; i < marks.length - 1; i++) {
    const m = marks[i];
    if (m[1] === "end" || i < done) continue;
    const s = cleanScene(m[2], m[3], text.slice(m.index! + m[0].length, marks[i + 1].index));
    if (s) scenes.push(s);
    done = i + 1;
  }
  return { scenes, done };
}

// ---- the hero (motion_hero.py) ----
export interface Hero { name: string; label: string; define: string }
/** Drawings the judge kept (yui_motion_things): parts by noun, and the word pattern each answers to. */
export interface Kept { things: Record<string, { label: string; parts: unknown[] }>; words: Record<string, string> }
export const NO_KEPT: Kept = { things: {}, words: {} };

/** A model id from the env: unset keeps `def`, `off` is no model (the chat model answers). */
export const modelEnv = (n: string, def: string): string => { const v = envOf(n).trim(); return v.toLowerCase() === "off" ? "" : v || def; };

export const envOf = (n: string): string => {
  const g = globalThis as any;
  try { return String(g.Deno?.env?.get?.(n) ?? g.process?.env?.[n] ?? ""); } catch { return ""; }
};
const off = (n: string) => envOf(n).trim().toLowerCase() === "off";
/** The on-demand drawing and the learner's off switches (the plugin's YUI_MOTION_THINGS and YUI_MOTION_LEARN). */
export const thingsOn = () => !off("YUI_MOTION_THINGS");
export const learnOn = () => thingsOn() && !off("YUI_MOTION_LEARN");

/** The kit thing the ask is about, or null. The earliest word wins; a weak word loses to a body noun. */
export function pick(ask: string): string | null {
  if (!ask.trim() || SKIP.test(ask)) return null;
  let best: [number, number, string] | null = null;
  for (const [name, pat] of PATS) {
    const m = pat.exec(ask);
    if (!m) continue;
    const cand: [number, number, string] = [WEAK.has(name) ? 1 : 0, m.index, name];
    if (!best || cand[0] < best[0] || (cand[0] === best[0] && (cand[1] < best[1] || (cand[1] === best[1] && cand[2] < best[2])))) best = cand;
  }
  if (!best) return null;
  const name = best[2];
  if (name === "chicken" && COOK.test(ask)) return "roast";
  return name === "roast" ? "chicken" : name;
}

/** A drawing the app ships with (MOTION_SEED) that the ask is about; the earliest word wins. */
export function seeded(ask: string, kept: Kept = NO_KEPT): Hero | null {
  if (!ask.trim() || SKIP.test(ask)) return null;
  let best: [number, string] | null = null;
  for (const [name, pat] of SEED_PATS) {
    const m = pat.exec(ask);
    if (m && (!best || m.index < best[0])) best = [m.index, name];
  }
  for (const [name, pat] of keptPats(kept)) { // MOTION-25: nouns drawn, judged and kept after an earlier ask
    const m = pat.exec(ask);
    if (m && (!best || m.index < best[0])) best = [m.index, name];
  }
  const th = best && (kept.things[best[1]] ?? MOTION_SEED.things[best[1]]);
  if (!best || !th) return null;
  return { name: best[1], label: th.label, define: `if (api.defineThing) api.defineThing("${best[1]}", ${JSON.stringify(th.parts)});` };
}

const keptCache = new WeakMap<Kept, [string, RegExp][]>();
function keptPats(kept: Kept): [string, RegExp][] {
  if (!learnOn()) return [];
  let out = keptCache.get(kept);
  if (!out) {
    out = [];
    for (const [n, w] of Object.entries(kept.words)) {
      if (!(n in kept.things)) continue;
      try { out.push([n, new RegExp(`\\b(?:${w})\\b`, "i")]); } catch { /* a bad pattern is not a word */ }
    }
    keptCache.set(kept, out);
  }
  return out;
}

export function heroOf(ask: string, kept: Kept = NO_KEPT): Hero | null {
  const name = pick(ask);
  return name ? { name, label: name.replace(/_/g, " "), define: "" } : seeded(ask, kept);
}

const HERO_SIZE = 280;
const HERO_SIZE_LATER = 230;
const LOOK = /^[ \t]*api\.look\([^)\n]*\)[ \t]*;?[ \t]*$/m;

/** Scene code with the hero drawn in it, after the scene's look call (the look paints the background). Scene 1 draws it
 *  on; later scenes keep it on screen unless the scene already calls api.thing. */
export function putIn(code: string, hero: Hero, first: boolean): string {
  const def = hero.define && !code.includes("api.defineThing(") ? hero.define : "";
  if (code.includes("api.thing(") && !first) return def ? def + "\n" + code : code;
  let line = `if (api.thing) api.thing("${hero.name}", api.w / 2, api.h * 0.47, ${first ? HERO_SIZE : HERO_SIZE_LATER}, {k: ${first ? "api.seg(t, 0, 1.2)" : "1"}});`;
  if (def) line = def + "\n" + line;
  const m = LOOK.exec(code);
  return m ? code.slice(0, m.index + m[0].length) + "\n" + line + code.slice(m.index + m[0].length) : line + "\n" + code;
}

const heroNote = (h: Hero) =>
  `\n\nHERO: the kit has ALREADY drawn the hero of this ask, a ${h.label}, as api.thing("${h.name}", x, y, size, {k: 1}) in every scene: big in the middle `
  + "(centred at api.w/2, api.h*0.47, about 280 px in scene 1 and 230 px after). Do not draw the "
  + `${h.label} yourself and do not hide it. Aim every callout at a spot inside its box and write the rest around it: a title near the top, `
  + "callouts on its parts in open space beside it, something moving. Do not call api.look unless you want a different look; the hero is drawn after it.";

// The hero is still being drawn when the writer starts (it takes its own call): the writer is told a drawing is coming, if the ask has a body.
const specNote = "\n\nHERO: if the ask is about one physical thing with a body (an animal, machine, building, tool, plant, vehicle), the kit has ALREADY drawn it, big in the middle "
  + "of the screen (api.thing). Do not draw it yourself and do not hide it. It is centred at (api.w/2, api.h*0.47) and about 280 px wide and tall: aim every callout at a spot inside that box. "
  + "Write the rest of the film around it: a title near the top, callouts on its parts in open space beside it (12 px clear), something moving. "
  + "Do not call api.look unless you want a different look; the hero is drawn after it.";

/** The prompt the film maker gets, one call for the whole film. `coming`: the hero is being drawn and is not known yet. */
export function promptFor(ask: string, hero: Hero | null, coming = false): string {
  return MOTION_PROMPT + (hero ? heroNote(hero) : coming ? specNote : "") + "\n\nASK: " + ask + "\n";
}

/** Makes the film for `ask`. `write` runs the model on the prompt and calls `onText` with each piece as it arrives.
 *  `save` stores one row. Each scene is saved the moment it is complete; a closing row says the film is whole. Resolves
 *  to the number of scenes saved (0: nothing was drawn, the caller says it in words). Never saves a half scene. */
export interface MakeOptions {
  kept?: Kept; // drawings the judge kept: a hit here is a seed hit
  say?: Say; // the model call that draws a thing the kit lacks; none: no on-demand drawing
  drew?: (hero: Hero | null) => void; // told the hero the film used, when it is over
  log?: (m: string) => void; // why a drawing came back empty
  early?: Promise<Hero | null> | null; // the hero drawn ahead from the person's words (speculate); null result: drawn now as before
  split?: boolean; // scene 1 from `write(..., "opener")` and scenes 2+ from `write(..., "rest")`, started together
  said?: string; // the person's own words: a kit word only the agent's line has (MOTION-30) does not pick the hero
}

/** MOTION-30: the agent writes the film line and often adds parts of the thing ("a skateboard turns: the metal trucks under the deck"),
 *  so a kit word in it (truck, plant, heart) can win over the noun the person asked about. When the person's own words name no kit,
 *  seed or kept thing and the line's kit word is not in them, the hero is drawn from the person's words instead; the kit word stays
 *  the fallback when that finds nothing. YUI_MOTION_GUARD=off turns it off. */
export const guardOn = () => !off("YUI_MOTION_GUARD");
export function elaborated(ask: string, said: string | undefined, kept: Kept = NO_KEPT): boolean {
  if (!guardOn() || !said || said.trim().split(/\s+/).length < 4 || SKIP.test(said)) return false;
  return !!pick(ask) && !heroOf(said, kept);
}

export type Role = "whole" | "opener" | "rest";
export async function make(ask: string, film: string, write: (prompt: string, onText: (piece: string) => void, role: Role) => Promise<unknown>,
                           save: (body: string, part: number, last: boolean) => Promise<unknown>, note: (words: string | null) => Promise<unknown> = async () => {},
                           opts: MakeOptions = {}): Promise<number> {
  const kitOnly = heroOf(ask, opts.kept);
  const guarded = !!kitOnly && !!opts.say && thingsOn() && elaborated(ask, opts.said, opts.kept);
  const found = guarded ? null : kitOnly;
  const drawWhy: { r?: string } = {};
  // A thing the kit lacks is drawn beside the writer, not before it; each scene waits for the drawing (up to CALL_TIMEOUT_MS) before it is saved.
  const pending: Promise<Hero | null> | null = !found && opts.say && thingsOn() && !SKIP.test(ask)
    ? (opts.early ?? Promise.resolve(null)).then((e) => e ?? drawNew(guarded ? opts.said! : ask, opts.say!, CALL_TIMEOUT_MS, drawWhy)).then((h) => { if (!h && drawWhy.r) opts.log?.(`no hero drawn: ${drawWhy.r}`); return h ?? kitOnly; }) : null;
  let hero: Hero | null = found;
  const title = titleOf(ask);
  let text = "", marks = 0, part = 0;
  let chain: Promise<unknown> = note(drawing(1));
  // The hero the film used (drawn or found), for the learner. A drawing has its own timeout, so this never waits long.
  const tell = async () => { if (opts.drew) opts.drew(hero ?? (pending ? await pending : null)); };
  const queue = (s: Scene) => {
    if (part >= MAX_SCENES) return;
    const n = ++part;
    chain = chain.then(async () => {
      if (!hero && pending) hero = await pending;
      await save(block(film, title, n, hero ? { ...s, code: putIn(s.code, hero, n === 1) } : s), n, false);
      await note(drawing(n + 1));
    });
  };
  try {
    const base = promptFor(ask, hero, !!pending);
    if (opts.split) {
      let t1 = "", m1 = 0, t2 = "", m2 = 0, opened = false;
      const held: Scene[] = [];
      const open = (first?: Scene) => { if (opened) return; opened = true; if (first) queue(first); held.splice(0).forEach(queue); };
      const rest = (sc: Scene) => (opened ? queue(sc) : void held.push(sc));
      const a = write(base + OPENER, (piece) => {
        t1 += piece;
        if (opened) return;
        const h = harvest(t1, m1);
        m1 = h.done;
        if (h.scenes.length) open(h.scenes[0]);
      }, "opener").catch(() => {}).then(() => { if (!opened) open(harvest(t1 + "\n=== end ===\n", 0).scenes[0]); });
      const b = write(base + CONTINUE, (piece) => {
        t2 += piece;
        const h = harvest(t2, m2);
        m2 = h.done;
        h.scenes.forEach(rest);
      }, "rest");
      b.catch(() => {}); // seen below; keeps an early rejection from going unhandled while the opener is awaited
      await a;
      await b;
      harvest(t2 + "\n=== end ===\n", m2).scenes.forEach(rest);
      open();
    } else {
      await write(base, (piece) => {
        text += piece;
        const h = harvest(text, marks);
        marks = h.done;
        h.scenes.forEach(queue);
      }, "whole");
    }
  } catch (e) {
    await chain.catch(() => {});
    await note(null);
    if (!part) throw e; // nothing played: the turn says so
    const n = await finish(chain, film, part, save);
    await tell();
    return n;
  }
  if (!opts.split) harvest(text + "\n=== end ===\n", marks).scenes.forEach(queue);
  const n = await finish(chain, film, part, save, note);
  await tell();
  return n;
}

async function finish(chain: Promise<unknown>, film: string, parts: number, save: (b: string, p: number, last: boolean) => Promise<unknown>,
                      note: (w: string | null) => Promise<unknown> = async () => {}): Promise<number> {
  await chain;
  await note(null);
  if (parts) await save(close(film, parts + 1), parts + 1, true);
  return parts;
}

// ---- a thing the kit lacks, drawn on demand (motion_hero.py, MOTION-15) ----
const FILLS = new Set(["ink", "panel", "accent", "a2", "warn", "good", "bad"]);
const MAX_PARTS = 12;
const MIN_PARTS = 5;
const LIM = 70;
export const CALL_TIMEOUT_MS = 14_000;

export const THING_PROMPT = `You name the thing a short film is about and sketch it as parts. Reply with JSON only, no words around it.

ASK: {ask}

If the ask is about one physical thing with a recognisable body or outline (an animal, machine, building, tool, plant, vehicle, organ, instrument; for a job or a person name the object they work with), reply {"noun":"<one or two lowercase words>","parts":[...]}. If it is about a plan, numbers, status, screens, software, a feeling, a place or a process with no single body, reply {"noun":null}.

parts: 7 to 12 shapes, back to front, drawn side-on in a box about -55..55 wide and -45..45 tall (y points down), centred on 0,0. Start with the big silhouette (body, hull, tower, case), then the details that name the thing (ears, trunk, lens, strings, blades, legs, wheels). The shapes must touch or overlap so it reads as one object, never loose bits. Shapes:
 {"s":"ellipse","x":0,"y":0,"rx":30,"ry":20,"f":"a2"}
 {"s":"circle","x":0,"y":0,"r":10,"f":"panel"}
 {"s":"rect","x":0,"y":0,"w":20,"h":30,"f":"warn"}  (x,y is the centre)
 {"s":"poly","p":[[x,y],[x,y],...],"f":"accent","smooth":true}  (closed filled shape, 3 to 12 points; smooth rounds the corners)
 {"s":"line","p":[[x,y],[x,y],...],"w":1.5,"smooth":true}  (open stroke, 2 to 12 points, w 0.5 to 3)
Fill f is one of: ink panel accent a2 warn good bad (leave out f for no fill). Use 3 or more different fills. The body must fill most of the box (at least 80 units wide or 60 tall).

Think of the outline first: where the head, the body and each end are, then place every part so it joins the next. A mushroom for example: {"noun":"mushroom","parts":[{"s":"rect","x":0,"y":22,"w":20,"h":44,"f":"panel"},{"s":"poly","p":[[-52,2],[-40,-26],[-14,-42],[14,-42],[40,-26],[52,2]],"f":"bad","smooth":true},{"s":"line","p":[[-52,2],[52,2]],"w":1.5},{"s":"circle","x":-22,"y":-16,"r":6,"f":"panel"},{"s":"circle","x":10,"y":-26,"r":5,"f":"panel"},{"s":"circle","x":28,"y":-8,"r":5,"f":"panel"},{"s":"ellipse","x":0,"y":46,"rx":30,"ry":6,"f":"good"}]}.
`;

const num = (v: unknown, lo = -LIM, hi = LIM): number => {
  const x = Number(v);
  if (typeof v === "boolean" || v === null || !Number.isFinite(x)) throw new Error("nan");
  return Math.min(hi, Math.max(lo, x));
};
const f1 = (x: number) => x.toFixed(1).replace(/\.?0+$/, "");

/** Catmull-Rom through the points as cubic curves. */
function smooth(pts: number[][], closed: boolean): string {
  const n = pts.length;
  let d = `M${f1(pts[0][0])} ${f1(pts[0][1])}`;
  for (let i = 0; i < (closed ? n : n - 1); i++) {
    const p0 = closed || i > 0 ? pts[(i - 1 + n) % n] : pts[0];
    const p1 = pts[i], p2 = pts[(i + 1) % n];
    const p3 = closed || i + 2 < n ? pts[(i + 2) % n] : pts[n - 1];
    const c1 = [p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6];
    const c2 = [p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6];
    d += ` C${f1(c1[0])} ${f1(c1[1])} ${f1(c2[0])} ${f1(c2[1])} ${f1(p2[0])} ${f1(p2[1])}`;
  }
  return d + (closed ? "Z" : "");
}
const ell = (x: number, y: number, rx: number, ry: number) =>
  `M${f1(x - rx)} ${f1(y)} A${f1(rx)} ${f1(ry)} 0 1 1 ${f1(x + rx)} ${f1(y)} A${f1(rx)} ${f1(ry)} 0 1 1 ${f1(x - rx)} ${f1(y)}Z`;

/** The model's parts, checked, as the kit's part list [[path, fill, stroke, width scale], ...], or null when anything is off.
 *  Only the five shapes of the vocabulary are read; every number is clamped; the model never writes a path string. */
export function buildParts(spec: unknown): unknown[][] | null {
  if (!Array.isArray(spec) || spec.length < MIN_PARTS || spec.length > MAX_PARTS + 4) return null;
  const out: unknown[][] = [], fills = new Set<string>(), xs: number[] = [], ys: number[] = [];
  try {
    for (const sh of spec.slice(0, MAX_PARTS)) {
      const kind = sh.s, f = sh.f;
      if (f !== undefined && f !== null && !FILLS.has(f)) return null;
      let d: string, pts: number[][];
      if (kind === "ellipse") {
        const x = num(sh.x), y = num(sh.y), rx = num(sh.rx, 2, LIM), ry = num(sh.ry, 2, LIM);
        d = ell(x, y, rx, ry); pts = [[x - rx, y - ry], [x + rx, y + ry]];
      } else if (kind === "circle") {
        const x = num(sh.x), y = num(sh.y), r = num(sh.r, 1.5, LIM);
        d = ell(x, y, r, r); pts = [[x - r, y - r], [x + r, y + r]];
      } else if (kind === "rect") {
        const x = num(sh.x), y = num(sh.y), w = num(sh.w, 2, 2 * LIM), h = num(sh.h, 2, 2 * LIM);
        d = `M${f1(x - w / 2)} ${f1(y - h / 2)} L${f1(x + w / 2)} ${f1(y - h / 2)} L${f1(x + w / 2)} ${f1(y + h / 2)} L${f1(x - w / 2)} ${f1(y + h / 2)}Z`;
        pts = [[x - w / 2, y - h / 2], [x + w / 2, y + h / 2]];
      } else if (kind === "poly" || kind === "line") {
        let raw = sh.p;
        if (!Array.isArray(raw) || raw.length < (kind === "poly" ? 3 : 2)) return null;
        // MOTION-30: a model that traces an outline in 16 points (Sonnet does, on a skateboard deck) lost the whole drawing; thin it to the 12 the prompt asks for.
        if (raw.length > 12) { if (raw.length > 40) return null; raw = Array.from({ length: 12 }, (_, i) => raw[Math.round(i * (raw.length - 1) / 11)]); }
        pts = raw.map((p: unknown[]) => [num(p[0]), num(p[1])]);
        const closed = kind === "poly";
        d = sh.smooth && pts.length >= 3 ? smooth(pts, closed) : "M" + pts.map(([a, b]) => `${f1(a)} ${f1(b)}`).join(" L") + (closed ? "Z" : "");
      } else return null;
      for (const [a, b] of pts) { xs.push(a); ys.push(b); }
      if (kind === "line") out.push([d, 0, "fg", num(sh.w || 1.2, 0.5, 3)]);
      else { out.push([d, f || 0, "fg", 1]); if (f) fills.add(f); }
    }
  } catch { return null; }
  if (fills.size < 2 || out.filter((p) => p[1]).length < 3) return null;
  if (Math.max(...xs) - Math.min(...xs) < 60 && Math.max(...ys) - Math.min(...ys) < 45) return null;
  return out;
}

export function nounId(noun: string): string | null {
  let n = (noun ?? "").trim().toLowerCase().replace(/[^a-z0-9 -]/g, "").trim().replace(/[ -]+/g, "_");
  return /^[a-z][a-z0-9_]{1,23}$/.test(n) ? n : null;
}

export interface Drawn { name: string; label: string; parts: unknown[][] | null } // parts null: the kit already draws it

/** {name, label, parts} from the model's JSON, {} for 'no single thing', null when unusable. */
export function parseReply(text: string): Drawn | Record<string, never> | null {
  const i = (text ?? "").indexOf("{");
  if (i < 0) return null;
  let d: any;
  try { d = firstJson(text.slice(i)); } catch { return null; }
  if (!d || typeof d !== "object" || Array.isArray(d)) return null;
  if (d.noun === null || d.noun === undefined || d.noun === "" || d.noun === "null") return {};
  const name = nounId(String(d.noun));
  if (!name) return null;
  if (name in WORDS) return { name, label: name.replace(/_/g, " "), parts: null }; // the kit already draws it
  const parts = buildParts(d.parts);
  return parts ? { name, label: String(d.noun).trim().toLowerCase().slice(0, 24), parts } : null;
}

/** The first JSON object at the start of `s`; whatever follows it is ignored (MOTION-20). */
function firstJson(s: string): unknown {
  let depth = 0, inStr = false, esc = false;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (inStr) { if (esc) esc = false; else if (c === "\\") esc = true; else if (c === '"') inStr = false; continue; }
    if (c === '"') inStr = true;
    else if (c === "{") depth++;
    else if (c === "}" && --depth === 0) return JSON.parse(s.slice(0, i + 1));
  }
  throw new Error("no object");
}

/** The model call a drawing needs: the prompt in, the reply text out. */
export type Say = (prompt: string) => Promise<string>;

/** The hero for an ask the word match missed, or null for no hero (no body, a failed call, slow, unusable). Never throws.
 *  Nothing is stored here, and nothing of the ask: the learner stores the noun alone, after the film. */
export async function drawNew(ask: string, call: Say, timeoutMs = CALL_TIMEOUT_MS, why: { r?: string } = {}): Promise<Hero | null> {
  if (!thingsOn() || !ask.trim() || SKIP.test(ask)) return null;
  try {
    let timer: ReturnType<typeof setTimeout> | undefined;
    const reply = await Promise.race([call(THING_PROMPT.replace("{ask}", ask.slice(0, 400))),
                                      new Promise<never>((_, no) => { timer = setTimeout(() => no(new Error("slow")), timeoutMs); })])
      .finally(() => clearTimeout(timer));
    const d = parseReply(reply);
    if (!d || !("name" in d)) { why.r = d ? "no single thing" : "unusable reply: " + String(reply).slice(0, 80).replace(/\s+/g, " "); return null; }
    return { name: d.name, label: d.label, define: d.parts ? `if (api.defineThing) api.defineThing("${d.name}", ${JSON.stringify(d.parts)});` : "" };
  } catch (e: any) { why.r = String(e?.message ?? e).slice(0, 80); return null; }
}

// ---- the learner (MOTION-25): a noun in neither the kit, the seed nor the kept set is drawn again once its film is over ----
export const LEARN_MAX_INFLIGHT = 2;
export const LEARN_DAILY = 20;
export const LEARN_PARTS_TIMEOUT_MS = 40_000;
/** The model that draws a learned thing: a drawing is kept for everyone, so it gets a stronger model than the chat route (YUI_MOTION_LEARN_MODEL; OpenRouter only). */
export const LEARN_MODEL = "anthropic/claude-sonnet-5.5";
// Single words that mean something else in a software or planning ask; a seed word wins over the parts call, so these are never learned.
const LEARN_AMBIGUOUS = new Set(["cell", "cloud", "ship", "phone", "plant", "bank", "table", "chart", "graph", "key", "screen", "window", "file", "folder", "tree",
  "map", "board", "card", "page", "pipe", "stack", "mouse", "network", "server", "tool", "light", "box", "net", "web", "bug", "frame"]);
const esc = (w: string) => w.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

function forms(w: string): string {
  const plural = w.endsWith("y") && !"aeiou".includes(w[w.length - 2]) ? w.slice(0, -1) + "ies" : w + (/(s|x|ch|sh)$/.test(w) ? "es" : "s");
  return `(?:${esc(w)}|${esc(plural)})`;
}

/** The narrow pattern a learned noun answers to: its own name and plural, and for a two-word name its last word alone when that word
 *  is not an everyday one ('snare drum' also answers to 'drum'; 'kayak' and 'boat' never answer to 'kayak paddle'; 'cell' is never learned). */
export function learnWords(label: string): string | null {
  const toks = (label ?? "").toLowerCase().match(/[a-z][a-z0-9]*/g) ?? [];
  if (!toks.length || toks.length > 2 || toks[toks.length - 1].length < 3 || (toks.length === 1 && LEARN_AMBIGUOUS.has(toks[0]))) return null;
  if (toks.length === 1) return forms(toks[0]);
  const full = [esc(toks[0]!), forms(toks[1]!)].join("[ -]?");
  const head = toks[1]!;
  return head.length >= 4 && !LEARN_AMBIGUOUS.has(head) ? full + "|" + forms(head) : full;
}

/** Whether a film that drew `hero` itself should queue a learner for it: a drawn thing (not a kit one) with a learnable name that is
 *  not already known. Off with YUI_MOTION_LEARN=off. */
export function worthLearning(hero: Hero | null, kept: Kept): boolean {
  if (!hero || !hero.define || !learnOn()) return false; // no hero, or a kit thing (it has no define)
  const n = hero.name;
  return !(n in WORDS) && !(n in MOTION_SEED.things) && !(n in kept.things) && !!learnWords(n.replace(/_/g, " "));
}

const specCalls = new Map<string, number[]>();
export const SPEC_MAX_PER_HOUR = 20;
const EXPLAIN = /\b(how|why|what|show|explain|works?|draw|looks?|happens?)\b/i;
/** The hero drawn ahead of the agent's reply (MOTION-30): when the person's own words ask for an explanation, have at least 4 words and name no kit, seed or
 *  kept thing, one drawing call starts now. At most SPEC_MAX_PER_HOUR an hour a person. Null: not started. Never throws; a failed drawing resolves null. */
export function speculate(who: string, said: string | undefined, call: Say, log: (m: string) => void = () => {}, now: number = Date.now(), kept: Kept = NO_KEPT): Promise<Hero | null> | null {
  if (!speculateOn() || !thingsOn() || !said || SKIP.test(said) || !EXPLAIN.test(said) || said.trim().split(/\s+/).length < 4 || heroOf(said, kept)) return null;
  const mine = (specCalls.get(who) ?? []).filter((t) => now - t < 3_600_000);
  if (mine.length >= SPEC_MAX_PER_HOUR) return null;
  mine.push(now);
  specCalls.set(who, mine);
  const why: { r?: string } = {};
  return drawNew(said, call, CALL_TIMEOUT_MS, why).then((h) => { if (!h && why.r) log(`speculative hero: ${why.r}`); return h; });
}
/** YUI_MOTION_SPECULATE=off keeps the drawing until the film starts. */
export const speculateOn = () => !off("YUI_MOTION_SPECULATE");

export function learnAsk(label: string): string {
  return `${/^[aeiou]/.test(label) ? "An" : "A"} ${label}, shown clearly.`; // the seed's own ask, so a learned drawing is made like a seed one
}

export interface Learner {
  claim(noun: string, daily: number, inflight: number): Promise<boolean>;
  put(noun: string, label: string | null, parts: unknown[] | null, words: string | null, why: string): Promise<void>;
}

/** Draws `noun` again for the judge. The store's claim holds the caps (2 in flight, 20 a day, two tries a noun ever); the drawing is
 *  saved as `drawn` and a judge on a machine with a browser keeps or drops it. Returns why it stopped. Never throws. */
export async function learn(noun: string, db: Learner, call: Say, timeoutMs = LEARN_PARTS_TIMEOUT_MS): Promise<string> {
  try {
    if (!learnOn()) return "off";
    const words = learnWords(noun.replace(/_/g, " "));
    if (!words || noun in WORDS || noun in MOTION_SEED.things) return "not learnable";
    if (!(await db.claim(noun, LEARN_DAILY, LEARN_MAX_INFLIGHT))) return "capped or known";
    let why = "no parts";
    for (let i = 0; i < 2; i++) { // as seed_build: one retry when the parts come back empty or name another thing
      let d: Drawn | Record<string, never> | null = null;
      try {
        let timer: ReturnType<typeof setTimeout> | undefined;
        d = parseReply(await Promise.race([call(THING_PROMPT.replace("{ask}", learnAsk(noun.replace(/_/g, " ")))),
                                           new Promise<never>((_, no) => { timer = setTimeout(() => no(new Error("slow")), timeoutMs); })])
          .finally(() => clearTimeout(timer)));
      } catch { d = null; }
      if (d && "name" in d && d.parts && d.name === noun) {
        await db.put(noun, d.label, d.parts, words, "");
        return "drawn";
      }
      why = d && "name" in d && d.name ? `parts named ${d.name}` : "no parts";
    }
    await db.put(noun, null, null, null, why);
    return why;
  } catch (e: any) {
    return `crash ${e?.name ?? "error"}`;
  }
}
