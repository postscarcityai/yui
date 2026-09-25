// Yui holds the thread (INT-12): a chat API remembers nothing, so every turn
// sends the channel guide as the system message, then as much of the thread as
// fits, then the person's new messages. Runtime-neutral, no I/O.
import type { ChatMessage } from "./openai.ts";

/** A row of yui_messages, as the bridge reads it. */
export interface ThreadRow {
  id: string;
  sender: "user" | "agent" | string;
  kind: string;
  body: string;
  meta?: any;
  created_at?: string;
}

export interface BuildOptions {
  guide: string; // the channel guide body
  system?: string; // the person's own words for this agent, before the guide
  context?: number; // the model's context window in tokens (default 4096)
  reserve?: number; // tokens kept free for the answer (default 1024)
}

/** A rough count that errs high: about 3.5 characters a token for English and code. */
export const tokens = (s: string) => Math.ceil(s.length / 3.5) + 4;

/** One row as a chat message, or null for rows the model should not see. */
export function toMessage(row: ThreadRow): ChatMessage | null {
  const meta = row.meta ?? {};
  if (meta.bridge) return null; // the bridge's own status lines ("can't reach the model")
  const body = (row.body ?? "").trim();
  if (!body) return null;
  if (row.sender === "agent") {
    // Another agent answering an @mention lands in this thread in its own look.
    if (meta.mention_reply) return { role: "user", content: `[yui] ${meta.mention_reply.name ?? "another agent"} answered: ${body}` };
    return { role: "assistant", content: body };
  }
  return { role: "user", content: body }; // text, and taps as their [yui] line
}

/** Chat templates of many open models want user and assistant to take turns: join runs. */
export function alternate(msgs: ChatMessage[]): ChatMessage[] {
  const out: ChatMessage[] = [];
  for (const m of msgs) {
    const last = out[out.length - 1];
    if (last && last.role === m.role) last.content += `\n${m.content}`;
    else out.push({ ...m });
  }
  while (out.length && out[0].role === "assistant") out.shift(); // start with the person
  return out;
}

/** system (guide), then the newest history that fits, then the turn. Returns what was left out too. */
export function buildMessages(history: ThreadRow[], turn: ThreadRow[], opts: BuildOptions): { messages: ChatMessage[]; dropped: number; over: boolean } {
  const system = [opts.system?.trim(), opts.guide.trim()].filter(Boolean).join("\n\n");
  const now = alternate(turn.map(toMessage).filter((m): m is ChatMessage => !!m));
  let budget = (opts.context ?? 4096) - (opts.reserve ?? 1024) - tokens(system) - now.reduce((n, m) => n + tokens(m.content), 0);
  const over = budget < 0;
  const past = history.map(toMessage).filter((m): m is ChatMessage => !!m);
  const kept: ChatMessage[] = [];
  for (let i = past.length - 1; i >= 0; i--) {
    const cost = tokens(past[i].content);
    if (cost > budget) break; // keep it contiguous: never a gap in the middle of the thread
    budget -= cost;
    kept.unshift(past[i]);
  }
  const messages = alternate([...kept, ...now]);
  if (system) messages.unshift({ role: "system", content: system });
  return { messages, dropped: past.length - kept.length, over };
}
