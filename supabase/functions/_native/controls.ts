// Copied from runtime/src/controls.ts by runtime/scripts/build.mjs. Do not edit here.
// The drawer's Controls tab for native agents (YUI-140 in the app, spec
// yuigui spec/CONTROLS.md): the same control rows the Hermes plugin answers
// (hermes-plugin/yui/controls.py), served from the person's native Yui.
// Personality (the soul), Memory (the about-you card and the agent's notes),
// Schedules (check-ins), Tables (YUI-170: the agent's own tables with their
// row counts, read and delete) and Model (read only). No turn, no model call.
import { MODELS } from "./models.ts";
import type { Store } from "./store.ts";
import { isStop, stopTurns } from "./stop.ts";
import { describe, next, parseLine } from "./schedule.ts";
import type { MemoryItem, NativeAgent, ScheduleItem } from "./types.ts";
import { asText, diff, write } from "./tables.ts";

export const V = 1;
export const SECTIONS: Record<string, string> = { soul: "rw", memory: "rwd", schedules: "rwd", tables: "rd", model: "r" };
/** What provisioning writes to yui_agents.controls, so the app shows the tab. */
export const REPORT = { v: V, sections: SECTIONS };
const OPS = ["list", "get", "put", "act", "delete"];
const VERBS: Record<string, string[]> = { schedules: ["pause", "resume", "run"] };
const SOUL = "SOUL.md";
const MAX_TEXT = 32 * 1024;

const MESSAGES: Record<string, string> = {
  version: "Update Yui to change this agent's settings.",
  not_owner: "Only the owner can change this agent's settings.",
  bad_op: "Yui doesn't know that request.",
  bad_section: "Yui doesn't know that section.",
  not_allowed: "That can't be changed here.",
  bad_id: "That isn't something Yui listed.",
  not_found: "It's gone. Pull to refresh.",
  conflict: "Changed since you opened it.",
  confirm: "Deleting needs a confirm.",
  bad_verb: "Yui doesn't know that action.",
  too_big: "That's over 32 KB.",
  empty: "An agent needs a personality. It can't be empty.",
  bad_schedule: "That time doesn't parse. Try \"every mon,wed 07:00\".",
  keep_soul: "An agent always has a personality. Edit it instead.",
  failed: "Yui couldn't do that.",
};

class Refused extends Error {
  error: string;
  extra: Record<string, unknown>;
  constructor(error: string, extra: Record<string, unknown> = {}, message?: string) {
    super(message ?? MESSAGES[error] ?? error);
    this.error = error;
    this.extra = extra;
  }
}

export async function rev(value: unknown): Promise<string> {
  const raw = typeof value === "string" ? value : JSON.stringify(value);
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(raw));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 12);
}

const firstLine = (s: string) => (s.split("\n").find((l) => l.trim()) ?? "").replace(/^#+\s*/, "").trim().slice(0, 80);
const textOf = (req: any): string => (typeof req?.value?.text === "string" ? req.value.text : "");

export interface ControlContext {
  store: Store;
  agent: NativeAgent;
  owner: boolean;
  provider: string; // "OpenRouter, on Yui" or "your own Groq key"
  searchKey?: boolean; // they added their own Firecrawl key
}

/** One answer for one request: {v, req, ok, ...}. Never throws. */
export async function handleControl(req: any, ctx: ControlContext): Promise<Record<string, unknown>> {
  const base: Record<string, unknown> = { v: V, req: String(req?.req ?? "").slice(0, 40) };
  try {
    if (req?.v !== V) throw new Refused("version");
    if (!ctx.owner) throw new Refused("not_owner");
    const { op, section } = req;
    if (!OPS.includes(op)) throw new Refused("bad_op");
    if (!(section in SECTIONS)) throw new Refused("bad_section");
    const need = ({ list: "r", get: "r", put: "w", act: "w", delete: "d" } as Record<string, string>)[op];
    if (!SECTIONS[section].includes(need)) throw new Refused(section === "soul" && op === "delete" ? "keep_soul" : "not_allowed");
    base.section = section;
    const s = sections[section];
    if (op === "list") return { ...base, ok: true, items: await s.list(ctx) };
    const id = req.id;
    if (typeof id !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/.test(id)) throw new Refused("bad_id");
    base.id = id;
    if (op === "get") {
      const [r, item] = await s.get(ctx, id);
      return { ...base, ok: true, rev: r, item };
    }
    if (op === "act") {
      if (!(VERBS[section] ?? []).includes(req.verb)) throw new Refused("bad_verb");
      const [r, item] = await s.act!(ctx, id, req.verb);
      return { ...base, ok: true, rev: r, item };
    }
    if (op === "delete" && req.confirmed !== true) throw new Refused("confirm");
    const [cur, curItem] = await s.get(ctx, id);
    if (req.rev !== cur) throw new Refused("conflict", { rev: cur, item: curItem });
    if (op === "delete") {
      await s.delete!(ctx, id);
      return { ...base, ok: true, deleted: true, rev: null, item: null };
    }
    const [r, item] = await s.put!(ctx, id, req);
    return { ...base, ok: true, rev: r, item };
  } catch (e: any) {
    if (e instanceof Refused) return { ...base, ok: false, error: e.error, message: e.message, ...e.extra };
    return { ...base, ok: false, error: "failed", message: MESSAGES.failed, detail: String(e?.name ?? "Error") };
  }
}

/** A control row from the person, answered in place. False when the row is not a control. */
export async function answerControl(store: Store, rowId: string): Promise<boolean> {
  const row = await store.row(rowId);
  if (!row || row.kind !== "control" || row.sender !== "user") return false;
  const agent = await store.agent(row.agent_id);
  if (!agent) return true;
  // Stop (YUI-190): the running turn sees it at its next write; the rest is dropped here.
  if (isStop(row)) {
    await stopTurns(store, agent, row);
    return true;
  }
  const own = await store.ownKey(agent.userId);
  const provider = own ? `your own ${({ openrouter: "OpenRouter", trustedrouter: "TrustedRouter", groq: "Groq", custom: "model server" } as Record<string, string>)[own.provider]} key`
    : "OpenRouter, on Yui";
  const req = row.meta ?? {};
  const searchKey = !!(await store.searchKey(agent.userId));
  const ans = await handleControl(req, { store, agent, owner: row.user_id === agent.userId, provider, searchKey });
  await store.controlAnswer(agent, row.id, bodyOf(req, ans), ans);
  return true;
}

/** The plain line a control row carries for anyone reading the table. No values. */
export function bodyOf(req: any, ans: Record<string, unknown>): string {
  const what = `${req?.op ?? "?"} ${ans.section ?? "?"}` + (ans.id ? ` ${ans.id}` : "");
  return `controls: ${what}` + (ans.ok ? "" : ` (${ans.error})`);
}

interface Section {
  list(ctx: ControlContext): Promise<unknown[]>;
  get(ctx: ControlContext, id: string): Promise<[string, Record<string, unknown>]>;
  put?(ctx: ControlContext, id: string, req: any): Promise<[string, Record<string, unknown>]>;
  act?(ctx: ControlContext, id: string, verb: string): Promise<[string, Record<string, unknown>]>;
  delete?(ctx: ControlContext, id: string): Promise<void>;
}

// -- soul ------------------------------------------------------------------------------

const soul: Section = {
  async list({ agent }) {
    return [{ id: SOUL, title: firstLine(agent.profile.soul) || "Personality", rev: await rev(agent.profile.soul) }];
  },
  async get({ agent }, id) {
    if (id !== SOUL) throw new Refused("bad_id");
    const text = agent.profile.soul;
    const outline = text.split("\n").filter((l) => /^#{1,3}\s+\S/.test(l)).map((l) => l.replace(/^#+\s*/, "").trim()).slice(0, 20);
    return [await rev(text), { id: SOUL, text, outline, read_only: false }];
  },
  async put(ctx, id, req) {
    const text = textOf(req);
    if (!text.trim()) throw new Refused("empty");
    if (text.length > MAX_TEXT) throw new Refused("too_big");
    ctx.agent.profile = { ...ctx.agent.profile, soul: text.trim(), soulEdited: true }; // theirs now: the shelf's never replaces it
    await ctx.store.updateAgent(ctx.agent.id, ctx.agent.profile);
    return soul.get(ctx, id);
  },
};

// -- memory ------------------------------------------------------------------------------

function memTitle(m: MemoryItem) {
  return m.kind === "about" ? `${m.key}: ${m.body}` : m.body;
}

async function memoryItems({ store, agent }: ControlContext): Promise<MemoryItem[]> {
  return (await store.memory(agent.userId, agent.id)).slice().sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
}

async function findMemory(ctx: ControlContext, id: string): Promise<MemoryItem> {
  const hit = (await memoryItems(ctx)).find((m) => m.id === id);
  if (!hit) throw new Refused("not_found");
  return hit;
}

const memory: Section = {
  async list(ctx) {
    const out = [];
    for (const m of await memoryItems(ctx)) {
      out.push({ id: m.id, group: m.kind === "about" ? "you" : "remembers", title: firstLine(memTitle(m)), rev: await rev(m.body) });
    }
    return out;
  },
  async get(ctx, id) {
    const m = await findMemory(ctx, id);
    return [await rev(m.body), { id, group: m.kind === "about" ? "you" : "remembers", text: m.body, read_only: false,
                                 ...(m.key ? { title: m.key } : {}), updated: m.updatedAt }];
  },
  async put(ctx, id, req) {
    const m = await findMemory(ctx, id);
    const text = textOf(req).replace(/\s+/g, " ").trim();
    if (!text) throw new Refused("bad_op", {}, "Use Forget to remove a memory.");
    if (text.length > 300) throw new Refused("too_big", {}, "Keep a memory under 300 characters.");
    await ctx.store.saveMemory(ctx.agent.userId, [{ ...m, body: text, updatedAt: new Date().toISOString() }], []);
    return memory.get(ctx, id);
  },
  async delete(ctx, id) {
    await findMemory(ctx, id);
    await ctx.store.saveMemory(ctx.agent.userId, [], [id]);
  },
};

// -- schedules ------------------------------------------------------------------------------

async function findSchedule(ctx: ControlContext, id: string): Promise<ScheduleItem> {
  const s = await ctx.store.schedule(id);
  if (!s || s.agentId !== ctx.agent.id) throw new Refused("not_found");
  return s;
}

async function scheduleRow(s: ScheduleItem) {
  const when = describe(s.rule, s.tz);
  return { id: s.id, title: s.note.slice(0, 60), when, schedule: when, next_run: s.paused ? null : s.nextAt, paused: !!s.paused,
           last_run: s.firedAt ?? null, rev: await rev({ note: s.note, rule: s.rule }) };
}

const schedules: Section = {
  async list(ctx) {
    return Promise.all((await ctx.store.schedules(ctx.agent.id)).map(scheduleRow));
  },
  async get(ctx, id) {
    const s = await findSchedule(ctx, id);
    const row = await scheduleRow(s);
    return [row.rev, { ...row, text: s.note, read_only: false, deliver: "this chat" }];
  },
  async put(ctx, id, req) {
    const s = await findSchedule(ctx, id);
    const v = req?.value ?? {};
    const note = typeof v.text === "string" ? v.text.replace(/\s+/g, " ").trim() : s.note;
    if (!note) throw new Refused("empty", {}, "A check-in needs a note.");
    let rule = s.rule;
    if (typeof v.schedule === "string") {
      const parsed = parseLine(`${v.schedule.trim()} "${note.replace(/"/g, "'")}"`, s.tz, Date.now());
      if (!parsed || "cancel" in parsed) throw new Refused("bad_schedule");
      rule = parsed.rule;
    }
    const at = next(rule, s.tz, Date.now());
    if (!at) throw new Refused("bad_schedule");
    await ctx.store.updateSchedule(id, { note: note.slice(0, 300), rule, nextAt: s.paused ? null : new Date(at).toISOString() });
    return schedules.get(ctx, id);
  },
  async act(ctx, id, verb) {
    const s = await findSchedule(ctx, id);
    if (verb === "pause") await ctx.store.updateSchedule(id, { paused: true, nextAt: null });
    else if (verb === "resume") {
      const at = next(s.rule, s.tz, Date.now());
      await ctx.store.updateSchedule(id, { paused: false, nextAt: at ? new Date(at).toISOString() : null });
    } else await ctx.store.updateSchedule(id, { paused: false, nextAt: new Date().toISOString() });
    const [r, item] = await schedules.get(ctx, id);
    return [r, verb === "run" ? { ...item, running_soon: true } : item];
  },
  async delete(ctx, id) {
    await findSchedule(ctx, id);
    await ctx.store.dropSchedule(id);
  },
};

// -- tables (read, delete) ----------------------------------------------------------------------

async function tableRow(t: { name: string; cols: { name: string; type: string; unit?: string }[]; order: string[] }) {
  const n = t.order.length;
  return { id: t.name, title: t.name.replace(/[_-]+/g, " ").replace(/^./, (c) => c.toUpperCase()), sub: `${n} row${n === 1 ? "" : "s"}`,
           rows: n, cols: t.cols.map((c) => c.name), rev: await rev({ cols: t.cols, n, last: t.order[n - 1] ?? null }) };
}

const tables: Section = {
  async list(ctx) {
    const s = await ctx.store.tables(ctx.agent.id);
    return Promise.all(Object.values(s.tables).map(tableRow));
  },
  async get(ctx, id) {
    const s = await ctx.store.tables(ctx.agent.id);
    const t = s.tables[id];
    if (!t) throw new Refused("not_found");
    const row = await tableRow(t);
    return [row.rev, { ...row, text: asText(s, { table: id, limit: 100 }), read_only: true,
                       columns: t.cols.map((c) => `${c.name}: ${c.type}${c.unit ? ` (${c.unit})` : ""}`) }];
  },
  async delete(ctx, id) {
    const s = await ctx.store.tables(ctx.agent.id);
    if (!s.tables[id]) throw new Refused("not_found");
    const after = write(s, { op: "drop", name: id }).store;
    await ctx.store.saveTables(ctx.agent, diff(s, after), after);
  },
};

// -- model (read only) ------------------------------------------------------------------------

/** The model's name from the eval list (models.ts MODELS), or its id when it isn't there. */
export function modelLabel(id: string | undefined): string {
  const m = id || "default";
  return MODELS.find((c) => c.id === m)?.label ?? m;
}

function modelInfo(ctx: ControlContext) {
  const p = ctx.agent.profile;
  return { id: "model", model: modelLabel(p.model), provider: ctx.provider,
           // Which profile it runs, and its version (YUI-145): "Basil" v1.
           profile: p.name, version: p.version ?? 1,
           toolsets: [{ name: "Every Yui screen", on: true }, { name: "Memory", on: true }, { name: "Check-ins", on: true },
                      { name: ctx.searchKey ? "Web search, your Firecrawl key" : "Web search", on: true }, { name: "Hand-offs", on: true }, { name: "Its own tables", on: true },
                      ...(ctx.agent.profile.maker ? [{ name: "Makes agents", on: true }] : [])] };
}

const model: Section = {
  async list(ctx) {
    const info = modelInfo(ctx);
    return [{ id: "model", title: info.model, sub: info.provider, rev: await rev(info) }];
  },
  async get(ctx, id) {
    if (id !== "model") throw new Refused("bad_id");
    const info = modelInfo(ctx);
    return [await rev(info), info];
  },
};

const sections: Record<string, Section> = { soul, memory, schedules, tables, model };
