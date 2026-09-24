// yui-connect: the agent host's side of the registry (a Mac running Hermes).
// Spec: yuigui/spec/AGENTS.md. Called by `hermes -p <profile> yui pair|add`.
//
//   {action: "pair", code, remote_ref, host_name?, kind?}
//       No auth, or the machine's existing connector token to reuse it.
//       Claims a 6-digit code from the app and binds that agent to this
//       host's profile. Returns the connector token when a new connector
//       was created (shown once, stored hashed).
//   {action: "add", remote_ref, name?, color?}          Bearer yui_ct_...
//       A paired host registers another of its profiles. No code needed.
//   {action: "heartbeat"}                                Bearer yui_ct_...
//       Marks the host online; returns the agents it serves.
//
// Wrong codes are throttled per client address (10 per 10 minutes).
import {
  admin,
  AGENT_COLORS,
  agentView,
  bearer,
  cleanName,
  CONNECTOR_PREFIX,
  defaultColor,
  insertAgent,
  json,
  nameFromRef,
  randomToken,
  sha256Hex,
  validRemoteRef,
} from "../_shared/yui.ts";

const MAX_FAILED_CLAIMS = 10;
const THROTTLE_WINDOW_MS = 10 * 60_000;
const KINDS = ["hermes", "http", "mcp", "hosted"];

// deno-lint-ignore no-explicit-any
type Body = Record<string, any>;
// deno-lint-ignore no-explicit-any
type DB = any;

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  let body: Body;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_request" }, 400);
  }
  try {
    switch (body.action) {
      case "pair":
        return await pair(req, body);
      case "add":
        return await add(req, body);
      case "heartbeat":
        return await heartbeat(req);
      default:
        return json({ error: "unknown_action" }, 400);
    }
  } catch (e) {
    console.error("yui-connect", body.action, e);
    return json({ error: "server_error" }, 500);
  }
});

async function connectorFor(db: DB, req: Request) {
  const token = bearer(req);
  if (!token.startsWith(CONNECTOR_PREFIX)) return null;
  const { data } = await db.from("yui_connectors").select("id, user_id, name, kind")
    .eq("token_hash", await sha256Hex(token)).is("revoked_at", null).maybeSingle();
  return data;
}

function clientIp(req: Request): string {
  return (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() || "unknown";
}

async function pair(req: Request, b: Body): Promise<Response> {
  if (typeof b.code !== "string" || !/^\d{6}$/.test(b.code)) return json({ error: "invalid_code" }, 400);
  if (!validRemoteRef(b.remote_ref)) return json({ error: "invalid_remote_ref" }, 400);
  const kind = b.kind ?? "hermes";
  if (!KINDS.includes(kind)) return json({ error: "invalid_kind" }, 400);
  const db = admin();

  const ip = clientIp(req);
  const since = new Date(Date.now() - THROTTLE_WINDOW_MS).toISOString();
  const { count } = await db.from("yui_pair_attempts").select("id", { count: "exact", head: true })
    .eq("ip", ip).gte("created_at", since);
  if ((count ?? 0) >= MAX_FAILED_CLAIMS) return json({ error: "too_many_attempts" }, 429);

  // Claim the code: single use, so the update itself is the lock.
  const now = new Date().toISOString();
  const { data: claimed } = await db.from("yui_pairings").update({ used_at: now })
    .eq("code_hash", await sha256Hex(`pair:${b.code}`)).is("used_at", null).gt("expires_at", now)
    .select("id, user_id, agent_id");
  const p = claimed?.[0];
  if (!p || !p.agent_id) {
    await db.from("yui_pair_attempts").insert({ ip });
    return json({ error: "invalid_or_expired_code" }, 401);
  }

  // Reuse this machine's connector if it presented one for the same user.
  let connector = await connectorFor(db, req);
  let newToken: string | null = null;
  if (!connector || connector.user_id !== p.user_id) {
    newToken = CONNECTOR_PREFIX + randomToken();
    const hostName = cleanName(b.host_name) ?? "My computer";
    const { data, error } = await db.from("yui_connectors").insert({
      user_id: p.user_id,
      name: hostName,
      kind,
      token_hash: await sha256Hex(newToken),
      last_seen_at: now,
    }).select("id, user_id, name, kind").single();
    if (error) throw error;
    connector = data;
  } else {
    await db.from("yui_connectors").update({ last_seen_at: now }).eq("id", connector.id);
  }

  const { error } = await db.from("yui_agents")
    .update({ connector_id: connector.id, remote_ref: b.remote_ref, kind })
    .eq("id", p.agent_id).eq("user_id", p.user_id);
  if (error) {
    if (error.code === "23505") {
      // That profile is already another agent on this host. Give the code back.
      await db.from("yui_pairings").update({ used_at: null }).eq("id", p.id);
      return json({ error: "profile_already_added", connector_token: newToken }, 409);
    }
    throw error;
  }
  await db.from("yui_pairings").update({ connector_id: connector.id }).eq("id", p.id);

  return json({
    connector: { id: connector.id, name: connector.name, kind: connector.kind },
    connector_token: newToken,
    agent: await agentView(db, p.user_id, p.agent_id),
  });
}

async function add(req: Request, b: Body): Promise<Response> {
  const db = admin();
  const connector = await connectorFor(db, req);
  if (!connector) return json({ error: "unauthorized" }, 401);
  if (!validRemoteRef(b.remote_ref)) return json({ error: "invalid_remote_ref" }, 400);
  if (b.color != null && !AGENT_COLORS.includes(b.color)) return json({ error: "invalid_color" }, 400);
  const name = b.name == null ? nameFromRef(b.remote_ref) : cleanName(b.name);
  if (!name) return json({ error: "invalid_name" }, 400);

  await db.from("yui_connectors").update({ last_seen_at: new Date().toISOString() }).eq("id", connector.id);
  const { data: existing } = await db.from("yui_agents").select("id")
    .eq("connector_id", connector.id).eq("remote_ref", b.remote_ref).maybeSingle();
  if (existing) {
    return json({ created: false, agent: await agentView(db, connector.user_id, existing.id) });
  }
  const id = await insertAgent(db, {
    user_id: connector.user_id,
    name,
    color: b.color ?? defaultColor(name),
    kind: connector.kind,
    connector_id: connector.id,
    remote_ref: b.remote_ref,
  });
  return json({ created: true, agent: await agentView(db, connector.user_id, id) });
}

async function heartbeat(req: Request): Promise<Response> {
  const db = admin();
  const connector = await connectorFor(db, req);
  if (!connector) return json({ error: "unauthorized" }, 401);
  const now = new Date().toISOString();
  await db.from("yui_connectors").update({ last_seen_at: now }).eq("id", connector.id);
  const { data: agents } = await db.from("yui_agents").select("id, name, handle, remote_ref")
    .eq("connector_id", connector.id).order("sort");
  return json({ connector: { id: connector.id, name: connector.name }, seen_at: now, agents: agents ?? [] });
}
