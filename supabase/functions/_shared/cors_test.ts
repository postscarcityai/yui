import { allowedOrigin, withCors } from "./cors.ts";

const assert = (c: boolean, m: string) => { if (!c) throw new Error(m); };

Deno.test("allowlist: the site and the yui project's previews only", () => {
  assert(allowedOrigin("https://www.yuigui.com") === "https://www.yuigui.com", "site");
  assert(allowedOrigin("https://yui-en5urq2wm-cjohndesigns-projects.vercel.app") !== null, "preview");
  assert(allowedOrigin("https://yui-git-feature-x-cjohndesigns-projects.vercel.app") !== null, "branch preview");
  for (const bad of [
    "http://www.yuigui.com", "https://yuigui.com", "https://evil.com",
    "https://www.yuigui.com.evil.com", "https://yui-x-someone-else.vercel.app",
    "https://notyui-x-cjohndesigns-projects.vercel.app", null, "null",
  ]) assert(allowedOrigin(bad) === null, `refused ${bad}`);
});

Deno.test("preflight answers for an allowed origin, refuses the rest", async () => {
  const h = withCors(() => new Response("x"));
  const ok = await h(new Request("https://f/", { method: "OPTIONS", headers: { origin: "https://www.yuigui.com" } }));
  assert(ok.status === 204, "204");
  assert(ok.headers.get("access-control-allow-origin") === "https://www.yuigui.com", "acao");
  assert((ok.headers.get("access-control-allow-headers") ?? "").includes("authorization"), "auth header");
  const no = await h(new Request("https://f/", { method: "OPTIONS", headers: { origin: "https://evil.com" } }));
  assert(no.status === 403 && !no.headers.get("access-control-allow-origin"), "refused");
});

Deno.test("responses carry the origin only when allowed; no Origin passes through", async () => {
  const h = withCors(() => new Response("body", { status: 401, headers: { "content-type": "application/json" } }));
  const a = await h(new Request("https://f/", { method: "POST", headers: { origin: "https://www.yuigui.com" } }));
  assert(a.status === 401 && a.headers.get("access-control-allow-origin") === "https://www.yuigui.com", "allowed");
  assert((await a.text()) === "body", "body kept");
  const b = await h(new Request("https://f/", { method: "POST", headers: { origin: "https://evil.com" } }));
  assert(!b.headers.get("access-control-allow-origin"), "evil");
  const c = await h(new Request("https://f/", { method: "POST" }));
  assert(!c.headers.get("access-control-allow-origin") && c.status === 401, "app");
});
