// What the proxy needs from the database. The real one calls the service-role
// functions of migration 20260930000000_yui_vault.sql; tests plug in one that
// talks to a local Postgres with the same migration.

export type Begin =
  | { ok: true; use_id: number; provider: string; sealed: string; key_id: string; user_id: string; agent_id: string }
  | { ok: false; error: string };

export interface Store {
  /** The host behind an agent connection token, or null (unknown or revoked). */
  connector(token: string): Promise<{ id: string; suspended: boolean } | null>;
  /** False when this host is over its rate. */
  take(connectorId: string): Promise<boolean>;
  begin(a: { handle: string; connector: string; path: string; pathOk: boolean; estCents: number }): Promise<Begin>;
  finish(useId: number, status: number, costCents: number, error?: string): Promise<void>;
}

// deno-lint-ignore no-explicit-any
export function supabaseStore(db: any, lookup: (db: any, token: string, cols: string) => Promise<any>): Store {
  return {
    async connector(token) {
      const c = await lookup(db, token, "id, user_id, suspended_at");
      if (!c) return null;
      const { data: owner } = await db.from("yui_users").select("suspended_at").eq("id", c.user_id).maybeSingle();
      return { id: c.id, suspended: Boolean(c.suspended_at || owner?.suspended_at) };
    },
    async take(connectorId) {
      const { data, error } = await db.rpc("yui_take", { k: `vault:c:${connectorId}`, lim: "vault" });
      // A broken limiter lets the call through (same rule as _shared/yui.ts take).
      return error ? true : data !== false;
    },
    async begin(a) {
      const { data, error } = await db.rpc("yui_vault_begin", {
        p_handle: a.handle, p_connector: a.connector, p_path: a.path, p_path_ok: a.pathOk, p_est: a.estCents,
      });
      if (error) throw new Error("vault begin failed: " + (error.code ?? "") );
      return data as Begin;
    },
    async finish(useId, status, costCents, error) {
      const { error: e } = await db.rpc("yui_vault_finish", { p_use: useId, p_status: status, p_cost: costCents, p_error: error ?? null });
      if (e) throw new Error("vault finish failed: " + (e.code ?? ""));
    },
  };
}
