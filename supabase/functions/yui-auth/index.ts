// yui-auth: Sign in with Apple -> Yui session.
//
//   {grant_type: "apple", identity_token, nonce, authorization_code?}
//   {grant_type: "refresh", refresh_token}
//   {grant_type: "sign_out", refresh_token}
//
// Returns {access_token, expires_in, refresh_token, user}. Yui users never
// enter Supabase Auth (PROOF keeps signups disabled).
import { createRemoteJWKSet, jwtVerify } from "npm:jose@5";
import {
  ACCESS_TTL_SECONDS,
  admin,
  APPLE_ISSUER,
  appleClientId,
  appleClientSecret,
  json,
  mintAccessToken,
  randomToken,
  REFRESH_TTL_DAYS,
  sha256Hex,
} from "../_shared/yui.ts";

const appleKeys = createRemoteJWKSet(new URL(`${APPLE_ISSUER}/auth/keys`));

type Body = {
  grant_type?: string;
  identity_token?: string;
  nonce?: string;
  authorization_code?: string;
  refresh_token?: string;
};

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  let body: Body;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_request" }, 400);
  }
  try {
    switch (body.grant_type) {
      case "apple":
        return await signInWithApple(body);
      case "refresh":
        return await refresh(body.refresh_token);
      case "sign_out":
        return await signOut(body.refresh_token);
      default:
        return json({ error: "unsupported_grant_type" }, 400);
    }
  } catch (e) {
    console.error("yui-auth", e);
    return json({ error: "server_error" }, 500);
  }
});

async function signInWithApple(body: Body): Promise<Response> {
  if (!body.identity_token || !body.nonce) return json({ error: "invalid_request" }, 400);

  let claims;
  try {
    ({ payload: claims } = await jwtVerify(body.identity_token, appleKeys, {
      issuer: APPLE_ISSUER,
      audience: appleClientId(),
      algorithms: ["RS256"],
    }));
  } catch {
    return json({ error: "invalid_grant" }, 401);
  }
  // The app hands Apple sha256(nonce) and sends us the raw nonce.
  if (claims.nonce !== (await sha256Hex(body.nonce)) || typeof claims.sub !== "string") {
    return json({ error: "invalid_grant" }, 401);
  }

  const db = admin();
  const email = typeof claims.email === "string" ? claims.email : null;
  const relay = claims.is_private_email === true || claims.is_private_email === "true";
  const row: Record<string, unknown> = {
    apple_sub: claims.sub,
    last_sign_in_at: new Date().toISOString(),
  };
  // Apple only sends the email on some sign-ins; never blank a stored one.
  if (email) Object.assign(row, { email, email_is_private_relay: relay });
  const { data: user, error } = await db
    .from("yui_users")
    .upsert(row, { onConflict: "apple_sub" })
    .select("id, email, created_at")
    .single();
  if (error) throw error;

  // Keep Apple's refresh token so account deletion can revoke it.
  if (body.authorization_code) {
    const res = await fetch(`${APPLE_ISSUER}/auth/token`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        client_id: appleClientId(),
        client_secret: await appleClientSecret(),
        code: body.authorization_code,
        grant_type: "authorization_code",
      }),
    });
    const tok = await res.json().catch(() => ({}));
    if (res.ok && tok.refresh_token) {
      const { error: e2 } = await db.from("yui_apple_tokens").upsert({
        user_id: user.id,
        refresh_token: tok.refresh_token,
        updated_at: new Date().toISOString(),
      });
      if (e2) throw e2;
    } else {
      console.error("apple token exchange failed", res.status, tok.error);
    }
  }

  return json(await issueSession(user.id, user));
}

async function issueSession(userId: string, user: unknown) {
  const refreshToken = randomToken();
  const { error } = await admin().from("yui_sessions").insert({
    user_id: userId,
    refresh_hash: await sha256Hex(refreshToken),
    expires_at: new Date(Date.now() + REFRESH_TTL_DAYS * 864e5).toISOString(),
  });
  if (error) throw error;
  return {
    access_token: await mintAccessToken(userId),
    token_type: "bearer",
    expires_in: ACCESS_TTL_SECONDS,
    refresh_token: refreshToken,
    user,
  };
}

async function refresh(token?: string): Promise<Response> {
  if (!token) return json({ error: "invalid_request" }, 400);
  const db = admin();
  const { data: s } = await db
    .from("yui_sessions")
    .select("id, user_id, expires_at, revoked_at")
    .eq("refresh_hash", await sha256Hex(token))
    .maybeSingle();
  if (!s) return json({ error: "invalid_grant" }, 401);
  if (s.revoked_at) {
    // A rotated token came back: assume it leaked, end every session.
    await db.from("yui_sessions").update({ revoked_at: new Date().toISOString() })
      .eq("user_id", s.user_id).is("revoked_at", null);
    return json({ error: "invalid_grant" }, 401);
  }
  if (new Date(s.expires_at) < new Date()) return json({ error: "invalid_grant" }, 401);

  const { data: rotated } = await db.from("yui_sessions")
    .update({ revoked_at: new Date().toISOString() })
    .eq("id", s.id).is("revoked_at", null).select("id");
  if (!rotated?.length) return json({ error: "invalid_grant" }, 401);

  const { data: user } = await db.from("yui_users")
    .select("id, email, created_at").eq("id", s.user_id).single();
  return json(await issueSession(s.user_id, user));
}

async function signOut(token?: string): Promise<Response> {
  if (token) {
    await admin().from("yui_sessions").update({ revoked_at: new Date().toISOString() })
      .eq("refresh_hash", await sha256Hex(token)).is("revoked_at", null);
  }
  return json({ ok: true });
}
