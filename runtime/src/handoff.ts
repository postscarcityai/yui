// Hand-offs, mentions and groups for native agents (YUI-144, spec/NATIVE.md section 10).
//
// A hand-off is one Yui Lines card: `card "Basil" body="<the note>" url=yui://agent/basil cta="Open Basil"`.
// The phone jumps to that agent's thread when the card lands live (spec/YL.md, card), and the agent
// handed to answers there first with the note. An agent can write the card itself, or a ```handoff
// block, which the runtime turns into the card.
//
// Connected agents (Hermes and others) are reached with @handles: the database routes them as
// mentions (or group asks, in a group). They read only what the agent wrote, never its memory.
import type { Row } from "./types.ts";

export interface Target { handle: string; name: string }

const HANDLE = /(?<![\w@.])@([a-z0-9][a-z0-9-]{0,31})\b/gi;
const FENCE = /```[\s\S]*?(?:```|$)/g;
const INLINE = /`[^`\n]*`/g;
// `yui://agent/<id>/thread` only opens an agent (Yui's crew page, YUI-168): not a hand-off.
const CARD = /^card\b.*\burl=(?:"yui:\/\/agent\/([a-z0-9-]+)"|yui:\/\/agent\/([a-z0-9-]+)(?![a-z0-9-]|\/thread))/i;
const BODY = /\bbody="((?:[^"\\]|\\.)*)"/;
const MAX_MENTIONS = 3;

const q = (s: string) => `"${s.replace(/\\/g, "\\\\").replace(/"/g, "'").replace(/\s+/g, " ").trim()}"`;

/** The card that takes the person to `to`, with the note on it. */
export function card(to: Target, note: string): string {
  return `card ${q(to.name)} body=${q(note.slice(0, 280))} url=yui://agent/${to.handle} cta=${q(`Open ${to.name}`)}`;
}

/** Hand-off cards the agent wrote itself in a yui block: who, and the note (the card's body). */
export function cards(text: string): { target: string; note: string }[] {
  const out: { target: string; note: string }[] = [];
  for (const block of text.match(/```yui[^\n]*\n[\s\S]*?(?:```|$)/g) ?? []) {
    for (const l of block.split("\n")) {
      const m = l.trim().match(CARD);
      if (m) out.push({ target: (m[1] ?? m[2]).toLowerCase(), note: (l.match(BODY)?.[1] ?? "").replace(/\\(.)/g, "$1") });
    }
  }
  return out;
}

/** Adds the card to the answer's yui block (a new block at the end when it has none there). */
export function withCard(body: string, line: string): string {
  const b = body.trim();
  const open = b.lastIndexOf("```yui");
  if (open >= 0 && b.endsWith("\n```") && b.indexOf("```", open + 3) === b.length - 3) return `${b.slice(0, -3)}${line}\n\`\`\``;
  return `${b}${b ? "\n" : ""}\`\`\`yui\n${line}\n\`\`\``;
}

/** @handles in the words (not in fences or code), lower case, first seen first, at most three. */
export function handlesIn(text: string, skip: string[] = []): string[] {
  const plain = text.replace(FENCE, " ").replace(INLINE, " ");
  const out: string[] = [];
  for (const m of plain.matchAll(HANDLE)) {
    const h = m[1].toLowerCase();
    if (!skip.includes(h) && !out.includes(h)) out.push(h);
  }
  return out.slice(0, MAX_MENTIONS);
}

/** This turn came from another agent (a mention or a hand-off): it answers, it never passes the person on. */
export function handedIn(rows: Row[]): boolean {
  return rows.some((r) => /^\[yui\] (mention|handoff) /.test(r.body) || r.meta?.mentioned);
}

/** The group a row belongs to, or null for the agent's own thread. */
export const threadOf = (r: Row): string | null => r.thread_id ?? r.meta?.group?.thread ?? null;

/** One turn answers one thread: the oldest waiting row's, the rest wait for the next turn. */
export function oneThread(rows: Row[]): Row[] {
  if (!rows.length) return rows;
  const t = threadOf(rows[0]);
  return rows.filter((r) => threadOf(r) === t);
}
