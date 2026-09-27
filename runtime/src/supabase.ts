// The server's store: a person's native Yui as rows in the Yui relay
// (migration supabase/migrations/20260927000000_yui_native.sql). Plain fetch to
// PostgREST and Storage with the service key, so it runs in the edge function
// and, for a check, from a laptop. Never ship the service key to a client.
import type { Store } from "./store.ts";
import { DEFAULT_ROUTES, type MemoryItem, type NativeAgent, type Profile, type Routes, type Row } from "./types.ts";

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
    await this.rest("PATCH", `yui_native_profiles?agent_id=eq.${agentId}`, { profile, updated_at: new Date().toISOString() }, "return=minimal");
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
}
