// yui-agents: the agent registry API. Spec: yuigui/spec/AGENTS.md.
//
// POST {action, ...}. Authorization is either
//   - a Yui access token (the app), or
//   - a management token `yui_mt_...` (Settings > Agent access), scope
//     agents:manage. It can list/create/update/delete agents and mint pairing
//     codes. It is not a PostgREST JWT, so it can never read messages, and it
//     cannot manage tokens, revoke hosts or delete the account.
//
// Actions: list, create, update, delete, reorder, pair_code,
//          token_create, token_list, token_revoke, connector_revoke (app only).
import {
  admin,
  AGENT_COLORS,
  AGENT_COLUMNS,
  agentView,
  assertActive,
  bearer,
  cleanLook,
  cleanName,
  defaultColor,
  failure,
  insertAgent,
  json,
  MGMT_PREFIX,
  nameFromRef,
  randomToken,
  sha256Hex,
  take,
  validRemoteRef,
  verifyAccessToken,
} from "../_shared/yui.ts";

const PAIR_TTL_MINUTES = 10;

type Caller = { userId: string; via: "app" | "token" };
// deno-lint-ignore no-explicit-any
type Body = Record<string, any>;

class HttpError extends Error {
  constructor(public status: number, public code: string) {
    super(code);
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  let caller: Caller;
  try {
    caller = await authenticate(req);
  } catch {
    return json({ error: "unauthorized" }, 401);
  }
  let body: Body;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_request" }, 400);
  }
  try {
    const handler = ACTIONS[body.action as string];
    if (!handler) return json({ error: "unknown_action" }, 400);
    if (handler.appOnly && caller.via !== "app") return json({ error: "forbidden" }, 403);
    // YUI-26: a suspended account manages nothing; each account has a call budget.
    const db = admin();
    await assertActive(db, caller.userId);
    await take(db, `agents:u:${caller.userId}`, "agents_api");
    return json(await handler.run(caller.userId, body));
  } catch (e) {
    if (e instanceof HttpError) return json({ error: e.code }, e.status);
    return failure(`yui-agents ${body.action}`, e);
  }
});

async function authenticate(req: Request): Promise<Caller> {
  const token = bearer(req);
  if (token.startsWith(MGMT_PREFIX)) {
    const db = admin();
    const { data } = await db.from("yui_mgmt_tokens").select("id, user_id")
      .eq("token_hash", await sha256Hex(token)).is("revoked_at", null).maybeSingle();
    if (!data) throw new Error("bad token");
    await db.from("yui_mgmt_tokens").update({ last_used_at: new Date().toISOString() }).eq("id", data.id);
    return { userId: data.user_id, via: "token" };
  }
  return { userId: await verifyAccessToken(req), via: "app" };
}

// deno-lint-ignore no-explicit-any
async function ownAgent(db: any, userId: string, id: unknown) {
  if (typeof id !== "string") throw new HttpError(400, "invalid_request");
  const { data } = await db.from("yui_agents").select("id, is_default")
    .eq("user_id", userId).eq("id", id).maybeSingle();
  if (!data) throw new HttpError(404, "not_found");
  return data;
}

// deno-lint-ignore no-explicit-any
async function ownConnector(db: any, userId: string, id: unknown) {
  if (typeof id !== "string") throw new HttpError(400, "invalid_request");
  const { data } = await db.from("yui_connectors").select("id, revoked_at")
    .eq("user_id", userId).eq("id", id).maybeSingle();
  if (!data) throw new HttpError(404, "connector_not_found");
  if (data.revoked_at) throw new HttpError(409, "connector_revoked");
  return data;
}

function sixDigits(): string {
  const n = crypto.getRandomValues(new Uint32Array(1))[0] % 1_000_000;
  return n.toString().padStart(6, "0");
}

// deno-lint-ignore no-explicit-any
async function mintPairCode(db: any, userId: string, agentId: string) {
  // One live code per agent; clear this agent's old ones and anything expired.
  await db.from("yui_pairings").delete().eq("agent_id", agentId).is("used_at", null);
  await db.from("yui_pairings").delete().is("used_at", null).lt("expires_at", new Date().toISOString());
  const expires = new Date(Date.now() + PAIR_TTL_MINUTES * 60_000).toISOString();
  for (let i = 0; i < 5; i++) {
    const code = sixDigits();
    const { error } = await db.from("yui_pairings").insert({
      user_id: userId,
      agent_id: agentId,
      code_hash: await sha256Hex(`pair:${code}`),
      expires_at: expires,
    });
    if (!error) return { code, expires_at: expires };
    if (error.code !== "23505") throw error; // collided with another live code: retry
  }
  throw new Error("could not allocate a pairing code");
}

// A shared agent (YUI-95): someone else's agent this person holds a live grant
// for. They may mute it and move it in their list; nothing else.
// deno-lint-ignore no-explicit-any
async function liveGrant(db: any, userId: string, agentId: unknown): Promise<boolean> {
  if (typeof agentId !== "string") return false;
  const { data } = await db.from("yui_agent_grants").select("id").eq("user_id", userId)
    .eq("agent_id", agentId).is("revoked_at", null).maybeSingle();
  return !!data;
}

// deno-lint-ignore no-explicit-any
async function updateGrant(db: any, userId: string, b: Body) {
  if (["name", "color", "theme", "is_default", "remote_ref"].some((k) => b[k] !== undefined)) {
    throw new HttpError(403, "shared_agent");
  }
  const patch: Record<string, unknown> = {};
  if (b.sort !== undefined) {
    if (!Number.isInteger(b.sort)) throw new HttpError(400, "invalid_sort");
    patch.sort = b.sort;
  }
  if (b.push_muted !== undefined) {
    if (typeof b.push_muted !== "boolean") throw new HttpError(400, "invalid_push_muted");
    patch.push_muted = b.push_muted;
  }
  if (!Object.keys(patch).length) throw new HttpError(400, "nothing_to_update");
  const { error } = await db.from("yui_agent_grants").update(patch).eq("user_id", userId)
    .eq("agent_id", b.id).is("revoked_at", null);
  if (error) throw error;
  const { data, error: e2 } = await db.from("yui_agent_list").select(AGENT_COLUMNS)
    .eq("user_id", userId).eq("id", b.id).single();
  if (e2) throw e2;
  return { agent: data };
}

type Action = { appOnly?: boolean; run: (userId: string, b: Body) => Promise<unknown> };

const ACTIONS: Record<string, Action> = {
  list: {
    async run(userId) {
      const db = admin();
      const { data: agents, error } = await db.from("yui_agent_list").select(AGENT_COLUMNS)
        .eq("user_id", userId).order("sort").order("created_at");
      if (error) throw error;
      const { data: connectors, error: e2 } = await db.from("yui_connectors")
        .select("id, name, kind, created_at, last_seen_at")
        .eq("user_id", userId).is("revoked_at", null).order("created_at");
      if (e2) throw e2;
      return { agents, connectors };
    },
  },

  // {name?, remote_ref?, color?, connector_id?, pair?}. With connector_id the
  // agent is bound at once (the host already serves that profile). With
  // pair: true the reply carries a 6-digit code for `hermes yui pair`.
  create: {
    async run(userId, b) {
      const db = admin();
      if (b.remote_ref != null && !validRemoteRef(b.remote_ref)) throw new HttpError(400, "invalid_remote_ref");
      const name = b.name == null ? null : cleanName(b.name);
      if (b.name != null && !name) throw new HttpError(400, "invalid_name");
      if (!name && !b.remote_ref) throw new HttpError(400, "name_or_remote_ref_required");
      if (b.color != null && !AGENT_COLORS.includes(b.color)) throw new HttpError(400, "invalid_color");
      if (b.connector_id != null) {
        await ownConnector(db, userId, b.connector_id);
        if (!b.remote_ref) throw new HttpError(400, "remote_ref_required");
      }
      const finalName = name ?? nameFromRef(b.remote_ref);
      let id: string;
      try {
        id = await insertAgent(db, {
          user_id: userId,
          name: finalName,
          color: b.color ?? defaultColor(finalName),
          remote_ref: b.remote_ref ?? null,
          connector_id: b.connector_id ?? null,
        });
      } catch (e) {
        if ((e as { code?: string }).code === "23505") throw new HttpError(409, "already_added");
        throw e;
      }
      const agent = await agentView(db, userId, id);
      return b.pair ? { agent, pairing: await mintPairCode(db, userId, id) } : { agent };
    },
  },

  // {id, name?, color?, theme?, sort?, is_default?, remote_ref?, push_muted?}
  update: {
    async run(userId, b) {
      const db = admin();
      if (await liveGrant(db, userId, b.id)) return await updateGrant(db, userId, b);
      await ownAgent(db, userId, b.id);
      const patch: Record<string, unknown> = {};
      if (b.name !== undefined) {
        const n = cleanName(b.name);
        if (!n) throw new HttpError(400, "invalid_name");
        patch.name = n;
      }
      if (b.color !== undefined) {
        if (!AGENT_COLORS.includes(b.color)) throw new HttpError(400, "invalid_color");
        patch.color = b.color;
      }
      if (b.theme !== undefined) {
        const look = cleanLook(b.theme);
        if (!look) throw new HttpError(400, "invalid_theme");
        patch.theme = look;
      }
      if (b.sort !== undefined) {
        if (!Number.isInteger(b.sort)) throw new HttpError(400, "invalid_sort");
        patch.sort = b.sort;
      }
      if (b.is_default === true) patch.is_default = true;
      if (b.push_muted !== undefined) {
        if (typeof b.push_muted !== "boolean") throw new HttpError(400, "invalid_push_muted");
        patch.push_muted = b.push_muted;
      }
      if (b.remote_ref !== undefined) {
        if (!validRemoteRef(b.remote_ref)) throw new HttpError(400, "invalid_remote_ref");
        patch.remote_ref = b.remote_ref;
      }
      if (!Object.keys(patch).length) throw new HttpError(400, "nothing_to_update");
      const { error } = await db.from("yui_agents").update(patch).eq("user_id", userId).eq("id", b.id);
      if (error) {
        if (error.code === "23505") throw new HttpError(409, "already_added");
        throw error;
      }
      return { agent: await agentView(db, userId, b.id) };
    },
  },

  // {id}. Deletes the agent and, by cascade, its whole thread.
  delete: {
    async run(userId, b) {
      const db = admin();
      if (await liveGrant(db, userId, b.id)) throw new HttpError(403, "shared_agent");
      await ownAgent(db, userId, b.id);
      // A trigger hands the default to the next agent if this one had it.
      const { error } = await db.from("yui_agents").delete().eq("user_id", userId).eq("id", b.id);
      if (error) throw error;
      return { deleted: true, id: b.id };
    },
  },

  // {ids: [...]} in display order.
  reorder: {
    async run(userId, b) {
      if (!Array.isArray(b.ids) || !b.ids.every((x: unknown) => typeof x === "string")) {
        throw new HttpError(400, "invalid_request");
      }
      const db = admin();
      for (const [i, id] of b.ids.entries()) {
        await db.from("yui_agents").update({ sort: i }).eq("user_id", userId).eq("id", id);
        await db.from("yui_agent_grants").update({ sort: i }).eq("user_id", userId).eq("agent_id", id)
          .is("revoked_at", null);
      }
      return { ok: true };
    },
  },

  // {agent_id}. A fresh 6-digit code for this agent (10 min, single use).
  pair_code: {
    async run(userId, b) {
      const db = admin();
      await ownAgent(db, userId, b.agent_id);
      return await mintPairCode(db, userId, b.agent_id);
    },
  },

  // {name}. The token is returned once; only its hash is stored.
  token_create: {
    appOnly: true,
    async run(userId, b) {
      const name = cleanName(b.name ?? "Agent access");
      if (!name) throw new HttpError(400, "invalid_name");
      const token = MGMT_PREFIX + randomToken();
      const { data, error } = await admin().from("yui_mgmt_tokens")
        .insert({ user_id: userId, name, token_hash: await sha256Hex(token) })
        .select("id, name, scope, created_at").single();
      if (error) throw error;
      return { token, ...data };
    },
  },

  token_list: {
    appOnly: true,
    async run(userId) {
      const { data, error } = await admin().from("yui_mgmt_tokens")
        .select("id, name, scope, created_at, last_used_at")
        .eq("user_id", userId).is("revoked_at", null).order("created_at");
      if (error) throw error;
      return { tokens: data };
    },
  },

  token_revoke: {
    appOnly: true,
    async run(userId, b) {
      const { data } = await admin().from("yui_mgmt_tokens")
        .update({ revoked_at: new Date().toISOString() })
        .eq("user_id", userId).eq("id", b.id).is("revoked_at", null).select("id");
      if (!data?.length) throw new HttpError(404, "not_found");
      return { revoked: true };
    },
  },

  // {id}. Unpairs a host. Its agents stay, marked offline.
  connector_revoke: {
    appOnly: true,
    async run(userId, b) {
      const { data } = await admin().from("yui_connectors")
        .update({ revoked_at: new Date().toISOString() })
        .eq("user_id", userId).eq("id", b.id).is("revoked_at", null).select("id");
      if (!data?.length) throw new HttpError(404, "not_found");
      return { revoked: true };
    },
  },
};
