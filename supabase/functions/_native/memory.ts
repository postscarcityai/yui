// Copied from runtime/src/memory.ts by runtime/scripts/build.mjs. Do not edit here.
// Memory (YUI-140): each agent's own notes, and one "about you" card every
// native agent on the person's Yui reads. Pure: a list in, changes out; the
// store keeps them (Postgres on the server, a JSON file locally).
import type { MemoryOp } from "./directives.ts";
import type { MemoryItem } from "./types.ts";

export const MAX_NOTES = 40; // per agent; the oldest go first
export const MAX_ABOUT = 30; // facts on the about-you card
export const MAX_BODY = 300; // characters in one note or fact

/** The changes to make: rows to write (new or updated) and ids to delete. */
export interface MemoryChange {
  put: MemoryItem[];
  drop: string[];
}

/** Notes in the order the prompt numbers them (n1 is the oldest). */
export function notesOf(items: MemoryItem[], agentId: string): MemoryItem[] {
  return items.filter((i) => i.kind === "note" && i.agentId === agentId)
    .sort((a, b) => a.updatedAt.localeCompare(b.updatedAt) || a.id.localeCompare(b.id));
}

export function aboutOf(items: MemoryItem[]): MemoryItem[] {
  return items.filter((i) => i.kind === "about").sort((a, b) => (a.key ?? "").localeCompare(b.key ?? ""));
}

/** Applies what the agent wrote. `newId` makes ids for new rows. */
export function applyMemory(items: MemoryItem[], agentId: string, ops: MemoryOp[], now: string, newId: () => string): MemoryChange {
  const put = new Map<string, MemoryItem>();
  const drop = new Set<string>();
  const notes = notesOf(items, agentId);
  const about = new Map(aboutOf(items).map((i) => [i.key!, i]));
  const clip = (s: string) => s.replace(/\s+/g, " ").trim().slice(0, MAX_BODY);
  for (const op of ops) {
    if (op.op === "note") {
      const body = clip(op.body);
      if (!body || notes.some((n) => n.body.toLowerCase() === body.toLowerCase())) continue;
      const item: MemoryItem = { id: newId(), agentId, kind: "note", body, updatedAt: now };
      notes.push(item);
      put.set(item.id, item);
    } else if (op.op === "about") {
      const body = clip(op.body);
      if (!op.key || !body) continue;
      const old = about.get(op.key);
      if (old && old.body === body) continue;
      const item: MemoryItem = { id: old?.id ?? newId(), agentId: null, kind: "about", key: op.key, body, updatedAt: now };
      about.set(op.key, item);
      put.set(item.id, item);
    } else if (op.op === "forget_note") {
      const n = Number(op.ref.slice(1));
      const hit = notesOf(items, agentId)[n - 1]; // numbers are the ones the agent was shown
      if (hit) {
        drop.add(hit.id);
        put.delete(hit.id);
        const i = notes.indexOf(hit);
        if (i >= 0) notes.splice(i, 1);
      }
    } else if (op.op === "forget_about") {
      const hit = about.get(op.key);
      if (hit) {
        drop.add(hit.id);
        put.delete(hit.id);
        about.delete(op.key);
      }
    }
  }
  // Over the cap: the oldest notes, and the oldest facts, make room.
  while (notes.length > MAX_NOTES) {
    const old = notes.shift()!;
    drop.add(old.id);
    put.delete(old.id);
  }
  const facts = [...about.values()].sort((a, b) => a.updatedAt.localeCompare(b.updatedAt));
  while (facts.length > MAX_ABOUT) {
    const old = facts.shift()!;
    drop.add(old.id);
    put.delete(old.id);
  }
  return { put: [...put.values()], drop: [...drop] };
}

/** The memory part of the system prompt. */
export function memoryPrompt(items: MemoryItem[], agentId: string): string {
  const about = aboutOf(items);
  const notes = notesOf(items, agentId);
  const lines = ["## What you remember"];
  lines.push(about.length ? "About this person (every agent on their Yui shares this card):" : "About this person: nothing yet.");
  for (const a of about) lines.push(`- ${a.key}: ${a.body}`);
  lines.push(notes.length ? "Your own notes:" : "Your own notes: none yet.");
  notes.forEach((n, i) => lines.push(`- [n${i + 1}] ${n.body}`));
  return lines.join("\n");
}
