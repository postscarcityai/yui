// INT-19: an OAuth-only MCP client, played by the MCP TypeScript SDK's own
// OAuth code (@modelcontextprotocol/sdk client/auth): no token is handed to
// it. It finds yui-oauth from yui-mcp's 401, registers itself, runs PKCE, and
// once the person allows it in the Yui app it asks "Ready for a tabata?" and
// answers a Yes with a timer. Driven by mcp_oauth_e2e.py, which installs the
// SDK next to a copy of this file.
//
//   MCP_URL=... OUT_DIR=... node mcp_oauth_client.mjs
import { writeFileSync } from "node:fs";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { UnauthorizedError } from "@modelcontextprotocol/sdk/client/auth.js";

const MCP = process.env.MCP_URL;
const OUT = process.env.OUT_DIR;
const CB = "http://localhost:33418/callback";
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);

// Every OAuth call and its answer go to the log (tokens masked).
const traced = async (url, init) => {
  const r = await fetch(url, init);
  if (String(url).includes("yui-oauth") || String(url).includes("well-known") || r.status >= 400) {
    const body = await r.clone().text();
    log(init?.method ?? "GET", String(url).replace(/^.*\/functions\/v1/, ""), r.status, body.replace(/yui_(at|rt|ac|cs)_[A-Za-z0-9_-]+/g, "yui_$1_***").slice(0, 200));
  }
  return r;
};

const provider = {
  get redirectUrl() { return CB; },
  get clientMetadata() {
    return { client_name: "SDK Agent", redirect_uris: [CB], grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"], token_endpoint_auth_method: "none" };
  },
  clientInformation() { return this.ci; },
  saveClientInformation(ci) { this.ci = ci; log("registered", ci.client_id.slice(0, 12) + "..."); },
  tokens() { return this.t; },
  saveTokens(t) { this.t = t; log("tokens saved:", t.access_token.slice(0, 7) + "***", "expires_in", t.expires_in); },
  redirectToAuthorization(url) { this.authUrl = url; log("authorize ->", url.origin + url.pathname); },
  saveCodeVerifier(v) { this.v = v; },
  codeVerifier() { return this.v; },
};

const client = new Client({ name: "sdk-oauth-e2e", version: "1.0.0" });
// finishAuth must run on the transport that got the 401: it holds the
// resource_metadata URL from WWW-Authenticate. Yui lives under a path on a
// shared host, so the root-level fallbacks a fresh transport tries all 404.
const first = new StreamableHTTPClientTransport(new URL(MCP), { authProvider: provider, fetch: traced });
try {
  await client.connect(first);
  throw new Error("connected with no token: the server should have said 401");
} catch (e) {
  if (!(e instanceof UnauthorizedError)) throw e;
  log("401 -> OAuth, as expected");
}

// The browser step: /authorize sends it to www.yuigui.com/connect/<id>.
const r = await fetch(provider.authUrl, { redirect: "manual" });
const page = r.headers.get("location") ?? "";
const id = page.split("/connect/")[1];
if (r.status !== 302 || !id) throw new Error(`authorize answered ${r.status} ${page}`);
log("sign-in page", page);
writeFileSync(`${OUT}/connect`, id);

// What the page does: poll until the person allowed it in the app.
const oauth = provider.authUrl.origin + provider.authUrl.pathname.replace(/\/authorize$/, "");
let redirect = "";
for (let i = 0; i < 150 && !redirect; i++) {
  const s = await (await fetch(oauth, { method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ action: "request", id }) })).json();
  redirect = s.redirect ?? "";
  if (!redirect) await new Promise((res) => setTimeout(res, 2000));
}
if (!redirect) throw new Error("never approved");
const back = new URL(redirect);
log("approved, back to", back.origin + back.pathname, "state ok:", back.searchParams.has("state"));
await first.finishAuth(back.searchParams.get("code"));

await client.connect(new StreamableHTTPClientTransport(new URL(MCP), { authProvider: provider, fetch: traced }));
log("connected:", client.getServerVersion()?.name);
const text = (res) => res.content?.[0]?.text ?? "";
const data = (res) => JSON.parse(text(res).split("\n").pop());
const threads = data(await client.callTool({ name: "yui_threads", arguments: {} }));
log("threads:", threads.threads.map((t) => t.agent).join(", "));
const shown = await client.callTool({ name: "yui_show", arguments: { lines: 'ask "Ready for a tabata?" Yes|"Not now"', text: "Quick one." } });
const screen = data(shown).screen_id;
log("ask shown, screen", screen);
let tap = "";
for (let i = 0; i < 10 && !tap; i++) {
  const a = data(await client.callTool({ name: "yui_answers", arguments: { screen_id: screen, wait: 25 } }));
  tap = a.answers.map((x) => x.text).join(" ");
}
log("answer:", tap);
if (/Yes/.test(tap)) await client.callTool({ name: "yui_show", arguments: { lines: "timer 20/10x8 Tabata" } });
else await client.callTool({ name: "yui_say", arguments: { text: "Later then." } });
writeFileSync(`${OUT}/result.json`, JSON.stringify({ threads: threads.threads.map((t) => t.agent), screen, tap }));
await client.close();
log("done");
