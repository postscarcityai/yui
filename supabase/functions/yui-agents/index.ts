// yui-agents: the agent registry API. Spec: yuigui/spec/AGENTS.md.
//
// POST {action, ...}. Authorization is either
//   - a Yui access token (the app), or
//   - a management token `yui_mt_...` (Settings > Agent access), scope
//     agents:manage. It can list/create/update/delete agents and mint pairing
//     codes. It is not a PostgREST JWT, so it can never read messages, and it
//     cannot manage tokens, revoke hosts or delete the account.
//
// Actions: list, create, update, delete, reorder, pair_code, crew_add, crew_add_all,
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
import { starters } from "../_native/profiles.ts";
import { type CrewOffer, crewOffer, crewRefusal, type DescribedRow, describeAgents, readdSort, starter } from "../_native/starters.ts";

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

// NATIVE-1: every person gets Yui and the starter crew, once, the first time
// the app lists agents after native_enabled is switched on. The database does
// the work (yui_native_provision) so two phones opening at once make one crew.
// A failure here never breaks the list.
// deno-lint-ignore no-explicit-any
async function provisionNative(db: any, userId: string) {
  try {
    const { data: hosted } = await db.from("yui_connectors").select("id").eq("user_id", userId).eq("kind", "hosted").limit(1);
    if (hosted?.length) return;
    const { error } = await db.rpc("yui_native_provision", { uid: userId, profs: starters() });
    if (error) console.error("yui_native_provision", error);
  } catch (e) {
    console.error("yui_native_provision", e);
  }
}

// The person's native profiles: base and what each says it does (YUI-165).
// Null when this person has no native Yui (native_enabled off).
// deno-lint-ignore no-explicit-any
async function nativeRows(db: any, userId: string): Promise<DescribedRow[] | null> {
  const { data: hosted } = await db.from("yui_connectors").select("id").eq("user_id", userId)
    .eq("kind", "hosted").is("revoked_at", null).limit(1);
  if (!hosted?.length) return null;
  const { data: rows, error } = await db.from("yui_native_profiles")
    .select("agent_id, base:profile->>base, tagline:profile->>tagline, about:profile->>about, can:profile->can")
    .eq("user_id", userId);
  if (error) throw error;
  return (rows ?? []).map((r: DescribedRow) => ({ ...r, can: Array.isArray(r.can) ? r.can : null }));
}

// YUI-145: the crew in Add agent, by name, with the agent each one is while it
// is in the list.
// deno-lint-ignore no-explicit-any
async function crewFor(db: any, userId: string): Promise<CrewOffer[] | null> {
  const rows = await nativeRows(db, userId);
  return rows && crewOffer(rows);
}

// YUI-165: each starter says what it does, so Add agent can show it before the tap.
// Older apps ignore the fields they don't know.
const crewView = (o: CrewOffer) => ({ base: o.base, name: o.name, role: o.role, color: o.color, agent_id: o.agentId,
                                      tagline: o.tagline, about: o.about, can: o.can });

type Action = { appOnly?: boolean; run: (userId: string, b: Body) => Promise<unknown> };

const ACTIONS: Record<string, Action> = {
  list: {
    async run(userId) {
      const db = admin();
      await provisionNative(db, userId);
      const { data: agents, error } = await db.from("yui_agent_list").select(AGENT_COLUMNS)
        .eq("user_id", userId).order("sort").order("created_at");
      if (error) throw error;
      const { data: connectors, error: e2 } = await db.from("yui_connectors")
        .select("id, name, kind, created_at, last_seen_at")
        .eq("user_id", userId).is("revoked_at", null).order("created_at");
      if (e2) throw e2;
      // An invited person's first name, for "Hi Maya. Sam set these up for you." (YUI-97).
      const { data: invite } = await db.from("yui_invites").select("first_name")
        .eq("claimed_user_id", userId).not("first_name", "is", null)
        .order("claimed_at", { ascending: false }).limit(1).maybeSingle();
      const rows = await nativeRows(db, userId).catch((e) => (console.error("crew", e), null));
      // YUI-165: a native agent carries what it does (About, the picker); others get nothing new.
      const said = rows ? describeAgents(rows) : {};
      const listed = (agents ?? []).map((a: { id: string }) => said[a.id] ? { ...a, ...said[a.id] } : a);
      return { agents: listed, connectors, first_name: invite?.first_name ?? null, crew: rows ? crewOffer(rows).map(crewView) : null };
    },
  },

  // {base}. Puts one starter (Arnold, Basil...) back in the list, after the
  // crew and above paired agents. Nothing else in the list changes. Already
  // there: that agent, added false.
  crew_add: {
    async run(userId, b) {
      const db = admin();
      const prof = starter(b.base);
      if (!prof) throw new HttpError(400, "invalid_base");
      const offer = await crewFor(db, userId);
      const had = offer?.find((o) => o.base === prof.base)?.agentId;
      if (had) return { agent: await agentView(db, userId, had), added: false };
      const { data: listed, error } = await db.from("yui_agents").select("kind, sort").eq("user_id", userId);
      if (error) throw error;
      const why = crewRefusal(offer, prof.base, (listed ?? []).filter((a: { kind: string }) => a.kind === "hosted").length);
      if (why) throw new HttpError(why === "invalid_base" ? 400 : 409, why);
      const { data, error: e2 } = await db.rpc("yui_native_add_agent", { uid: userId, prof, at_sort: readdSort(listed ?? []) });
      if (e2) throw e2;
      const id = Array.isArray(data) ? data[0]?.agent_id : data?.agent_id;
      if (!id) throw new Error("yui_native_add_agent returned no agent");
      return { agent: await agentView(db, userId, id), added: true };
    },
  },

  // Everyone in the crew who isn't in the list, back in one tap (Chris,
  // 2026-09-27: "either have all these agents or ... any number of them").
  // Same rules as crew_add, one at a time; nothing already there changes.
  crew_add_all: {
    async run(userId) {
      const db = admin();
      const offer = await crewFor(db, userId);
      if (!offer) throw new HttpError(409, "native_off");
      const added: string[] = [];
      for (const o of offer) {
        if (o.agentId) continue;
        const prof = starter(o.base);
        if (!prof) continue;
        const { data: listed, error } = await db.from("yui_agents").select("kind, sort").eq("user_id", userId);
        if (error) throw error;
        const why = crewRefusal(offer, prof.base, (listed ?? []).filter((a: { kind: string }) => a.kind === "hosted").length);
        if (why) break;
        const { error: e2 } = await db.rpc("yui_native_add_agent", { uid: userId, prof, at_sort: readdSort(listed ?? []) });
        if (e2) throw e2;
        added.push(o.base);
      }
      return { added };
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
