// One native turn, the same on a laptop and in the edge function (YUI-130):
// take the person's new rows, build the prompt, ask the model, keep what the
// agent chose to remember, apply its agent changes, check-ins, search and
// hand-offs, write the answer.
// Relay rules as every host (yuigui spec/RELAY.md): delivered when the turn
// starts, `doing` while it works, handled once the answer is written, and the
// answer names its rows in meta.turn.
//
// A turn can also start with no row from the person (a "synthetic" turn): a
// check-in firing (runScheduled) or another agent handing the person over.
// Those answer in the thread and are never marked on any row.
import { ChatClient, ModelError, ModelUnavailable, type Completion } from "./openai.ts";
import { extract } from "./directives.ts";
import { applyMemory } from "./memory.ts";
import { applyAgentOps } from "./agents.ts";
import { buildTurn, photoPaths, type CrewEntry } from "./prompt.ts";
import { next, parseLine, validZone } from "./schedule.ts";
import { Firecrawl, LookupError, searchInvite, sourceCards, type Source } from "./search.ts";
import type { Store } from "./store.ts";
import type { NativeAgent, OwnKey, Row, ScheduleItem } from "./types.ts";

export interface Provider {
  url: string; // an OpenAI-compatible base URL
  key?: string;
  headers?: Record<string, string>;
  extra?: Record<string, unknown>; // sent with every request (OpenRouter's provider rules)
  model?: string; // this provider's own model, when it is not OpenRouter's ids (a person's Groq key)
  reasoning?: number; // tokens the model may think before it answers, on top of the answer's (OpenRouter's reasoning.max_tokens)
}

const OPENROUTER = "https://openrouter.ai/api/v1";
// GLM 5.2 left alone can think through the whole answer budget and say nothing
// (YUI-162): the thinking gets its own 1000 on top, and the answer keeps its 2000.
const REASONING = 1000;

/** OpenRouter, on Yui's key for now (spec/NATIVE.md section 7). */
export function openRouter(key: string): Provider {
  return {
    url: OPENROUTER,
    key,
    headers: { "HTTP-Referer": "https://www.yuigui.com", "X-Title": "Yui" },
    extra: { provider: { data_collection: "deny" } },
    reasoning: REASONING,
  };
}

/** A person's own key: OpenRouter keeps Yui's routes; any other server runs the model they named. */
export function ownProvider(k: OwnKey): Provider {
  if (k.provider === "openrouter") return { ...openRouter(k.key), ...(k.model ? { model: k.model } : {}) };
  return { url: k.baseUrl, key: k.key, ...(k.model ? { model: k.model } : {}) };
}

export interface TurnOptions {
  provider: Provider; // Yui's own; a person's own key replaces it
  search?: SearchOptions; // web lookups (Firecrawl); none: agents answer from what they know
  fetch?: typeof fetch; // the model side only (tests)
  fetchMedia?: typeof fetch; // fetching a person's photo to inline it (tests)
  maxTokens?: number; // default 2000
  context?: number; // default 32768
  historyRows?: number; // default 60
  maxTurns?: number; // turns in one wake, default 3
  log?: (msg: string) => void;
  now?: () => number;
  newId?: () => string;
}

export interface SearchOptions {
  key?: string; // Yui's Firecrawl key; a person's own key (Settings) replaces it and lifts the monthly cap
  fetch?: typeof fetch; // the Firecrawl side (tests)
  base?: string;
}

export interface TurnResult {
  turns: number;
  replies: string[]; // row ids written, in any thread (hand-offs write in another)
  busy?: boolean;
}

const HISTORY_ROWS = 60;
const SYNTHETIC = "synthetic:";

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
      const done = await oneTurn(store, agent, rows, opts, log, result, 0);
      result.turns++;
      if (!done.handled) break; // the model is away: the rows wait for the next message
    }
  } finally {
    await store.unlock(agentId);
  }
  return result;
}

/** A check-in fires: set its next time first, then the agent opens with it. */
export async function runScheduled(store: Store, scheduleId: string, opts: TurnOptions): Promise<TurnResult> {
  const log = opts.log ?? (() => {});
  const result: TurnResult = { turns: 0, replies: [] };
  const s = await store.schedule(scheduleId);
  if (!s || s.paused) return result;
  const agent = await store.agent(s.agentId);
  const now = (opts.now ?? Date.now)();
  // Its number as the agent's list shows it, read before a one-time check-in leaves the list.
  const n = agent ? (await store.schedules(agent.id)).findIndex((x) => x.id === s.id) + 1 || "x" : "x";
  const at = next(s.rule, s.tz, now + 60_000);
  if (at) await store.setScheduleNext(s.id, new Date(at).toISOString());
  else await store.dropSchedule(s.id); // a one-time check-in is done once it fires
  if (!agent) return result;
  await synthetic(store, agent, `[yui] check-in s${n} "${s.note.replace(/"/g, "'")}"`, opts, log, result, 0);
  return result;
}

/** A turn with no row from the person, under the agent's lock (waits a little for it). */
async function synthetic(store: Store, agent: NativeAgent, line: string, opts: TurnOptions, log: (m: string) => void,
                         result: TurnResult, depth: number): Promise<void> {
  let locked = false;
  for (let i = 0; i < 20 && !(locked = await store.lock(agent.id, 300)); i++) await new Promise((r) => setTimeout(r, 1500));
  if (!locked) {
    log(`${agent.profile.name}: busy, skipped "${line.slice(0, 60)}"`);
    return;
  }
  try {
    const row: Row = { id: `${SYNTHETIC}${uuid()}`, sender: "user", kind: "event", body: line, meta: {},
                       created_at: new Date((opts.now ?? Date.now)()).toISOString() };
    await oneTurn(store, agent, [row], opts, log, result, depth);
    result.turns++;
    // The person may have written while this ran: their own wake found the lock taken and left (t_a88dc3b5, a
    // macros ask sent four hand-offs to Basil and his answer to the ask never came). Answer them before letting go.
    for (let i = 0; i < (opts.maxTurns ?? 3); i++) {
      const rows = await store.pending(agent.id);
      if (!rows.length) break;
      const done = await oneTurn(store, agent, rows, opts, log, result, depth);
      result.turns++;
      if (!done.handled) break;
    }
  } finally {
    await store.unlock(agent.id);
  }
}

async function oneTurn(store: Store, agent: NativeAgent, rows: Row[], opts: TurnOptions, log: (m: string) => void,
                       result: TurnResult, depth: number): Promise<{ handled: boolean }> {
  const real = rows.filter((r) => !r.id.startsWith(SYNTHETIC)).map((r) => r.id);
  const last = real[real.length - 1];
  const p = agent.profile;
  const now = (opts.now ?? Date.now)();
  const say = async (body: string, meta: Record<string, unknown>) => {
    const id = await store.reply(agent, body, meta);
    result.replies.push(id);
    return id;
  };
  if (real.length) await store.markDelivered(real);

  // A person's own key: their model, no monthly cap. Otherwise Yui's key and free turns.
  const own = await store.ownKey(agent.userId);
  const provider = own ? ownProvider(own) : opts.provider;
  const budget = own ? { ok: true, left: Infinity, limit: 0 } : await store.takeTurn(agent.userId);
  if (!budget.ok) {
    if (real.length) {
      await say(outOfTurns(budget.limit), { turn: real, native: { limit: true } });
      await store.markHandled(real);
    }
    log(`${p.name}: free turns used up`);
    return { handled: true };
  }

  if (last) await store.doing(last, "Thinking");
  const [history, memory, guide, routes, tzRaw, schedules, mine] = await Promise.all([
    store.history(agent.id, rows[0].created_at, opts.historyRows ?? HISTORY_ROWS),
    store.memory(agent.userId, agent.id),
    store.guide(),
    store.routes(),
    store.timezone(agent.userId),
    store.schedules(agent.id),
    store.agents(agent.userId),
  ]);
  const tz = validZone(tzRaw);
  const crew: CrewEntry[] = mine.map((a) => ({ handle: a.profile.handle, name: a.profile.name, role: a.profile.role }));

  // One photo per turn, the newest (spec/NATIVE.md, limits); the model hears how many it missed.
  const photos = photoPaths(rows);
  const images = (await Promise.all(photos.slice(-1).map((x) => store.signMedia(x)))).filter((u): u is string => !!u);
  // A turn with a picture goes to the model that sees (spec/NATIVE.md section 6).
  const model = provider.model ?? (images.length ? routes.vision : p.model && p.model !== "default" ? p.model : routes.text);
  const { messages } = buildTurn({
    guide, agent, memory, crew, history: history.filter((h) => !real.includes(h.id)), turn: rows, images, photosLeftOut: Math.max(photos.length - 1, 0),
    context: opts.context, reserve: (opts.maxTokens ?? 2000) + (provider.reasoning ?? 0), now, tz: tzRaw ? tz : undefined, schedules,
  });
  const room = opts.maxTokens ?? 2000;
  const req: { model: string; messages: any[]; max_tokens: number; reasoning?: Record<string, unknown> } = provider.reasoning
    ? { model, messages, max_tokens: room + provider.reasoning, reasoning: { max_tokens: provider.reasoning } }
    : { model, messages, max_tokens: room };

  let answer: Completion;
  let looked: Looked = { sources: [] };
  try {
    let sent: typeof req & { messages: any[] } = req;
    try {
      answer = await ask(opts, provider, req);
    } catch (e) {
      // Some providers can't fetch every photo URL (Z.AI's fetcher gets turned away by some hosts):
      // fetch it here and send the bytes instead, once.
      if (!(e instanceof ModelError) || !images.length) throw e;
      const inlined = await inlineImages(messages, opts.fetchMedia ?? fetch);
      if (!inlined) throw e;
      log(`${p.name}: the model couldn't fetch the photo, sending it inline`);
      sent = { ...req, messages: inlined };
      answer = await ask(opts, provider, sent);
    }
    // A search or fetch block alone: look it up, then ask again with what came back.
    if (hasLookup(answer.text)) {
      looked = await lookUp(store, agent, opts, provider, sent, answer, last, log);
      answer = looked.answer!;
    }
    // Thought the budget away and said nothing, or a few words cut off: ask once more without the thinking.
    if (thoughtOut(answer, req.max_tokens)) {
      log(`${p.name}: ${model} thought until it ran out of room, asking again without thinking`);
      answer = await ask(opts, provider, provider.reasoning
        ? { ...sent, messages: looked.messages ?? sent.messages, reasoning: { enabled: false } }
        : { ...sent, messages: [...(looked.messages ?? sent.messages), { role: "user", content: RETRY_NOTE }] });
    } else if (silent(answer.text)) {
      // Nothing the person would see (empty, or only notes to itself): ask once more, keep the notes.
      log(`${p.name}: ${model} answered nothing the person sees, asking again`);
      const again = await ask(opts, provider, { ...sent, messages: [...(looked.messages ?? sent.messages), { role: "user", content: SILENT_NOTE }],
                                                ...(provider.reasoning ? { reasoning: { enabled: false } } : {}) });
      answer = { ...again, text: `${answer.text.trim()}\n${again.text}`.trim() };
    }
  } catch (e: any) {
    if (last) await store.doing(last, null);
    if (e instanceof ModelUnavailable) {
      // Nothing retries the turn later on a serverless host: say so, keep the rows for the next message.
      if (real.length) await store.reply(agent, `${p.name} can't reach its model right now. Send that again in a minute.`, { bridge: "status" });
      log(`${p.name}: ${e.message}`);
      return { handled: false };
    }
    if (!(e instanceof ModelError)) throw e;
    const why = own ? `${e.message} (this is your own ${own.provider} key)` : e.message;
    await say(`${p.name} couldn't answer that: ${why}`, { turn: real });
    if (real.length) await store.markHandled(real);
    return { handled: true };
  }

  const out = extract(answer.text);
  const notes: string[] = [];
  if (out.memory.length) {
    const change = applyMemory(memory, agent.id, out.memory, new Date(now).toISOString(), opts.newId ?? uuid);
    if (change.put.length || change.drop.length) await store.saveMemory(agent.userId, change.put, change.drop);
  }
  if (out.agents.length) {
    const results = await applyAgentOps(store, agent, out.agents);
    for (const r of results) log(`${p.name}: ${r.ok ? r.did : r.why}`);
    for (const r of results) if (!r.ok) notes.push(r.why);
    if (!out.text.trim()) out.text = results.filter((r) => r.ok).map((r) => `Done: ${(r as { did: string }).did}.`).join("\n");
  }
  if (out.schedule.length) notes.push(...await applySchedules(store, agent, out.schedule, schedules, tzRaw ? tz : "UTC", now, log));
  let body = unsprawl(unmark(unend(unbreak(undash(out.text)))));
  if (notes.length) body += `\n\n(I couldn't do all of that: ${notes.join("; ")}.)`;
  // Sources the answer didn't link, and the invite to add a Firecrawl key when the free lookups ran out.
  const cards = [...sourceCards(body, looked.sources), ...(looked.capped ? [searchInvite(looked.capped.why, looked.capped.limit)] : [])];
  if (cards.length && body.trim()) body = `${body.trim()}\n\`\`\`yui\n${cards.join("\n")}\n\`\`\``;
  if (!body.trim() && answer.finish === "length") body = `${p.name} ran out of room before it could answer. Try a shorter message.`;
  // Never close a turn the person started without a word back.
  else if (real.length && silent(answer.text)) body = `${p.name} couldn't put an answer together. Send that again?`;

  if (last) await store.doing(last, null);
  if (body.trim()) {
    await say(body.trim(), {
      ...(real.length ? { turn: real } : {}),
      native: { model, ...(answer.usage ? { usage: answer.usage } : {}), ...(budget.left <= 10 ? { left: budget.left } : {}),
                ...(looked.sources.length ? { sources: looked.sources.slice(0, 8) } : {}), ...(looked.capped ? { search_capped: looked.capped.why } : {}) },
      ...(depth === 0 && !real.length && rows[0]?.body.startsWith("[yui] check-in") ? { checkin: true } : {}),
    });
  }
  if (real.length) await store.markHandled(real);
  log(`${p.name}: ${model} answered, ${body.length} chars`);

  // Hand-offs last, so the person reads this answer first. One level only: a handed-off agent can't hand on.
  if (depth === 0) {
    for (const h of out.handoff.slice(0, 1)) {
      const target = mine.find((a) => a.profile.handle === h.target);
      if (!target || target.id === agent.id) {
        log(`${p.name}: no agent @${h.target} to hand off to`);
        continue;
      }
      await synthetic(store, target, `[yui] handoff from=${p.handle} note="${h.note.replace(/"/g, "'")}"`, opts, log, result, 1);
    }
  }
  return { handled: true };
}

async function applySchedules(store: Store, agent: NativeAgent, lines: string[], current: ScheduleItem[], tz: string, now: number,
                              log: (m: string) => void): Promise<string[]> {
  const problems: string[] = [];
  for (const line of lines.slice(0, 5)) {
    const parsed = parseLine(line, tz, now);
    if (!parsed) {
      problems.push(`I couldn't read the check-in "${line.slice(0, 60)}"`);
      continue;
    }
    if ("cancel" in parsed) {
      const hit = current[Number(parsed.cancel.slice(1)) - 1];
      if (hit) await store.dropSchedule(hit.id);
      continue;
    }
    const at = next(parsed.rule, tz, now);
    if (!at) {
      problems.push(`that check-in time has passed`);
      continue;
    }
    const id = await store.addSchedule({ userId: agent.userId, agentId: agent.id, note: parsed.note.slice(0, 300), rule: parsed.rule, tz,
                                         nextAt: new Date(at).toISOString() });
    if (!id) problems.push("you're at the most check-ins for now");
    else log(`${agent.profile.name}: check-in set for ${new Date(at).toISOString()}`);
  }
  return problems;
}

/**
 * Cut off at the limit with nothing to say, or with most of the budget spent
 * thinking (GLM takes reasoning.max_tokens as a hint: one run thought 2958 of
 * 3000 and left half a sentence). A long answer that simply ran long is kept.
 */
export function thoughtOut(a: Completion, maxTokens: number): boolean {
  if (a.finish !== "length") return false;
  if (!a.text.trim()) return true;
  const thought = (a.usage as any)?.completion_tokens_details?.reasoning_tokens ?? Math.round(a.reasoning.length / 4);
  return thought > maxTokens / 2;
}

const RETRY_NOTE = "[yui] Your last try ran out of room while thinking. Answer the person now, shorter, with little thinking.";
const SILENT_NOTE = "[yui] Your last try had nothing the person can see. Answer them now: a line of words and a screen.";

/** An answer with no words or screen for the person and no agent change or handoff. Called after the lookups ran,
 *  so a search or fetch block still in it answers nothing. */
export function silent(text: string): boolean {
  const e = extract(text);
  return !e.text.trim() && !e.agents.length && !e.handoff.length;
}

interface Looked {
  answer?: Completion;
  messages?: any[]; // the conversation the last answer came from, lookups and all
  sources: Source[];
  capped?: { why: "month" | "day"; limit: number }; // Yui's free lookups ran out this turn
}

function hasLookup(text: string): boolean {
  const x = extract(text);
  return !!(x.search || x.fetch);
}

/**
 * Runs the agent's lookups one at a time, each answered with a new model call,
 * until it answers the person or hits the turn's cap (yui_limits
 * native_searches_per_turn). On Yui's key each lookup comes out of the free
 * month and day; the person's own Firecrawl key only counts them.
 */
async function lookUp(store: Store, agent: NativeAgent, opts: TurnOptions, provider: Provider, req: { messages: any[] } & Record<string, unknown>,
                      first: Completion, last: string | undefined, log: (m: string) => void): Promise<Looked> {
  const p = agent.profile;
  const theirs = await store.searchKey(agent.userId);
  const key = theirs ?? opts.search?.key;
  const fc = key ? new Firecrawl(key, opts.search?.fetch ?? fetch, opts.search?.base) : null;
  const out: Looked = { sources: [] };
  let messages = req.messages;
  let answer = first;
  let perTurn = 1;
  for (let n = 0; ; n++) {
    const x = extract(answer.text);
    const look = x.search ? { kind: "search" as const, q: x.search } : x.fetch ? { kind: "fetch" as const, q: x.fetch } : null;
    if (!look) break;
    let note: string;
    if (n >= perTurn || n >= 4) {
      note = "[yui] That's all the lookups for this turn. Answer the person now with what you have, with no search or fetch block.";
    } else if (!fc) {
      note = "[yui] Search isn't available right now. Answer from what you know, and say briefly that you couldn't look it up.";
    } else {
      const take = await store.takeSearch(agent.userId, !!theirs);
      perTurn = Math.max(1, take.perTurn);
      if (!take.ok) {
        out.capped = { why: take.why ?? "month", limit: take.limit };
        note = `[yui] The free web searches are used up ${take.why === "day" ? "for today" : "for this month"}. Answer from what you know, say in one line that you couldn't look it up, and don't write a search block again this turn.`;
        log(`${p.name}: ${look.kind} "${look.q}" (free lookups used up, ${take.why})`);
      } else {
        if (last) await store.doing(last, look.kind === "search" ? `Looking up ${look.q.slice(0, 40)}` : `Reading ${hostName(look.q)}`);
        try {
          const found = look.kind === "search" ? await fc.search(look.q) : await fc.fetchPage(look.q);
          out.sources.push(...found.sources);
          note = `[yui] ${look.kind === "search" ? `Web results for "${look.q}"` : "The page"}:\n\n${found.text}\n\n`
            + "[yui] Answer the person now from these, and name where it came from. If one page is worth reading in full, "
            + "you may write a fetch block with its link instead.";
          log(`${p.name}: ${look.kind} "${look.q.slice(0, 80)}", ${found.sources.length} source(s), ${take.used}/${take.limit} this month${theirs ? " (their key)" : ""}`);
        } catch (e) {
          if (!(e instanceof LookupError)) throw e;
          const whose = theirs && (e.status === 401 || e.status === 402) ? " (it's their own Firecrawl key, in Settings)" : "";
          note = `[yui] The lookup didn't work: ${e.message}${whose}. Answer from what you know and say so in one line.`;
          log(`${p.name}: ${look.kind} failed: ${e.message}`);
        }
      }
    }
    messages = [...messages, { role: "assistant", content: answer.text }, { role: "user", content: note }];
    answer = await ask(opts, provider, { ...req, messages });
    if (n >= perTurn || out.capped || !fc) {
      // Asked to answer without looking again: whatever block it still wrote is dropped by extract().
      break;
    }
  }
  out.answer = answer;
  out.messages = messages;
  return out;
}

function hostName(u: string): string {
  try {
    return new URL(u).hostname.replace(/^www\./, "");
  } catch {
    return "a page";
  }
}

// The house voice has no em or en dashes (YUI-163). The prompt says so; models
// still write them, so the answer is swept once more before it is written.
const OPENERS = new Set(["i", "i'm", "i'll", "you", "you're", "you'll", "we", "we'll", "let's", "they", "he", "she", "it", "it's",
  "that", "that's", "this", "here", "here's", "there", "there's", "tap", "try", "pick", "send", "tell", "say", "ask", "give",
  "just", "open", "start", "go"]);

/** One piece of prose without dashes: a spaced one becomes a comma, or a period when a new sentence follows. */
function undashProse(t: string): string {
  return t
    .replace(/(\d)\s?[\u2013\u2014]\s?(\d)/g, "$1-$2") // 3–5, 9:00—10:00
    .replace(/^([ \t]*)[\u2013\u2014][ \t]+/gm, "$1- ") // a dash used as a bullet
    .replace(/[ \t]*[\u2013\u2014]+[ \t]*(?=\n|$)/g, ".") // a dash that ends a line
    .replace(/[ \t]*[\u2013\u2014]+[ \t]*(\S+)/g, (_m, word: string, at: number, all: string) => {
      const before = all.slice(0, at).trimEnd();
      if (/[.!?:,;]$/.test(before) || !before) return ` ${word}`;
      const bare = word.replace(/^["'(\u201c\u2018]+/, "").replace(/[^A-Za-z']+$/, "").toLowerCase();
      if (OPENERS.has(bare)) return `. ${word.replace(/[A-Za-z]/, (c) => c.toUpperCase())}`;
      return `, ${word}`;
    })
    .replace(/[\u2013\u2014]/g, ", ");
}

/**
 * The answer without em or en dashes, where the person reads them: the chat text
 * and the quoted strings in a yui block. Everything else in a fence (tokens,
 * links, code) is left as the model wrote it.
 */
export function undash(text: string): string {
  if (!/[\u2013\u2014]/.test(text)) return text;
  const parts = text.split(/(^```[^\n]*\n[\s\S]*?^```[ \t]*$)/m);
  return parts.map((part, i) => {
    if (i % 2 === 0) return undashProse(part);
    if (!/^```yui\b/.test(part)) return part;
    return part.replace(/"((?:[^"\\\n]|\\.)*)"/g, (_m, inner: string) => `"${undashProse(inner)}"`);
  }).join("");
}

// Models write \n inside a quoted YL string to break a line (YUI-161). In YL a
// backslash escapes the next character, so the person would read "nn". The
// answer is swept once more: a `say` becomes one line per break, a run of
// bullets a `list`, and a break in any other quoted string a space.
const QUOTED = /"((?:[^"\\\n]|\\.)*)"/g;
const BULLET = /^\s*(?:[•·*-]|\d{1,2}[.)])\s+/;

/** A quoted string's inside, cut at each \n (\r dropped, \t a space). Other escapes stay as written. */
function breaks(inner: string): string[] {
  const out = [""];
  for (let i = 0; i < inner.length; i++) {
    if (inner[i] !== "\\" || i + 1 >= inner.length) {
      out[out.length - 1] += inner[i];
      continue;
    }
    const next = inner[++i];
    if (next === "n") out.push("");
    else if (next === "t") out[out.length - 1] += " ";
    else if (next !== "r") out[out.length - 1] += `\\${next}`;
  }
  return out;
}

/** One `say` line whose text breaks, as the lines it meant: a `say` per line, a `list` per run of bullets. */
function sayLines(route: string, id: string, segs: string[]): string[] {
  const lines: string[] = [];
  let run: string[] = [];
  let numbered = true;
  const flush = () => {
    if (run.length) lines.push(`${route}list ${run.map((s) => `"${s}"`).join(" ")}${numbered ? " +num" : ""}`);
    run = [];
    numbered = true;
  };
  for (const s of segs.map((x) => x.trim())) {
    if (!s) {
      flush();
      continue;
    }
    if (BULLET.test(s)) {
      numbered &&= /^\s*\d/.test(s);
      run.push(s.replace(BULLET, ""));
      continue;
    }
    flush();
    lines.push(`${route}say${lines.length ? "" : id} "${s}"`);
  }
  flush();
  return lines.length ? lines : [`${route}say${id} ""`];
}

/** One line of a yui block with no \n left in its quoted strings. */
function breakLine(line: string): string[] {
  if (!line.includes("\\")) return [line];
  const say = line.match(/^(\s*(?:>[\w-]+\s+)?)say(@[\w-]+)?\s+(.*?)\s*$/);
  if (say) {
    const [, route, id = "", rest] = say;
    const whole = rest.match(/^"((?:[^"\\]|\\.)*)"$/);
    // Outside quotes a backslash is literal, so an unquoted say is cut at the two characters \n.
    const segs = whole ? breaks(whole[1])
      : rest.includes('"') ? null
      : rest.replace(/\\r/g, "").split("\\n").map((s) => s.replace(/\\/g, "\\\\"));
    if (segs && segs.length > 1) return sayLines(route, id, segs);
  }
  return [line.replace(QUOTED, (m, inner: string) => {
    const segs = breaks(inner);
    if (segs.length < 2) return m;
    const text = segs.map((s) => s.replace(BULLET, "").trim()).filter(Boolean)
      .reduce((all, s) => (!all ? s : /[.!?:;,]$/.test(all) ? `${all} ${s}` : `${all}. ${s}`), "");
    return `"${text}"`;
  })];
}

/** The answer with every \n inside a yui block's quoted strings turned into real lines. */
export function unbreak(text: string): string {
  if (!text.includes("\\")) return text;
  const parts = text.split(/(^```[^\n]*\n[\s\S]*?^```[ \t]*$)/m);
  return parts.map((part, i) => {
    if (i % 2 === 0 || !/^```yui\b/.test(part)) return part;
    return part.split("\n").flatMap(breakLine).join("\n");
  }).join("");
}

// The presets that open a group an `end` closes (yuilines GROUPS) and `flow`.
const GROUPS = /^(?:plan|deck|narrate|timeline|sketch|shapes|map|flow)(?:@[A-Za-z0-9_-]+)?(?:\s|$)/;

/** Two slips in a yui block, mended: a line that starts with a quote or a `+flag` (options wrapped onto their own
 *  line; no YL line can start with either) joins the line above, and a block that opens no group loses its `end` lines. */
export function unend(text: string): string {
  const parts = text.split(/(^```[^\n]*\n[\s\S]*?^```[ \t]*$)/m);
  return parts.map((part, i) => {
    if (i % 2 === 0 || !/^```yui\b/.test(part)) return part;
    const lines: string[] = [];
    for (const l of part.split("\n")) {
      const t = l.trim();
      if (/^(?:"|\+[a-z])/.test(t) && lines.length > 1 && lines[lines.length - 1].trim()) lines[lines.length - 1] += " " + t;
      else lines.push(l);
    }
    if (lines.some((l) => GROUPS.test(l.trim()))) return lines.join("\n");
    return lines.filter((l) => l.trim() !== "end").join("\n");
  }).join("");
}

// The phone shows markdown as it is written (t_a88dc3b5, TestFlight build 244: Basil's "what can you do" came back
// as raw **bold** bullets the stage cut into 7 pages). The prompt says no markdown; what a model still writes is
// swept here: chat text with bullets, headings or bold becomes Yui Lines (a `say` per paragraph or heading, a
// `list` per run of bullets) at the top of the answer's yui block, and bold left in a quoted string loses its stars.
const MD_BULLET = /^[ \t]*(?:[-*•+]|\d{1,2}[.)])[ \t]+(?=\S)/;
const MD_HEADING = /^[ \t]{0,3}#{1,6}[ \t]+(?=\S)/;
const MD_BOLD = /\*\*(?=\S)([^*\n]+?)\*\*|__(?=\S)([^_\n]+?)__/;

function plainInline(t: string): string {
  return t
    .replace(/\*\*(?=\S)([^*\n]+?)\*\*/g, "$1").replace(/__(?=\S)([^_\n]+?)__/g, "$1")
    .replace(/(^|[\s(])\*(?=\S)([^*\n]+?)\*(?=[\s).,!?:;]|$)/g, "$1$2")
    .replace(/`([^`\n]+)`/g, "$1")
    .replace(/\[([^\]\n]+)\]\((https?:[^)\s]+)\)/g, "$1 ($2)")
    .replace(/\*\*/g, "")
    .replace(/\s+/g, " ").trim();
}

const quote = (t: string) => `"${t.replace(/\\/g, "\\\\").replace(/"/g, "'")}"`;

/** Prose with markdown in it, as Yui Lines; null when it has none. */
function markdownLines(prose: string): string[] | null {
  const lines = prose.split("\n");
  const bullets = lines.filter((l) => MD_BULLET.test(l));
  // One numbered line ("1) Stretch first.") reads fine as prose; a real list has two or more, or a dash or a star.
  const listy = bullets.length >= 2 || bullets.some((l) => /^[ \t]*[-*•+][ \t]/.test(l));
  if (!listy && !lines.some((l) => MD_HEADING.test(l)) && !MD_BOLD.test(prose)) return null;
  const out: string[] = [];
  let para: string[] = [];
  let run: string[] = [];
  let numbered = true;
  const flushPara = () => {
    const t = plainInline(para.join(" "));
    if (t) out.push(`say ${quote(t)}`);
    para = [];
  };
  const flushRun = () => {
    if (run.length) out.push(`list ${run.map(quote).join(" ")}${numbered ? " +num" : ""}`);
    run = [];
    numbered = true;
  };
  for (const l of lines) {
    if (!l.trim()) {
      flushPara();
      flushRun();
    } else if (MD_HEADING.test(l)) {
      flushPara();
      flushRun();
      out.push(`say ${quote(plainInline(l.replace(MD_HEADING, "")))}`);
    } else if (listy && MD_BULLET.test(l)) {
      flushPara();
      numbered &&= /^[ \t]*\d/.test(l);
      const item = plainInline(l.replace(MD_BULLET, ""));
      if (item) run.push(item);
    } else if (run.length && /^[ \t]+\S/.test(l)) {
      run[run.length - 1] = plainInline(`${run[run.length - 1]} ${l}`); // a bullet wrapped onto the next line
    } else {
      flushRun();
      para.push(l);
    }
  }
  flushPara();
  flushRun();
  return out;
}

/** The answer with no markdown where the person reads it (see above). Code fences other than yui are left alone. */
export function unmark(text: string): string {
  const parts = text.split(/(^```[^\n]*\n[\s\S]*?^```[ \t]*$)/m);
  const isYui = (i: number) => i % 2 === 1 && /^```yui\b/.test(parts[i]);
  // Bold inside a yui block's quoted strings loses its stars; a heading's hashes go too.
  for (let i = 1; i < parts.length; i += 2) {
    if (!isYui(i)) continue;
    parts[i] = parts[i].replace(QUOTED, (m, inner: string) =>
      MD_BOLD.test(inner) || /^#{1,6} /.test(inner) ? `"${inner.replace(/^#{1,6} +/, "").replace(/\*\*|__/g, "")}"` : m);
  }
  const into = (i: number, lines: string[], atTop: boolean) => {
    const head = parts[i].match(/^```[^\n]*\n/)![0];
    const rest = parts[i].slice(head.length);
    parts[i] = atTop ? `${head}${lines.join("\n")}\n${rest}` : parts[i].replace(/\n?```[ \t]*$/, `\n${lines.join("\n")}\n\`\`\``);
  };
  for (let i = 0; i < parts.length; i += 2) {
    const lines = markdownLines(parts[i]);
    if (!lines) continue;
    const lead = parts[i].match(/^\s*/)![0].includes("\n") ? "\n" : "";
    const tail = /\n\s*$/.test(parts[i]) ? "\n" : "";
    if (!lines.length) continue;
    if (isYui(i + 1)) {
      into(i + 1, lines, true);
      parts[i] = lead;
    } else if (isYui(i - 1)) {
      into(i - 1, lines, false);
      parts[i] = tail;
    } else {
      parts[i] = `${lead}\`\`\`yui\n${lines.join("\n")}\n\`\`\`${tail}`;
    }
  }
  return parts.join("");
}

// The stage plays an answer as pages: a paragraph of chat text, a `say` or a deck `page` is one each (the app's
// StageChunks). Past MOST_PAGES, short neighbours are merged so a small answer is never a long swipe.
const MOST_PAGES = 4;
const SHORT_WORDS = 40;
const wordsIn = (t: string) => t.split(/\s+/).filter(Boolean).length;
const SAY = /^say\s+"((?:[^"\\]|\\.)*)"\s*$/;
const PAGE = /^page\s+"((?:[^"\\]|\\.)*)"(?:\s+body="((?:[^"\\]|\\.)*)")?\s*$/;

/** Merges neighbours in `items` (`pair` returns the merge, or null for a pair that can't share a page) while `over()`. */
function squeeze<T>(items: T[], over: () => boolean, pair: (a: T, b: T) => T | null): void {
  for (let i = 0; over() && i < items.length - 1;) {
    const m = pair(items[i], items[i + 1]);
    if (m === null) i++;
    else items.splice(i, 2, m);
  }
}

const withStop = (t: string) => (/[.!?:]$/.test(t) ? t : `${t}.`);

function mergeLines(a: string, b: string): string | null {
  const sa = a.trim().match(SAY), sb = b.trim().match(SAY);
  if (sa && sb && wordsIn(sa[1]) + wordsIn(sb[1]) <= SHORT_WORDS) return `say "${withStop(sa[1])} ${sb[1]}"`;
  const pa = a.trim().match(PAGE), pb = b.trim().match(PAGE);
  if (pa && pb && wordsIn(`${pa[2] ?? ""} ${pb[1]} ${pb[2] ?? ""}`) <= SHORT_WORDS) {
    return `page "${pa[1]}" body="${[pa[2] && withStop(pa[2]), withStop(pb[1]), pb[2]].filter(Boolean).join(" ")}"`;
  }
  return null;
}

// The stage plays every loose `stat` tile as a page of its own (Chris, t_afb1bf90: "a full breakdown of the calories
// and macros, I don't need eight screens for that"). Three or more tiles in a row become one table, one page.
const STAT = /^stat(?:@([\w-]+))?\s+("(?:[^"\\]|\\.)*"|\S+)\s+("(?:[^"\\]|\\.)*"|[^\s=+]+(?:\s+[^\s=+"]+)*?)(?=\s+[\w]+=|\s+\+|\s*$)(.*)$/;
const bare = (t: string) => t.replace(/^"|"$/g, "").replace(/\|/g, "/");

function tilesToTable(lines: string[]): string[] {
  const out: string[] = [];
  for (let i = 0; i < lines.length;) {
    let j = i;
    while (j < lines.length && STAT.test(lines[j].trim())) j++;
    if (j - i < 3) {
      out.push(...lines.slice(i, Math.max(j, i + 1)));
      i = Math.max(j, i + 1);
      continue;
    }
    const rows = lines.slice(i, j).map((l) => {
      const [, , value, label, rest] = l.trim().match(STAT)!;
      const sub = rest.match(/\bsub="((?:[^"\\]|\\.)*)"/)?.[1];
      return `"${bare(label)}|${bare(value)}${sub ? ` (${bare(sub)})` : ""}"`;
    });
    const id = lines[i].trim().match(STAT)![1];
    const title = rows.some((r) => /protein|carb|fat|calorie|kcal/i.test(r)) ? "Macros" : "Numbers";
    out.push(`table${id ? `@${id}` : ""} ${title} Item|Amount ${rows.join(" ")}`);
    i = j;
  }
  return out;
}

// A table's title is a bare word; a quoted one (`table "Two eggs, toast" Item|Kcal ...`) reads as the header, and the
// real header becomes a row. It moves to name=, which the phone shows as the title.
const QUOTED_TITLE = /^(\s*(?:>[\w-]+\s+)?table(?:@[\w-]+)?)\s+"((?:[^"\\]|\\.)*)"(?=\s+[^\s"=]*\|)/;

// A row written `"Eggs (2 large)"|140|12g` (the quote closed before the pipes) draws as its first cell alone on the
// phone: it is rejoined into one quoted row, `"Eggs (2 large)|140|12g"`.
const SPLIT_ROW = /"((?:[^"\\|]|\\.)*)"((?:\|(?:"(?:[^"\\]|\\.)*"|[^\s|"]+))+)/g;

function tableLine(l: string): string {
  if (!/^\s*(?:>[\w-]+\s+)?table(?:@[\w-]+)?\s/.test(l) || /^\s*(?:>[\w-]+\s+)?table\s+create\b/.test(l)) return l;
  return l.replace(QUOTED_TITLE, '$1 name="$2"')
    .replace(SPLIT_ROW, (_m, first: string, rest: string) => `"${first}${rest.replace(/"/g, "")}"`);
}

/** The answer on at most MOST_PAGES stage pages where short ones can share a page. */
export function unsprawl(text: string): string {
  text = text.split(/(^```[^\n]*\n[\s\S]*?^```[ \t]*$)/m)
    .map((p, i) => (i % 2 === 1 && /^```yui\b/.test(p)
      ? tilesToTable(p.split("\n")).map(tableLine).join("\n") : p)).join("");
  const parts = text.split(/(^```[^\n]*\n[\s\S]*?^```[ \t]*$)/m);
  const isYui = (i: number) => i % 2 === 1 && /^```yui\b/.test(parts[i]);
  const paras = (p: string) => p.split(/\n\s*\n/).filter((x) => x.trim());
  const count = (p: string, i: number) =>
    i % 2 === 0 ? paras(p).length : isYui(i) ? p.split("\n").filter((l) => SAY.test(l.trim()) || PAGE.test(l.trim())).length : 0;
  const total = () => parts.reduce((n, p, i) => n + count(p, i), 0);
  if (total() <= MOST_PAGES) return text;
  // Chat paragraphs first, then says and deck pages.
  for (let i = 0; i < parts.length; i++) {
    if (total() <= MOST_PAGES) break;
    if (i % 2 === 0) {
      const ps = paras(parts[i]).map((x) => x.trim());
      if (ps.length < 2) continue;
      const rest = total() - ps.length;
      squeeze(ps, () => rest + ps.length > MOST_PAGES, (a, b) => (wordsIn(a) + wordsIn(b) <= SHORT_WORDS ? `${a} ${b}` : null));
      parts[i] = `${parts[i].match(/^\s*/)![0]}${ps.join("\n\n")}${parts[i].match(/\s*$/)![0]}`;
    } else if (isYui(i)) {
      const lines = parts[i].split("\n");
      const rest = total() - count(parts[i], i);
      squeeze(lines, () => rest + count(lines.join("\n"), i) > MOST_PAGES, mergeLines);
      parts[i] = lines.join("\n");
    }
  }
  return parts.join("");
}

/** Streams when it can; one retry when the model is busy. */
const INLINE_MAX = 8 * 1024 * 1024;

/** The same messages with every photo URL swapped for its bytes (data: URL), or null when none could be fetched. */
export async function inlineImages(messages: any[], fetchImpl: typeof fetch): Promise<any[] | null> {
  let swapped = 0;
  const out = await Promise.all(messages.map(async (m) => {
    if (!Array.isArray(m.content)) return m;
    const content = await Promise.all(m.content.map(async (part: any) => {
      const url = part?.type === "image_url" ? part.image_url?.url : null;
      if (!url || url.startsWith("data:")) return part;
      try {
        const r = await fetchImpl(url);
        const type = (r.headers.get("content-type") ?? "").split(";")[0].trim();
        if (!r.ok || !type.startsWith("image/")) return part;
        const bytes = new Uint8Array(await r.arrayBuffer());
        if (bytes.length > INLINE_MAX) return part;
        let bin = "";
        for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
        swapped++;
        return { type: "image_url", image_url: { url: `data:${type};base64,${btoa(bin)}` } };
      } catch {
        return part;
      }
    }));
    return { ...m, content };
  }));
  return swapped ? out : null;
}

async function ask(opts: TurnOptions, pv: Provider, req: Record<string, unknown>): Promise<Completion> {
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
  return `That's your ${limit} free turns for this month. They come back on ${when}, or add your own model key in Settings to keep going now.\n\`\`\`yui\ncard "Free turns used" body="${limit} a month on Yui. Your own OpenRouter, TrustedRouter or Groq key has no limit."\n\`\`\``;
}

export function uuid(): string {
  return crypto.randomUUID();
}
