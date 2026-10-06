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
//   register also notes which app the token is for (YUI-91): `bundle`, or a
//   test build's "Yui/<n>.<m>" user agent means Yui Dev (<topic>.dev).
//   register and presence also note the phone's app build (`build`, or the
//   "Yui/<build> CFNetwork" user agent every build sends), so hosts can skip
//   presets that build cannot draw (yui-connect session: app_build).
//
//   {action: "register_web", endpoint, keys: {p256dh, auth}, name?}   (YUI-248)
//       The same for a browser: a Web Push subscription (VAPID, public key in the site's
//       lib/web/push.mjs). Stored next to the APNs tokens in yui_devices (no apns_token).
//       `tz` (an IANA zone, "America/New_York") is the browser's time zone; reminders read in it (YUI-258).
//   {action: "unregister_web", endpoint}
//       Sign out, or the person turned notifications off in that browser.
//   presence also takes `endpoint` in place of `token` for a browser. When a device reports it is
//   reading an agent's thread, the person's other browsers get a quiet "clear" push: the page closes
//   that agent's notification (no double buzz).
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
// Server side, Bearer the service role key (grant.py, YUI-97):
//   {action: "notify", message_id, native: true}
//       A native agent's reply (yui-native, NATIVE-1): as the host's notify,
//       for agents on a hosted connector.
//   {action: "revoked", agent_id, user_id}
//       A grant was just revoked. A silent push (kind "revoked", no content)
//       to every phone of that person, so the app refreshes its agent list at
//       once and closes the thread if it is open. Only for a grant that is
//       revoked now: a live one pushes nothing.
//
// Widget side, header x-yui-widgets (the database trigger, YUI-40 step 4):
//   {action: "widgets", ids: [yui_widgets row ids]}
//       An agent patched a lasting id on a screen a phone has pinned: send that phone's
//       widget a WidgetKit push (apns-push-type: widgets). The database already decided
//       which rows are due (one per pinned screen per 15 minutes, a timer at once).
//       Rows of one phone share a push token: it gets one push.
//
//   {action: "reminders", due: [{user_id, agent_id, key, text}]}
//       The minute tick (yui_web_reminders_tick, YUI-258) claimed reminders an agent set that are due now.
//       Each goes as a Web Push (kind "reminder") to that person's browsers only, closed tab or open, and
//       never skipped for an open thread: the service worker drops a double of the tab's own notification.
//
// APNs: token auth (ES256, the APNs key), HTTP/2 straight to Apple. Secrets:
// YUI_APNS_P8, YUI_APNS_KEY_ID, YUI_APPLE_TEAM_ID, YUI_APNS_TOPIC. Yui Dev
// phones push to YUI_APNS_TOPIC + ".dev" with the same key (yui_devices.topic).
import { withCors } from "../_shared/cors.ts";
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
import { apnsPayload, reminderPayload, webPayload, webQuiet, widgetPush } from "./payload.ts";
import { sendWeb, validEndpoint, validKey, validTz } from "./web.ts";

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

Deno.serve(withCors(async (req) => {
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
      case "register_web":
      case "unregister_web":
      case "presence": {
        let userId: string;
        try {
          userId = await verifyAccessToken(req);
        } catch {
          return json({ error: "unauthorized" }, 401);
        }
        body.build = appBuild(req, body);
        if (body.action === "presence") return await presence(userId, body);
        if (body.action === "register_web") return await registerWeb(userId, body);
        if (body.action === "unregister_web") return await unregisterWeb(userId, body);
        return body.action === "register"
          ? await register(userId, body, topicFor(req, body))
          : await unregister(userId, body);
      }
      case "notify":
        return await notify(req, body);
      case "revoked":
        return await revoked(req, body);
      case "widgets":
        return await widgets(req, body);
      case "reminders":
        return await reminders(req, body);
      default:
        return json({ error: "unknown_action" }, 400);
    }
  } catch (e) {
    return failure(`yui-push ${body.action}`, e);
  }
}));

/** The phone's app build: `build` in the body, else URLSession's "Yui/112 CFNetwork/..." (devbuilds say 112.1). */
function appBuild(req: Request, b: Body): number | null {
  const n = typeof b.build === "number" ? b.build : typeof b.build === "string" ? parseInt(b.build, 10) : NaN;
  if (Number.isInteger(n) && n > 0 && n < 1_000_000) return n;
  const m = /^Yui\/(\d{1,6})(?:\.\d+)?\s+CFNetwork\//.exec(req.headers.get("user-agent") ?? "");
  return m ? parseInt(m[1], 10) : null;
}

/** The APNs topic for this token: null for the main app, "<topic>.dev" for Yui Dev. */
function topicFor(req: Request, b: Body): string | null {
  const main = env("YUI_APNS_TOPIC");
  if (typeof b.bundle === "string") return b.bundle === `${main}.dev` ? b.bundle : null;
  // Test builds by link are numbered <commit count>.<n>; TestFlight builds never have a dot.
  return /^Yui\/\d{1,6}\.\d+\s+CFNetwork\//.test(req.headers.get("user-agent") ?? "") ? `${main}.dev` : null;
}

function built(b: Body): Record<string, unknown> {
  return b.build ? { app_build: b.build, app_build_at: new Date().toISOString() } : {};
}

async function register(userId: string, b: Body, topic: string | null): Promise<Response> {
  const token = typeof b.token === "string" ? b.token.toLowerCase() : "";
  if (!TOKEN.test(token)) return json({ error: "invalid_token" }, 400);
  const environment = b.environment ?? "production";
  if (!(environment in HOSTS)) return json({ error: "invalid_environment" }, 400);
  const { error } = await admin().from("yui_devices").upsert({
    user_id: userId,
    apns_token: token,
    environment,
    topic,
    name: cleanName(b.name),
    updated_at: new Date().toISOString(),
    last_error: null,
    ...built(b),
  }, { onConflict: "apns_token" });
  if (error) throw error;
  return json({ ok: true });
}

async function registerWeb(userId: string, b: Body): Promise<Response> {
  if (!validEndpoint(b.endpoint)) return json({ error: "invalid_endpoint" }, 400);
  if (!validKey(b.keys?.p256dh) || !validKey(b.keys?.auth)) return json({ error: "invalid_keys" }, 400);
  const { error } = await admin().from("yui_devices").upsert({
    user_id: userId,
    apns_token: null,
    web_endpoint: b.endpoint,
    web_p256dh: b.keys.p256dh,
    web_auth: b.keys.auth,
    // The browser's time zone (YUI-258): a reminder's `at` is the person's local time. Absent keeps the last one.
    ...(validTz(b.tz) ? { web_tz: b.tz } : {}),
    environment: "production",
    topic: null,
    name: cleanName(b.name),
    updated_at: new Date().toISOString(),
    last_error: null,
  }, { onConflict: "web_endpoint" });
  if (error) throw error;
  return json({ ok: true });
}

async function unregisterWeb(userId: string, b: Body): Promise<Response> {
  if (!validEndpoint(b.endpoint)) return json({ error: "invalid_endpoint" }, 400);
  await admin().from("yui_devices").delete().eq("web_endpoint", b.endpoint).eq("user_id", userId);
  return json({ ok: true });
}

/** Another device of this person is reading `agentId`: tell their other browsers (quietly) to clear it. */
async function clearElsewhere(userId: string, agentId: string, exceptDevice: string) {
  const db = admin();
  const { data } = await db.from("yui_devices").select("id, web_endpoint, web_p256dh, web_auth")
    .eq("user_id", userId).not("web_endpoint", "is", null).neq("id", exceptDevice);
  await Promise.all((data ?? []).map((d: DB) => sendWeb(db, d, webQuiet("clear", agentId), true).catch(() => null)));
}

async function unregister(userId: string, b: Body): Promise<Response> {
  const token = typeof b.token === "string" ? b.token.toLowerCase() : "";
  if (!TOKEN.test(token)) return json({ error: "invalid_token" }, 400);
  await admin().from("yui_devices").delete().eq("apns_token", token).eq("user_id", userId);
  return json({ ok: true });
}

async function presence(userId: string, b: Body): Promise<Response> {
  const web = typeof b.endpoint === "string";
  const token = typeof b.token === "string" ? b.token.toLowerCase() : "";
  if (web ? !validEndpoint(b.endpoint) : !TOKEN.test(token)) return json({ error: web ? "invalid_endpoint" : "invalid_token" }, 400);
  if (typeof b.active !== "boolean") return json({ error: "invalid_active" }, 400);
  let agentId: string | null = null;
  if (b.active && b.agent_id != null) {
    if (typeof b.agent_id !== "string" || !UUID.test(b.agent_id)) return json({ error: "invalid_agent_id" }, 400);
    const { data } = await admin().from("yui_agents").select("id").eq("id", b.agent_id).eq("user_id", userId).maybeSingle();
    const { data: g } = data ? { data: null } : await admin().from("yui_agent_grants").select("agent_id")
      .eq("agent_id", b.agent_id).eq("user_id", userId).is("revoked_at", null).maybeSingle();
    agentId = data?.id ?? g?.agent_id ?? null;
  }
  const col = web ? "web_endpoint" : "apns_token";
  const { data, error } = await admin().from("yui_devices").update({
    active_at: b.active ? new Date().toISOString() : null,
    active_agent_id: agentId,
    ...(web ? {} : built(b)),
  }).eq(col, web ? b.endpoint : token).eq("user_id", userId).select("id");
  if (error) throw error;
  // Read here: the person's other browsers drop that agent's notification, so one reply never sits on two screens.
  if (agentId && (data ?? []).length) await clearElsewhere(userId, agentId, (data ?? [])[0].id);
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

// A native agent's reply (NATIVE-1): yui-native calls with the service key, and
// the connector is the hosted one the message's agent sits on.
async function nativeConnector(db: DB, messageId: unknown) {
  if (typeof messageId !== "string") return null;
  const { data: msg } = await db.from("yui_messages").select("user_id, agent_id").eq("id", messageId).maybeSingle();
  if (!msg) return null;
  const { data: agent } = await db.from("yui_agents").select("connector_id, kind").eq("id", msg.agent_id).maybeSingle();
  if (!agent || agent.kind !== "hosted" || !agent.connector_id) return null;
  return { id: agent.connector_id as string, user_id: msg.user_id as string };
}

async function notify(req: Request, b: Body): Promise<Response> {
  const db = admin();
  const connector = b.native === true && await isService(req) ? await nativeConnector(db, b.message_id) : await connectorFor(db, req);
  if (!connector) return json({ error: "unauthorized" }, 401);
  if (typeof b.message_id !== "string") return json({ error: "invalid_message_id" }, 400);

  const { data: msg } = await db.from("yui_messages").select("id, user_id, agent_id, chat_id, sender, body, kind, meta, created_at")
    .eq("id", b.message_id).maybeSingle();
  const { data: agent } = msg
    ? await db.from("yui_agents").select("id, name, connector_id, push_muted, client_safe").eq("id", msg.agent_id).maybeSingle()
    : { data: null };
  // A shared agent's thread with someone else (YUI-95): only while the grant is
  // live and the agent is client-safe, with that person's own mute.
  let muted = agent?.push_muted ?? false;
  let mine = msg?.user_id === connector.user_id;
  if (msg && agent && !mine) {
    const { data: g } = await db.from("yui_agent_grants").select("push_muted")
      .eq("agent_id", agent.id).eq("user_id", msg.user_id).is("revoked_at", null).maybeSingle();
    mine = !!g && agent.client_safe === true;
    muted = g?.push_muted ?? true;
  }
  // Same answer for "no such message" and "not yours": no probing other threads.
  if (!msg || !agent || agent.connector_id !== connector.id || !mine) {
    return json({ error: "not_found" }, 404);
  }
  if (msg.sender !== "agent") return json({ error: "not_an_agent_message" }, 400);
  // A settings answer from the drawer's Controls tab (YUI-70): never a notification.
  if (msg.kind === "control") return json({ error: "control_row" }, 400);
  if (Date.now() - new Date(msg.created_at).getTime() > NOTIFY_WINDOW_MS) return json({ error: "too_old" }, 409);
  if (muted) return json({ ok: true, muted: true, devices: 0, delivered: 0, skipped: 0, results: [] });

  // A native check-in (YUI-143) reads as the agent checking in when its reply is only a screen.
  const payload = apnsPayload(agent, msg, { from: cleanName(b.from), handoff: !!b.handoff });

  const { data: all } = await db.from("yui_devices").select("id, apns_token, environment, topic, active_at, active_agent_id")
    .eq("user_id", msg.user_id).not("apns_token", "is", null);
  // Open on this thread right now: the answer is already on screen.
  const watching = (d: DB) =>
    d.active_agent_id === agent.id && d.active_at && Date.now() - new Date(d.active_at).getTime() < PRESENCE_MS;
  const devices = (all ?? []).filter((d: DB) => !watching(d));
  const { data: browsers } = await db.from("yui_devices")
    .select("id, web_endpoint, web_p256dh, web_auth, active_at, active_agent_id")
    .eq("user_id", msg.user_id).not("web_endpoint", "is", null);
  const openBrowsers = (browsers ?? []).filter((d: DB) => !watching(d));
  const wp = webPayload(agent, msg, { from: cleanName(b.from), handoff: !!b.handoff });
  const results = await Promise.all([
    ...devices.map((d: DB) => push(db, d, payload)),
    ...openBrowsers.map((d: DB) => sendWeb(db, d, wp).catch((e) => ({ device: d.id, kind: "web", ok: false, status: 0, reason: String(e?.message ?? e) }))),
  ]);
  return json({
    ok: true,
    devices: results.length,
    delivered: results.filter((r) => r.ok).length,
    skipped: (all ?? []).length - devices.length + (browsers ?? []).length - openBrowsers.length,
    results,
  });
}

/** The caller holds a service-role key (legacy JWT or sb_secret_...): it can read
 * yui_invites, which no other role can. Comparing strings misses the other format. */
async function isService(req: Request): Promise<boolean> {
  const key = bearer(req);
  if (!key || key === Deno.env.get("SUPABASE_ANON_KEY")) return false;
  const r = await fetch(`${env("SUPABASE_URL")}/rest/v1/yui_invites?select=id&limit=1`, {
    headers: { apikey: key, authorization: `Bearer ${key}` },
  });
  await r.body?.cancel();
  return r.status === 200;
}

async function revoked(req: Request, b: Body): Promise<Response> {
  if (!(await isService(req))) return json({ error: "unauthorized" }, 401);
  if (typeof b.agent_id !== "string" || !UUID.test(b.agent_id)) return json({ error: "invalid_agent_id" }, 400);
  if (typeof b.user_id !== "string" || !UUID.test(b.user_id)) return json({ error: "invalid_user_id" }, 400);
  const db = admin();
  const { data: grants } = await db.from("yui_agent_grants").select("revoked_at")
    .eq("agent_id", b.agent_id).eq("user_id", b.user_id);
  const live = (grants ?? []).some((g: DB) => g.revoked_at === null);
  if (live || !(grants ?? []).length) return json({ error: "not_revoked" }, 409);
  const { data: all } = await db.from("yui_devices").select("id, apns_token, environment, topic")
    .eq("user_id", b.user_id).not("apns_token", "is", null);
  // No alert, no sound: the app wakes, refreshes its list and says one quiet line.
  const payload = { aps: { "content-available": 1 }, kind: "revoked", agent_id: b.agent_id };
  const { data: browsers } = await db.from("yui_devices").select("id, web_endpoint, web_p256dh, web_auth")
    .eq("user_id", b.user_id).not("web_endpoint", "is", null);
  const results = await Promise.all([
    ...(all ?? []).map((d: DB) => push(db, d, payload, "background")),
    ...(browsers ?? []).map((d: DB) => sendWeb(db, d, webQuiet("revoked", b.agent_id), true).catch(() => ({ ok: false }))),
  ]);
  return json({ ok: true, devices: results.length, delivered: results.filter((r) => r.ok).length, results });
}

async function widgets(req: Request, b: Body): Promise<Response> {
  const secret = Deno.env.get("YUI_WIDGETS_SECRET");
  const given = req.headers.get("x-yui-widgets") ?? "";
  if (!secret || given.length !== secret.length || given !== secret) return json({ error: "unauthorized" }, 401);
  if (!Array.isArray(b.ids) || b.ids.length > 500 || !b.ids.every((i: unknown) => typeof i === "string" && UUID.test(i))) {
    return json({ error: "invalid_ids" }, 400);
  }
  const db = admin();
  const { data: rows } = await db.from("yui_widgets").select("id, push_token, environment, topic")
    .in("id", b.ids).not("push_token", "is", null);
  // One push per phone: rows of one token ride together.
  const byToken = new Map<string, DB>();
  for (const r of rows ?? []) if (!byToken.has(r.push_token)) byToken.set(r.push_token, r);
  const results = await Promise.all([...byToken.values()].map(async (r: DB) => {
    const main = env("YUI_APNS_TOPIC");
    const w = widgetPush(r.topic ?? main);
    const { r: res, reason } = await send({ apns_token: r.push_token, environment: r.environment }, w.topic, w.payload, w.type);
    const same = (rows ?? []).filter((x: DB) => x.push_token === r.push_token).map((x: DB) => x.id);
    if (res.status === 410 || reason === "Unregistered" || reason === "BadDeviceToken") {
      // The widgets are gone (or the token is stale): forget it until the app registers again.
      await db.from("yui_widgets").update({ push_token: null, last_error: reason }).in("id", same);
    } else if (reason) {
      await db.from("yui_widgets").update({ last_error: reason }).in("id", same);
    } else {
      for (const id of same) await db.rpc("yui_widgets_pushed", { p_id: id });
    }
    // The log line the reload budget is checked against (spec section 3).
    console.log(`widget push ${res.status} ${reason ?? "ok"} rows=${same.length} env=${r.environment}`);
    return { rows: same.length, ok: res.status === 200, status: res.status, reason, apns_id: res.headers.get("apns-id") };
  }));
  return json({ ok: true, phones: results.length, delivered: results.filter((r) => r.ok).length, results });
}

async function reminders(req: Request, b: Body): Promise<Response> {
  const secret = Deno.env.get("YUI_WIDGETS_SECRET");
  const given = req.headers.get("x-yui-widgets") ?? "";
  if (!secret || given.length !== secret.length || given !== secret) return json({ error: "unauthorized" }, 401);
  const ok = (r: Body) =>
    r && typeof r.user_id === "string" && UUID.test(r.user_id) && typeof r.agent_id === "string" && UUID.test(r.agent_id) &&
    typeof r.key === "string" && r.key.length > 0 && r.key.length <= 200 && typeof r.text === "string";
  if (!Array.isArray(b.due) || b.due.length > 500 || !b.due.every(ok)) return json({ error: "invalid_due" }, 400);
  const db = admin();
  const results = await Promise.all(b.due.map(async (r: Body) => {
    const { data: agent } = await db.from("yui_agents").select("id, name").eq("id", r.agent_id).maybeSingle();
    if (!agent) return [];
    const { data: browsers } = await db.from("yui_devices").select("id, web_endpoint, web_p256dh, web_auth")
      .eq("user_id", r.user_id).not("web_endpoint", "is", null);
    const msg = reminderPayload(agent, r.key, r.text);
    return await Promise.all((browsers ?? []).map((d: DB) =>
      sendWeb(db, d, msg).catch((e) => ({ device: d.id, kind: "web", ok: false, status: 0, reason: String(e?.message ?? e) }))
    ));
  }));
  const flat = results.flat();
  console.log(`reminders ${b.due.length} due, ${flat.filter((x: DB) => x.ok).length}/${flat.length} delivered`);
  return json({ ok: true, due: b.due.length, devices: flat.length, delivered: flat.filter((x: DB) => x.ok).length, results: flat });
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

async function send(d: DB, topic: string, payload: unknown, type = "alert") {
  const host = HOSTS[d.environment as keyof typeof HOSTS] ?? HOSTS.production;
  const r = await fetch(`${host}/3/device/${d.apns_token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${await providerToken()}`,
      "apns-topic": topic,
      "apns-push-type": type,
      // Apple refuses priority 10 on a background push; a widget reload is budgeted, so it waits for the system too.
      "apns-priority": type === "background" || type === "widgets" ? "5" : "10",
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });
  const reason = r.status === 200 ? null : ((await r.json().catch(() => ({}))).reason ?? `http_${r.status}`);
  return { r, reason };
}

async function push(db: DB, d: DB, payload: unknown, type = "alert") {
  const main = env("YUI_APNS_TOPIC");
  let topic: string = d.topic ?? main;
  let { r, reason } = await send(d, topic, payload, type);
  if (reason === "DeviceTokenNotForTopic") {
    // The token is the other app's (Yui vs Yui Dev, YUI-91): try that once and remember it.
    const other = topic === main ? `${main}.dev` : main;
    const again = await send(d, other, payload, type);
    if (again.reason !== "DeviceTokenNotForTopic") {
      ({ r, reason } = again);
      topic = other;
      await db.from("yui_devices").update({ topic: other === main ? null : other }).eq("id", d.id);
    }
  }
  const apnsId = r.headers.get("apns-id");
  if (r.status === 410 || reason === "Unregistered") {
    // App deleted or notifications reset: forget the token.
    await db.from("yui_devices").delete().eq("id", d.id);
  } else {
    await db.from("yui_devices").update(
      reason ? { last_error: reason } : { last_push_at: new Date().toISOString(), last_error: null },
    ).eq("id", d.id);
  }
  return { device: d.id, environment: d.environment, topic, ok: r.status === 200, status: r.status, reason, apns_id: apnsId };
}
