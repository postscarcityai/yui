// yui-push: push notifications (YUI-8). Spec: yuigui/spec/RELAY.md "Push".
//
// App side, Bearer yui_user access token:
//   {action: "register", token, environment?, name?}
//       Stores this phone's APNs device token for the signed-in user. A token
//       that was on another account moves to this one (same phone, new login).
//       environment: "production" (TestFlight/App Store) or "sandbox" (Xcode).
//   {action: "unregister", token}
//       Sign out: this phone stops getting the user's pushes.
//   {action: "presence", token, active, agent_id?}   (YUI-24)
//       The app is open (active: true) on agent_id's thread, or it just went
//       to the background (active: false). Sent on every change and once a
//       minute while open. Stale after PRESENCE_MS: a killed app is closed.
//   register and presence also note the phone's app build (`build`, or the
//   "Yui/<build> CFNetwork" user agent every build sends), so hosts can skip
//   presets that build cannot draw (yui-connect session: app_build).
//
// Host side, Bearer yui_ct_... connector token:
//   {action: "notify", message_id, from?, handoff?}
//       The host just wrote agent message `message_id`. Pushes it to every
//       phone of that user: "<Agent> has something for you in Yui", or a
//       preview of the text. Tapping opens yui://agent/<agent id>/thread.
//       Only for messages in threads of agents bound to this connector,
//       written in the last 10 minutes. `from` names the Hermes profile that
//       handed the message off when it is not the thread's own agent.
//       Skipped (YUI-24): agents the user muted (yui_agents.push_muted), and
//       phones that are open on that agent's thread right now, where the
//       answer already shows. Phones open on another thread still get it.
//
// APNs: token auth (ES256, the APNs key), HTTP/2 straight to Apple. Secrets:
// YUI_APNS_P8, YUI_APNS_KEY_ID, YUI_APPLE_TEAM_ID, YUI_APNS_TOPIC.
import { importPKCS8, SignJWT } from "npm:jose@5";
import {
  admin,
  bearer,
  cleanName,
  connectorByToken,
  failure,
  json,
  Refused,
  take,
  verifyAccessToken,
} from "../_shared/yui.ts";

const NOTIFY_WINDOW_MS = 10 * 60_000;
const PRESENCE_MS = 90_000;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const HOSTS = { production: "https://api.push.apple.com", sandbox: "https://api.sandbox.push.apple.com" };
const TOKEN = /^[0-9a-f]{64,200}$/;

// deno-lint-ignore no-explicit-any
type Body = Record<string, any>;
// deno-lint-ignore no-explicit-any
type DB = any;

function env(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw new Error(`missing env ${name}`);
  return v;
}

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
      case "register":
      case "unregister":
      case "presence": {
        let userId: string;
        try {
          userId = await verifyAccessToken(req);
        } catch {
          return json({ error: "unauthorized" }, 401);
        }
        body.build = appBuild(req, body);
        if (body.action === "presence") return await presence(userId, body);
        return body.action === "register" ? await register(userId, body) : await unregister(userId, body);
      }
      case "notify":
        return await notify(req, body);
      default:
        return json({ error: "unknown_action" }, 400);
    }
  } catch (e) {
    return failure(`yui-push ${body.action}`, e);
  }
});

/** The phone's app build: `build` in the body, else URLSession's "Yui/112 CFNetwork/..." (devbuilds say 112.1). */
function appBuild(req: Request, b: Body): number | null {
  const n = typeof b.build === "number" ? b.build : typeof b.build === "string" ? parseInt(b.build, 10) : NaN;
  if (Number.isInteger(n) && n > 0 && n < 1_000_000) return n;
  const m = /^Yui\/(\d{1,6})(?:\.\d+)?\s+CFNetwork\//.exec(req.headers.get("user-agent") ?? "");
  return m ? parseInt(m[1], 10) : null;
}

function built(b: Body): Record<string, unknown> {
  return b.build ? { app_build: b.build, app_build_at: new Date().toISOString() } : {};
}

async function register(userId: string, b: Body): Promise<Response> {
  const token = typeof b.token === "string" ? b.token.toLowerCase() : "";
  if (!TOKEN.test(token)) return json({ error: "invalid_token" }, 400);
  const environment = b.environment ?? "production";
  if (!(environment in HOSTS)) return json({ error: "invalid_environment" }, 400);
  const { error } = await admin().from("yui_devices").upsert({
    user_id: userId,
    apns_token: token,
    environment,
    name: cleanName(b.name),
    updated_at: new Date().toISOString(),
    last_error: null,
    ...built(b),
  }, { onConflict: "apns_token" });
  if (error) throw error;
  return json({ ok: true });
}

async function unregister(userId: string, b: Body): Promise<Response> {
  const token = typeof b.token === "string" ? b.token.toLowerCase() : "";
  if (!TOKEN.test(token)) return json({ error: "invalid_token" }, 400);
  await admin().from("yui_devices").delete().eq("apns_token", token).eq("user_id", userId);
  return json({ ok: true });
}

async function presence(userId: string, b: Body): Promise<Response> {
  const token = typeof b.token === "string" ? b.token.toLowerCase() : "";
  if (!TOKEN.test(token)) return json({ error: "invalid_token" }, 400);
  if (typeof b.active !== "boolean") return json({ error: "invalid_active" }, 400);
  let agentId: string | null = null;
  if (b.active && b.agent_id != null) {
    if (typeof b.agent_id !== "string" || !UUID.test(b.agent_id)) return json({ error: "invalid_agent_id" }, 400);
    const { data } = await admin().from("yui_agents").select("id").eq("id", b.agent_id).eq("user_id", userId).maybeSingle();
    agentId = data?.id ?? null;
  }
  const { data, error } = await admin().from("yui_devices").update({
    active_at: b.active ? new Date().toISOString() : null,
    active_agent_id: agentId,
    ...built(b),
  }).eq("apns_token", token).eq("user_id", userId).select("id");
  if (error) throw error;
  // Not registered (yet): nothing to track. The app registers first.
  return json({ ok: true, tracked: (data ?? []).length > 0 });
}

async function connectorFor(db: DB, req: Request) {
  // A host's connector token, or an MCP client's OAuth access token (INT-19).
  const data = await connectorByToken(db, bearer(req), "id, user_id, suspended_at");
  if (!data) return null;
  // YUI-26: a suspended host or account pushes nothing; each host has a push budget.
  const { data: owner } = await db.from("yui_users").select("suspended_at").eq("id", data.user_id).maybeSingle();
  if (data.suspended_at || owner?.suspended_at) throw new Refused(403, "suspended");
  await take(db, `push:c:${data.id}`, "push");
  return { id: data.id, user_id: data.user_id };
}

// Text outside ```yui fences, squashed to one line.
function preview(body: string): string {
  return body.replace(/```yui[\s\S]*?(```|$)/g, " ").replace(/\s+/g, " ").trim().slice(0, 160);
}

async function notify(req: Request, b: Body): Promise<Response> {
  const db = admin();
  const connector = await connectorFor(db, req);
  if (!connector) return json({ error: "unauthorized" }, 401);
  if (typeof b.message_id !== "string") return json({ error: "invalid_message_id" }, 400);

  const { data: msg } = await db.from("yui_messages").select("id, user_id, agent_id, sender, body, created_at")
    .eq("id", b.message_id).maybeSingle();
  const { data: agent } = msg
    ? await db.from("yui_agents").select("id, name, connector_id, push_muted").eq("id", msg.agent_id).maybeSingle()
    : { data: null };
  // Same answer for "no such message" and "not yours": no probing other threads.
  if (!msg || !agent || agent.connector_id !== connector.id || msg.user_id !== connector.user_id) {
    return json({ error: "not_found" }, 404);
  }
  if (msg.sender !== "agent") return json({ error: "not_an_agent_message" }, 400);
  if (Date.now() - new Date(msg.created_at).getTime() > NOTIFY_WINDOW_MS) return json({ error: "too_old" }, 409);
  if (agent.push_muted) return json({ ok: true, muted: true, devices: 0, delivered: 0, skipped: 0, results: [] });

  const from = cleanName(b.from);
  const who = from ?? agent.name;
  const text = preview(msg.body);
  const alert = {
    title: agent.name,
    body: b.handoff || from || !text ? `${who} has something for you in Yui` : text,
  };
  const payload = {
    aps: { alert, sound: "default", "thread-id": agent.id, "mutable-content": 1 },
    agent_id: agent.id,
    message_id: msg.id,
    url: `yui://agent/${agent.id}/thread`,
  };

  const { data: all } = await db.from("yui_devices").select("id, apns_token, environment, active_at, active_agent_id")
    .eq("user_id", msg.user_id).not("apns_token", "is", null);
  // Open on this thread right now: the answer is already on screen.
  const watching = (d: DB) =>
    d.active_agent_id === agent.id && d.active_at && Date.now() - new Date(d.active_at).getTime() < PRESENCE_MS;
  const devices = (all ?? []).filter((d: DB) => !watching(d));
  const results = await Promise.all(devices.map((d: DB) => push(db, d, payload)));
  return json({
    ok: true,
    devices: results.length,
    delivered: results.filter((r) => r.ok).length,
    skipped: (all ?? []).length - devices.length,
    results,
  });
}

let jwtCache: { jwt: string; at: number } | null = null;

// Apple wants a fresh provider token at most every 20 min and at least hourly.
async function providerToken(): Promise<string> {
  if (jwtCache && Date.now() - jwtCache.at < 40 * 60_000) return jwtCache.jwt;
  const key = await importPKCS8(env("YUI_APNS_P8"), "ES256");
  const jwt = await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: env("YUI_APNS_KEY_ID") })
    .setIssuer(env("YUI_APPLE_TEAM_ID"))
    .setIssuedAt()
    .sign(key);
  jwtCache = { jwt, at: Date.now() };
  return jwt;
}

async function push(db: DB, d: DB, payload: unknown) {
  const host = HOSTS[d.environment as keyof typeof HOSTS] ?? HOSTS.production;
  const r = await fetch(`${host}/3/device/${d.apns_token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${await providerToken()}`,
      "apns-topic": env("YUI_APNS_TOPIC"),
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });
  const reason = r.status === 200 ? null : ((await r.json().catch(() => ({}))).reason ?? `http_${r.status}`);
  const apnsId = r.headers.get("apns-id");
  if (r.status === 410 || reason === "Unregistered") {
    // App deleted or notifications reset: forget the token.
    await db.from("yui_devices").delete().eq("id", d.id);
  } else {
    await db.from("yui_devices").update(
      reason ? { last_error: reason } : { last_push_at: new Date().toISOString(), last_error: null },
    ).eq("id", d.id);
  }
  return { device: d.id, environment: d.environment, ok: r.status === 200, status: r.status, reason, apns_id: apnsId };
}
