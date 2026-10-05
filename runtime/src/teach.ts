// A picture on every page of an explanation (t_88023cf2). Chris, Oct 5: "Eli5 string theory" came back as pages of
// plain text on the native Home agent, and the guide's "Explainers draw every page" had been skipped. The prompt
// teaches the shape (TEACH_RULES in prompt.ts); this is the net under it. When the person asked to have something
// explained and the answer is a deck with a page that has no drawing right after it (or no deck at all), the turn
// asks the model once more to redraw it, and keeps the second try only when it is better. Counts and titles only.

/** Presets that draw something. A rendered image or a `card` does not count as the page's picture. */
const PICTURE = new Set(["sketch", "shapes", "map", "chart", "stat", "math", "image", "diagram", "mock", "calc", "compare", "gallery", "timeline", "video"]);

// Asks that are an explanation whatever the topic: a deck is owed, so an answer with none is redrawn too.
const ASKS = /\b(eli5|explain|teach me|walk me through|like i['’]?m (5|five|a kid|ten|10)|in (simple|plain) (terms|words|english)|simply)\b|\bhow (does|do|did|is|are|can)\b[^?.!]{0,60}\b(work|works|happen|happens|made|make|form|forms)\b/i;
// Asks that may be a plain fact ("what is the capital of France"): only a deck that came back with a bare page is redrawn.
const MAYBE = /\b(what('?s| is| are)|why (is|are|do|does|did)|how come)\b/i;

export type Taught = "explain" | "maybe" | null;

/** What the person's words ask for: an explanation, maybe one, or something else. */
export function explainAsk(said: string): Taught {
  if (ASKS.test(said)) return "explain";
  return MAYBE.test(said) ? "maybe" : null;
}

const head = (line: string) => line.trim().replace(/^[>~]\d*\s*/, "").split(/[\s]/)[0].split("@")[0];

/** Lines of the answer's yui blocks, in order. */
function lines(text: string): string[] {
  const out: string[] = [];
  for (const f of text.matchAll(/```yui[^\n]*\n([\s\S]*?)(?:```|$)/g)) out.push(...f[1].split("\n").map((l) => l.trim()).filter(Boolean));
  return out;
}

export interface Pages { decks: number; pages: number; bare: string[] }

/** The decks in an answer, their pages and the titles of the pages with no drawing on the very next line. */
export function pagesOf(text: string): Pages {
  const ls = lines(text);
  const r: Pages = { decks: 0, pages: 0, bare: [] };
  for (let i = 0; i < ls.length; i++) {
    const h = head(ls[i]);
    if (h === "deck") r.decks++;
    if (h !== "page") continue;
    r.pages++;
    if (!PICTURE.has(head(ls[i + 1] ?? ""))) r.bare.push(ls[i].match(/^\S+\s+"([^"]*)"/)?.[1] ?? ls[i].slice(0, 30));
  }
  return r;
}

/** Whether this answer to this ask needs a redraw, and the titles of the pages that have no drawing. */
export function owes(said: string, answer: string): { why: string; bare: string[] } | null {
  const ask = explainAsk(said);
  if (!ask) return null;
  const p = pagesOf(answer);
  // A plan is findings then questions, never an explainer; a deck with every page drawn is done.
  if (/^\s*plan\b/m.test(lines(answer).join("\n"))) return null;
  if (p.decks && p.bare.length) return { why: "bare", bare: p.bare };
  if (!p.decks && ask === "explain" && !/```yui/.test(answer) && answer.trim().split(/\s+/).length > 12) return { why: "no deck", bare: [] };
  return null;
}

/** The note that goes back to the model for its one redraw. */
export function redrawNote(o: { why: string; bare: string[] }): string {
  const what = o.why === "bare"
    ? `Pages with no drawing: ${o.bare.map((t) => `"${t}"`).join(", ")}.`
    : "That was words only.";
  return `[yui] ${what} They asked for an explanation, so draw it: one short line, then one deck on >full of 2 to 4 pages. `
    + "Every page has its title, a body of 25 words or fewer, and its drawing (shapes, chart, stat, sketch, map or math) on the very next line. "
    + "End with a choose of where to go next, then end. Send the whole deck again.";
}

/** Better when it is a deck and has fewer undrawn pages; an answer with no deck must come back fully drawn. */
export function better(before: string, after: string): boolean {
  const a = pagesOf(before), b = pagesOf(after);
  if (!b.decks) return false;
  return a.decks ? b.bare.length < a.bare.length : b.bare.length === 0;
}

/** The redraw's text with the first try's `remember` and `schedule` blocks kept, so nothing the agent learned is lost. */
export function keepNotes(before: string, after: string): string {
  const notes = [...before.matchAll(/```(remember|schedule)\n[\s\S]*?```/g)].map((m) => m[0]).filter((n) => !after.includes(n.split("\n")[0] + "\n"));
  return notes.length ? `${after.trim()}\n${notes.join("\n")}` : after;
}
