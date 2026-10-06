// Web Push for yui-push (YUI-248): VAPID + RFC 8291 encryption through web-push, to the browser's own
// push service (Apple, Google, Mozilla). Secrets: YUI_VAPID_PUBLIC, YUI_VAPID_PRIVATE, YUI_VAPID_SUBJECT.
import webpush from "npm:web-push@3.6.7";

// deno-lint-ignore no-explicit-any
type DB = any;

/** A push-service endpoint is an https URL on the service's own host, never ours to guess: https only, no credentials. */
export function validEndpoint(e: unknown): e is string {
  if (typeof e !== "string" || e.length > 1000) return false;
  try {
    const u = new URL(e);
    return u.protocol === "https:" && !u.username && !u.password;
  } catch {
    return false;
  }
}

/** An IANA zone name as the browser reports it ("America/New_York"); the database checks it against its own list. */
export function validTz(z: unknown): z is string {
  return typeof z === "string" && z.length >= 1 && z.length <= 64 && /^[A-Za-z0-9_+\/-]+$/.test(z);
}

const B64URL = /^[A-Za-z0-9_-]{16,200}$/;
export const validKey = (k: unknown): k is string => typeof k === "string" && B64URL.test(k);

let configured = false;
function configure() {
  if (configured) return;
  const pub = Deno.env.get("YUI_VAPID_PUBLIC");
  const priv = Deno.env.get("YUI_VAPID_PRIVATE");
  if (!pub || !priv) throw new Error("missing env YUI_VAPID_PUBLIC / YUI_VAPID_PRIVATE");
  webpush.setVapidDetails(Deno.env.get("YUI_VAPID_SUBJECT") ?? "mailto:cjohndesign@gmail.com", pub, priv);
  configured = true;
}

/** Send one message to one subscription row. A gone subscription (404, 410) is forgotten. `quiet` messages
 * carry no notification, so they ride at low urgency with a short life. */
export async function sendWeb(db: DB, d: DB, payload: unknown, quiet = false) {
  configure();
  let status = 201;
  let reason: string | null = null;
  try {
    const r = await webpush.sendNotification(
      { endpoint: d.web_endpoint, keys: { p256dh: d.web_p256dh, auth: d.web_auth } },
      JSON.stringify(payload),
      { TTL: quiet ? 60 : 24 * 3600, urgency: quiet ? "low" : "high" },
    );
    status = r.statusCode;
  } catch (e) {
    // deno-lint-ignore no-explicit-any
    status = (e as any).statusCode ?? 0;
    reason = `web_${status || "error"}`;
  }
  if (status === 404 || status === 410) {
    await db.from("yui_devices").delete().eq("id", d.id);
  } else {
    await db.from("yui_devices").update(
      reason ? { last_error: reason } : { last_push_at: new Date().toISOString(), last_error: null },
    ).eq("id", d.id);
  }
  return { device: d.id, kind: "web", ok: !reason, status, reason };
}
