// YUI-34: the yui-vault proxy, end to end against a real Postgres that has the
// vault migration (functions/yui-vault/handler.ts -> yui_vault_begin/finish),
// with the provider mocked (no real provider call, no spend).
//
//   supabase/tests/vault_local.sh <kit dir>       # once: leaves container yui34-pg up
//   VAULT_PG=yui34-pg deno test -A supabase/tests/vault/proxy_test.ts
import { assert, assertEquals, assertNotEquals } from "jsr:@std/assert@1";
import { createHandler } from "../../functions/yui-vault/handler.ts";
import { cleanPath, pathAllowed } from "../../functions/yui-vault/paths.ts";
import { PRICED } from "../../functions/yui-vault/pricing.ts";
import { b64encode, generateKeyPair, sealKey } from "../../functions/yui-vault/seal.ts";
import { scrub, secretsOf } from "../../functions/yui-vault/scrub.ts";
import type { Begin, Store } from "../../functions/yui-vault/store.ts";

const PG = Deno.env.get("VAULT_PG") ?? "yui34-pg";
const lit = (s: string) => "'" + s.replaceAll("'", "''") + "'";
const sha = async (s: string) =>
  [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)))].map((b) => b.toString(16).padStart(2, "0")).join("");

async function psql(sql: string): Promise<string> {
  const p = await new Deno.Command("docker", {
    args: ["exec", "-i", PG, "psql", "-q", "-t", "-A", "-U", "postgres", "-v", "ON_ERROR_STOP=1", "-c", sql],
    stdout: "piped", stderr: "piped",
  }).output();
  if (!p.success) throw new Error("psql: " + new TextDecoder().decode(p.stderr));
  return new TextDecoder().decode(p.stdout).trim();
}

// The real functions, called through psql as the service role would.
class PsqlStore implements Store {
  rate = true;
  async connector(token: string) {
    const r = await psql(`select id || ',' || (suspended_at is not null) from yui_connectors where token_hash = ${lit(await sha(token))} and revoked_at is null`);
    if (!r) return null;
    const [id, sus] = r.split(",");
    return { id, suspended: sus === "true" };
  }
  take(_c: string) { return Promise.resolve(this.rate); }
  async begin(a: { handle: string; connector: string; path: string; pathOk: boolean; estCents: number }): Promise<Begin> {
    return JSON.parse(await psql(`select yui_vault_begin(${lit(a.handle)}, ${lit(a.connector)}, ${lit(a.path)}, ${a.pathOk}, ${a.estCents})`));
  }
  async finish(u: number, s: number, c: number, e?: string) {
    await psql(`select yui_vault_finish(${u}, ${s}, ${c}, ${e ? lit(e) : "null"})`);
  }
}

// Every line the function or anything else writes, for the last test.
const logged: string[] = [];
for (const m of ["log", "error", "warn", "info", "debug"] as const) {
  // deno-lint-ignore no-explicit-any
  (console as any)[m] = (...a: unknown[]) => logged.push(a.map(String).join(" "));
}

const kp = await generateKeyPair();
const KEY_ID = "yvk-test";
const env: Record<string, string> = { YUI_VAULT_PRIVATE_KEY: b64encode(kp.privateKey) };
const store = new PsqlStore();
type Call = { url: string; init: RequestInit };
let calls: Call[] = [];
let upstream: (c: Call) => Response | Promise<Response> = () => new Response("{}", { headers: { "content-type": "application/json" } });
const handler = createHandler({
  store,
  fetch: ((url: string, init: RequestInit) => {
    const c = { url: String(url), init };
    calls.push(c);
    return Promise.resolve(upstream(c));
  }) as unknown as typeof fetch,
  env: (n) => env[n],
  log: (l) => logged.push(l),
  wellKnown: { key_id: KEY_ID, public_key: b64encode(kp.publicKey), rotated_at: "2026-09-30" },
});

const FAL_KEY = "12345678-abcd-4ef0-9abc-def012345678:abcdef0123456789abcdef0123456789";
const ANT_KEY = "sk-ant-api03-TESTONLYnotarealkeyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
const ALL_KEYS = [FAL_KEY, ANT_KEY];

async function world() {
  const id = () => crypto.randomUUID();
  const w = { A: id(), B: id(), cA: id(), cQ: id(), cB: id(), penny: id(), quill: id(), bee: id(),
    tA: "yui_ct_" + id(), tQ: "yui_ct_" + id(), tB: "yui_ct_" + id() };
  await psql(`
    insert into yui_users (id, apple_sub) values ('${w.A}', 'p.${w.A}'), ('${w.B}', 'p.${w.B}');
    insert into yui_connectors (id, user_id, name, token_hash) values
      ('${w.cA}', '${w.A}', 'a', ${lit(await sha(w.tA))}), ('${w.cQ}', '${w.A}', 'q', ${lit(await sha(w.tQ))}), ('${w.cB}', '${w.B}', 'b', ${lit(await sha(w.tB))});
    insert into yui_agents (id, user_id, name, handle, connector_id, remote_ref) values
      ('${w.penny}', '${w.A}', 'Penny', 'penny', '${w.cA}', 'penny'),
      ('${w.quill}', '${w.A}', 'Quill', 'quill', '${w.cQ}', 'quill'),
      ('${w.bee}', '${w.B}', 'Bee', 'bee', '${w.cB}', 'bee');`);
  return w;
}

async function addKey(uid: string, provider: string, plain: string, opts: { cap?: number; keyId?: string; sealed?: Uint8Array } = {}) {
  const sealed = opts.sealed ?? await sealKey(plain, opts.keyId ?? KEY_ID, kp.publicKey);
  const hex = [...sealed].map((b) => b.toString(16).padStart(2, "0")).join("");
  return await psql(`insert into yui_vault_keys (user_id, provider, name, last4, sealed, key_id, cap_cents, provider_limit_confirmed)
    values ('${uid}', '${provider}', 'test', ${lit(plain.slice(-4))}, decode('${hex}', 'hex'), ${lit(opts.keyId ?? KEY_ID)}, ${opts.cap ?? 1000}, true) returning id`);
}
const grant = (key: string, agent: string, extra = "") =>
  psql(`insert into yui_vault_grants (key, agent_id, purpose${extra ? ", once" : ""}) values ('${key}', '${agent}', 'test'${extra ? ", " + extra : ""}) returning handle`);

const req = (token: string, handle: string, path: string, body: unknown = { prompt: "a cat" }, method = "POST") =>
  new Request(`https://x.test/functions/v1/yui-vault/vault/v1/${handle}/${path}`, {
    method,
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: method === "GET" ? undefined : JSON.stringify(body),
  });
const uses = async (handle: string) => JSON.parse(await psql(`select coalesce(json_agg(u order by id), '[]') from (select id, kind, status, cost_cents, allowed, error, path from yui_vault_uses where handle = ${lit(handle)} and kind = 'call') u`));

Deno.test("well-known publishes the connector key", async () => {
  const r = await handler(new Request("https://x.test/functions/v1/yui-vault/.well-known/yui-vault.json"));
  assertEquals(r.status, 200);
  assertEquals(await r.json(), { key_id: KEY_ID, public_key: b64encode(kp.publicKey), rotated_at: "2026-09-30" });
});

Deno.test("a good call: fixed host, provider auth header, agent token never forwarded, one use row at its cost", async () => {
  const w = await world();
  const key = await addKey(w.A, "fal", FAL_KEY);
  const h = await grant(key, w.penny);
  calls = [];
  upstream = () => new Response(JSON.stringify({ images: [{ url: "https://cdn.test/1.png" }] }), { headers: { "content-type": "application/json" } });
  const r = await handler(req(w.tA, h, "fal-ai/flux/dev", { prompt: "a cat", num_images: 1 }));
  assertEquals(r.status, 200);
  assertEquals((await r.json()).images.length, 1);
  assertEquals(calls.length, 1);
  assertEquals(calls[0].url, "https://fal.run/fal-ai/flux/dev");
  const sent = new Headers(calls[0].init.headers);
  assertEquals(sent.get("authorization"), `Key ${FAL_KEY}`);
  assertEquals(calls[0].init.redirect, "manual");
  assert(!JSON.stringify([...sent]).includes("yui_ct_"));
  assertEquals(new TextDecoder().decode(calls[0].init.body as unknown as Uint8Array), JSON.stringify({ prompt: "a cat", num_images: 1 }));
  const u = await uses(h);
  assertEquals(u.length, 1);
  assertEquals([u[0].status, u[0].cost_cents, u[0].allowed], [200, 3, true]); // 2.5 cents rounds up
});

Deno.test("wrong agent: the host that serves another agent, another account's host, no token, a junk token", async () => {
  const w = await world();
  const h = await grant(await addKey(w.A, "fal", FAL_KEY), w.penny);
  calls = [];
  for (const t of [w.tQ, w.tB, "", "yui_ct_nope"]) {
    const r = await handler(req(t, h, "fal-ai/flux/dev"));
    assertEquals([r.status, (await r.json()).error], [403, "not_granted"]);
  }
  assertEquals(calls.length, 0, "the provider was never called");
  const u = await uses(h);
  assertEquals(u.length, 2, "the two real hosts left a refused row on the owner's trail");
  assert(u.every((x: { allowed: boolean; error: string }) => !x.allowed && x.error === "not_granted"));
});

Deno.test("revoked: not_granted on the very next call", async () => {
  const w = await world();
  const h = await grant(await addKey(w.A, "fal", FAL_KEY), w.penny);
  assertEquals((await handler(req(w.tA, h, "fal-ai/flux/dev"))).status, 200);
  await psql(`update yui_vault_grants set revoked_at = now() where handle = ${lit(h)}`);
  calls = [];
  const r = await handler(req(w.tA, h, "fal-ai/flux/dev"));
  assertEquals([r.status, (await r.json()).error], [403, "not_granted"]);
  assertEquals(calls.length, 0);
});

Deno.test("path off the list: path_not_allowed, and the provider is never called", async () => {
  const w = await world();
  const h = await grant(await addKey(w.A, "fal", FAL_KEY), w.penny);
  calls = [];
  for (const p of ["fal-ai/../secret", "storage/upload", "fal-ai/%2e%2e/x", "fal-ai//x", "evil.com/x", "fal-ai/flux/dev@evil.com", "fal-ai/flux/dev?a=b%2F", "", "fal-ai"]) {
    const r = await handler(req(w.tA, h, p));
    const body = await r.json();
    assertEquals([p, r.status, body.error], [p, 400, "path_not_allowed"]);
  }
  const g = await handler(req(w.tA, h, "fal-ai/flux/dev", {}, "GET")); // wrong method for fal
  assertEquals((await g.json()).error, "path_not_allowed");
  assertEquals(calls.length, 0);
  assertEquals((await uses(h)).every((x: { error: string }) => x.error === "path_not_allowed"), true);
});

Deno.test("path rules: every provider's list, fixed hosts only", () => {
  assertEquals(cleanPath("a/../b"), null);
  assertEquals(cleanPath("a/%2e%2e/b"), null);
  assertEquals(cleanPath("a\\b"), null);
  assert(pathAllowed("anthropic", "POST", "v1/messages"));
  assert(!pathAllowed("anthropic", "POST", "v1/organizations/keys"));
  assert(!pathAllowed("openai", "POST", "v1/files"));
  assert(pathAllowed("openai", "POST", "v1/chat/completions"));
  assert(pathAllowed("replicate", "GET", "v1/predictions/abc123"));
  assert(!pathAllowed("replicate", "GET", "v1/account"));
  assert(pathAllowed("elevenlabs", "POST", "v1/text-to-speech/voiceid"));
  assert(!pathAllowed("elevenlabs", "POST", "v1/voices/add"));
});

Deno.test("cap reached: 402, no provider call, a refused row", async () => {
  const w = await world();
  const h = await grant(await addKey(w.A, "fal", FAL_KEY, { cap: 5 }), w.penny); // 5 cents
  assertEquals((await handler(req(w.tA, h, "fal-ai/flux/dev"))).status, 200); // 3 cents
  calls = [];
  const r = await handler(req(w.tA, h, "fal-ai/flux/dev")); // 3 + 3 > 5
  assertEquals([r.status, (await r.json()).error], [402, "cap_reached"]);
  assertEquals(calls.length, 0);
  const u = await uses(h);
  assertEquals(u.map((x: { error: string | null }) => x.error), [null, "cap_reached"]);
});

Deno.test("cap holds: ten at once cannot all slip under the cap", async () => {
  const w = await world();
  const h = await grant(await addKey(w.A, "fal", FAL_KEY, { cap: 10 }), w.penny); // room for 3 calls of 3 cents
  let release!: () => void;
  const gate = new Promise<void>((res) => (release = res));
  upstream = async () => { await gate; return new Response("{}", { headers: { "content-type": "application/json" } }); };
  const rs = Array.from({ length: 10 }, () => handler(req(w.tA, h, "fal-ai/flux/dev")));
  await new Promise((r) => setTimeout(r, 1500)); // let every begin land while no call has finished
  release();
  const out = await Promise.all(rs);
  const codes = await Promise.all(out.map(async (r) => r.status === 200 ? 200 : (await r.json()).error));
  upstream = () => new Response("{}", { headers: { "content-type": "application/json" } });
  assertEquals(codes.filter((c) => c === 200).length, 3, JSON.stringify(codes));
  assertEquals(codes.filter((c) => c === "cap_reached").length, 7);
  // Drain the streamed bodies so every use row finishes.
  await Promise.all(out.map((r) => r.body?.cancel().catch(() => {})));
});

Deno.test("once: the first call works, the second is once_used", async () => {
  const w = await world();
  const h = await grant(await addKey(w.A, "fal", FAL_KEY), w.penny, "true");
  assertEquals((await handler(req(w.tA, h, "fal-ai/flux/dev"))).status, 200);
  calls = [];
  const r = await handler(req(w.tA, h, "fal-ai/flux/dev"));
  assertEquals([r.status, (await r.json()).error], [403, "once_used"]);
  assertEquals(calls.length, 0);
});

Deno.test("provider refusal: key_rejected, key scrubbed, no cost", async () => {
  const w = await world();
  const key = await addKey(w.A, "fal", FAL_KEY);
  const h = await grant(key, w.penny);
  upstream = () => new Response(JSON.stringify({ detail: `Invalid key ${FAL_KEY}` }), { status: 401, headers: { "content-type": "application/json" } });
  const r = await handler(req(w.tA, h, "fal-ai/flux/dev"));
  const text = await r.text();
  assertEquals(r.status, 502);
  assertEquals(JSON.parse(text).error, "key_rejected");
  assert(!text.includes("abcdef0123456789") && !text.includes("12345678-abcd"));
  const u = await uses(h);
  assertEquals([u[0].status, u[0].cost_cents, u[0].error, u[0].allowed], [401, 0, "key_rejected", true]);
  // 402 and 403 are refusals of the key too.
  for (const st of [402, 403]) {
    upstream = () => new Response("{}", { status: st });
    assertEquals((await (await handler(req(w.tA, h, "fal-ai/flux/dev"))).json()).error, "key_rejected");
  }
});

Deno.test("another provider error passes through with its status, scrubbed, at no cost", async () => {
  const w = await world();
  const h = await grant(await addKey(w.A, "fal", FAL_KEY), w.penny);
  upstream = () => new Response(`rate limited for ${FAL_KEY}`, { status: 429, headers: { "content-type": "text/plain" } });
  const r = await handler(req(w.tA, h, "fal-ai/flux/dev"));
  const t = await r.text();
  assertEquals(r.status, 429);
  assert(!t.includes("abcdef0123456789"));
  assert(t.includes("[key]"));
  assertEquals((await uses(h))[0].cost_cents, 0);
});

Deno.test("a redirect is not followed, not passed on", async () => {
  const w = await world();
  const h = await grant(await addKey(w.A, "fal", FAL_KEY), w.penny);
  calls = [];
  upstream = () => new Response(null, { status: 302, headers: { location: "https://evil.test/steal" } });
  const r = await handler(req(w.tA, h, "fal-ai/flux/dev"));
  assertEquals(r.status, 502);
  assertEquals(calls.length, 1);
  assertEquals(r.headers.get("location"), null);
});

Deno.test("a network failure carrying the key in its message: 502, scrubbed everywhere", async () => {
  const w = await world();
  const h = await grant(await addKey(w.A, "fal", FAL_KEY), w.penny);
  upstream = () => { throw new Error(`invalid header value: Key ${FAL_KEY}`); };
  const before = logged.length;
  const r = await handler(req(w.tA, h, "fal-ai/flux/dev"));
  assertEquals(r.status, 502);
  assert(!(await r.text()).includes("abcdef0123456789"));
  const mine = logged.slice(before).join("\n");
  assert(mine.includes("upstream_failed") && mine.includes("[key]"), "the failure was logged, with the key scrubbed: " + mine);
  upstream = () => new Response("{}", { headers: { "content-type": "application/json" } });
});

Deno.test("cost from the provider's usage figures (Anthropic, plain and streamed)", async () => {
  const w = await world();
  const h = await grant(await addKey(w.A, "anthropic", ANT_KEY), w.penny);
  upstream = (c) => {
    assertEquals(new Headers(c.init.headers).get("x-api-key"), ANT_KEY);
    assertEquals(new Headers(c.init.headers).get("anthropic-version"), "2023-06-01");
    assertEquals(c.url, "https://api.anthropic.com/v1/messages");
    return new Response(JSON.stringify({ content: [], usage: { input_tokens: 1000, output_tokens: 2000 } }), { headers: { "content-type": "application/json" } });
  };
  let r = await handler(req(w.tA, h, "v1/messages", { model: "claude-sonnet-4-5", max_tokens: 4000, messages: [] }));
  await r.text();
  // 1000 in at $3/M + 2000 out at $15/M = $0.033 = 3.3 cents -> 4
  assertEquals((await uses(h))[0].cost_cents, 4);
  const sse = 'event: message_start\ndata: {"message":{"usage":{"input_tokens":500,"output_tokens":1}}}\n\nevent: message_delta\ndata: {"usage":{"output_tokens":1000}}\n\n';
  upstream = () => new Response(sse, { headers: { "content-type": "text/event-stream" } });
  r = await handler(req(w.tA, h, "v1/messages", { model: "claude-haiku-4-5", max_tokens: 4000, stream: true, messages: [] }));
  assertEquals(await r.text(), sse, "the stream comes back untouched");
  // 500 in at $1/M + 1000 out at $5/M = $0.0055 = 0.55 cents -> 1
  assertEquals((await uses(h))[1].cost_cents, 1);
});

Deno.test("a blob sealed to a connector key that is gone: key_rejected, tells the app to reseal", async () => {
  const w = await world();
  const h = await grant(await addKey(w.A, "fal", FAL_KEY, { keyId: "yvk-retired" }), w.penny);
  calls = [];
  const r = await handler(req(w.tA, h, "fal-ai/flux/dev"));
  const b = await r.json();
  assertEquals([r.status, b.error, b.reason], [502, "key_rejected", "reseal_needed"]);
  assertEquals(calls.length, 0);
  assertEquals((await uses(h))[0].error, "key_rejected");
});

Deno.test("the previous connector key still opens its blobs during the rotation window", async () => {
  const w = await world();
  const old = await generateKeyPair();
  const sealed = await sealKey(FAL_KEY, "yvk-old", old.publicKey);
  const h = await grant(await addKey(w.A, "fal", FAL_KEY, { keyId: "yvk-old", sealed }), w.penny);
  env.YUI_VAULT_PREV_PRIVATE_KEY = b64encode(old.privateKey);
  env.YUI_VAULT_PREV_KEY_ID = "yvk-old";
  env.YUI_VAULT_PREV_UNTIL = new Date(Date.now() + 86400_000).toISOString();
  assertEquals((await handler(req(w.tA, h, "fal-ai/flux/dev"))).status, 200);
  env.YUI_VAULT_PREV_UNTIL = new Date(Date.now() - 1000).toISOString();
  const r = await handler(req(w.tA, h, "fal-ai/flux/dev"));
  assertEquals((await r.json()).error, "key_rejected");
  for (const k of ["YUI_VAULT_PREV_PRIVATE_KEY", "YUI_VAULT_PREV_KEY_ID", "YUI_VAULT_PREV_UNTIL"]) delete env[k];
});

Deno.test("rate limited host: 429", async () => {
  const w = await world();
  const h = await grant(await addKey(w.A, "fal", FAL_KEY), w.penny);
  store.rate = false;
  const r = await handler(req(w.tA, h, "fal-ai/flux/dev"));
  store.rate = true;
  assertEquals([r.status, (await r.json()).error], [429, "rate_limited"]);
});

Deno.test("interop: a key sealed by CryptoKit (the app's side) opens here", async () => {
  const sw = await new Deno.Command("swift", { args: ["--version"], stdout: "null", stderr: "null" }).output().catch(() => null);
  if (!sw?.success) { console.info("swift not available, interop skipped"); return; }
  const script = new URL("./seal_interop.swift", import.meta.url).pathname;
  const p = await new Deno.Command("swift", { args: [script, b64encode(kp.publicKey), KEY_ID, FAL_KEY], stdout: "piped", stderr: "piped" }).output();
  assert(p.success, "swift: " + new TextDecoder().decode(p.stderr));
  const sealed = Uint8Array.from(atob(new TextDecoder().decode(p.stdout).trim()), (c) => c.charCodeAt(0));
  const w = await world();
  const h = await grant(await addKey(w.A, "fal", FAL_KEY, { sealed }), w.penny);
  calls = [];
  assertEquals((await handler(req(w.tA, h, "fal-ai/flux/dev"))).status, 200);
  assertEquals(new Headers(calls[0].init.headers).get("authorization"), `Key ${FAL_KEY}`);
});

Deno.test("PRICED here matches yui_vault_priced() in the migration", async () => {
  const all = ["fal", "replicate", "elevenlabs", "openrouter", "anthropic", "openai"];
  const inSql = (await psql(`select string_agg(p, ',' order by p) from unnest(array[${all.map(lit).join(",")}]) p where yui_vault_priced(p)`)).split(",");
  assertEquals(inSql, [...PRICED].sort());
});

Deno.test("scrub: the key, each half of id:secret, and key-shaped text", () => {
  const s = scrub(`bad ${FAL_KEY} and ${ANT_KEY} and Bearer abcdefgh12345678`, [...secretsOf(FAL_KEY)]);
  for (const k of ["abcdef0123456789", "12345678-abcd", "TESTONLY", "abcdefgh12345678"]) assertNotEquals(s.includes(k), true, k);
});

// Last: nothing the function or anything else printed holds a key.
Deno.test("the key is absent from every log line", () => {
  assert(logged.length > 10, "there is something to check: " + logged.length);
  const parts = ALL_KEYS.flatMap((k) => secretsOf(k));
  const bad = logged.filter((l) => parts.some((p) => l.includes(p)));
  assertEquals(bad, []);
  assert(logged.some((l) => l.startsWith("yui-vault call ")), "call lines exist");
});
