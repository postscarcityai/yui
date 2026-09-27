// yui-native: the native Yui runtime (NATIVE-1, yuigui spec/NATIVE.md).
//
// Called by the database, not by people: a person's new row in a hosted
// agent's thread fires the yui_native_wake trigger (migration
// 20260927000000_yui_native.sql), which POSTs {agent_id, message_id} here with
// the x-yui-native secret. The turn runs after the answer (202), so pg_net's
// short timeout never cuts it off.
//
// Secrets: YUI_NATIVE_SECRET (the same string as the vault's yui_native_secret),
// YUI_OPENROUTER_KEY (Yui's own key, with a spend ceiling set on OpenRouter).
// The runtime itself lives in runtime/ and is copied to ../_native by
// runtime/scripts/build.mjs.
import { runAgent, openRouter } from "../_native/turn.ts";
import { SupabaseStore } from "../_native/supabase.ts";

const env = (n: string) => Deno.env.get(n) ?? "";

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

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });
  if (!same(req.headers.get("x-yui-native") ?? "", env("YUI_NATIVE_SECRET"))) return new Response("unauthorized", { status: 401 });
  let body: { agent_id?: string };
  try {
    body = await req.json();
  } catch {
    return new Response("invalid request", { status: 400 });
  }
  const agentId = body.agent_id;
  if (typeof agentId !== "string" || !/^[0-9a-f-]{36}$/i.test(agentId)) return new Response("invalid agent", { status: 400 });
  const key = env("YUI_OPENROUTER_KEY");
  if (!key) return new Response("no model key", { status: 503 });

  const store = new SupabaseStore(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"));
  const work = runAgent(store, agentId, {
    provider: openRouter(key),
    log: (m) => console.log(`yui-native ${agentId.slice(0, 8)}: ${m}`),
  }).then(async (r) => {
    for (const id of r.replies) await push(id);
  }).catch((e) => console.error("yui-native", agentId.slice(0, 8), e));
  // deno-lint-ignore no-explicit-any
  const rt = (globalThis as any).EdgeRuntime;
  if (rt?.waitUntil) rt.waitUntil(work);
  else await work;
  return new Response(JSON.stringify({ ok: true }), { status: 202, headers: { "content-type": "application/json" } });
});
