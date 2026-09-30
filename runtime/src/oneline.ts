// One line and a picture for the native crew (VIS-3). A port of hermes-plugin/yui/oneline.py, same rules, same numbers;
// hermes-plugin/tests/test_oneline.py is the spec and tests/oneline.test.ts runs its cases here.
//
// A reply breaks the rule when its chat text (outside the ```yui blocks) runs over LINE_WORDS words, draws more than one
// text bubble, or opens with a filler word. gate() then rewrites it before it is saved: the first sentence (plus the
// question when there is one) cut short at a clause, the blocks kept as they are, and when the reply had no picture the
// other sentences become a `sketch` of short rows. Replies with a code fence, or with no prose, are left alone.
//
// Modes: `shadow` (default) reports what it would change and saves the reply untouched; `on` saves the rewrite; `off`.
// Counts only, never the text. Nothing here throws: a broken gate must not break a reply.

export const LINE_WORDS = 30;
export const LINE_TARGET = 22; // the first sentence is cut near here
const ROW_WORDS = 8;
const MAX_ROWS = 4;
export type OneLineMode = "off" | "shadow" | "on";

const FENCE = () => /```yui[^\n]*\n.*?(?:```|$)/gs;
const OTHER_FENCE = /```(?!yui)/;
const SENTENCE = /(?<=[.!?])\s+(?=[A-Z0-9("'`])/;
const CLAUSE = /[,;:—]|\s-\s/g;
// A drawing made of Yui Lines. A rendered image does not count.
const PICTURE = new Set(["sketch", "shapes", "map", "chart", "stat", "timeline"]);
const FILLER_LEAD = /^(so|now|well|okay|ok|sure|alright|anyway|however|basically|overall|actually|got it|understood|agreed)\b[,.!]?\s+/i;
const DANGLING = new Set(["and", "or", "but", "the", "a", "an", "of", "to", "in", "on", "at", "for", "by", "with", "because", "that",
  "which", "is", "are", "was", "were", "so", "as", "from", "it", "its", "into", "than", "then", "if", "when"]);
const ACK_ONLY = /^(got it|understood|agreed|okay|ok|sure|alright)[.!]*$/i;
const MARKUP = /^\s*(?:#{1,6}\s+|[-*•]\s+|\d+[.)]\s+)/;

export interface Measure { words: number; bubbles: number; picture: boolean; filler: boolean }

export function oneLineMode(v: string | undefined | null): OneLineMode {
  const m = String(v ?? "").trim().toLowerCase();
  return m === "off" || m === "on" || m === "shadow" ? m : "shadow";
}

const split = (s: string) => s.trim().split(/\s+/).filter(Boolean);
const parts = (body: string) => body.replace(FENCE(), "\x00").split("\x00");

function paragraphs(text: string): string[] {
  return text.split(/\n\s*\n/).map((p) => p.trim())
    .filter((p) => p.split("\n").some((l) => l.trim() && !l.trim().startsWith("MEDIA:")));
}

export function measure(body: string): Measure {
  let words = 0;
  let bubbles = 0;
  const paras: string[] = [];
  for (const chunk of parts(body ?? "")) {
    const ps = paragraphs(chunk);
    paras.push(...ps);
    bubbles += ps.length;
    words += ps.filter((p) => !p.startsWith("MEDIA:")).reduce((n, p) => n + (p.match(/\S+/g)?.length ?? 0), 0);
  }
  let picture = false;
  for (const m of (body ?? "").matchAll(FENCE())) {
    for (const ln of m[0].split("\n").slice(1)) {
      const tok = ln.trim().replace(/^[>~]\d*\s*/, "").split(" ")[0].split("@")[0];
      if (PICTURE.has(tok)) picture = true;
    }
  }
  return { words, bubbles, picture, filler: FILLER_LEAD.test(paras[0] ?? "") };
}

export function violates(m: Measure, prior = 0): boolean {
  return m.bubbles > 0 && (m.words > LINE_WORDS || m.bubbles > 1 || prior > 0 || m.filler);
}

function unfill(s: string): string {
  const t = s.replace(FILLER_LEAD, "");
  return t !== s ? t.slice(0, 1).toUpperCase() + t.slice(1) : s;
}

/** At most n words, cut at the last clause inside the limit, never with an ellipsis and never ending on a dangling "and" or "the". */
export function clip(s: string, n: number): string {
  const w = split(s);
  if (w.length <= n) return s.trim().replace(/[,;:]+$/, "");
  let head = w.slice(0, n).join(" ");
  const cut = [...head.matchAll(CLAUSE)].map((m) => m.index!);
  if (cut.length && cut[cut.length - 1] >= Math.floor(head.length / 2)) head = head.slice(0, cut[cut.length - 1]);
  const words = split(head);
  while (words.length > 2 && (DANGLING.has(words[words.length - 1].toLowerCase().replace(/^[,;:]+|[,;:]+$/g, ""))
    || (/^\d/.test(words[words.length - 1]) && DANGLING.has(words[words.length - 2].toLowerCase())))) words.pop();
  return words.join(" ").replace(/[,;:\-—]+$/, "") + (s.trimEnd().endsWith(".") ? "." : "");
}

function sentences(text: string): string[] {
  const out: string[] = [];
  for (const p of paragraphs(text)) {
    for (let ln of p.split("\n")) {
      ln = ln.replace(MARKUP, "").trim();
      if (ln) out.push(...ln.split(SENTENCE).map((s) => s.trim()).filter(Boolean));
    }
  }
  return out;
}

const q = (s: string) => '"' + split(s).join(" ").replace(/\\/g, "").replace(/"/g, "'") + '"';

/** The reply as one line and its picture, or null when it should go as written. */
export function rewrite(body: string, prior = 0): string | null {
  if (!body || OTHER_FENCE.test(body.replace(FENCE(), " "))) return null;
  const m = measure(body);
  if (!violates(m, prior)) return null;
  const fences = [...body.matchAll(FENCE())].map((f) => f[0].trimEnd());
  const prose = body.replace(FENCE(), " ");
  const sents = sentences(prose);
  if (!sents.length) return null;
  let title = "The short version";
  for (const p of paragraphs(prose)) {
    const h = p.match(/^\s*#{1,6}\s+(.+)/);
    if (h) { title = clip(h[1], 4).replace(/\.+$/, ""); break; }
  }
  const rest = [...sents];
  while (rest.length > 1 && ACK_ONLY.test(rest[0])) rest.shift(); // "Got it." on its own says nothing
  let head: string | null = null;
  if (prior === 0) {
    const first = rest.shift()!;
    let line = clip(unfill(first), LINE_TARGET);
    const ask = rest.find((s) => s.endsWith("?"));
    if (ask && !line.endsWith("?") && split(line).length + split(ask).length <= LINE_WORDS) {
      line += " " + ask;
      rest.splice(rest.indexOf(ask), 1);
    }
    head = line;
  }
  const out = head ? [head] : [];
  if (m.picture || !rest.length) out.push(...fences); // the picture stays; extra prose goes
  else {
    const rows = rest.slice(0, MAX_ROWS).map((s) => clip(s, ROW_WORDS).replace(/\.+$/, ""));
    const sketch = [`sketch ${q(title)} frame=bubble`, ...rows.map((r) => `row ${q(r)}`)];
    out.push(...fences, "```yui\n" + sketch.join("\n") + "\n```");
  }
  return out.join("\n").trim() || null;
}

export interface Gated {
  body: string; // what to save
  before: Measure;
  after?: Measure; // the rewrite's counts, whether or not it was saved
  action: "ok" | "would-rewrite" | "rewrote";
}

/** `prior` is the prose bubbles already sent in this turn. */
export function gate(body: string, prior: number, mode: OneLineMode): Gated {
  const none: Measure = { words: 0, bubbles: 0, picture: false, filler: false };
  try {
    const before = measure(body);
    if (mode === "off" || !violates(before, prior)) return { body, before, action: "ok" };
    const next = rewrite(body, prior);
    if (next === null) return { body, before, action: "ok" };
    const after = measure(next);
    return mode === "on" ? { body: next, before, after, action: "rewrote" } : { body, before, after, action: "would-rewrite" };
  } catch {
    return { body, before: none, action: "ok" };
  }
}

/** The counts that go on the saved row and into the log: never the words. */
export function onelineNote(g: Gated): Record<string, unknown> {
  return { action: g.action, words: g.before.words, bubbles: g.before.bubbles, picture: g.before.picture,
    ...(g.after ? { words_after: g.after.words, bubbles_after: g.after.bubbles, picture_after: g.after.picture } : {}) };
}
