// Shared helpers for the Yui account functions. See
// supabase/migrations/20260923230000_yui_accounts.sql for the security model.
import { createClient } from "npm:@supabase/supabase-js@2";
import { importPKCS8, jwtVerify, SignJWT } from "npm:jose@5";

export const APPLE_ISSUER = "https://appleid.apple.com";
export const ACCESS_TTL_SECONDS = 15 * 60;
export const REFRESH_TTL_DAYS = 60;
const ISSUER = "yui-auth";
const AUDIENCE = "yui";

function env(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw new Error(`missing env ${name}`);
  return v;
}

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export function admin() {
  return createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

const jwtKey = () => new TextEncoder().encode(env("YUI_JWT_SECRET"));

// Access token PostgREST accepts as role yui_user. Never role=authenticated:
// that role owns PROOF's portal tables.
export function mintAccessToken(userId: string): Promise<string> {
  return new SignJWT({ role: "yui_user" })
    .setProtectedHeader({ alg: "HS256", typ: "JWT" })
    .setSubject(userId)
    .setIssuer(ISSUER)
    .setAudience(AUDIENCE)
    .setIssuedAt()
    .setExpirationTime(`${ACCESS_TTL_SECONDS}s`)
    .sign(jwtKey());
}

// Host transport token: role yui_connector, scoped by RLS to the threads of
// agents bound to connector `cid` (migration 20260924010000_yui_relay.sql).
export const CONNECTOR_TTL_SECONDS = 60 * 60;
export function mintConnectorToken(userId: string, connectorId: string): Promise<string> {
  return new SignJWT({ role: "yui_connector", cid: connectorId })
    .setProtectedHeader({ alg: "HS256", typ: "JWT" })
    .setSubject(userId)
    .setIssuer("yui-connect")
    .setAudience(AUDIENCE)
    .setIssuedAt()
    .setExpirationTime(`${CONNECTOR_TTL_SECONDS}s`)
    .sign(jwtKey());
}

export async function verifyAccessToken(req: Request): Promise<string> {
  const header = req.headers.get("authorization") ?? "";
  const token = header.replace(/^Bearer\s+/i, "");
  const { payload } = await jwtVerify(token, jwtKey(), {
    issuer: ISSUER,
    audience: AUDIENCE,
    algorithms: ["HS256"],
  });
  if (payload.role !== "yui_user" || typeof payload.sub !== "string") {
    throw new Error("not a yui_user token");
  }
  return payload.sub;
}

export async function sha256Hex(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function randomToken(): string {
  const b = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// Sign in with Apple client secret (ES256, signed with the SIWA key).
export async function appleClientSecret(): Promise<string> {
  const key = await importPKCS8(env("YUI_SIWA_P8"), "ES256");
  return new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: env("YUI_SIWA_KEY_ID") })
    .setIssuer(env("YUI_APPLE_TEAM_ID"))
    .setSubject(env("YUI_SIWA_CLIENT_ID"))
    .setAudience(APPLE_ISSUER)
    .setIssuedAt()
    .setExpirationTime("5m")
    .sign(key);
}

export function appleClientId(): string {
  return env("YUI_SIWA_CLIENT_ID");
}

// Opaque bearer secrets that are not JWTs. Only their SHA-256 is stored.
export const MGMT_PREFIX = "yui_mt_";
export const CONNECTOR_PREFIX = "yui_ct_";

export function bearer(req: Request): string {
  return (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
}

// OAuth tokens for the MCP server (INT-19, functions/yui-oauth). Each points at
// a kind-mcp connector row, so the connector's revoke, suspend and limits
// apply to it.
export const OAUTH_ACCESS_PREFIX = "yui_at_";
export const OAUTH_REFRESH_PREFIX = "yui_rt_";

// RFC 8414 metadata for yui-oauth. yui-oauth serves it, and so does yui-mcp at
// its own .well-known paths: a client that lost the 401's resource_metadata
// (the MCP SDK after the redirect back) falls back to treating the MCP URL as
// the authorization server, and must still find these endpoints.
export function oauthMetadata() {
  const ISSUER = `${env("SUPABASE_URL")}/functions/v1/yui-oauth`;
  return {
    issuer: ISSUER,
    authorization_endpoint: `${ISSUER}/authorize`,
    token_endpoint: `${ISSUER}/token`,
    registration_endpoint: `${ISSUER}/register`,
    revocation_endpoint: `${ISSUER}/revoke`,
    scopes_supported: ["yui"],
    response_types_supported: ["code"],
    response_modes_supported: ["query"],
    grant_types_supported: ["authorization_code", "refresh_token"],
    token_endpoint_auth_methods_supported: ["none", "client_secret_post", "client_secret_basic"],
    revocation_endpoint_auth_methods_supported: ["none", "client_secret_post", "client_secret_basic"],
    code_challenge_methods_supported: ["S256"],
    authorization_response_iss_parameter_supported: true,
    client_id_metadata_document_supported: false,
    service_documentation: "https://www.yuigui.com/developers/mcp",
    // OpenID discovery asks for these; Yui issues no id tokens.
    jwks_uri: `${ISSUER}/jwks`,
    subject_types_supported: ["public"],
    id_token_signing_alg_values_supported: ["ES256"],
  };
}

// The live connector row behind a connector token or an OAuth access token,
// or null (unknown, expired or revoked). Suspension is the caller's check.
// deno-lint-ignore no-explicit-any
export async function connectorByToken(db: any, token: string, columns: string): Promise<any | null> {
  let id: string | null = null;
  if (token.startsWith(OAUTH_ACCESS_PREFIX)) {
    const { data } = await db.from("yui_oauth_tokens").select("connector_id")
      .eq("token_hash", await sha256Hex(token)).eq("kind", "access").is("revoked_at", null)
      .gt("expires_at", new Date().toISOString()).maybeSingle();
    if (!data) return null;
    id = data.connector_id;
  } else if (!token.startsWith(CONNECTOR_PREFIX)) {
    return null;
  }
  let q = db.from("yui_connectors").select(columns).is("revoked_at", null);
  q = id ? q.eq("id", id) : q.eq("token_hash", await sha256Hex(token));
  const { data } = await q.maybeSingle();
  return data ?? null;
}

export const AGENT_COLORS = ["lavender", "mint", "butter", "brand"] as const;
const REMOTE_REF = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/;

export function validRemoteRef(s: unknown): s is string {
  return typeof s === "string" && REMOTE_REF.test(s);
}

export function cleanName(s: unknown): string | null {
  if (typeof s !== "string") return null;
  const t = s.trim().replace(/\s+/g, " ");
  return t.length >= 1 && t.length <= 40 ? t : null;
}

// "yui" -> "Yui", "sean-rush" -> "Sean Rush".
export function nameFromRef(ref: string): string {
  return ref.split(/[-_.]+/).filter(Boolean)
    .map((w) => w[0].toUpperCase() + w.slice(1)).join(" ").slice(0, 40) || "Agent";
}

// An agent's look (yui_agents.theme, spec yuigui/spec/AGENTS.md "Look"). The
// app compiles it into colors and enforces contrast; the server only keeps the
// shape honest: known keys, known words, hex colors, small.
const LOOK_WORDS: Record<string, RegExp> = {
  preset: /^[a-z0-9-]{1,24}$/,
  accent: /^#[0-9A-Fa-f]{6}$/,
  bg: /^#[0-9A-Fa-f]{6}$/,
  radius: /^(round|soft|square|\d{1,2}(\.\d+)?)$/,
  font: /^(rounded|default|serif|mono)$/,
  weight: /^(regular|bold|heavy)$/,
  motion: /^(bouncy|calm|snappy)$/,
  at: /^[0-9T:.+\-Z ]{10,40}$/,
  by: /^(agent|user)$/,
};
const LOOK_STYLE: Record<string, RegExp> = {
  screen: /^(chat|full)$/,
  gallery: /^(row|feed|row3d|grid)$/,
  chart: /^(line|bar|area|scatter|pie|donut)$/,
  buttons: /^(row|stack)$/,
};

// Returns the cleaned look, or null when it is not an object. Unknown keys and
// bad values are dropped, not rejected: an old app never breaks a newer look.
export function cleanLook(v: unknown): Record<string, unknown> | null {
  if (typeof v !== "object" || v === null || Array.isArray(v)) return null;
  const out: Record<string, unknown> = {};
  for (const [k, re] of Object.entries(LOOK_WORDS)) {
    const x = (v as Record<string, unknown>)[k];
    if (typeof x === "string" && re.test(x)) out[k] = x;
  }
  const style = (v as Record<string, unknown>).style;
  if (typeof style === "object" && style !== null && !Array.isArray(style)) {
    const s: Record<string, string> = {};
    for (const [k, re] of Object.entries(LOOK_STYLE)) {
      const x = (style as Record<string, unknown>)[k];
      if (typeof x === "string" && re.test(x)) s[k] = x;
    }
    if (Object.keys(s).length) out.style = s;
  }
  return out;
}

// Stable pastel per name, same rule as the app's YuiTheme.agentColorToken.
export function defaultColor(name: string): string {
  const pastels = ["mint", "lavender", "butter"];
  let n = 0;
  for (const ch of name.toLowerCase()) n += ch.codePointAt(0)!;
  return pastels[n % pastels.length];
}

function slug(name: string): string {
  const s = name.toLowerCase().normalize("NFKD").replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
  return (s || "agent").slice(0, 28);
}

// Creates an agent with a handle unique for the user ("yui", "yui-2", ...).
// deno-lint-ignore no-explicit-any
export async function insertAgent(db: any, row: Record<string, unknown>) {
  const base = slug(row.name as string);
  const { data: taken } = await db.from("yui_agents").select("handle")
    .eq("user_id", row.user_id).like("handle", `${base}%`);
  const used = new Set((taken ?? []).map((r: { handle: string }) => r.handle));
  let handle = base;
  for (let i = 2; used.has(handle); i++) handle = `${base}-${i}`;
  const { data: last } = await db.from("yui_agents").select("sort")
    .eq("user_id", row.user_id).order("sort", { ascending: false }).limit(1);
  const { count } = await db.from("yui_agents").select("id", { count: "exact", head: true })
    .eq("user_id", row.user_id);
  const { data, error } = await db.from("yui_agents").insert({
    handle,
    sort: (last?.[0]?.sort ?? -1) + 1,
    // The first agent is the default.
    is_default: count === 0,
    ...row,
  }).select("id").single();
  if (error) throw error;
  return data.id as string;
}

export const AGENT_COLUMNS =
  "id, name, handle, color, avatar, theme, kind, connector_id, connector_name, remote_ref, status, last_seen_at, is_default, sort, created_at, updated_at, push_muted, presence";

// deno-lint-ignore no-explicit-any
export async function agentView(db: any, userId: string, id: string) {
  const { data, error } = await db.from("yui_agent_list").select(AGENT_COLUMNS)
    .eq("user_id", userId).eq("id", id).single();
  if (error) throw error;
  return data;
}

// Limits and the kill switch (YUI-26, migration 20260924070000_yui_limits.sql).
// The database guards raise SQLSTATE PTxxx and PostgREST answers status xxx;
// `failure` hands that status on instead of a 500. Numbers: README "Limits".
export class Refused extends Error {
  constructor(public status: number, public code: string) {
    super(code);
  }
}

export function failure(where: string, e: unknown): Response {
  if (e instanceof Refused) return json({ error: e.code }, e.status);
  const m = /^PT(\d{3})$/.exec((e as { code?: string })?.code ?? "");
  if (m) return json({ error: (e as { message?: string }).message || "refused" }, Number(m[1]));
  console.error(where, e);
  return json({ error: "server_error" }, 500);
}

// Takes one token from a rate bucket; throws 429 when it is empty. A database
// error lets the call through: a broken limiter must not take Yui down.
// deno-lint-ignore no-explicit-any
export async function take(db: any, key: string, limit: string): Promise<void> {
  const { data, error } = await db.rpc("yui_take", { k: key, lim: limit });
  if (error) console.error("yui_take", key, error);
  else if (data === false) throw new Refused(429, "rate_limited");
}

// Throws 403 when the account is switched off.
// deno-lint-ignore no-explicit-any
export async function assertActive(db: any, userId: string): Promise<void> {
  const { data } = await db.from("yui_users").select("suspended_at").eq("id", userId).maybeSingle();
  if (data?.suspended_at) throw new Refused(403, "account_suspended");
}
