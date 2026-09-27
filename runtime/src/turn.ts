// One native turn, the same on a laptop and in the edge function (YUI-130):
// take the person's new rows, build the prompt, ask the model, keep what the
// agent chose to remember, apply any agent changes, write the answer.
// Relay rules as every host (yuigui spec/RELAY.md): delivered when the turn
// starts, `doing` while it works, handled once the answer is written, and the
// answer names its rows in meta.turn.
import { ChatClient, ModelError, ModelUnavailable, type Completion } from "./openai.ts";
import { extract } from "./directives.ts";
import { applyMemory } from "./memory.ts";
import { applyAgentOps } from "./agents.ts";
import { buildTurn, photoPaths, type CrewEntry } from "./prompt.ts";
import type { Store } from "./store.ts";
import type { NativeAgent, Row } from "./types.ts";

export interface Provider {
  url: string; // an OpenAI-compatible base URL
  key?: string;
  headers?: Record<string, string>;
  extra?: Record<string, unknown>; // sent with every request (OpenRouter's provider rules)
}

/** OpenRouter, on Yui's key for now (spec/NATIVE.md section 7). */
export function openRouter(key: string): Provider {
  return {
    url: "https://openrouter.ai/api/v1",
    key,
    headers: { "HTTP-Referer": "https://www.yuigui.com", "X-Title": "Yui" },
    extra: { provider: { data_collection: "deny" } },
  };
}

export interface TurnOptions {
  provider: Provider;
  fetch?: typeof fetch; // the model side only (tests)
  maxTokens?: number; // default 2000
  context?: number; // default 32768
  historyRows?: number; // default 60
  maxTurns?: number; // turns in one wake, default 3
  log?: (msg: string) => void;
  now?: () => string;
  newId?: () => string;
}

export interface TurnResult {
  turns: number;
  replies: string[]; // row ids written
  busy?: boolean;
}

const HISTORY_ROWS = 60;

/** Runs every turn waiting for this agent, one at a time. Safe to call twice: the second sees the lock. */
export async function runAgent(store: Store, agentId: string, opts: TurnOptions): Promise<TurnResult> {
  const log = opts.log ?? (() => {});
  const result: TurnResult = { turns: 0, replies: [] };
  if (!(await store.lock(agentId, 300))) return { ...result, busy: true };
  try {
    for (let i = 0; i < (opts.maxTurns ?? 3); i++) {
      const agent = await store.agent(agentId);
      if (!agent) break;
      const rows = await store.pending(agentId);
      if (!rows.length) break;
      const done = await oneTurn(store, agent, rows, opts, log);
      result.turns++;
      if (done.reply) result.replies.push(done.reply);
      if (!done.handled) break; // the model is away: the rows wait for the next message
    }
  } finally {
    await store.unlock(agentId);
  }
  return result;
}

async function oneTurn(store: Store, agent: NativeAgent, rows: Row[], opts: TurnOptions, log: (m: string) => void): Promise<{ handled: boolean; reply?: string }> {
  const ids = rows.map((r) => r.id);
  const last = ids[ids.length - 1];
  const p = agent.profile;
  await store.markDelivered(ids);

  const budget = await store.takeTurn(agent.userId);
  if (!budget.ok) {
    const reply = await store.reply(agent, outOfTurns(budget.limit), { turn: ids, native: { limit: true } });
    await store.markHandled(ids);
    log(`${p.name}: free turns used up`);
    return { handled: true, reply };
  }

  await store.doing(last, "Thinking");
  const [history, memory, guide, routes] = await Promise.all([
    store.history(agent.id, rows[0].created_at, opts.historyRows ?? HISTORY_ROWS),
    store.memory(agent.userId, agent.id),
    store.guide(),
    store.routes(),
  ]);
  let crew: CrewEntry[] | undefined;
  if (p.maker) crew = (await store.agents(agent.userId)).map((a) => ({ handle: a.profile.handle, name: a.profile.name, role: a.profile.role }));

  const photos = photoPaths(rows);
  const images = (await Promise.all(photos.map((x) => store.signMedia(x)))).filter((u): u is string => !!u);
  // A turn with a picture goes to the model that sees (spec/NATIVE.md section 6).
  const model = images.length ? routes.vision : p.model && p.model !== "default" ? p.model : routes.text;
  const { messages, dropped } = buildTurn({
    guide, agent, memory, crew, history: history.filter((h) => !ids.includes(h.id)), turn: rows, images,
    context: opts.context, reserve: opts.maxTokens ?? 2000,
  });
  if (dropped) log(`${p.name}: ${dropped} older row(s) left out`);

  let answer: Completion;
  try {
    answer = await ask(opts, { model, messages, max_tokens: opts.maxTokens ?? 2000 });
  } catch (e: any) {
    await store.doing(last, null);
    if (e instanceof ModelUnavailable) {
      // Nothing to retry the turn later on a serverless host: say so, keep the rows for the next message.
      await store.reply(agent, `${p.name} can't reach its model right now. Send that again in a minute.`, { bridge: "status" });
      log(`${p.name}: ${e.message}`);
      return { handled: false };
    }
    if (!(e instanceof ModelError)) throw e;
    const reply = await store.reply(agent, `${p.name} couldn't answer that: ${e.message}`, { turn: ids });
    await store.markHandled(ids);
    return { handled: true, reply };
  }

  const { text, memory: memOps, agents: agentOps } = extract(answer.text);
  if (memOps.length) {
    const change = applyMemory(memory, agent.id, memOps, (opts.now ?? (() => new Date().toISOString()))(), opts.newId ?? uuid);
    if (change.put.length || change.drop.length) await store.saveMemory(agent.userId, change.put, change.drop);
  }
  let body = text;
  if (agentOps.length) {
    const results = await applyAgentOps(store, agent, agentOps);
    for (const r of results) log(`${p.name}: ${r.ok ? r.did : r.why}`);
    const failed = results.filter((r) => !r.ok);
    if (failed.length) body += `\n\n(I couldn't do all of that: ${failed.map((f) => (f as { why: string }).why).join("; ")}.)`;
    if (!body.trim()) body = results.filter((r) => r.ok).map((r) => `Done: ${(r as { did: string }).did}.`).join("\n");
  }
  if (!body.trim() && answer.finish === "length") body = `${p.name} ran out of room before it could answer. Try a shorter message.`;

  await store.doing(last, null);
  let reply: string | undefined;
  if (body.trim()) {
    reply = await store.reply(agent, body.trim(), {
      turn: ids,
      native: { model, ...(answer.usage ? { usage: answer.usage } : {}), ...(budget.left <= 10 ? { left: budget.left } : {}) },
    });
  }
  await store.markHandled(ids);
  log(`${p.name}: ${model} answered, ${body.length} chars${memOps.length ? `, ${memOps.length} memory` : ""}${agentOps.length ? `, ${agentOps.length} agent change(s)` : ""}`);
  return { handled: true, reply };
}

/** Streams when it can; one retry when the model is busy. */
async function ask(opts: TurnOptions, req: { model: string; messages: any[]; max_tokens: number }): Promise<Completion> {
  const pv = opts.provider;
  const client = new ChatClient(pv.url, { key: pv.key, headers: pv.headers, fetch: opts.fetch, idle: 120 });
  const body = { ...req, ...(pv.extra ?? {}) } as any;
  try {
    return await client.complete(body, { stream: true });
  } catch (e) {
    if (!(e instanceof ModelUnavailable)) throw e;
    await new Promise((r) => setTimeout(r, Math.min((e.retryAfter ?? 2) * 1000, 8000)));
    return await client.complete(body, { stream: true });
  }
}

export function outOfTurns(limit: number): string {
  const next = new Date();
  next.setUTCMonth(next.getUTCMonth() + 1, 1);
  const when = next.toLocaleDateString("en-US", { month: "long", day: "numeric", timeZone: "UTC" });
  return `That's your ${limit} free turns for this month. They come back on ${when}.\n\`\`\`yui\ncard "Free turns used" body="${limit} a month on Yui. Soon you can add your own model key to keep going."\n\`\`\``;
}

export function uuid(): string {
  return crypto.randomUUID();
}
