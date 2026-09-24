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
