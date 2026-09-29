// yui-vault: the hosted connector's proxy for a person's own tool keys (YUI-34,
// yuigui spec/VAULT.md, CONTRACT.md).
//
//   POST|GET  /vault/v1/<handle>/<provider path>     Bearer yui_ct_...
//       The agent's own connection token. Checks, in order: the token is a live
//       host; the handle is granted to an agent that host serves; the path is on
//       the provider's list; a once grant is unused; the cap has room (a hold is
//       taken). Then it opens the sealed key in memory, forwards to the
//       provider's one fixed host with the provider's own auth header, and
//       streams the answer back. One use row per call, whatever the outcome.
//   GET  /.well-known/yui-vault.json                 no auth
//       {key_id, public_key, rotated_at}: what the app pins.
//
// Errors are JSON {error}: not_granted 403, once_used 403, cap_reached 402,
// path_not_allowed 400, key_rejected 502, rate_limited 429.
//
// The key exists in the clear only inside `call`, for one request. It is never
// stored, never logged (every log line is scrubbed), and scrubbed from any
// provider error text handed back.
import { cleanPath, cleanQuery, HOSTS, pathAllowed } from "./paths.ts";
import { estimateCents, finalCents } from "./pricing.ts";
import { makeLogger, scrub, secretsOf } from "./scrub.ts";
import { b64decode, hexToBytes, openKey } from "./seal.ts";
import type { Store } from "./store.ts";

export type Deps = {
  store: Store;
  fetch: typeof fetch;
  env: (name: string) => string | undefined;
  log?: (line: string) => void;
  now?: () => number;
  /** The connector's public identity for the well-known document. */
  wellKnown: { key_id: string; public_key: string; rotated_at: string };
};

const HANDLE = /^vk_[a-z]+_[0-9a-f]{4,8}$/;
const MAX_BODY = 10 * 1024 * 1024;
const MAX_JSON_FOR_ESTIMATE = 2 * 1024 * 1024;
const UPSTREAM_TIMEOUT_MS = 110_000;
const ERROR_BODY_MAX = 64 * 1024;

const STATUS: Record<string, number> = {
  not_granted: 403, once_used: 403, cap_reached: 402, path_not_allowed: 400, key_rejected: 502, rate_limited: 429,
};
const fail = (error: string, extra: Record<string, unknown> = {}) =>
  new Response(JSON.stringify({ error, ...extra }), { status: STATUS[error] ?? 500, headers: { "content-type": "application/json" } });

// How each provider wants its key.
function authHeaders(provider: string, key: string, incoming: Headers): Headers {
  const h = new Headers();
  for (const n of ["content-type", "accept"]) if (incoming.get(n)) h.set(n, incoming.get(n)!);
  switch (provider) {
    case "fal": h.set("authorization", `Key ${key}`); break;
    case "replicate":
      h.set("authorization", `Bearer ${key}`);
      if (incoming.get("prefer")) h.set("prefer", incoming.get("prefer")!);
      break;
    case "elevenlabs": h.set("xi-api-key", key); break;
    case "anthropic":
      h.set("x-api-key", key);
      h.set("anthropic-version", incoming.get("anthropic-version") ?? "2023-06-01");
      if (incoming.get("anthropic-beta")) h.set("anthropic-beta", incoming.get("anthropic-beta")!);
      break;
    case "openai": h.set("authorization", `Bearer ${key}`); break;
  }
  return h;
}

// The private key that opens a blob sealed under `keyId`: the current one, or
// the previous one for 30 days after a rotation.
function privateKeyFor(env: Deps["env"], keyId: string, currentId: string, now: number): Uint8Array | null {
  const cur = env("YUI_VAULT_PRIVATE_KEY");
  if (cur && keyId === (env("YUI_VAULT_KEY_ID") ?? currentId)) return b64decode(cur);
  const prev = env("YUI_VAULT_PREV_PRIVATE_KEY");
  const until = Date.parse(env("YUI_VAULT_PREV_UNTIL") ?? "");
  if (prev && keyId === env("YUI_VAULT_PREV_KEY_ID") && until > now) return b64decode(prev);
  return null;
}

export function createHandler(deps: Deps) {
  const log = makeLogger(deps.log);
  const now = deps.now ?? Date.now;

  return async function handle(req: Request): Promise<Response> {
    const url = new URL(req.url);
    const secrets: string[] = [];
    let held: number | null = null; // a hold nobody has settled yet
    try {
      if (url.pathname.endsWith("/.well-known/yui-vault.json")) {
        return new Response(JSON.stringify(deps.wellKnown), {
          headers: { "content-type": "application/json", "cache-control": "public, max-age=300" },
        });
      }
      const at = url.pathname.indexOf("/vault/v1/");
      if (at < 0) return fail("not_granted");
      if (req.method !== "GET" && req.method !== "POST") return new Response(JSON.stringify({ error: "method_not_allowed" }), { status: 405 });

      const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
      const host = token ? await deps.store.connector(token) : null;
      if (!host) return fail("not_granted");
      if (host.suspended) return new Response(JSON.stringify({ error: "suspended" }), { status: 403 });
      if (!(await deps.store.take(host.id))) return fail("rate_limited");

      const rest = url.pathname.slice(at + "/vault/v1/".length);
      const slash = rest.indexOf("/");
      const handleId = slash < 0 ? rest : rest.slice(0, slash);
      if (!HANDLE.test(handleId)) return fail("not_granted");
      const provider = handleId.split("_")[1];
      if (!HOSTS[provider]) return fail("not_granted");
      const path = cleanPath(slash < 0 ? "" : rest.slice(slash + 1));
      const query = cleanQuery(url.search);
      const pathOk = pathAllowed(provider, req.method, path) && query !== null;

      // The body: read once, bounded. It is the provider's own request body.
      let bodyBytes: Uint8Array | null = null;
      if (req.method === "POST") {
        bodyBytes = new Uint8Array(await req.arrayBuffer());
        if (bodyBytes.length > MAX_BODY) return fail("path_not_allowed", { reason: "body_too_large" });
      }
      // deno-lint-ignore no-explicit-any
      let json: any = null;
      if (bodyBytes && bodyBytes.length <= MAX_JSON_FOR_ESTIMATE && (req.headers.get("content-type") ?? "").includes("json")) {
        try { json = JSON.parse(new TextDecoder().decode(bodyBytes)); } catch { json = null; }
      }
      const cleanedPath = path ?? "";
      const est = pathOk ? estimateCents(provider, req.method, cleanedPath, json, bodyBytes?.length ?? 0) : 1;

      const begun = await deps.store.begin({ handle: handleId, connector: host.id, path: cleanedPath, pathOk, estCents: est });
      if (!begun.ok) {
        log([], "refused", { handle: handleId, error: begun.error, method: req.method });
        return fail(begun.error);
      }

      held = begun.use_id;
      // The key, for this call only.
      const priv = privateKeyFor(deps.env, begun.key_id, deps.wellKnown.key_id, now());
      let key: string;
      try {
        if (!priv) throw new Error("no private key for " + begun.key_id);
        key = await openKey(hexToBytes(begun.sealed), begun.key_id, priv);
      } catch (e) {
        log([], "open_failed", { handle: handleId, key_id: begun.key_id, err: (e as Error).message });
        await deps.store.finish(begun.use_id, 0, 0, "key_rejected");
        return fail("key_rejected", { reason: "reseal_needed" });
      }
      secrets.push(...secretsOf(key));

      const target = HOSTS[provider] + "/" + cleanedPath + (query ?? "");
      const t0 = now();
      let up: Response;
      try {
        up = await deps.fetch(target, {
          method: req.method,
          headers: authHeaders(provider, key, req.headers),
          body: bodyBytes && bodyBytes.length ? (bodyBytes as unknown as BodyInit) : undefined,
          redirect: "manual", // a redirect must never carry the key elsewhere
          signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
        });
      } catch (e) {
        log(secrets, "upstream_failed", { handle: handleId, provider, path: cleanedPath, err: (e as Error).message });
        await deps.store.finish(begun.use_id, 0, 0, "upstream_failed");
        return new Response(JSON.stringify({ error: "upstream_failed" }), { status: 502, headers: { "content-type": "application/json" } });
      }
      const ms = now() - t0;

      // The provider refused the key (revoked, no credits, not allowed).
      if (up.status === 401 || up.status === 402 || up.status === 403) {
        await up.body?.cancel();
        log(secrets, "call", { handle: handleId, provider, path: cleanedPath, status: up.status, ms, error: "key_rejected" });
        await deps.store.finish(begun.use_id, up.status, 0, "key_rejected");
        return fail("key_rejected", { provider, upstream_status: up.status });
      }
      // A redirect is not followed and not passed on.
      if (up.status >= 300 && up.status < 400) {
        await up.body?.cancel();
        log(secrets, "call", { handle: handleId, provider, path: cleanedPath, status: up.status, ms, error: "redirect" });
        await deps.store.finish(begun.use_id, up.status, 0, "redirect");
        return new Response(JSON.stringify({ error: "upstream_failed" }), { status: 502, headers: { "content-type": "application/json" } });
      }

      const ctype = up.headers.get("content-type") ?? "";
      const outHeaders = new Headers();
      if (ctype) outHeaders.set("content-type", ctype);

      // Any other error from the provider: its text, scrubbed, its status.
      if (up.status >= 400) {
        const text = (await up.text()).slice(0, ERROR_BODY_MAX);
        log(secrets, "call", { handle: handleId, provider, path: cleanedPath, status: up.status, ms });
        await deps.store.finish(begun.use_id, up.status, 0, "provider_error");
        return new Response(scrub(text, secrets), { status: up.status, headers: outHeaders });
      }

      // Success: stream it back, watching the text (JSON or an event stream) for the usage figures.
      const textual = /json|event-stream|text\//.test(ctype);
      let seen = "";
      const dec = new TextDecoder();
      let done = false;
      const finishOnce = async (status: number) => {
        if (done) return;
        done = true;
        held = null;
        try {
          const cost = finalCents(provider, req.method, cleanedPath, json, status, seen, est);
          log(secrets, "call", { handle: handleId, provider, path: cleanedPath, status, ms, cost });
          await deps.store.finish(begun.use_id, status, cost);
        } catch (e) {
          log(secrets, "finish_failed", { handle: handleId, err: (e as Error).message });
        }
      };
      if (!up.body) {
        await finishOnce(up.status);
        return new Response(null, { status: up.status, headers: outHeaders });
      }
      const reader = up.body.getReader();
      const stream = new ReadableStream<Uint8Array>({
        async pull(ctrl) {
          const { done: end, value } = await reader.read();
          if (end) {
            await finishOnce(up.status); // the use row is settled before the caller sees the end
            ctrl.close();
            return;
          }
          if (textual && seen.length < 512 * 1024) seen += dec.decode(value, { stream: true });
          ctrl.enqueue(value);
        },
        async cancel(reason) {
          await reader.cancel(reason);
          await finishOnce(up.status); // the caller left early: charge what we know
        },
      });
      return new Response(stream, { status: up.status, headers: outHeaders });
    } catch (e) {
      log(secrets, "error", { err: (e as Error).message });
      if (held !== null) await deps.store.finish(held, 0, 0, "server_error").catch(() => {});
      return new Response(JSON.stringify({ error: "server_error" }), { status: 500, headers: { "content-type": "application/json" } });
    }
  };
}
