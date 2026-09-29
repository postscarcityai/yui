// yui-native: the native Yui runtime (NATIVE-1, yuigui spec/NATIVE.md).
//
// Two kinds of caller:
//
// The database, with the x-yui-native secret header:
//   {agent_id, message_id}  a person's new row in a hosted agent's thread
//                           (trigger yui_native_wake): run that agent's turns,
//                           or answer it at once when it is a Controls request.
//   {schedule_id}           a check-in is due (pg_cron, yui_native_tick).
//   {job_id}                work queued behind an answer that no run finished (yui_native_tick):
//                           a meal's macros (YUI-103). Jobs a turn queues run right after its answer.
// The work runs after the answer (202), so pg_net's short timeout never cuts it.
//
// The app, with the person's Yui access token:
//   {action: "status"}                         their key (provider, last four), models, time zone
//   {action: "key_set", provider, key, model?, base_url?}
//                                              checks the key with the provider, then keeps it in Vault
//   {action: "key_remove"}
//   {action: "search_key_set", key}            their own Firecrawl key: checked with Firecrawl, kept in Vault,
//                                              lifts the free monthly web search cap
//   {action: "search_key_remove"}
//   {action: "timezone", tz}                   "America/New_York"
//   {action: "agent_model", agent_id, model}   a model from the list, or "default"
// What agents remember and their check-ins the app reads, fixes and deletes
// through PostgREST (row level security on yui_native_memory and
// yui_native_schedules).
//
// Secrets: YUI_NATIVE_SECRET (same string as the vault's yui_native_secret),
// YUI_OPENROUTER_KEY (Yui's own key, with a spend ceiling on OpenRouter),
// YUI_FIRECRAWL_KEY (Yui's own Firecrawl key for web search; free lookups a month per person in yui_limits).
// The runtime lives in runtime/ and is copied to ../_native by runtime/scripts/build.mjs.
import { openRouter, runAgent, runJob, runScheduled, type TurnResult } from "../_native/turn.ts";
import { SupabaseStore } from "../_native/supabase.ts";
import { MODELS, PROVIDERS } from "../_native/models.ts";
import { answerControl } from "../_native/controls.ts";
import { validZone } from "../_native/schedule.ts";
import { Firecrawl } from "../_native/search.ts";
import { admin, assertActive, failure, json, take, verifyAccessToken } from "../_shared/yui.ts";

const env = (n: string) => Deno.env.get(n) ?? "";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function same(a: string, b: string): boolean {
  if (!a || a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

async function push(messageId: string) {
  // yui-push takes the service key for native replies (it finds the connector from the message).
  const key = env("SUPABASE_SERVICE_ROLE_KEY");
  try {
    const r = await fetch(`${env("SUPABASE_URL")}/functions/v1/yui-push`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${key}` },
      body: JSON.stringify({ action: "notify", message_id: messageId, native: true }),
    });
    await r.body?.cancel();
  } catch (e) {
    console.error("yui-native push", e);
  }
}

function later(work: Promise<unknown>) {
  // deno-lint-ignore no-explicit-any
  const rt = (globalThis as any).EdgeRuntime;
  if (rt?.waitUntil) rt.waitUntil(work);
  return rt?.waitUntil ? Promise.resolve() : work;
}

async function fromDatabase(body: { agent_id?: string; schedule_id?: string; message_id?: string; job_id?: string }): Promise<Response> {
  const key = env("YUI_OPENROUTER_KEY");
  const store = new SupabaseStore(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"));
  const id = body.job_id ?? body.schedule_id ?? body.agent_id ?? "";
  if (!UUID.test(id)) return new Response("invalid request", { status: 400 });
  // A Controls request: answered now (the app waits 5 seconds), never a turn.
  if (body.message_id && UUID.test(body.message_id) && await answerControl(store, body.message_id)) return json({ ok: true, control: true });
  const opts = { provider: openRouter(key), search: { key: env("YUI_FIRECRAWL_KEY") || undefined }, log: (m: string) => console.log(`yui-native ${id.slice(0, 8)}: ${m}`) };
  const run: Promise<TurnResult> = body.job_id ? runJob(store, id, opts) : body.schedule_id ? runScheduled(store, id, opts) : runAgent(store, id, opts);
  await later(run.then(async (r) => {
    for (const m of r.replies) await push(m);
    // The answer is out ("Got it, working out the macros"): now the work behind it, and its own push.
    for (const j of r.jobs) {
      const done = await runJob(store, j, opts);
      for (const m of done.replies) await push(m);
    }
  }).catch((e) => console.error("yui-native", id.slice(0, 8), e)));
  return json({ ok: true }, 202);
}

// deno-lint-ignore no-explicit-any
type Body = Record<string, any>;

/** Asks the provider for its models with the key: a bad key or a wrong address says so before it is kept. */
async function checkKey(baseUrl: string, key: string, model?: string, provider?: string): Promise<string | null> {
  try {
    // Claude's own list wants x-api-key; the others take the bearer.
    const headers: Record<string, string> = { authorization: `Bearer ${key}` };
    if (provider === "anthropic") Object.assign(headers, { "x-api-key": key, "anthropic-version": "2023-06-01" });
    const r = await fetch(`${baseUrl}/models`, { headers, signal: AbortSignal.timeout(10_000) });
    if (r.status === 401 || r.status === 403) return "the provider turned this key down";
    if (!r.ok) return `the provider answered ${r.status}`;
    // deno-lint-ignore no-explicit-any
    const d: any = await r.json().catch(() => null);
    const ids: string[] = (d?.data ?? []).map((m: { id?: string }) => String(m.id ?? "").replace(/^models\//, "")); // Gemini lists "models/<id>"
    if (model && ids.length && !ids.includes(model)) return `this provider has no model called ${model}`;
    return null;
  } catch {
    return "couldn't reach the provider";
  }
}

async function fromApp(req: Request, b: Body): Promise<Response> {
  let userId: string;
  try {
    userId = await verifyAccessToken(req);
  } catch {
    return json({ error: "unauthorized" }, 401);
  }
  const db = admin();
  await assertActive(db, userId);
  await take(db, `agents:u:${userId}`, "agents_api");
  switch (b.action) {
    case "status": {
      const [{ data: key }, { data: user }, { data: usage }, { data: searchKey }, { data: lims }] = await Promise.all([
        db.from("yui_native_keys").select("provider, model, hint, base_url").eq("user_id", userId).maybeSingle(),
        db.from("yui_users").select("timezone").eq("id", userId).maybeSingle(),
        db.from("yui_native_usage").select("turns, searches").eq("user_id", userId).eq("month", new Date().toISOString().slice(0, 7) + "-01").maybeSingle(),
        db.from("yui_native_search_keys").select("hint").eq("user_id", userId).maybeSingle(),
        db.from("yui_limits").select("name, value").in("name", ["native_free_turns", "native_searches_per_month"]),
      ]);
      const lim = (n: string, d: number) => Number(lims?.find((l: { name: string }) => l.name === n)?.value ?? d);
      return json({ key: key ?? null, providers: PROVIDERS.filter((p) => p.scored), models: MODELS, timezone: user?.timezone ?? null,
                    turns: { used: usage?.turns ?? 0, limit: lim("native_free_turns", 100) },
                    search: { used: usage?.searches ?? 0, limit: lim("native_searches_per_month", 50), key: searchKey ?? null } });
    }
    case "search_key_set": {
      const key = typeof b.key === "string" ? b.key.trim() : "";
      if (key.length < 8 || key.length > 200 || /\s/.test(key)) return json({ error: "invalid_key" }, 400);
      const problem = await new Firecrawl(key).check();
      if (problem) return json({ error: "key_check_failed", message: problem }, 400);
      const { error } = await db.rpc("yui_native_search_key_set", { uid: userId, secret: key });
      if (error) throw error;
      return json({ ok: true, search: { key: { hint: key.slice(-4) } } });
    }
    case "search_key_remove": {
      const { error } = await db.rpc("yui_native_search_key_remove", { uid: userId });
      if (error) throw error;
      return json({ ok: true });
    }
    case "key_set": {
      const p = PROVIDERS.find((x) => x.id === b.provider && x.scored);
      if (!p) return json({ error: "unknown_provider" }, 400);
      const key = typeof b.key === "string" ? b.key.trim() : "";
      if (key.length < 8 || key.length > 400 || /\s/.test(key)) return json({ error: "invalid_key" }, 400);
      const baseUrl = p.id === "custom" ? String(b.base_url ?? "").trim().replace(/\/+$/, "").replace(/\/chat\/completions$/, "") : p.url;
      if (!/^https:\/\/[A-Za-z0-9.-]+(:\d+)?(\/[A-Za-z0-9._\/-]*)?$/.test(baseUrl) || /^https:\/\/(localhost|[\d.]+|\[)/i.test(baseUrl)) {
        return json({ error: "invalid_base_url" }, 400);
      }
      const model = typeof b.model === "string" && b.model.trim() ? b.model.trim().slice(0, 120) : null;
      if (p.needsModel && !model) return json({ error: "model_required" }, 400);
      const problem = await checkKey(baseUrl, key, model ?? p.model, p.id);
      if (problem) return json({ error: "key_check_failed", message: problem }, 400);
      const { error } = await db.rpc("yui_native_key_set", { uid: userId, prov: p.id, url: baseUrl, mdl: model, secret: key });
      if (error) throw error;
      return json({ ok: true, key: { provider: p.id, model, hint: key.slice(-4), base_url: baseUrl } });
    }
    case "key_remove": {
      const { error } = await db.rpc("yui_native_key_remove", { uid: userId });
      if (error) throw error;
      return json({ ok: true });
    }
    case "timezone": {
      const tz = typeof b.tz === "string" ? b.tz : "";
      if (!tz || tz.length > 64 || validZone(tz) !== tz) return json({ error: "invalid_timezone" }, 400);
      const { error } = await db.from("yui_users").update({ timezone: tz }).eq("id", userId);
      if (error) throw error;
      return json({ ok: true });
    }
    case "agent_model": {
      if (typeof b.agent_id !== "string" || !UUID.test(b.agent_id)) return json({ error: "invalid_agent" }, 400);
      if (!MODELS.some((m) => m.id === b.model)) return json({ error: "unknown_model" }, 400);
      const { data: row } = await db.from("yui_native_profiles").select("profile").eq("agent_id", b.agent_id).eq("user_id", userId).maybeSingle();
      if (!row) return json({ error: "not_found" }, 404);
      const { error } = await db.from("yui_native_profiles").update({ profile: { ...row.profile, model: b.model }, updated_at: new Date().toISOString() })
        .eq("agent_id", b.agent_id).eq("user_id", userId);
      if (error) throw error;
      return json({ ok: true, model: b.model });
    }
    default:
      return json({ error: "unknown_action" }, 400);
  }
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
    const secret = req.headers.get("x-yui-native");
    if (secret !== null) {
      if (!same(secret, env("YUI_NATIVE_SECRET"))) return json({ error: "unauthorized" }, 401);
      return await fromDatabase(body);
    }
    return await fromApp(req, body);
  } catch (e) {
    return failure(`yui-native ${body.action ?? "wake"}`, e);
  }
});
