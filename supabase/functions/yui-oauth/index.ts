// yui-oauth: the OAuth 2.1 authorization server for the Yui MCP server
// (INT-19). Spec: yuigui/spec/MCP.md "OAuth". Clients that only speak OAuth
// (the Claude and ChatGPT apps' custom connectors, MCP Inspector) add Yui with
// no token to copy:
//
//   1. POST yui-mcp with no token -> 401, WWW-Authenticate resource_metadata
//      -> GET yui-mcp/.well-known/oauth-protected-resource -> this server.
//   2. GET  yui-oauth/.well-known/oauth-authorization-server (or
//      openid-configuration): the metadata below.
//   3. POST yui-oauth/register: dynamic client registration (RFC 7591).
//   4. GET  yui-oauth/authorize (PKCE S256 required): checks the client and
//      redirect_uri, keeps the request, sends the browser to
//      www.yuigui.com/connect/<request id>. That page asks the person to
//      approve on their phone (yui://connect/<id>, or a QR of the universal
//      link www.yuigui.com/a/<id>), or to type a pairing code from
//      Agents > Add agent. Once approved it redirects back with the code.
//   5. POST yui-oauth/token: authorization_code (+ code_verifier) and
//      refresh_token (single use, rotated; a reused one revokes the grant).
//   6. POST yui-oauth/revoke (RFC 7009).
//
// A grant is a kind-mcp connector row (migration 20260925010000_yui_oauth.sql):
// "remove this computer" in the app, the kill switch and the connector limits
// all apply to its tokens. Only hashes are stored.
//
// JSON API, POST {action, ...} to yui-oauth:
//   request {id}                    web page: what is asking, and its status.
//                                   Once approved, the first call gets the
//                                   redirect back to the client (with the code).
//   code {id, code}                 web page: approve with a pairing code.
//   deny {id}                       web page: the person said no.
//   app_request {id}                app (Yui access token): the request plus
//                                   the agents it may serve.
//   app_approve {id, agent_id?|name?}  app: approve for an existing agent, or
//                                   a new agent (named after the client).
//   app_deny {id}                   app: said no.
import {
  admin,
  cleanName,
  defaultColor,
  failure,
  insertAgent,
  OAUTH_ACCESS_PREFIX,
  OAUTH_REFRESH_PREFIX,
  oauthMetadata,
  randomToken,
  Refused,
  sha256Hex,
  take,
  verifyAccessToken,
} from "../_shared/yui.ts";

const FUNCTIONS = `${Deno.env.get("SUPABASE_URL")}/functions/v1`;
const ISSUER = `${FUNCTIONS}/yui-oauth`;
const RESOURCE = `${FUNCTIONS}/yui-mcp`;
const SITE = "https://www.yuigui.com";
const ACCESS_TTL = 60 * 60;
const REFRESH_TTL = 60 * 24 * 60 * 60;
const CODE_TTL = 5 * 60;
const MAX_FAILED_CODES = 10;
const THROTTLE_WINDOW_MS = 10 * 60_000;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

// deno-lint-ignore no-explicit-any
type Json = any;
// deno-lint-ignore no-explicit-any
type DB = any;

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET, POST, OPTIONS",
  "access-control-allow-headers": "authorization, content-type, accept, mcp-protocol-version, apikey",
};

function out(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "content-type": "application/json", "cache-control": "no-store", ...extra },
  });
}

// RFC 6749 error shape.
class OAuthError extends Error {
  constructor(public status: number, public error: string, public description: string) {
    super(error);
  }
}
const oauthError = (e: OAuthError) =>
  out({ error: e.error, error_description: e.description }, e.status,
    e.status === 401 ? { "www-authenticate": 'Basic realm="yui"' } : {});

const METADATA = oauthMetadata();

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  const path = new URL(req.url).pathname.replace(/^.*?\/yui-oauth/, "").replace(/\/+$/, "") || "/";
  try {
    if (req.method === "GET") {
      if (path === "/.well-known/oauth-authorization-server" || path === "/.well-known/openid-configuration") {
        return out(METADATA, 200, { "cache-control": "public, max-age=300" });
      }
      if (path === "/jwks") return out({ keys: [] }, 200, { "cache-control": "public, max-age=300" });
      if (path === "/authorize") return await authorize(req);
      return out({ error: "not_found" }, 404);
    }
    if (req.method !== "POST") return out({ error: "method_not_allowed" }, 405);
    switch (path) {
      case "/register":
        return await register(req);
      case "/token":
        return await token(req);
      case "/revoke":
        return await revoke(req);
      case "/":
        return await api(req);
      default:
        return out({ error: "not_found" }, 404);
    }
  } catch (e) {
    if (e instanceof OAuthError) return oauthError(e);
    if (e instanceof Refused && e.status === 429) {
      return out({ error: "slow_down", error_description: "Too many requests. Wait a minute." }, 429);
    }
    const r = failure(`yui-oauth ${path}`, e);
    return new Response(r.body, { status: r.status, headers: { ...CORS, "content-type": "application/json" } });
  }
});

function clientIp(req: Request): string {
  return (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() || "unknown";
}

// Form bodies (the OAuth standard) or JSON.
async function params(req: Request): Promise<Record<string, string>> {
  const type = req.headers.get("content-type") ?? "";
  const o: Record<string, string> = {};
  if (type.includes("application/json")) {
    const j = await req.json().catch(() => ({}));
    for (const [k, v] of Object.entries(j ?? {})) if (typeof v === "string") o[k] = v;
  } else {
    for (const [k, v] of new URLSearchParams(await req.text())) o[k] = v;
  }
  return o;
}

async function s256(verifier: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  return btoa(String.fromCharCode(...new Uint8Array(d))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// -- registration ---------------------------------------------------------------

// https anywhere; http only on loopback; a native app's own scheme. Never a
// fragment, never javascript:/data:/file:.
function validRedirect(u: unknown): u is string {
  if (typeof u !== "string" || u.length > 500) return false;
  let url: URL;
  try {
    url = new URL(u);
  } catch {
    return false;
  }
  if (url.hash) return false;
  const scheme = url.protocol.slice(0, -1);
  if (["javascript", "data", "file", "vbscript", "blob", "about"].includes(scheme)) return false;
  if (scheme === "http") return ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
  if (scheme === "https") return !!url.hostname;
  return /^[a-z][a-z0-9+.-]*$/.test(scheme);
}

function optionalUrl(u: unknown): string | null {
  if (typeof u !== "string" || u.length > 500) return null;
  try {
    return new URL(u).protocol === "https:" ? u : null;
  } catch {
    return null;
  }
}

async function register(req: Request): Promise<Response> {
  const db = admin();
  await take(db, `oauth:reg:${clientIp(req)}`, "oauth");
  const b = await req.json().catch(() => null);
  if (!b || typeof b !== "object") throw new OAuthError(400, "invalid_client_metadata", "Send client metadata as JSON.");
  const uris = b.redirect_uris;
  if (!Array.isArray(uris) || !uris.length || uris.length > 10 || !uris.every(validRedirect)) {
    throw new OAuthError(400, "invalid_redirect_uri", "redirect_uris: 1 to 10 https URLs (http only on localhost), no fragments.");
  }
  const method = b.token_endpoint_auth_method ?? "none";
  if (!["none", "client_secret_post", "client_secret_basic"].includes(method)) {
    throw new OAuthError(400, "invalid_client_metadata", "token_endpoint_auth_method: none, client_secret_post or client_secret_basic.");
  }
  const grants = b.grant_types ?? ["authorization_code", "refresh_token"];
  if (!Array.isArray(grants) || !grants.includes("authorization_code") ||
    !grants.every((g: unknown) => g === "authorization_code" || g === "refresh_token")) {
    throw new OAuthError(400, "invalid_client_metadata", "grant_types: authorization_code, refresh_token.");
  }
  if (b.response_types && (!Array.isArray(b.response_types) || b.response_types.some((t: unknown) => t !== "code"))) {
    throw new OAuthError(400, "invalid_client_metadata", "response_types: code.");
  }
  const name = (typeof b.client_name === "string" ? b.client_name.trim().replace(/\s+/g, " ").slice(0, 60) : "") || "MCP client";
  const id = "yui_oc_" + randomToken().slice(0, 32);
  const secret = method === "none" ? null : "yui_cs_" + randomToken();
  const row = {
    id,
    name,
    redirect_uris: uris,
    client_uri: optionalUrl(b.client_uri),
    logo_uri: optionalUrl(b.logo_uri),
    auth_method: method,
    secret_hash: secret ? await sha256Hex(secret) : null,
  };
  const { error } = await db.from("yui_oauth_clients").insert(row);
  if (error) throw error;
  return out({
    client_id: id,
    client_id_issued_at: Math.floor(Date.now() / 1000),
    client_name: name,
    redirect_uris: uris,
    grant_types: grants,
    response_types: ["code"],
    token_endpoint_auth_method: method,
    scope: "yui",
    ...(row.client_uri ? { client_uri: row.client_uri } : {}),
    ...(row.logo_uri ? { logo_uri: row.logo_uri } : {}),
    ...(secret ? { client_secret: secret, client_secret_expires_at: 0 } : {}),
  }, 201);
}

// -- authorize ------------------------------------------------------------------

function redirectTo(url: string): Response {
  return new Response(null, { status: 302, headers: { location: url, "cache-control": "no-store" } });
}

function withParams(uri: string, p: Record<string, string | null | undefined>): string {
  const u = new URL(uri);
  for (const [k, v] of Object.entries(p)) if (v != null) u.searchParams.set(k, v);
  return u.toString();
}

async function authorize(req: Request): Promise<Response> {
  const q = new URL(req.url).searchParams;
  const db = admin();
  await take(db, `oauth:auth:${clientIp(req)}`, "oauth");
  // Until client and redirect_uri check out, errors go to our own page, never
  // to an unverified redirect.
  const clientId = q.get("client_id") ?? "";
  const { data: client } = clientId.startsWith("yui_oc_")
    ? await db.from("yui_oauth_clients").select("id, redirect_uris").eq("id", clientId).maybeSingle()
    : { data: null };
  if (!client) return redirectTo(`${SITE}/connect?error=unknown_client`);
  const redirectUri = q.get("redirect_uri") ?? (client.redirect_uris.length === 1 ? client.redirect_uris[0] : "");
  if (!client.redirect_uris.includes(redirectUri)) return redirectTo(`${SITE}/connect?error=bad_redirect`);

  const state = q.get("state");
  const back = (error: string, description: string) =>
    redirectTo(withParams(redirectUri, { error, error_description: description, state, iss: ISSUER }));
  if (q.get("response_type") !== "code") return back("unsupported_response_type", "response_type must be code.");
  const challenge = q.get("code_challenge") ?? "";
  if (q.get("code_challenge_method") !== "S256" || !/^[A-Za-z0-9_-]{43}$/.test(challenge)) {
    return back("invalid_request", "PKCE is required: code_challenge with code_challenge_method S256.");
  }
  const resource = q.get("resource");
  if (resource && resource.replace(/\/+$/, "") !== RESOURCE) return back("invalid_target", `The only resource here is ${RESOURCE}.`);
  if (state && state.length > 500) return back("invalid_request", "state is too long.");

  // Old requests go away as new ones come in.
  await db.from("yui_oauth_requests").delete().lt("created_at", new Date(Date.now() - 86400_000).toISOString());
  const { data, error } = await db.from("yui_oauth_requests").insert({
    client_id: client.id,
    redirect_uri: redirectUri,
    state,
    code_challenge: challenge,
    resource: resource ?? RESOURCE,
  }).select("id").single();
  if (error) throw error;
  return redirectTo(`${SITE}/connect/${data.id}`);
}

// -- the approval API (web page and app) ------------------------------------------

async function loadRequest(db: DB, id: unknown) {
  if (typeof id !== "string" || !UUID.test(id)) throw new OAuthError(400, "invalid_request", "Unknown request.");
  const { data } = await db.from("yui_oauth_requests")
    .select("id, client_id, redirect_uri, state, status, expires_at, code_hash, user_id, agent_id, yui_oauth_clients(name, client_uri)")
    .eq("id", id).maybeSingle();
  if (!data) throw new OAuthError(404, "invalid_request", "Unknown request.");
  return data;
}

function describe(r: Json) {
  const expired = r.status === "pending" && new Date(r.expires_at).getTime() < Date.now();
  return {
    id: r.id,
    client: { name: r.yui_oauth_clients?.name ?? "MCP client", site: siteOf(r.redirect_uri), url: r.yui_oauth_clients?.client_uri ?? null },
    status: expired ? "expired" : r.status,
    expires_at: r.expires_at,
  };
}

// "claude.ai" for https://claude.ai/api/mcp/auth_callback, "cursor" for cursor://...
function siteOf(uri: string): string {
  try {
    const u = new URL(uri);
    return u.protocol === "https:" || u.protocol === "http:" ? u.host : u.protocol.slice(0, -1);
  } catch {
    return "";
  }
}

function assertPending(r: Json) {
  if (r.status !== "pending") throw new OAuthError(409, "invalid_request", `This request is ${r.status} already.`);
  if (new Date(r.expires_at).getTime() < Date.now()) {
    throw new OAuthError(410, "invalid_request", "This request expired. Add the connector again.");
  }
}

async function api(req: Request): Promise<Response> {
  const db = admin();
  const b = await req.json().catch(() => ({}));
  switch (b?.action) {
    case "request": {
      // Polled by the web page every few seconds, so no rate bucket: the id is
      // a random UUID and all it can hand out is a code bound to PKCE.
      const r = await loadRequest(db, b.id);
      const view: Json = describe(r);
      if (r.status === "approved" && !r.code_hash) {
        const code = "yui_ac_" + randomToken();
        const { data } = await db.from("yui_oauth_requests").update({
          code_hash: await sha256Hex(code),
          code_expires_at: new Date(Date.now() + CODE_TTL * 1000).toISOString(),
        }).eq("id", r.id).eq("status", "approved").is("code_hash", null).select("id");
        if (data?.length) view.redirect = withParams(r.redirect_uri, { code, state: r.state, iss: ISSUER });
      } else if (r.status === "denied") {
        view.redirect = withParams(r.redirect_uri, { error: "access_denied", error_description: "The person said no in Yui.", state: r.state, iss: ISSUER });
      }
      return out(view);
    }
    case "deny": {
      const r = await loadRequest(db, b.id);
      assertPending(r);
      await db.from("yui_oauth_requests").update({ status: "denied", decided_at: new Date().toISOString() })
        .eq("id", r.id).eq("status", "pending");
      return out({ ...describe({ ...r, status: "denied" }),
        redirect: withParams(r.redirect_uri, { error: "access_denied", error_description: "The person said no in Yui.", state: r.state, iss: ISSUER }) });
    }
    case "code":
      return await approveWithCode(req, db, b);
    case "app_request":
    case "app_approve":
    case "app_deny": {
      let userId: string;
      try {
        userId = await verifyAccessToken(req);
      } catch {
        return out({ error: "unauthorized" }, 401);
      }
      const { data: owner } = await db.from("yui_users").select("suspended_at").eq("id", userId).maybeSingle();
      if (!owner) return out({ error: "unauthorized" }, 401);
      if (owner.suspended_at) return out({ error: "account_suspended" }, 403);
      await take(db, `oauth:u:${userId}`, "oauth");
      const r = await loadRequest(db, b.id);
      if (b.action === "app_request") {
        return out({ ...describe(r), agents: await eligibleAgents(db, userId), suggested_name: agentName(r) });
      }
      assertPending(r);
      if (b.action === "app_deny") {
        await db.from("yui_oauth_requests").update({ status: "denied", user_id: userId, via: "app", decided_at: new Date().toISOString() })
          .eq("id", r.id).eq("status", "pending");
        return out(describe({ ...r, status: "denied" }));
      }
      const agent = await approve(db, r, userId, "app", b.agent_id ?? null, b.name ?? null);
      return out({ ...describe({ ...r, status: "approved" }), agent });
    }
    default:
      return out({ error: "unknown_action" }, 400);
  }
}

// Agents an MCP grant may take: ones already served by an MCP client, and ones
// not bound to any host yet. Never a Hermes or OpenClaw agent: that would pull
// it off its computer.
async function eligibleAgents(db: DB, userId: string) {
  const { data } = await db.from("yui_agents").select("id, name, handle, color, kind, connector_id")
    .eq("user_id", userId).order("sort");
  return (data ?? []).filter((a: Json) => a.kind === "mcp" || !a.connector_id)
    .map((a: Json) => ({ id: a.id, name: a.name, handle: a.handle, color: a.color }));
}

function agentName(r: Json): string {
  return cleanName(r.yui_oauth_clients?.name) ?? "MCP";
}

function refFor(name: string): string {
  return name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 60) || "mcp";
}

// The grant: a new kind-mcp connector named after the client, serving the
// chosen agent (or a new one). Returns the agent {id, name}.
async function approve(db: DB, r: Json, userId: string, via: "app" | "code", agentId: string | null, name: string | null) {
  const clientName = agentName(r);
  let agent: { id: string; name: string; connector_id: string | null } | null = null;
  if (agentId) {
    const ok = (await eligibleAgents(db, userId)).find((a: Json) => a.id === agentId);
    if (!ok) throw new OAuthError(400, "invalid_request", "That agent can't take an MCP connection.");
    const { data } = await db.from("yui_agents").select("id, name, connector_id").eq("id", agentId).eq("user_id", userId).single();
    agent = data;
  }
  const { data: connector, error } = await db.from("yui_connectors").insert({
    user_id: userId,
    name: clientName,
    kind: "mcp",
    // Nobody holds a token for this row: OAuth tokens point at it instead.
    token_hash: await sha256Hex("oauth:" + randomToken()),
    last_seen_at: new Date().toISOString(),
  }).select("id").single();
  if (error) throw error;

  if (agent) {
    const old = agent.connector_id;
    const { error: e } = await db.from("yui_agents")
      .update({ connector_id: connector.id, remote_ref: refFor(agent.name), kind: "mcp" })
      .eq("id", agent.id).eq("user_id", userId);
    if (e) throw e;
    // The client's older grant for this agent now serves nothing: close it.
    if (old) {
      const { count } = await db.from("yui_agents").select("id", { count: "exact", head: true }).eq("connector_id", old);
      if (!count) await db.from("yui_connectors").update({ revoked_at: new Date().toISOString() }).eq("id", old).eq("kind", "mcp");
    }
  } else {
    const n = cleanName(name) ?? clientName;
    const id = await insertAgent(db, {
      user_id: userId,
      name: n,
      color: defaultColor(n),
      kind: "mcp",
      connector_id: connector.id,
      remote_ref: refFor(n),
    });
    agent = { id, name: n, connector_id: connector.id };
  }

  const { data: done } = await db.from("yui_oauth_requests").update({
    status: "approved",
    user_id: userId,
    connector_id: connector.id,
    agent_id: agent.id,
    via,
    decided_at: new Date().toISOString(),
  }).eq("id", r.id).eq("status", "pending").select("id");
  if (!done?.length) {
    // Someone decided first (a double tap): undo this grant.
    await db.from("yui_connectors").update({ revoked_at: new Date().toISOString() }).eq("id", connector.id);
    throw new OAuthError(409, "invalid_request", "This request was decided already.");
  }
  return { id: agent.id, name: agent.name };
}

// The web page's way in with no app hand-off: the 6-digit code the app shows
// under Agents > Add agent. Same throttle as a host's pairing.
async function approveWithCode(req: Request, db: DB, b: Json): Promise<Response> {
  const r = await loadRequest(db, b.id);
  assertPending(r);
  const code = typeof b.code === "string" ? b.code.replace(/\D/g, "") : "";
  if (code.length !== 6) return out({ error: "invalid_code" }, 400);
  const ip = clientIp(req);
  const since = new Date(Date.now() - THROTTLE_WINDOW_MS).toISOString();
  const { count } = await db.from("yui_pair_attempts").select("id", { count: "exact", head: true })
    .eq("ip", ip).gte("created_at", since);
  if ((count ?? 0) >= MAX_FAILED_CODES) return out({ error: "too_many_attempts" }, 429);

  const now = new Date().toISOString();
  const { data: claimed } = await db.from("yui_pairings").update({ used_at: now })
    .eq("code_hash", await sha256Hex(`pair:${code}`)).is("used_at", null).gt("expires_at", now)
    .select("id, user_id, agent_id");
  const p = claimed?.[0];
  if (!p || !p.agent_id) {
    await db.from("yui_pair_attempts").insert({ ip });
    return out({ error: "invalid_or_expired_code" }, 401);
  }
  const { data: owner } = await db.from("yui_users").select("suspended_at").eq("id", p.user_id).maybeSingle();
  if (owner?.suspended_at) return out({ error: "account_suspended" }, 403);
  // The code's agent was just made by Add agent and is not bound to a host.
  const agent = await approve(db, r, p.user_id, "code", p.agent_id, null);
  const { data: grant } = await db.from("yui_oauth_requests").select("connector_id").eq("id", r.id).single();
  await db.from("yui_pairings").update({ connector_id: grant.connector_id }).eq("id", p.id);
  return out({ ...describe({ ...r, status: "approved" }), agent });
}

// -- token ----------------------------------------------------------------------

// Client authentication: public clients send client_id; confidential ones a
// secret in the body or HTTP Basic.
async function authClient(db: DB, req: Request, p: Record<string, string>) {
  let id = p.client_id ?? "";
  let secret = p.client_secret ?? "";
  const basic = (req.headers.get("authorization") ?? "").match(/^Basic\s+(.+)$/i);
  if (basic) {
    try {
      const [u, s] = atob(basic[1]).split(":");
      id = decodeURIComponent(u);
      secret = decodeURIComponent(s ?? "");
    } catch {
      throw new OAuthError(401, "invalid_client", "Bad Basic credentials.");
    }
  }
  const { data: c } = id.startsWith("yui_oc_")
    ? await db.from("yui_oauth_clients").select("id, name, auth_method, secret_hash").eq("id", id).maybeSingle()
    : { data: null };
  if (!c) throw new OAuthError(401, "invalid_client", "Unknown client. Register again.");
  if (c.auth_method !== "none" && (!secret || (await sha256Hex(secret)) !== c.secret_hash)) {
    throw new OAuthError(401, "invalid_client", "Client authentication failed.");
  }
  await db.from("yui_oauth_clients").update({ last_used_at: new Date().toISOString() }).eq("id", c.id);
  return c;
}

async function issue(db: DB, clientId: string, userId: string, connectorId: string, requestId: string | null) {
  const access = OAUTH_ACCESS_PREFIX + randomToken();
  const refresh = OAUTH_REFRESH_PREFIX + randomToken();
  const now = Date.now();
  const base = { client_id: clientId, user_id: userId, connector_id: connectorId, request_id: requestId };
  const { error } = await db.from("yui_oauth_tokens").insert([
    { ...base, kind: "access", token_hash: await sha256Hex(access), expires_at: new Date(now + ACCESS_TTL * 1000).toISOString() },
    { ...base, kind: "refresh", token_hash: await sha256Hex(refresh), expires_at: new Date(now + REFRESH_TTL * 1000).toISOString() },
  ]);
  if (error) throw error;
  return out({ access_token: access, token_type: "Bearer", expires_in: ACCESS_TTL, refresh_token: refresh, scope: "yui" });
}

// The connector behind a grant must still be live: removed in the app, or a
// suspended connector or account, and the grant is gone.
async function assertGrantLive(db: DB, connectorId: string) {
  const { data: c } = await db.from("yui_connectors").select("revoked_at, suspended_at, user_id").eq("id", connectorId).maybeSingle();
  if (!c || c.revoked_at) throw new OAuthError(400, "invalid_grant", "This connection was removed in Yui. Connect again.");
  const { data: u } = await db.from("yui_users").select("suspended_at").eq("id", c.user_id).maybeSingle();
  if (c.suspended_at || u?.suspended_at) throw new OAuthError(400, "invalid_grant", "This Yui account or connection is switched off.");
}

async function revokeGrant(db: DB, connectorId: string) {
  const now = new Date().toISOString();
  await db.from("yui_oauth_tokens").update({ revoked_at: now }).eq("connector_id", connectorId).is("revoked_at", null);
  await db.from("yui_connectors").update({ revoked_at: now }).eq("id", connectorId).eq("kind", "mcp").is("revoked_at", null);
}

async function token(req: Request): Promise<Response> {
  const db = admin();
  const p = await params(req);
  const client = await authClient(db, req, p);
  await take(db, `oauth:tok:${client.id}`, "oauth");

  if (p.grant_type === "authorization_code") {
    const code = p.code ?? "";
    if (!code.startsWith("yui_ac_")) throw new OAuthError(400, "invalid_grant", "Unknown code.");
    const hash = await sha256Hex(code);
    const { data: r } = await db.from("yui_oauth_requests")
      .select("id, client_id, redirect_uri, code_challenge, status, code_expires_at, user_id, connector_id")
      .eq("code_hash", hash).maybeSingle();
    if (!r || r.client_id !== client.id) throw new OAuthError(400, "invalid_grant", "Unknown code.");
    if (r.status === "used") {
      // A code played twice: whoever has it, the tokens it gave are no longer trusted.
      await db.from("yui_oauth_tokens").update({ revoked_at: new Date().toISOString() }).eq("request_id", r.id).is("revoked_at", null);
      throw new OAuthError(400, "invalid_grant", "This code was used already.");
    }
    if (r.status !== "approved" || new Date(r.code_expires_at).getTime() < Date.now()) {
      throw new OAuthError(400, "invalid_grant", "This code expired.");
    }
    if (p.redirect_uri && p.redirect_uri !== r.redirect_uri) throw new OAuthError(400, "invalid_grant", "redirect_uri does not match.");
    if (!p.code_verifier || !/^[A-Za-z0-9._~-]{43,128}$/.test(p.code_verifier) || (await s256(p.code_verifier)) !== r.code_challenge) {
      throw new OAuthError(400, "invalid_grant", "PKCE check failed: code_verifier does not match.");
    }
    const { data: used } = await db.from("yui_oauth_requests").update({ status: "used" })
      .eq("id", r.id).eq("status", "approved").select("id");
    if (!used?.length) throw new OAuthError(400, "invalid_grant", "This code was used already.");
    await assertGrantLive(db, r.connector_id);
    return await issue(db, client.id, r.user_id, r.connector_id, r.id);
  }

  if (p.grant_type === "refresh_token") {
    const t = p.refresh_token ?? "";
    if (!t.startsWith(OAUTH_REFRESH_PREFIX)) throw new OAuthError(400, "invalid_grant", "Unknown refresh token.");
    const { data: row } = await db.from("yui_oauth_tokens")
      .select("id, client_id, user_id, connector_id, request_id, expires_at, used_at, revoked_at")
      .eq("token_hash", await sha256Hex(t)).eq("kind", "refresh").maybeSingle();
    if (!row || row.client_id !== client.id) throw new OAuthError(400, "invalid_grant", "Unknown refresh token.");
    if (row.revoked_at) throw new OAuthError(400, "invalid_grant", "This connection was removed. Connect again.");
    if (row.used_at) {
      // Rotation: an old refresh token played again means it leaked.
      await revokeGrant(db, row.connector_id);
      throw new OAuthError(400, "invalid_grant", "Refresh token reused: the connection is revoked. Connect again.");
    }
    if (new Date(row.expires_at).getTime() < Date.now()) throw new OAuthError(400, "invalid_grant", "Refresh token expired. Connect again.");
    const { data: marked } = await db.from("yui_oauth_tokens").update({ used_at: new Date().toISOString() })
      .eq("id", row.id).is("used_at", null).select("id");
    if (!marked?.length) {
      await revokeGrant(db, row.connector_id);
      throw new OAuthError(400, "invalid_grant", "Refresh token reused: the connection is revoked. Connect again.");
    }
    await assertGrantLive(db, row.connector_id);
    return await issue(db, client.id, row.user_id, row.connector_id, row.request_id);
  }

  throw new OAuthError(400, "unsupported_grant_type", "grant_type: authorization_code or refresh_token.");
}

// RFC 7009. A refresh token ends the whole grant (the connector); an access
// token only itself. Unknown tokens answer 200 too.
async function revoke(req: Request): Promise<Response> {
  const db = admin();
  const p = await params(req);
  const client = await authClient(db, req, p);
  await take(db, `oauth:tok:${client.id}`, "oauth");
  const t = p.token ?? "";
  if (t.startsWith(OAUTH_ACCESS_PREFIX) || t.startsWith(OAUTH_REFRESH_PREFIX)) {
    const { data: row } = await db.from("yui_oauth_tokens").select("id, kind, client_id, connector_id")
      .eq("token_hash", await sha256Hex(t)).maybeSingle();
    if (row && row.client_id === client.id) {
      if (row.kind === "refresh") await revokeGrant(db, row.connector_id);
      else await db.from("yui_oauth_tokens").update({ revoked_at: new Date().toISOString() }).eq("id", row.id);
    }
  }
  return new Response(null, { status: 200, headers: CORS });
}

