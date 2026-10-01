// CORS for the web client (YUI-241). The browser may call these functions from
// www.yuigui.com and from the yui project's Vercel previews, nothing else.
// Tokens ride in the Authorization header, never cookies, so no credentials.
// A request with no Origin (the app, the plugin, curl) passes through
// untouched. Wrap each function's handler: Deno.serve(withCors(handler)).

const WEB_ORIGINS = ["https://www.yuigui.com"];
// yui-<hash>-cjohndesigns-projects.vercel.app and yui-git-<branch>-... only.
const PREVIEW = /^https:\/\/yui-[a-z0-9-]+-cjohndesigns-projects\.vercel\.app$/;

export function allowedOrigin(origin: string | null): string | null {
  if (!origin) return null;
  return WEB_ORIGINS.includes(origin) || PREVIEW.test(origin) ? origin : null;
}

const ALLOW_HEADERS = "authorization, content-type, apikey, x-client-info";

export function withCors(handler: (req: Request) => Response | Promise<Response>) {
  return async (req: Request): Promise<Response> => {
    const origin = allowedOrigin(req.headers.get("origin"));
    if (req.method === "OPTIONS") {
      if (!origin) return new Response(null, { status: 403 });
      return new Response(null, {
        status: 204,
        headers: {
          "access-control-allow-origin": origin,
          "access-control-allow-methods": "POST, GET, OPTIONS",
          "access-control-allow-headers": ALLOW_HEADERS,
          "access-control-max-age": "600",
          "vary": "Origin",
        },
      });
    }
    const res = await handler(req);
    if (!origin) return res;
    const headers = new Headers(res.headers);
    headers.set("access-control-allow-origin", origin);
    headers.append("vary", "Origin");
    return new Response(res.body, { status: res.status, statusText: res.statusText, headers });
  };
}
