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
//   {action: "heartbeat", serving?}                      Bearer yui_ct_...
//       Marks the host online; returns the agents it serves.
//   {action: "session", serving?}                        Bearer yui_ct_...
//       Trades the connector token for a 60-minute database token (role
//       yui_connector) for Realtime and REST on the threads it serves, plus
//       the current channel guide. Heartbeats too. app_build: the oldest
//       app build among the user's phones seen in the last 14 days (null when
//       none has said), so the host sends only presets that build can draw.
//   sandbox (YUI-95): {<remote_ref>: {terminal, files, reach, memory, runner,
//   profile, extra_keys}} with heartbeat and session, one per profile in
//   serving. Sets yui_agents.client_safe from the five client-safe rules
//   (sandboxFailures); only a client-safe agent can be shared.
//   {action: "bye", serving?}                            Bearer yui_ct_...
//       The host is stopping cleanly (YUI-28): its agents read offline at
//       once instead of asleep. The next heartbeat or session clears it.
//
//   serving (YUI-64): the Hermes profiles this gateway reads threads for,
//   ["yui"]. A gateway is one profile on a computer that may run several, so
//   presence is per agent: an agent paired since the last report naming its
//   profile reads not_listening, and one whose gateway said bye reads offline
//   while the others stay online. `pair` and `add` send [] (a CLI serves
//   nothing) so the computer counts as one that reports. Hosts that never
//   send it keep per-computer presence.
//   {action: "commands", remote_ref, commands}           Bearer yui_ct_...
//       The /commands that profile accepts (YUI-61): [{name, description,
//       args?}], cleaned here, stored on its agents for the composer's
//       suggestions. commands: null clears them.
//   {action: "guide"}                                    no auth
//       The current channel guide {version, body}: the text any agent gets
//       on the Yui channel (yuigui/spec/CHANNEL.md).
//
// Wrong codes are throttled per client address (10 per 10 minutes). Every
// call with a connector token takes from that host's rate bucket, and a
// suspended host or account gets 403 suspended (YUI-26).
import {
  admin,
  AGENT_COLORS,
  agentView,
  bearer,
  cleanName,
  CONNECTOR_PREFIX,
  CONNECTOR_TTL_SECONDS,
  defaultColor,
  failure,
  insertAgent,
  json,
  mintConnectorToken,
  nameFromRef,
  randomToken,
  Refused,
  sha256Hex,
  take,
  validRemoteRef,
} from "../_shared/yui.ts";

const MAX_FAILED_CLAIMS = 10;
const THROTTLE_WINDOW_MS = 10 * 60_000;
const KINDS = ["hermes", "openclaw", "http", "mcp", "hosted"];

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
        return await heartbeat(req, body);
      case "session":
        return await session(req, body);
      case "bye":
        return await bye(req, body);
      case "commands":
        return await commands(req, body);
      case "guide":
        return json({ guide: await guide(admin()) });
      default:
        return json({ error: "unknown_action" }, 400);
    }
  } catch (e) {
    return failure(`yui-connect ${body.action}`, e);
  }
});

async function connectorFor(db: DB, req: Request) {
  const token = bearer(req);
  if (!token.startsWith(CONNECTOR_PREFIX)) return null;
  const { data } = await db.from("yui_connectors").select("id, user_id, name, kind, suspended_at")
    .eq("token_hash", await sha256Hex(token)).is("revoked_at", null).maybeSingle();
  if (!data) return null;
  const { data: owner } = await db.from("yui_users").select("suspended_at").eq("id", data.user_id).maybeSingle();
  if (data.suspended_at || owner?.suspended_at) throw new Refused(403, "suspended");
  await take(db, `connect:c:${data.id}`, "connect");
  const { suspended_at: _, ...connector } = data;
  return connector;
}

// The profiles a gateway says it serves, or null when the host doesn't report.
// deno-lint-ignore no-explicit-any
function servingRefs(v: any): string[] | null {
  if (!Array.isArray(v)) return null;
  return v.filter(validRemoteRef).slice(0, 50);
}

async function reportServing(db: DB, connectorId: string, b: Body): Promise<void> {
  const refs = servingRefs(b.serving);
  if (refs === null) return;
  const { error } = await db.rpc("yui_serving", { connector: connectorId, refs });
  if (error) throw error;
}

// Client-safe (YUI-95, spec yuigui/spec/AGENTS.md "Client-safe"). Each gateway
// reports its profile's sandbox with serving: {sandbox: {<remote_ref>: report}}.
// Same five rules as hermes-plugin/yui/sandbox.py failures(): [] = safe. A
// gateway that serves a profile and sends no report for it clears the mark.
const SANDBOX_KEYS = ["terminal", "files", "reach", "memory", "runner", "profile", "extra_keys"];

// deno-lint-ignore no-explicit-any
function sandboxFailures(r: any): string[] {
  if (!r || typeof r !== "object" || Array.isArray(r)) return ["no sandbox report from its host yet"];
  const out: string[] = [];
  if (r.profile !== "own") out.push("profile: not its own Hermes profile");
  if (typeof r.extra_keys !== "number" || r.extra_keys > 0) {
    out.push(`keys: ${typeof r.extra_keys === "number" ? r.extra_keys : "unknown"} in its .env beyond its model key`);
  }
  if (!["off", "container", "remote"].includes(r.terminal)) out.push("terminal: local shell");
  if (!["off", "sandbox"].includes(r.files)) out.push("files: the host's files");
  if (!Array.isArray(r.reach) || r.reach.length) {
    out.push("reach: " + (Array.isArray(r.reach) ? r.reach.map(String).join(", ") : "unknown"));
  }
  if (!["off", "per-user"].includes(r.memory)) out.push("memory: shared between people");
  if (r.runner !== "api") out.push("runner: a local agent with a shell");
  return out;
}

async function reportSandbox(db: DB, connectorId: string, b: Body): Promise<void> {
  const refs = servingRefs(b.serving);
  if (!refs || !refs.length) return;
  const reports = b.sandbox && typeof b.sandbox === "object" && !Array.isArray(b.sandbox) ? b.sandbox : {};
  const now = new Date().toISOString();
  for (const ref of refs) {
    const raw = reports[ref];
    const clean = raw && typeof raw === "object" && !Array.isArray(raw)
      ? Object.fromEntries(SANDBOX_KEYS.filter((k) => k in raw).map((k) => [k,
        k === "reach" && Array.isArray(raw[k]) ? raw[k].slice(0, 20).map((x: unknown) => String(x).slice(0, 40))
        : typeof raw[k] === "string" ? raw[k].slice(0, 40) : raw[k]]))
      : null;
    const why = sandboxFailures(clean);
    const safe = why.length === 0;
    const sandbox = { ...(clean ?? {}), why, at: now };
    if (safe) {
      // client_safe_at: when it last started passing.
      const { error } = await db.from("yui_agents").update({ sandbox, client_safe: true, client_safe_at: now })
        .eq("connector_id", connectorId).eq("remote_ref", ref).eq("client_safe", false);
      if (error) throw error;
    }
    const { error } = await db.from("yui_agents").update(
      safe ? { sandbox } : { sandbox, client_safe: false, client_safe_at: null },
    ).eq("connector_id", connectorId).eq("remote_ref", ref);
    if (error) throw error;
  }
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
  await reportServing(db, connector.id, b);

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
    await reportServing(db, connector.id, b);
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
  await reportServing(db, connector.id, b);
  return json({ created: true, agent: await agentView(db, connector.user_id, id) });
}

async function heartbeat(req: Request, b: Body): Promise<Response> {
  const db = admin();
  const connector = await connectorFor(db, req);
  if (!connector) return json({ error: "unauthorized" }, 401);
  const now = new Date().toISOString();
  await db.from("yui_connectors").update({ last_seen_at: now, stopped_at: null }).eq("id", connector.id);
  await reportServing(db, connector.id, b);
  await reportSandbox(db, connector.id, b);
  const { data: agents } = await db.from("yui_agents").select("id, name, handle, remote_ref, theme, client_safe")
    .eq("connector_id", connector.id).order("sort");
  return json({ connector: { id: connector.id, name: connector.name }, seen_at: now, agents: agents ?? [] });
}

async function bye(req: Request, b: Body): Promise<Response> {
  const db = admin();
  const connector = await connectorFor(db, req);
  if (!connector) return json({ error: "unauthorized" }, 401);
  const now = new Date().toISOString();
  const refs = servingRefs(b.serving);
  if (refs !== null) {
    // One gateway of several: only its agents go offline, unless it was the last one up.
    const { data: last, error } = await db.rpc("yui_serving_bye", { connector: connector.id, refs });
    if (error) throw error;
    return json({ stopped_at: last ? now : null });
  }
  await db.from("yui_connectors").update({ last_seen_at: now, stopped_at: now }).eq("id", connector.id);
  return json({ stopped_at: now });
}

// A slash command as the composer shows it. Names are what the host accepts
// after the slash; anything else is dropped, never an error, so one odd
// plugin command can't cost the person the whole list.
const COMMAND_NAME = /^[a-z0-9][a-z0-9_-]{0,31}$/;
const MAX_COMMANDS = 200;

// deno-lint-ignore no-explicit-any
function cleanCommands(list: any): { name: string; description: string; args?: string }[] | null {
  if (!Array.isArray(list)) return null;
  const seen = new Set<string>();
  const out = [];
  for (const c of list) {
    if (!c || typeof c !== "object") continue;
    const name = typeof c.name === "string" ? c.name.trim().replace(/^\//, "").toLowerCase() : "";
    if (!COMMAND_NAME.test(name) || seen.has(name)) continue;
    const line = (v: unknown, max: number) =>
      typeof v === "string" ? v.replace(/\s+/g, " ").trim().slice(0, max) : "";
    const description = line(c.description, 100);
    const args = line(c.args, 60);
    seen.add(name);
    out.push(args ? { name, description, args } : { name, description });
    if (out.length >= MAX_COMMANDS) break;
  }
  return out;
}

async function commands(req: Request, b: Body): Promise<Response> {
  const db = admin();
  const connector = await connectorFor(db, req);
  if (!connector) return json({ error: "unauthorized" }, 401);
  if (!validRemoteRef(b.remote_ref)) return json({ error: "invalid_remote_ref" }, 400);
  const list = b.commands === null ? null : cleanCommands(b.commands);
  if (b.commands !== null && list === null) return json({ error: "invalid_commands" }, 400);
  const now = new Date().toISOString();
  const { data, error } = await db.from("yui_agents").update({ commands: list, commands_at: now })
    .eq("connector_id", connector.id).eq("remote_ref", b.remote_ref).select("id");
  if (error) throw error;
  return json({ agents: (data ?? []).length, commands: list?.length ?? 0, at: now });
}

// deno-lint-ignore no-explicit-any
async function guide(db: DB): Promise<any> {
  const { data } = await db.from("yui_channel_guides").select("version, body")
    .order("created_at", { ascending: false }).limit(1).maybeSingle();
  return data;
}

const APP_BUILD_WINDOW_MS = 14 * 24 * 3600_000;

/** Oldest build among the user's phones seen lately (yui-push records it), or null. */
async function appBuild(db: DB, userId: string): Promise<number | null> {
  const since = new Date(Date.now() - APP_BUILD_WINDOW_MS).toISOString();
  const { data } = await db.from("yui_devices").select("app_build").eq("user_id", userId)
    .gte("app_build_at", since).not("app_build", "is", null).order("app_build").limit(1).maybeSingle();
  return data?.app_build ?? null;
}

async function session(req: Request, b: Body): Promise<Response> {
  const db = admin();
  const connector = await connectorFor(db, req);
  if (!connector) return json({ error: "unauthorized" }, 401);
  const now = new Date();
  await db.from("yui_connectors").update({ last_seen_at: now.toISOString(), stopped_at: null })
    .eq("id", connector.id);
  await reportServing(db, connector.id, b);
  await reportSandbox(db, connector.id, b);
  const { data: agents } = await db.from("yui_agents").select("id, name, handle, remote_ref, theme, client_safe")
    .eq("connector_id", connector.id).order("sort");
  return json({
    access_token: await mintConnectorToken(connector.user_id, connector.id),
    expires_at: new Date(now.getTime() + CONNECTOR_TTL_SECONDS * 1000).toISOString(),
    user_id: connector.user_id,
    connector: { id: connector.id, name: connector.name },
    agents: agents ?? [],
    guide: await guide(db),
    app_build: await appBuild(db, connector.user_id),
  });
}
