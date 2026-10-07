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
// Not ported: the Hermes plugin's hero drawn on demand and learned afterwards (needs a warm CLI and a judge).
import { MOTION_PROMPT, MOTION_SEED } from "./motion.gen.ts";
import { COOK, SKIP, WEAK, WORDS } from "./motionwords.ts";

export const MAX_ASK = 700; // characters of ask the maker sees
export const MAX_SCENES = 12;
export const MAX_FILMS_PER_HOUR = 8;
export const FIRST_SCENE_SECONDS = 60;

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
export function seeded(ask: string): Hero | null {
  if (!ask.trim() || SKIP.test(ask)) return null;
  let best: [number, string] | null = null;
  for (const [name, pat] of SEED_PATS) {
    const m = pat.exec(ask);
    if (m && (!best || m.index < best[0])) best = [m.index, name];
  }
  const th = best && MOTION_SEED.things[best[1]];
  if (!best || !th) return null;
  return { name: best[1], label: th.label, define: `if (api.defineThing) api.defineThing("${best[1]}", ${JSON.stringify(th.parts)});` };
}

export function heroOf(ask: string): Hero | null {
  const name = pick(ask);
  return name ? { name, label: name.replace(/_/g, " "), define: "" } : seeded(ask);
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

/** The prompt the film maker gets, one call for the whole film. */
export function promptFor(ask: string, hero: Hero | null): string {
  return MOTION_PROMPT + (hero ? heroNote(hero) : "") + "\n\nASK: " + ask + "\n";
}

/** Makes the film for `ask`. `write` runs the model on the prompt and calls `onText` with each piece as it arrives.
 *  `save` stores one row. Each scene is saved the moment it is complete; a closing row says the film is whole. Resolves
 *  to the number of scenes saved (0: nothing was drawn, the caller says it in words). Never saves a half scene. */
export async function make(ask: string, film: string, write: (prompt: string, onText: (piece: string) => void) => Promise<unknown>,
                           save: (body: string, part: number, last: boolean) => Promise<unknown>, note: (words: string | null) => Promise<unknown> = async () => {}): Promise<number> {
  const hero = heroOf(ask);
  const title = titleOf(ask);
  let text = "", marks = 0, part = 0;
  let chain: Promise<unknown> = note(drawing(1));
  const queue = (s: Scene) => {
    if (part >= MAX_SCENES) return;
    const n = ++part;
    chain = chain.then(async () => {
      await save(block(film, title, n, hero ? { ...s, code: putIn(s.code, hero, n === 1) } : s), n, false);
      await note(drawing(n + 1));
    });
  };
  try {
    await write(promptFor(ask, hero), (piece) => {
      text += piece;
      const h = harvest(text, marks);
      marks = h.done;
      h.scenes.forEach(queue);
    });
  } catch (e) {
    await chain.catch(() => {});
    await note(null);
    if (!part) throw e; // nothing played: the turn says so
    return finish(chain, film, part, save);
  }
  harvest(text + "\n=== end ===\n", marks).scenes.forEach(queue);
  return finish(chain, film, part, save, note);
}

async function finish(chain: Promise<unknown>, film: string, parts: number, save: (b: string, p: number, last: boolean) => Promise<unknown>,
                      note: (w: string | null) => Promise<unknown> = async () => {}): Promise<number> {
  await chain;
  await note(null);
  if (parts) await save(close(film, parts + 1), parts + 1, true);
  return parts;
}
