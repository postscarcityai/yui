// Every email that leaves yuigui.com goes through sendMail: the switch, the
// suppressions, the caps, the row, then SendGrid. Nothing here waits on a person.
import { DOMAIN, frame, promoFooter, SITE, textToHtml } from "./mail.ts";

const env = (n: string) => Deno.env.get(n) ?? "";

export type Kind = "reply" | "new" | "template" | "promo" | "owner";
export type SentBy = "yui" | "hermes" | "site" | "app" | "server";

export interface Outgoing {
  to: string;
  toName?: string | null;
  subject: string;
  text: string;
  html?: string | null;       // the body only; the frame is added here
  from?: string;              // an address at yuigui.com
  fromName?: string;
  replyTo?: string;
  kind: Kind;
  sentBy: SentBy;
  template?: string;
  threadId?: string;
  inReplyTo?: string | null;
  refs?: string[];
}

export class MailRefused extends Error {
  constructor(public code: string) {
    super(code);
  }
}

// deno-lint-ignore no-explicit-any
type Db = any;

async function limit(db: Db, name: string, dflt: number): Promise<number> {
  const { data } = await db.rpc("yui_limit", { n: name });
  return data === null || data === undefined ? dflt : Number(data);
}

/** Stops a send before it is written, with the reason as a code. */
export async function mayMail(db: Db, to: string, kind: Kind): Promise<{ unsub: string | null }> {
  if (await limit(db, "mail_enabled", 1) < 1) throw new MailRefused("mail_off");
  const { data: c } = await db.from("yui_mail_contacts").select("*").eq("email", to).maybeSingle();
  if (c?.bounced_at || c?.complained_at) throw new MailRefused("address_suppressed");
  if (c?.unsubscribed_all_at && kind !== "template") throw new MailRefused("address_unsubscribed");
  if (kind === "promo") {
    if (!c?.promo || c.unsubscribed_at) throw new MailRefused("no_promo_consent");
    if (!env("YUI_MAIL_POSTAL_ADDRESS")) throw new MailRefused("no_postal_address");
  }
  const promo = kind === "promo";
  const [{ data: today }, cap] = await Promise.all([
    db.rpc("yui_mail_sent_today", { promo }),
    limit(db, promo ? "mail_promo_per_day" : "mail_per_day", promo ? 2000 : 400),
  ]);
  if (Number(today ?? 0) >= cap) throw new MailRefused("daily_cap");
  const since = new Date(Date.now() - 86_400_000).toISOString();
  const { count } = await db.from("yui_mail_messages").select("id", { count: "exact", head: true })
    .eq("direction", "out").neq("status", "failed").contains("to_addrs", [to]).gte("created_at", since);
  // Notes to the owner are not capped per address: they are how Yui reaches him.
  if (kind !== "owner" && (count ?? 0) >= await limit(db, "mail_per_address_per_day", 10)) throw new MailRefused("address_cap");
  return { unsub: c?.unsub_token ?? null };
}

/** The thread an outgoing email belongs to: the one given, or a new one. */
async function threadFor(db: Db, m: Outgoing): Promise<string> {
  if (m.threadId) return m.threadId;
  const { data, error } = await db.from("yui_mail_threads")
    .insert({ subject: m.subject.slice(0, 500), counterpart: m.to, status: m.kind === "reply" ? "handled" : "waiting" })
    .select("id").single();
  if (error) throw error;
  return data.id;
}

export function unsubUrl(token: string): string {
  return `${SITE}/unsubscribe?t=${token}`;
}

export function oneClickUrl(token: string): string {
  return `${env("SUPABASE_URL")}/functions/v1/yui-mail?unsub=${token}`;
}

/** Sends one email. Returns the stored row's id. Throws MailRefused or the provider's error. */
export async function sendMail(db: Db, m: Outgoing): Promise<{ id: string; threadId: string; messageId: string }> {
  const to = m.to.trim().toLowerCase();
  const { unsub } = await mayMail(db, to, m.kind);
  // A contact row for everyone Yui writes to, so an unsubscribe always has a token.
  if (!unsub) await db.from("yui_mail_contacts").upsert({ email: to, name: m.toName ?? null }, { onConflict: "email", ignoreDuplicates: true });
  const { data: c } = await db.from("yui_mail_contacts").select("unsub_token").eq("email", to).maybeSingle();
  const token: string = c?.unsub_token ?? unsub ?? "";

  const threadId = await threadFor(db, m);
  const id = crypto.randomUUID();
  const messageId = `${id}@${DOMAIN}`;
  const from = m.from ?? `yui@${DOMAIN}`;
  let text = m.text.trim();
  let body = m.html?.trim() || textToHtml(text);
  let footer = "";
  const headers: Record<string, string> = { "Message-ID": `<${messageId}>` };
  if (m.inReplyTo) headers["In-Reply-To"] = `<${m.inReplyTo}>`;
  const refs = [...(m.refs ?? []), ...(m.inReplyTo && !(m.refs ?? []).includes(m.inReplyTo) ? [m.inReplyTo] : [])].slice(-20);
  if (refs.length) headers["References"] = refs.map((r) => `<${r}>`).join(" ");
  if (m.kind === "promo") {
    const f = promoFooter(unsubUrl(token), env("YUI_MAIL_POSTAL_ADDRESS"));
    text += `\n\n--\n${f.text}`;
    footer = f.html;
    headers["List-Unsubscribe"] = `<${oneClickUrl(token)}>, <mailto:unsubscribe@${DOMAIN}?subject=unsubscribe>`;
    headers["List-Unsubscribe-Post"] = "List-Unsubscribe=One-Click";
  } else if (token) {
    headers["List-Unsubscribe"] = `<${oneClickUrl(token)}&all=1>`;
  }
  const html = frame(body, footer);

  const row = {
    id, thread_id: threadId, direction: "out", message_id: messageId, in_reply_to: m.inReplyTo ?? null, refs,
    from_addr: from, from_name: m.fromName ?? "Yui", to_addrs: [to], subject: m.subject, text_body: text,
    html_body: html, kind: m.kind, template: m.template ?? null, sent_by: m.sentBy, status: "sent",
  };
  const { error: insErr } = await db.from("yui_mail_messages").insert(row);
  if (insErr) throw insErr;

  const payload = {
    personalizations: [{ to: [{ email: to, ...(m.toName ? { name: m.toName } : {}) }], custom_args: { yui_msg: id } }],
    from: { email: from, name: m.fromName ?? "Yui" },
    reply_to: { email: m.replyTo ?? from, name: m.fromName ?? "Yui" },
    subject: m.subject,
    content: [{ type: "text/plain", value: text }, { type: "text/html", value: html }],
    headers,
    categories: ["yui", m.kind],
    // Links stay as written: a confirmation link must be the link, not a tracker.
    tracking_settings: { click_tracking: { enable: false, enable_text: false }, open_tracking: { enable: false }, subscription_tracking: { enable: false } },
  };
  const r = await fetch("https://api.sendgrid.com/v3/mail/send", {
    method: "POST",
    headers: { authorization: `Bearer ${env("YUI_SENDGRID_KEY")}`, "content-type": "application/json" },
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(20_000),
  }).catch((e) => e as Error);
  if (r instanceof Error || !r.ok) {
    const why = r instanceof Error ? r.message : `${r.status} ${(await r.text()).slice(0, 400)}`;
    await db.from("yui_mail_messages").update({ status: "failed", error: why }).eq("id", id);
    throw new Error(`sendgrid: ${why}`);
  }
  await r.body?.cancel();
  await db.from("yui_mail_messages").update({ sg_message_id: r.headers.get("x-message-id") }).eq("id", id);
  await db.from("yui_mail_threads").update({ last_at: new Date().toISOString() }).eq("id", threadId);
  return { id, threadId, messageId };
}
