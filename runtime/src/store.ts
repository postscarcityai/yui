// Where a person's native Yui lives. Two stores, one interface:
//   - SupabaseStore (supabase.ts): rows in Postgres, for the edge function;
//   - LocalStore (below): one JSON object, for `node runtime/cli.ts` and tests.
// Everything a turn needs goes through here, so the turn itself never knows
// where it runs.
import type { MemoryItem, NativeAgent, Profile, Routes, Row } from "./types.ts";
import { DEFAULT_ROUTES } from "./types.ts";

export interface Store {
  agent(agentId: string): Promise<NativeAgent | null>;
  agents(userId: string): Promise<NativeAgent[]>;
  memory(userId: string, agentId: string): Promise<MemoryItem[]>; // about-you plus this agent's notes
  saveMemory(userId: string, put: MemoryItem[], drop: string[]): Promise<void>;
  /** A new native agent on this person's Yui, with its first answer in its thread. */
  createAgent(userId: string, profile: Profile): Promise<NativeAgent>;
  updateAgent(agentId: string, profile: Profile): Promise<void>;
  removeAgent(agentId: string): Promise<void>;
  /** Person rows not handled yet, oldest first (text and taps only). */
  pending(agentId: string): Promise<Row[]>;
  history(agentId: string, before: string, limit: number): Promise<Row[]>; // oldest first
  markDelivered(ids: string[]): Promise<void>;
  markHandled(ids: string[]): Promise<void>;
  doing(rowId: string, text: string | null): Promise<void>;
  reply(agent: NativeAgent, body: string, meta: Record<string, unknown>): Promise<string>; // the new row id
  routes(): Promise<Routes>;
  guide(): Promise<string>;
  /** A URL the model can fetch for one of the person's photos, or null. */
  signMedia(path: string): Promise<string | null>;
  /** Takes one free turn this month; false when they are used up. */
  takeTurn(userId: string): Promise<{ ok: boolean; left: number; limit: number }>;
  /** One turn at a time per agent. */
  lock(agentId: string, seconds: number): Promise<boolean>;
  unlock(agentId: string): Promise<void>;
}

/** Everything in one plain object: `JSON.stringify(store.data)` saves it. */
export interface LocalData {
  users: Record<string, { turns: Record<string, number> }>;
  agents: Record<string, { userId: string; profile: Profile }>;
  memory: MemoryItem[];
  rows: (Row & { agent_id: string; delivered_at?: string | null; handled_at?: string | null; doing?: any })[];
  routes?: Routes;
}

export class LocalStore implements Store {
  data: LocalData;
  guideText: string;
  freeTurns: number;
  onChange?: () => void;
  private locks = new Set<string>();
  private n = 0;

  constructor(data?: Partial<LocalData>, opts: { guide?: string; freeTurns?: number; onChange?: () => void } = {}) {
    this.data = { users: {}, agents: {}, memory: [], rows: [], ...data };
    this.guideText = opts.guide ?? "";
    this.freeTurns = opts.freeTurns ?? 100;
    this.onChange = opts.onChange;
  }

  id(prefix: string): string {
    return `${prefix}-${Date.now().toString(36)}-${(this.n++).toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
  }
  private changed() {
    this.onChange?.();
  }

  async agent(agentId: string) {
    const a = this.data.agents[agentId];
    return a ? { id: agentId, userId: a.userId, profile: a.profile } : null;
  }
  async agents(userId: string) {
    return Object.entries(this.data.agents).filter(([, a]) => a.userId === userId)
      .map(([id, a]) => ({ id, userId, profile: a.profile }));
  }
  async memory(userId: string, agentId: string) {
    return this.data.memory.filter((m) => m.userId === userId && (m.agentId === null || m.agentId === agentId));
  }
  async saveMemory(userId: string, put: MemoryItem[], drop: string[]) {
    const gone = new Set([...drop, ...put.map((p) => p.id)]);
    this.data.memory = this.data.memory.filter((m) => !gone.has(m.id));
    this.data.memory.push(...put.map((p) => ({ ...p, userId })));
    this.changed();
  }
  async createAgent(userId: string, profile: Profile) {
    const taken = new Set(Object.values(this.data.agents).filter((a) => a.userId === userId).map((a) => a.profile.handle));
    let handle = profile.handle;
    for (let i = 2; taken.has(handle); i++) handle = `${profile.handle}-${i}`;
    const id = this.id("agent");
    const p = { ...profile, handle };
    this.data.agents[id] = { userId, profile: p };
    this.data.rows.push({ id: this.id("row"), agent_id: id, sender: "agent", kind: "text", body: p.first, meta: { native: "first" },
                          created_at: new Date().toISOString() });
    this.changed();
    return { id, userId, profile: p };
  }
  async updateAgent(agentId: string, profile: Profile) {
    if (this.data.agents[agentId]) this.data.agents[agentId].profile = profile;
    this.changed();
  }
  async removeAgent(agentId: string) {
    delete this.data.agents[agentId];
    this.data.rows = this.data.rows.filter((r) => r.agent_id !== agentId);
    this.data.memory = this.data.memory.filter((m) => m.agentId !== agentId);
    this.changed();
  }
  async pending(agentId: string) {
    return this.data.rows.filter((r) => r.agent_id === agentId && r.sender === "user" && !r.handled_at && r.kind !== "control");
  }
  async history(agentId: string, before: string, limit: number) {
    // <= in file order: rows written in the same millisecond still count (the turn drops its own rows).
    return this.data.rows.filter((r) => r.agent_id === agentId && r.created_at <= before).slice(-limit);
  }
  async markDelivered(ids: string[]) {
    for (const r of this.data.rows) if (ids.includes(r.id) && !r.delivered_at) r.delivered_at = new Date().toISOString();
  }
  async markHandled(ids: string[]) {
    for (const r of this.data.rows) if (ids.includes(r.id)) r.handled_at = new Date().toISOString();
    this.changed();
  }
  async doing(rowId: string, text: string | null) {
    const r = this.data.rows.find((x) => x.id === rowId);
    if (r) r.doing = text ? { text } : null;
  }
  async reply(agent: NativeAgent, body: string, meta: Record<string, unknown>) {
    const id = this.id("row");
    this.data.rows.push({ id, agent_id: agent.id, sender: "agent", kind: "text", body, meta, created_at: new Date().toISOString() });
    this.changed();
    return id;
  }
  async routes() {
    return this.data.routes ?? DEFAULT_ROUTES;
  }
  async guide() {
    return this.guideText;
  }
  async signMedia(path: string) {
    return /^(https?:|data:)/.test(path) ? path : null;
  }
  async takeTurn(userId: string) {
    const month = new Date().toISOString().slice(0, 7);
    const u = (this.data.users[userId] ??= { turns: {} });
    const used = u.turns[month] ?? 0;
    if (used >= this.freeTurns) return { ok: false, left: 0, limit: this.freeTurns };
    u.turns[month] = used + 1;
    this.changed();
    return { ok: true, left: this.freeTurns - used - 1, limit: this.freeTurns };
  }
  async lock(agentId: string) {
    if (this.locks.has(agentId)) return false;
    this.locks.add(agentId);
    return true;
  }
  async unlock(agentId: string) {
    this.locks.delete(agentId);
  }

  /** A person's message into an agent's thread (the CLI and the tests). */
  say(agentId: string, body: string, kind = "text"): string {
    const id = this.id("row");
    this.data.rows.push({ id, agent_id: agentId, sender: "user", kind, body, meta: {}, created_at: new Date().toISOString() });
    this.changed();
    return id;
  }
}
