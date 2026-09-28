// Pure pieces of yui-mail: addresses, headers, threading, the loop guard, the
// look of an email. No network, no database: supabase/tests/mail_unit_test.ts.

export const DOMAIN = "yuigui.com";
export const SITE = "https://www.yuigui.com";

const ADDRESS = /^[^\s@<>(),;:"]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/;

export function validAddress(a: string): boolean {
  return a.length <= 254 && ADDRESS.test(a);
}

/** `"Jane Doe" <Jane@X.com>` or `jane@x.com` -> {email: "jane@x.com", name: "Jane Doe"}. */
export function parseAddress(raw: string): { email: string; name: string | null } | null {
  const s = raw.trim();
  const m = /^(.*?)<([^<>]+)>\s*$/.exec(s);
  const email = (m ? m[2] : s).trim().toLowerCase();
  if (!validAddress(email)) return null;
  const name = m ? m[1].trim().replace(/^"(.*)"$/, "$1").trim() : "";
  return { email, name: name || null };
}

/** A header's list of addresses, commas inside quotes left alone. */
export function parseAddressList(raw: string | null | undefined): string[] {
  if (!raw) return [];
  const parts: string[] = [];
  let cur = "", quoted = false;
  for (const ch of raw) {
    if (ch === '"') quoted = !quoted;
    if (ch === "," && !quoted) { parts.push(cur); cur = ""; } else cur += ch;
  }
  parts.push(cur);
  return parts.map((p) => parseAddress(p)?.email).filter((e): e is string => !!e);
}

/** Raw header block -> lowercase name to the first value, folded lines joined. */
export function parseHeaders(raw: string | null | undefined): Record<string, string> {
  const out: Record<string, string> = {};
  if (!raw) return out;
  const lines = raw.replace(/\r\n/g, "\n").split("\n");
  let name = "";
  for (const line of lines) {
    if (/^[ \t]/.test(line) && name) { out[name] += " " + line.trim(); continue; }
    const i = line.indexOf(":");
    if (i <= 0) { name = ""; continue; }
    name = line.slice(0, i).trim().toLowerCase();
    if (name in out) { name = ""; continue; } // first wins (the newest Received is on top, the rest are single)
    out[name] = line.slice(i + 1).trim();
  }
  return out;
}

/** Message ids in a header: `<a@b> <c@d>` -> ["a@b", "c@d"]. */
export function messageIds(raw: string | null | undefined): string[] {
  if (!raw) return [];
  return [...raw.matchAll(/<([^<>\s]+)>/g)].map((m) => m[1]).slice(-30);
}

/** "Re: Fwd: RE: Hello" -> "hello", for matching a reply to its thread. */
export function baseSubject(s: string): string {
  return s.replace(/^(\s*((re|fw|fwd|aw|sv|tr)\s*(\[\d+\])?\s*:|\[\d+\])\s*)+/i, "").trim().toLowerCase();
}

export function replySubject(s: string): string {
  const t = s.trim() || "Your email";
  return /^re\s*:/i.test(t) ? t : `Re: ${t}`;
}

/**
 * Mail Yui never answers: machines, lists, bounces, herself. Answering them is
 * how two auto-responders talk forever. Returns why, or null to go ahead.
 */
export function noAnswerReason(from: string, h: Record<string, string>, spamScore: number | null): string | null {
  const local = from.split("@")[0];
  const domain = from.split("@")[1] ?? "";
  if (domain === DOMAIN || domain.endsWith(`.${DOMAIN}`)) return "from our own domain";
  if (/^(mailer-daemon|postmaster|no-?reply|do-?not-?reply|bounces?|notifications?|noreply-.*)$/i.test(local)) return "an automatic sender";
  const auto = (h["auto-submitted"] ?? "").toLowerCase();
  if (auto && auto !== "no") return "auto-submitted";
  if (/^(bulk|list|junk|auto_reply)$/i.test(h["precedence"] ?? "")) return "bulk or list mail";
  if (h["list-id"] || h["list-unsubscribe"]) return "a mailing list";
  if (h["x-autoreply"] || h["x-autorespond"] || h["x-auto-response-suppress"]) return "an auto-reply";
  if (spamScore !== null && spamScore >= 5) return "spam";
  return null;
}

/** An address Yui may send as: yui@, hello@, news@ and the like, at yuigui.com only. */
export function senderAddress(local: string | undefined): string {
  const l = (local ?? "yui").toLowerCase();
  return /^[a-z][a-z0-9.-]{0,30}$/.test(l) ? `${l}@${DOMAIN}` : `yui@${DOMAIN}`;
}

export function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

/** Plain text -> simple HTML: paragraphs, line breaks, bare links made links. */
export function textToHtml(text: string): string {
  return text.trim().split(/\n{2,}/).map((p) => {
    const body = escapeHtml(p).replace(/(https?:\/\/[^\s<]+[^\s<.,;:!?)])/g, '<a href="$1">$1</a>').replace(/\n/g, "<br>");
    return `<p style="margin:0 0 14px">${body}</p>`;
  }).join("\n");
}

/** The frame every email Yui sends wears. Light, one column, readable anywhere. */
export function frame(innerHtml: string, footerHtml = ""): string {
  return `<!doctype html><html><body style="margin:0;padding:0;background:#ffffff">
<div style="max-width:560px;margin:0 auto;padding:24px 20px;font:16px/1.5 -apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;color:#1d1d1f">
${innerHtml}
${footerHtml ? `<div style="margin-top:28px;padding-top:14px;border-top:1px solid #e5e5ea;font-size:13px;color:#6e6e73">${footerHtml}</div>` : ""}
</div></body></html>`;
}

/**
 * Promos carry who sent them, a postal address (CAN-SPAM) and how to stop them,
 * in words. The address is the secret YUI_MAIL_POSTAL_ADDRESS, never in the repo;
 * without it no promo goes out.
 */
export function promoFooter(unsubUrl: string, postal: string): { html: string; text: string } {
  return {
    html: `You get this because you asked for news from Yui. <a href="${unsubUrl}" style="color:#6e6e73">Stop these emails</a>.<br>${escapeHtml(postal)}`,
    text: `You get this because you asked for news from Yui. Stop these emails: ${unsubUrl}\n${postal}`,
  };
}

/** Transactional templates the site and app send. Text first; the HTML is the same words. */
export function template(name: string, data: Record<string, string>): { subject: string; text: string } | null {
  const first = data.first_name ? `Hi ${data.first_name},` : "Hi,";
  switch (name) {
    case "confirm":
      if (!data.link) return null;
      return {
        subject: "Confirm your email for Yui",
        text: `${first}\n\nTap to confirm this is your email:\n${data.link}\n\nIf you didn't ask for Yui, ignore this and nothing happens.\n\nYui`,
      };
    case "invite_request":
      if (!data.link) return null;
      return {
        subject: "Got your request for Yui",
        text: `${first}\n\nThanks for asking for Yui. Tap to confirm this is your email so I can reach you:\n${data.link}\n\nYou don't have to wait: the alpha is open to anyone on TestFlight at ${SITE}/start\n\nIf you didn't ask for Yui, ignore this and nothing happens.\n\nYui`,
      };
    case "invite_approved":
      if (!data.link) return null;
      return {
        subject: "You're in: your Yui invite",
        text: `${first}\n\nYou're in. Apple will email you a TestFlight invite for Yui. Once Yui is on your phone, sign in and your invite is waiting. If you hid your email from apps, open this link on your phone instead:\n${data.link}\n\nAnything odd, just answer this email.\n\nYui`,
      };
    case "account_deleted":
      return {
        subject: "Your Yui account is deleted",
        text: `${first}\n\nYour Yui account and everything in it are deleted, as you asked. Nothing else to do.\n\nIf that wasn't you, answer this email.\n\nYui`,
      };
    default:
      return null;
  }
}

// SendGrid's event webhook signs timestamp + body with ECDSA P-256 (SHA-256).
// WebCrypto wants the signature as r||s, SendGrid sends it DER encoded.
export function derToRaw(der: Uint8Array): Uint8Array<ArrayBuffer> {
  if (der[0] !== 0x30) throw new Error("not DER");
  let i = 2;
  if (der[1] & 0x80) i = 2 + (der[1] & 0x7f);
  const read = () => {
    if (der[i] !== 0x02) throw new Error("not DER");
    const len = der[i + 1];
    let v: Uint8Array = der.slice(i + 2, i + 2 + len);
    i += 2 + len;
    while (v.length > 32 && v[0] === 0) v = v.slice(1);
    const out = new Uint8Array(32);
    out.set(v, 32 - v.length);
    return out;
  };
  const r = read(), s = read();
  const raw = new Uint8Array(64);
  raw.set(r, 0);
  raw.set(s, 32);
  return raw;
}

export function b64ToBytes(b64: string): Uint8Array<ArrayBuffer> {
  const bin = atob(b64.replace(/\s+/g, ""));
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

export async function verifyEventSignature(publicKeyB64: string, signatureB64: string, timestamp: string, body: string): Promise<boolean> {
  try {
    const key = await crypto.subtle.importKey("spki", b64ToBytes(publicKeyB64), { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
    const sig = derToRaw(b64ToBytes(signatureB64));
    return await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, sig, new TextEncoder().encode(timestamp + body));
  } catch {
    return false;
  }
}

/** The first JSON object in a model's answer, fences and chatter around it ignored. */
export function firstJson(text: string): Record<string, unknown> | null {
  const t = text.replace(/```(?:json)?/g, "");
  const start = t.indexOf("{");
  if (start < 0) return null;
  let depth = 0, quoted = false, esc = false;
  for (let i = start; i < t.length; i++) {
    const c = t[i];
    if (quoted) {
      if (esc) esc = false;
      else if (c === "\\") esc = true;
      else if (c === '"') quoted = false;
      continue;
    }
    if (c === '"') quoted = true;
    else if (c === "{") depth++;
    else if (c === "}" && --depth === 0) {
      try {
        const v = JSON.parse(t.slice(start, i + 1));
        return v && typeof v === "object" && !Array.isArray(v) ? v : null;
      } catch {
        return null;
      }
    }
  }
  return null;
}

/** The quoted history under a reply, cut, so Yui reads what is new. */
export function newPart(text: string): string {
  const lines = text.replace(/\r\n/g, "\n").split("\n");
  const cut = lines.findIndex((l) => /^On .{4,200} wrote:\s*$/.test(l.trim()) || /^-{2,}\s*Original Message\s*-{2,}/i.test(l.trim()) || /^From: .+/.test(l) && lines.some((x) => /^Sent: /.test(x)));
  const kept = (cut > 0 ? lines.slice(0, cut) : lines).filter((l) => !/^>/.test(l));
  return kept.join("\n").trim();
}

/** HTML-only mail -> readable text for Yui. */
export function htmlToText(html: string): string {
  return html
    .replace(/<(script|style|head)[\s\S]*?<\/\1>/gi, "")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/(p|div|li|tr|h\d)>/gi, "\n")
    .replace(/<a [^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/gi, "$2 ($1)")
    .replace(/<[^>]+>/g, "")
    .replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;/g, "'")
    .replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
}
