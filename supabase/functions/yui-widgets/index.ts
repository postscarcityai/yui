// yui-widgets: the widget's side of the relay (YUI-40 step 4). Spec: yuigui/spec/WIDGETS.md.
//
// App side, Bearer yui_user access token:
//   {action: "register", widget_token?, push_token?, environment?, build?, pins: [{agent_id, screen, ids: [{id, preset}]}]}
//       The phone's pinned saved screens (WidgetCenter.getCurrentConfigurations). Replaces this
//       phone's rows: a screen no longer in `pins` is forgotten. Answers {widget_token}: the
//       token the widget extension keeps in the shared keychain. Send the one you have and you
//       get the same back; send none (or one that is not yours) and a new one is made.
//       Empty `pins` forgets them all (the last widget was removed, or the person signed out).
//
// Widget side, Bearer yui_wt_... widget token (only the hash is stored):
//   {action: "event", agent_id, id, body, meta}
//       A button on the widget (a tick, Start, a cta): the event row a tap in the thread would
//       send, with "via": "widget" in it. Only for an agent the phone has pinned a screen of.
//       A resend of the same id is a 200 (it landed before).
//   {action: "push_token", push_token, environment?}
//       The widgets' own WidgetKit push token changed (one was added or removed). Rows the app
//       already registered take it at once; the app registers the rest when it next opens.
//   {action: "read", agent_id, since?}
//       The agent's rows newer than `since` that carry patches or saves, oldest first, so the
//       widget can catch up after a push. Only for a pinned agent.
import {
  admin,
  bearer,
  failure,
  json,
  randomToken,
  sha256Hex,
  take,
  verifyAccessToken,
} from "../_shared/yui.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const TOKEN = /^[0-9a-f]{64,200}$/;
const WIDGET_PREFIX = "yui_wt_";
const MAX_PINS = 40;
// Lines a widget can be kept current by: a patch, a save or a forget.
const SCOPED = /(^|\n)[ \t]*(>[0-9]+[ \t]+)?(~|save |forget )/;

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
      case "register": {
        let userId: string;
        try {
          userId = await verifyAccessToken(req);
        } catch {
          return json({ error: "unauthorized" }, 401);
        }
        return await register(userId, body);
      }
      case "event":
      case "push_token":
      case "read": {
        const token = bearer(req);
        if (!token.startsWith(WIDGET_PREFIX)) return json({ error: "unauthorized" }, 401);
        const hash = await sha256Hex(token);
        if (body.action === "push_token") return await pushToken(hash, body);
        return body.action === "event" ? await event(hash, body) : await read(hash, body);
      }
      default:
        return json({ error: "unknown_action" }, 400);
    }
  } catch (e) {
    return failure(`yui-widgets ${body.action}`, e);
  }
});

/** The agent is this person's own, or shared with them while the grant is live. */
async function mayPin(db: DB, userId: string, agentId: string): Promise<boolean> {
  const { data } = await db.from("yui_agents").select("id").eq("id", agentId).eq("user_id", userId).maybeSingle();
  if (data) return true;
  const { data: g } = await db.from("yui_agent_grants").select("agent_id")
    .eq("agent_id", agentId).eq("user_id", userId).is("revoked_at", null).maybeSingle();
  return !!g;
}

function cleanIds(v: unknown): { id: string; preset: string }[] {
  if (!Array.isArray(v)) return [];
  const out: { id: string; preset: string }[] = [];
  for (const e of v.slice(0, 60)) {
    if (e && typeof e.id === "string" && /^[A-Za-z0-9_-]{1,60}$/.test(e.id)) {
      out.push({ id: e.id, preset: typeof e.preset === "string" ? e.preset.slice(0, 20) : "" });
    }
  }
  return out;
}

async function register(userId: string, b: Body): Promise<Response> {
  const db = admin();
  await take(db, `widgets:${userId}`, "agents_api");
  if (!Array.isArray(b.pins) || b.pins.length > MAX_PINS) return json({ error: "invalid_pins" }, 400);
  const environment = b.environment ?? "production";
  if (environment !== "production" && environment !== "sandbox") return json({ error: "invalid_environment" }, 400);
  const push = typeof b.push_token === "string" ? b.push_token.toLowerCase() : null;
  if (push !== null && !TOKEN.test(push)) return json({ error: "invalid_token" }, 400);
  const build = Number.isInteger(b.build) && b.build > 0 && b.build < 1_000_000 ? b.build : null;

  // The token the phone already has, if it is this person's.
  let token = typeof b.widget_token === "string" && b.widget_token.startsWith(WIDGET_PREFIX) ? b.widget_token : "";
  if (token) {
    const { data } = await db.from("yui_widgets").select("user_id").eq("token_hash", await sha256Hex(token)).limit(1);
    if (data?.length && data[0].user_id !== userId) token = "";
  }
  if (!token) token = WIDGET_PREFIX + randomToken();
  const hash = await sha256Hex(token);

  const rows: Record<string, unknown>[] = [];
  const seen = new Set<string>();
  for (const p of b.pins) {
    const agent = typeof p?.agent_id === "string" ? p.agent_id.toLowerCase() : "";
    const screen = typeof p?.screen === "string" ? p.screen.trim() : "";
    if (!UUID.test(agent) || !screen || screen.length > 80 || seen.has(`${agent}/${screen}`)) continue;
    if (!(await mayPin(db, userId, agent))) continue;
    seen.add(`${agent}/${screen}`);
    rows.push({
      user_id: userId, agent_id: agent, screen, ids: cleanIds(p.ids), token_hash: hash,
      push_token: push, environment, app_build: build, updated_at: new Date().toISOString(), last_error: null,
    });
  }
  // Forget what is no longer pinned on this phone, then keep what is.
  const { data: have } = await db.from("yui_widgets").select("id, agent_id, screen").eq("token_hash", hash);
  const gone = (have ?? []).filter((r: DB) => !seen.has(`${r.agent_id}/${r.screen}`)).map((r: DB) => r.id);
  if (gone.length) await db.from("yui_widgets").delete().in("id", gone);
  if (rows.length) {
    const { error } = await db.from("yui_widgets").upsert(rows, { onConflict: "token_hash,agent_id,screen" });
    if (error) throw error;
  }
  return json({ ok: true, widget_token: token, pinned: rows.length });
}

/** The user and agents this widget token is pinned to, or null. */
async function pinned(db: DB, hash: string, agentId: unknown): Promise<{ user_id: string } | null> {
  if (typeof agentId !== "string" || !UUID.test(agentId)) return null;
  const { data } = await db.from("yui_widgets").select("user_id").eq("token_hash", hash).eq("agent_id", agentId).limit(1);
  return data?.[0] ?? null;
}

async function pushToken(hash: string, b: Body): Promise<Response> {
  const db = admin();
  const push = typeof b.push_token === "string" ? b.push_token.toLowerCase() : "";
  if (!TOKEN.test(push)) return json({ error: "invalid_token" }, 400);
  const environment = b.environment ?? "production";
  if (environment !== "production" && environment !== "sandbox") return json({ error: "invalid_environment" }, 400);
  const { data, error } = await db.from("yui_widgets")
    .update({ push_token: push, environment, last_error: null, updated_at: new Date().toISOString() })
    .eq("token_hash", hash).select("id");
  if (error) throw error;
  if (!data?.length) return json({ error: "not_found" }, 404);
  return json({ ok: true, rows: data.length });
}

async function event(hash: string, b: Body): Promise<Response> {
  const db = admin();
  const w = await pinned(db, hash, b.agent_id);
  if (!w) return json({ error: "not_found" }, 404);
  if (typeof b.id !== "string" || !UUID.test(b.id)) return json({ error: "invalid_id" }, 400);
  if (typeof b.body !== "string" || !b.body.startsWith("[yui] ") || b.body.length > 4000) {
    return json({ error: "invalid_body" }, 400);
  }
  const meta = b.meta && typeof b.meta === "object" && !Array.isArray(b.meta) ? b.meta : {};
  if (meta.value?.via !== "widget") return json({ error: "invalid_meta" }, 400);
  await take(db, `widgets:${w.user_id}`, "agents_api");
  const { error } = await db.from("yui_messages").insert({
    id: b.id, user_id: w.user_id, agent_id: b.agent_id, sender: "user", kind: "event", body: b.body, meta,
  });
  // A resend of a row that already landed: the primary key answers it.
  if (error && (error as { code?: string }).code !== "23505") throw error;
  return json({ ok: true });
}

async function read(hash: string, b: Body): Promise<Response> {
  const db = admin();
  const w = await pinned(db, hash, b.agent_id);
  if (!w) return json({ error: "not_found" }, 404);
  await take(db, `widgets:${w.user_id}`, "agents_api");
  const since = typeof b.since === "string" && !Number.isNaN(Date.parse(b.since))
    ? b.since
    : new Date(Date.now() - 30 * 60_000).toISOString();
  const { data, error } = await db.from("yui_messages").select("id, body, created_at")
    .eq("agent_id", b.agent_id).eq("user_id", w.user_id).eq("sender", "agent").eq("kind", "text")
    .gt("created_at", since).order("created_at", { ascending: true }).order("id", { ascending: true }).limit(100);
  if (error) throw error;
  const rows = (data ?? []).filter((r: DB) => SCOPED.test(r.body));
  return json({ ok: true, rows });
}
