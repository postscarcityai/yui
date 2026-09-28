// Copied from runtime/src/supabase.ts by runtime/scripts/build.mjs. Do not edit here.
// The server's store: a person's native Yui as rows in the Yui relay
// (migration supabase/migrations/20260927000000_yui_native.sql). Plain fetch to
// PostgREST and Storage with the service key, so it runs in the edge function
// and, for a check, from a laptop. Never ship the service key to a client.
import type { Store } from "./store.ts";
import { type Cell, type TableChange, type TableStore, emptyStore } from "./tables.ts";
import { DEFAULT_ROUTES, type MemoryItem, type NativeAgent, type OwnKey, type Profile, type Routes, type Row, type ScheduleItem, type SearchTake } from "./types.ts";

export class SupabaseStore implements Store {
  private url: string;
  private key: string;
  private fetch: typeof fetch;
  private guideCache?: { at: number; body: string };

  constructor(url: string, serviceKey: string, fetchImpl: typeof fetch = fetch) {
    this.url = url.replace(/\/+$/, "");
    this.key = serviceKey;
    this.fetch = fetchImpl;
  }

  private async rest(method: string, path: string, body?: unknown, prefer?: string): Promise<any> {
    const r = await this.fetch(`${this.url}/rest/v1/${path}`, {
      method,
      headers: {
        apikey: this.key,
        authorization: `Bearer ${this.key}`,
        "content-type": "application/json",
        ...(prefer ? { prefer } : {}),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await r.text();
    if (!r.ok) throw new Error(`${method} ${path.split("?")[0]}: ${r.status} ${text.slice(0, 300)}`);
    return text ? JSON.parse(text) : null;
  }

  private rpc(fn: string, args: Record<string, unknown>): Promise<any> {
    return this.rest("POST", `rpc/${fn}`, args);
  }

  private toAgent(a: any, prof: any): NativeAgent | null {
    if (!prof?.profile) return null;
    // The registry row owns the name and handle (the app can rename an agent).
    return { id: a.id, userId: a.user_id, profile: { ...prof.profile, name: a.name, handle: a.handle } };
  }

  async agent(agentId: string) {
    const [a] = await this.rest("GET", `yui_agents?select=id,user_id,name,handle,kind&id=eq.${agentId}&kind=eq.hosted`);
    if (!a) return null;
    const [p] = await this.rest("GET", `yui_native_profiles?select=profile&agent_id=eq.${agentId}`);
    return this.toAgent(a, p);
  }

  async agents(userId: string) {
    const rows = await this.rest("GET", `yui_agents?select=id,user_id,name,handle,sort,yui_native_profiles(profile)`
      + `&user_id=eq.${userId}&kind=eq.hosted&order=sort,created_at`);
    return rows.map((a: any) => this.toAgent(a, Array.isArray(a.yui_native_profiles) ? a.yui_native_profiles[0] : a.yui_native_profiles))
      .filter((a: NativeAgent | null): a is NativeAgent => !!a);
  }

  async memory(userId: string, agentId: string) {
    const rows = await this.rest("GET", `yui_native_memory?select=id,user_id,agent_id,kind,key,body,updated_at`
      + `&user_id=eq.${userId}&or=(agent_id.is.null,agent_id.eq.${agentId})&order=updated_at`);
    return rows.map((m: any): MemoryItem => ({ id: m.id, userId: m.user_id, agentId: m.agent_id, kind: m.kind, ...(m.key ? { key: m.key } : {}),
                                             body: m.body, updatedAt: m.updated_at }));
  }

  async saveMemory(userId: string, put: MemoryItem[], drop: string[]) {
    if (drop.length) await this.rest("DELETE", `yui_native_memory?user_id=eq.${userId}&id=in.(${drop.join(",")})`);
    if (put.length) {
      await this.rest("POST", "yui_native_memory?on_conflict=id", put.map((m) => ({
        id: m.id, user_id: userId, agent_id: m.agentId, kind: m.kind, key: m.key ?? null, body: m.body, updated_at: m.updatedAt,
      })), "resolution=merge-duplicates,return=minimal");
    }
  }

  async createAgent(userId: string, profile: Profile) {
    const [row] = await this.rpc("yui_native_add_agent", { uid: userId, prof: profile });
    const id = row?.agent_id ?? row;
    const made = await this.agent(id);
    if (!made) throw new Error("the new agent did not save");
    return made;
  }

  async updateAgent(agentId: string, profile: Profile) {
    const { tables: _seeds, ...kept } = profile; // starter tables are rows of their own, never part of the profile
    await this.rest("PATCH", `yui_native_profiles?agent_id=eq.${agentId}`, { profile: kept, updated_at: new Date().toISOString() }, "return=minimal");
    await this.rest("PATCH", `yui_agents?id=eq.${agentId}&kind=eq.hosted`, { name: profile.name, color: profile.color }, "return=minimal");
  }

  async removeAgent(agentId: string) {
    await this.rest("DELETE", `yui_agents?id=eq.${agentId}&kind=eq.hosted`, undefined, "return=minimal");
  }

  async pending(agentId: string) {
    return await this.rest("GET", `yui_messages?select=id,sender,kind,body,meta,created_at`
      + `&agent_id=eq.${agentId}&sender=eq.user&handled_at=is.null&kind=in.(text,event)`
      + `&order=created_at.asc,id.asc&limit=50`) as Row[];
  }

  async history(agentId: string, before: string, limit: number) {
    const rows = await this.rest("GET", `yui_messages?select=id,sender,kind,body,meta,created_at`
      + `&agent_id=eq.${agentId}&kind=in.(text,event)&created_at=lt.${encodeURIComponent(before)}`
      + `&order=created_at.desc,id.desc&limit=${limit}`) as Row[];
    return rows.reverse();
  }

  async markDelivered(ids: string[]) {
    await this.rest("PATCH", `yui_messages?id=in.(${ids.join(",")})&delivered_at=is.null`, { delivered_at: new Date().toISOString() }, "return=minimal");
  }

  async markHandled(ids: string[]) {
    await this.rest("PATCH", `yui_messages?id=in.(${ids.join(",")})`, { handled_at: new Date().toISOString(), doing: null }, "return=minimal");
  }

  async doing(rowId: string, text: string | null) {
    await this.rest("PATCH", `yui_messages?id=eq.${rowId}`, { doing: text ? { text } : null }, "return=minimal");
  }

  async reply(agent: NativeAgent, body: string, meta: Record<string, unknown>) {
    const id = crypto.randomUUID();
    await this.rest("POST", "yui_messages", { id, user_id: agent.userId, agent_id: agent.id, sender: "agent", kind: "text",
                                               body: body.slice(0, 32000), meta }, "return=minimal");
    return id;
  }

  async routes(): Promise<Routes> {
    try {
      const rows = await this.rest("GET", "yui_native_models?select=kind,model");
      const out = { ...DEFAULT_ROUTES };
      for (const r of rows) if (r.kind === "text" || r.kind === "vision") out[r.kind as keyof Routes] = r.model;
      return out;
    } catch {
      return DEFAULT_ROUTES;
    }
  }

  async guide() {
    if (this.guideCache && Date.now() - this.guideCache.at < 300_000) return this.guideCache.body;
    const [g] = await this.rest("GET", "yui_channel_guides?select=body&order=created_at.desc&limit=1");
    this.guideCache = { at: Date.now(), body: g?.body ?? "" };
    return this.guideCache.body;
  }

  async signMedia(path: string) {
    if (/^https?:/.test(path)) return path;
    const clean = path.replace(/^\/+/, "").replace(/^yui-media\//, "");
    if (!/^[0-9a-f-]{36}\/[0-9a-f-]{36}\/user\/[\w.-]+$/i.test(clean)) return null; // only the person's own uploads
    const r = await this.fetch(`${this.url}/storage/v1/object/sign/yui-media/${clean}`, {
      method: "POST",
      headers: { apikey: this.key, authorization: `Bearer ${this.key}`, "content-type": "application/json" },
      body: JSON.stringify({ expiresIn: 600 }),
    });
    if (!r.ok) return null;
    const d: any = await r.json();
    const signed = d?.signedURL ?? d?.signedUrl;
    return signed ? `${this.url}/storage/v1${signed.startsWith("/") ? "" : "/"}${signed}` : null;
  }

  async takeTurn(userId: string) {
    const r = await this.rpc("yui_native_take_turn", { uid: userId });
    const row = Array.isArray(r) ? r[0] : r;
    return { ok: !!row?.ok, left: Number(row?.left_turns ?? 0), limit: Number(row?.lim ?? 100) };
  }

  async lock(agentId: string, seconds: number) {
    return (await this.rpc("yui_native_lock", { agent: agentId, secs: seconds })) === true;
  }

  async unlock(agentId: string) {
    await this.rest("DELETE", `yui_native_locks?agent_id=eq.${agentId}`, undefined, "return=minimal");
  }

  async timezone(userId: string) {
    const [u] = await this.rest("GET", `yui_users?select=timezone&id=eq.${userId}`);
    return u?.timezone ?? null;
  }

  private toSchedule(x: any): ScheduleItem {
    return { id: x.id, userId: x.user_id, agentId: x.agent_id, note: x.note, rule: x.rule, tz: x.tz, nextAt: x.next_at,
             paused: !!x.paused, firedAt: x.fired_at ?? null };
  }

  async schedules(agentId: string) {
    const rows = await this.rest("GET", `yui_native_schedules?select=*&agent_id=eq.${agentId}&order=created_at,id`);
    return rows.map((x: any) => this.toSchedule(x));
  }

  async schedule(id: string) {
    const [x] = await this.rest("GET", `yui_native_schedules?select=*&id=eq.${id}`);
    return x ? this.toSchedule(x) : null;
  }

  async addSchedule(item: Omit<ScheduleItem, "id">) {
    const r = await this.fetch(`${this.url}/rest/v1/yui_native_schedules?select=id&user_id=eq.${item.userId}`, {
      method: "HEAD", headers: { apikey: this.key, authorization: `Bearer ${this.key}`, prefer: "count=exact" },
    });
    const count = Number((r.headers.get("content-range") ?? "*/0").split("/")[1]);
    const [cap] = await this.rest("GET", "yui_limits?select=value&name=eq.native_schedules_per_user");
    if (count >= Number(cap?.value ?? 30)) return null;
    const [x] = await this.rest("POST", "yui_native_schedules", {
      user_id: item.userId, agent_id: item.agentId, note: item.note, rule: item.rule, tz: item.tz, next_at: item.nextAt,
    }, "return=representation");
    return x?.id ?? null;
  }

  async setScheduleNext(id: string, nextAt: string | null) {
    await this.rest("PATCH", `yui_native_schedules?id=eq.${id}`, { next_at: nextAt }, "return=minimal");
  }

  async updateSchedule(id: string, patch: Partial<Pick<ScheduleItem, "note" | "rule" | "nextAt" | "paused">>) {
    const body: Record<string, unknown> = {};
    if (patch.note !== undefined) body.note = patch.note;
    if (patch.rule !== undefined) body.rule = patch.rule;
    if (patch.nextAt !== undefined) body.next_at = patch.nextAt;
    if (patch.paused !== undefined) body.paused = patch.paused;
    await this.rest("PATCH", `yui_native_schedules?id=eq.${id}`, body, "return=minimal");
  }

  async row(id: string) {
    const [r] = await this.rest("GET", `yui_messages?select=id,user_id,agent_id,sender,kind,body,meta,created_at&id=eq.${id}`);
    return r ?? null;
  }

  async controlAnswer(agent: NativeAgent, requestId: string, body: string, meta: Record<string, unknown>) {
    await this.rest("POST", "yui_messages", { id: crypto.randomUUID(), user_id: agent.userId, agent_id: agent.id, sender: "agent",
                                               kind: "control", body: body.slice(0, 300), meta: { ...meta, for: requestId } }, "return=minimal");
    await this.rest("PATCH", `yui_messages?id=eq.${requestId}`, { delivered_at: new Date().toISOString(), handled_at: new Date().toISOString() },
                    "return=minimal");
  }

  // Tables (YUI-170): yui_native_tables holds each table's columns, yui_native_table_rows its rows as jsonb.
  async tables(agentId: string): Promise<TableStore> {
    const out = emptyStore();
    const defs = await this.rest("GET", `yui_native_tables?select=name,cols,next&agent_id=eq.${agentId}&order=created_at,name`);
    if (!defs.length) return out;
    for (const d of defs) out.tables[d.name] = { name: d.name, cols: d.cols, next: d.next, rows: {}, order: [] };
    // PostgREST hands back 1000 rows a request at most.
    for (let from = 0; ; from += 1000) {
      const rows = await this.rest("GET", `yui_native_table_rows?select=tname,key,vals&agent_id=eq.${agentId}`
        + `&order=tname,pos,created_at,key&limit=1000&offset=${from}`);
      for (const r of rows) {
        const t = out.tables[r.tname];
        if (!t) continue;
        t.rows[r.key] = r.vals as Record<string, Cell>;
        t.order.push(r.key);
      }
      if (rows.length < 1000) break;
    }
    return out;
  }

  async saveTables(agent: NativeAgent, ch: TableChange, _after: TableStore) {
    const a = agent.id, u = agent.userId, now = new Date().toISOString();
    const enc = encodeURIComponent;
    for (const name of ch.dropTables) {
      await this.rest("DELETE", `yui_native_tables?agent_id=eq.${a}&name=eq.${enc(name)}`, undefined, "return=minimal");
    }
    if (ch.tables.length) {
      await this.rest("POST", "yui_native_tables?on_conflict=agent_id,name", ch.tables.map((t) => ({
        agent_id: a, user_id: u, name: t.name, cols: t.cols, next: t.next, updated_at: now,
      })), "resolution=merge-duplicates,return=minimal");
    }
    for (const r of ch.dropRows) {
      await this.rest("DELETE", `yui_native_table_rows?agent_id=eq.${a}&tname=eq.${enc(r.table)}&key=eq.${enc(r.key)}`, undefined, "return=minimal");
    }
    // New rows get a place after every row there is; a changed row keeps its place.
    const base = Date.now() * 1000;
    const added = ch.rows.filter((r) => r.isNew).map((r, i) => ({ agent_id: a, user_id: u, tname: r.table, key: r.key, vals: r.values, pos: base + i }));
    const edited = ch.rows.filter((r) => !r.isNew).map((r) => ({ agent_id: a, user_id: u, tname: r.table, key: r.key, vals: r.values, updated_at: now }));
    for (const batch of [added, edited]) {
      for (let i = 0; i < batch.length; i += 500) {
        await this.rest("POST", "yui_native_table_rows?on_conflict=agent_id,tname,key", batch.slice(i, i + 500),
                        "resolution=merge-duplicates,return=minimal");
      }
    }
  }

  async dropSchedule(id: string) {
    await this.rest("DELETE", `yui_native_schedules?id=eq.${id}`, undefined, "return=minimal");
  }

  async takeSearch(userId: string, own: boolean): Promise<SearchTake> {
    const r = await this.rpc("yui_native_take_search", { uid: userId, own });
    const row = Array.isArray(r) ? r[0] : r;
    const why = row?.why === "month" || row?.why === "day" ? row.why : undefined;
    return { ok: !!row?.ok, used: Number(row?.used ?? 0), limit: Number(row?.lim ?? 0), perTurn: Number(row?.per_turn ?? 1),
             ...(why ? { why } : {}) };
  }

  async searchKey(userId: string): Promise<string | null> {
    const r = await this.rpc("yui_native_search_key_get", { uid: userId });
    const k = Array.isArray(r) ? r[0] : r;
    return typeof k === "string" && k ? k : null;
  }

  async ownKey(userId: string): Promise<OwnKey | null> {
    const r = await this.rpc("yui_native_key_get", { uid: userId });
    const k = Array.isArray(r) ? r[0] : r;
    return k?.secret ? { provider: k.provider, baseUrl: k.base_url, model: k.model ?? null, key: k.secret } : null;
  }
}
