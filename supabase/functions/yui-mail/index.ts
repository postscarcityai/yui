// yui-mail: Yui's mailbox at yuigui.com (spec: the plan in this function's migration,
// 20260928100000_yui_mail.sql).
//
// Callers, by how they prove who they are:
//
// SendGrid Inbound Parse, POST ?in=<YUI_MAIL_INBOUND_SECRET>, multipart: a new
//   email for any address at yuigui.com. Stored, threaded, then Yui reads it and
//   acts on her own (brain.ts). Always 200 once stored, so SendGrid never resends.
// SendGrid's event webhook, POST ?events=1, signed (YUI_MAIL_EVENTS_KEY is its
//   public key): delivered, bounce, dropped, spam report, unsubscribe. Only
//   events for mail sent here (custom arg yui_msg) are kept.
// A one-click unsubscribe, POST ?unsub=<token>[&all=1] (List-Unsubscribe-Post).
// The database's daily sweep, header x-yui-native: {action: "sweep"}.
//
// JSON {action, ...}:
//   public, by token:  confirm {token}            -> {ok, email}
//                      unsubscribe {token, all?}  -> {ok}
//   server (Bearer the service role key; the site and the app's functions):
//                      request {email, first_name?, template?: "invite_request"|"confirm", promo?, source?}
//                                                 -> sends a confirmation link
//                      template {to, template, data?}
//                      send {to, subject, text, html?, from?, kind?: "new"|"promo"}
//   Yui's own tools (Bearer YUI_MAIL_AGENT_KEY: Hermes Yui, MCP), plus everything above:
//                      inbox {status?, q?, limit?}, thread {id}, reply {thread_id, text, html?},
//                      mark {thread_id, status, summary?}, rules {}, rules_set {body, note?},
//                      contacts {q?, promo?, limit?}, contact_set {email, name?, promo?},
//                      campaign {subject, text, html?, dry_run?, limit?}
//
// Secrets: YUI_SENDGRID_KEY (a restricted key: mail send, suppressions),
// YUI_MAIL_INBOUND_SECRET, YUI_MAIL_EVENTS_KEY, YUI_MAIL_AGENT_KEY,
// YUI_MAIL_OWNER_EMAIL, YUI_MAIL_POSTAL_ADDRESS (promos only), YUI_OPENROUTER_KEY.
import { admin, failure, json, sha256Hex, take } from "../_shared/yui.ts";
import { handle, type Incoming } from "./brain.ts";
import {
  baseSubject, htmlToText, messageIds, parseAddress, parseAddressList, parseHeaders, replySubject, senderAddress, SITE,
  template, validAddress, verifyEventSignature,
} from "./mail.ts";
import { MailRefused, sendMail, type SentBy } from "./send.ts";

const env = (n: string) => Deno.env.get(n) ?? "";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// deno-lint-ignore no-explicit-any
type Db = any;
// deno-lint-ignore no-explicit-any
type Body = Record<string, any>;

function same(a: string, b: string): boolean {
  if (!a || !b || a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

function later(work: Promise<unknown>) {
  // deno-lint-ignore no-explicit-any
  const rt = (globalThis as any).EdgeRuntime;
  if (rt?.waitUntil) rt.waitUntil(work);
  return rt?.waitUntil ? Promise.resolve() : work;
}

/** Who is calling: the server (service role), Yui's own tools, or nobody in particular. */
function caller(req: Request): "server" | "agent" | null {
  const t = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!t) return null;
  if (same(t, env("YUI_MAIL_AGENT_KEY"))) return "agent";
  const keys = [env("SUPABASE_SERVICE_ROLE_KEY")];
  try {
    const more = JSON.parse(env("SUPABASE_SECRET_KEYS") || "{}");
    if (more && typeof more === "object") keys.push(...Object.values(more).map(String));
  } catch { /* not JSON: only the legacy key */ }
  return keys.some((k) => same(t, k)) ? "server" : null;
}

const str = (v: unknown, n: number) => (typeof v === "string" ? v.trim().slice(0, n) : "");

// Inbound ------------------------------------------------------------------------

async function threadFor(db: Db, from: string, subject: string, ids: string[]): Promise<{ id: string; isNew: boolean }> {
  if (ids.length) {
    const { data } = await db.from("yui_mail_messages").select("thread_id").in("message_id", ids).limit(1);
    if (data?.[0]) return { id: data[0].thread_id, isNew: false };
  }
  const base = baseSubject(subject);
  const since = new Date(Date.now() - 30 * 86_400_000).toISOString();
  const { data: recent } = await db.from("yui_mail_threads").select("id, subject").eq("counterpart", from).gte("last_at", since)
    .order("last_at", { ascending: false }).limit(20);
  const hit = (recent ?? []).find((t: { subject: string }) => baseSubject(t.subject) === base);
  if (hit) return { id: hit.id, isNew: false };
  const { data, error } = await db.from("yui_mail_threads").insert({ subject: subject.slice(0, 500), counterpart: from }).select("id").single();
  if (error) throw error;
  return { id: data.id, isNew: true };
}

async function inbound(req: Request, db: Db): Promise<Response> {
  const form = await req.formData();
  const field = (k: string) => {
    const v = form.get(k);
    return typeof v === "string" ? v : "";
  };
  const rawHeaders = field("headers");
  const h = parseHeaders(rawHeaders);
  const sender = parseAddress(field("from") || h["from"] || "");
  if (!sender) {
    console.error("yui-mail inbound: no sender");
    return json({ ok: true, skipped: "no sender" });
  }
  const messageId = messageIds(h["message-id"])[0] ?? null;
  if (messageId) {
    const { data: seen } = await db.from("yui_mail_messages").select("id").eq("message_id", messageId).maybeSingle();
    if (seen) return json({ ok: true, duplicate: true });
  }
  const subject = (field("subject") || h["subject"] || "").slice(0, 500);
  const inReplyTo = messageIds(h["in-reply-to"])[0] ?? null;
  const refs = messageIds(h["references"]);
  const thread = await threadFor(db, sender.email, subject, [...(inReplyTo ? [inReplyTo] : []), ...refs]);
  const html = field("html");
  const text = field("text") || htmlToText(html);
  const spam = Number.parseFloat(field("spam_score"));
  const id = crypto.randomUUID();

  const attachments: { name: string; type: string; size: number; path: string }[] = [];
  let i = 0;
  for (const [key, v] of form.entries()) {
    if (!(v instanceof File) || !/^attachment\d+$/.test(key)) continue;
    i++;
    const name = (v.name || key).replace(/[^A-Za-z0-9._-]+/g, "_").slice(-80) || key;
    const path = `${thread.id}/${id}/${i}-${name}`;
    const { error } = await db.storage.from("yui-mail").upload(path, v, { contentType: v.type || "application/octet-stream" });
    if (error) console.error("yui-mail attachment", error);
    else attachments.push({ name: v.name || key, type: v.type, size: v.size, path });
  }

  const { error } = await db.from("yui_mail_messages").insert({
    id, thread_id: thread.id, direction: "in", message_id: messageId, in_reply_to: inReplyTo, refs,
    from_addr: sender.email, from_name: sender.name, to_addrs: parseAddressList(field("to") || h["to"]),
    cc_addrs: parseAddressList(field("cc") || h["cc"]), subject, text_body: text.slice(0, 200_000),
    html_body: html.slice(0, 500_000) || null, headers: rawHeaders.slice(0, 50_000), attachments,
    spam_score: Number.isFinite(spam) ? spam : null, auth: { spf: field("SPF") || null, dkim: field("dkim") || null },
    status: "received",
  });
  if (error) throw error;
  await db.from("yui_mail_threads").update({ last_at: new Date().toISOString(), ...(thread.isNew ? {} : { status: "new" }) }).eq("id", thread.id);
  await db.from("yui_mail_contacts").upsert({ email: sender.email, name: sender.name }, { onConflict: "email", ignoreDuplicates: true });

  // The mailto: in List-Unsubscribe: stop their news, nothing to answer.
  if (parseAddressList(field("to") || h["to"]).includes("unsubscribe@yuigui.com")) {
    const now = new Date().toISOString();
    await db.from("yui_mail_contacts").update({ unsubscribed_at: now, promo: false, promo_pending: false, updated_at: now }).eq("email", sender.email);
    await db.from("yui_mail_threads").update({ status: "handled", summary: "Asked to stop the news; done." }).eq("id", thread.id);
    return json({ ok: true });
  }

  const m: Incoming = {
    id, threadId: thread.id, from: sender.email, fromName: sender.name, subject, text, headers: h,
    spamScore: Number.isFinite(spam) ? spam : null, messageId, refs: [...refs, ...(inReplyTo && !refs.includes(inReplyTo) ? [inReplyTo] : [])],
    attachments: attachments.map(({ name, type, size }) => ({ name, type, size })),
  };
  await later(handle(db, m));
  return json({ ok: true });
}

// Delivery events ------------------------------------------------------------------

const EVENT_STATUS: Record<string, string> = {
  delivered: "delivered", bounce: "bounced", dropped: "dropped", deferred: "deferred", spamreport: "spam_report", blocked: "blocked",
};

async function events(req: Request, db: Db): Promise<Response> {
  const body = await req.text();
  const ok = await verifyEventSignature(env("YUI_MAIL_EVENTS_KEY"),
    req.headers.get("x-twilio-email-event-webhook-signature") ?? "",
    req.headers.get("x-twilio-email-event-webhook-timestamp") ?? "", body);
  if (!ok) return json({ error: "bad_signature" }, 401);
  // deno-lint-ignore no-explicit-any
  let list: any[] = [];
  try {
    list = JSON.parse(body);
  } catch {
    return json({ error: "invalid_request" }, 400);
  }
  // The SendGrid account is shared: only mail sent from here carries yui_msg.
  const ours = (Array.isArray(list) ? list : []).filter((e) => typeof e?.yui_msg === "string" && UUID.test(e.yui_msg));
  for (const e of ours) {
    const email = String(e.email ?? "").toLowerCase();
    const event = String(e.event ?? "");
    const { error } = await db.from("yui_mail_events").insert({
      sg_event_id: e.sg_event_id ?? null, sg_message_id: e.sg_message_id ?? null, email, event,
      reason: String(e.reason ?? e.response ?? "").slice(0, 500) || null,
      at: e.timestamp ? new Date(Number(e.timestamp) * 1000).toISOString() : new Date().toISOString(),
    });
    if (error?.code === "23505") continue; // SendGrid resent it
    const status = EVENT_STATUS[event];
    if (status) await db.from("yui_mail_messages").update({ status }).eq("id", e.yui_msg).neq("status", "spam_report");
    const now = new Date().toISOString();
    if (event === "bounce" && e.type !== "blocked") await db.from("yui_mail_contacts").update({ bounced_at: now }).eq("email", email);
    if (event === "spamreport") await db.from("yui_mail_contacts").update({ complained_at: now, promo: false }).eq("email", email);
    if (event === "unsubscribe" || event === "group_unsubscribe") {
      await db.from("yui_mail_contacts").update({ unsubscribed_at: now, promo: false }).eq("email", email);
    }
  }
  return json({ ok: true, kept: ours.length });
}

// Tokens: confirm and unsubscribe ------------------------------------------------------

async function unsubscribe(db: Db, token: string, all: boolean): Promise<boolean> {
  if (!/^[0-9a-f]{36}$/.test(token)) return false;
  const now = new Date().toISOString();
  const { data } = await db.from("yui_mail_contacts")
    .update({ unsubscribed_at: now, promo: false, promo_pending: false, ...(all ? { unsubscribed_all_at: now } : {}), updated_at: now })
    .eq("unsub_token", token).select("email");
  return (data ?? []).length > 0;
}

async function confirm(db: Db, token: string): Promise<string | null> {
  if (!/^[A-Za-z0-9_-]{20,80}$/.test(token)) return null;
  const sha = await sha256Hex(token);
  const { data: c } = await db.from("yui_mail_contacts").select("email, promo_pending, confirm_sent_at").eq("confirm_sha", sha).maybeSingle();
  if (!c) return null;
  if (c.confirm_sent_at && Date.parse(c.confirm_sent_at) < Date.now() - 14 * 86_400_000) return null;
  const now = new Date().toISOString();
  await db.from("yui_mail_contacts").update({
    confirmed_at: now, confirm_sha: null, updated_at: now,
    ...(c.promo_pending ? { promo: true, promo_at: now, promo_pending: false, unsubscribed_at: null } : {}),
  }).eq("email", c.email);
  await db.from("yui_invites").update({ email_confirmed_at: now }).eq("email", c.email).is("email_confirmed_at", null);
  return c.email;
}

/** A confirmation link by email: invite requests from the site, any address the app wants checked. */
async function request(db: Db, b: Body, by: SentBy): Promise<Response> {
  const email = str(b.email, 254).toLowerCase();
  if (!validAddress(email)) return json({ error: "invalid_email" }, 400);
  const name = str(b.first_name, 80) || null;
  const which = b.template === "confirm" ? "confirm" : "invite_request";
  const tokenBytes = crypto.getRandomValues(new Uint8Array(24));
  const token = btoa(String.fromCharCode(...tokenBytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  const now = new Date().toISOString();
  const { data: existing } = await db.from("yui_mail_contacts").select("email, confirm_sent_at").eq("email", email).maybeSingle();
  // One link a minute per address: a form pressed twice sends one email.
  if (existing?.confirm_sent_at && Date.parse(existing.confirm_sent_at) > Date.now() - 60_000) return json({ ok: true, sent: false });
  const patch = {
    email, confirm_sha: await sha256Hex(token), confirm_sent_at: now, updated_at: now,
    ...(name ? { name } : {}),
    ...(b.promo === true ? { promo_pending: true, promo_source: str(b.source, 60) || "site" } : {}),
  };
  const { error } = await db.from("yui_mail_contacts").upsert(patch, { onConflict: "email" });
  if (error) throw error;
  const t = template(which, { first_name: name ?? "", link: `${SITE}/confirm?t=${token}` })!;
  await sendMail(db, { to: email, toName: name, subject: t.subject, text: t.text, kind: "template", template: which, sentBy: by });
  return json({ ok: true, sent: true });
}

// Yui's own tools ------------------------------------------------------------------

async function signed(db: Db, atts: { name: string; path: string; type: string; size: number }[]) {
  return await Promise.all((atts ?? []).map(async (a) => {
    const { data } = await db.storage.from("yui-mail").createSignedUrl(a.path, 3600);
    return { name: a.name, type: a.type, size: a.size, url: data?.signedUrl ?? null };
  }));
}

async function campaign(db: Db, b: Body, by: SentBy): Promise<Response> {
  const subject = str(b.subject, 200), text = str(b.text, 50_000);
  if (!subject || !text) return json({ error: "subject_and_text_required" }, 400);
  const max = Math.min(Math.max(Number(b.limit) || 5000, 1), 5000);
  const { data: people, error } = await db.from("yui_mail_contacts").select("email, name")
    .eq("promo", true).is("unsubscribed_at", null).is("unsubscribed_all_at", null).is("bounced_at", null).is("complained_at", null)
    .order("email").limit(max);
  if (error) throw error;
  if (b.dry_run) return json({ ok: true, dry_run: true, would_send: people.length });
  const results = { sent: 0, refused: {} as Record<string, number>, failed: 0 };
  for (const p of people) {
    try {
      await sendMail(db, { to: p.email, toName: p.name, subject, text, html: str(b.html, 200_000) || null, from: senderAddress(b.from ?? "yui"), kind: "promo", sentBy: by });
      results.sent++;
    } catch (e) {
      if (e instanceof MailRefused) {
        results.refused[e.code] = (results.refused[e.code] ?? 0) + 1;
        if (e.code === "daily_cap" || e.code === "mail_off" || e.code === "no_postal_address") break;
      } else results.failed++;
    }
  }
  return json({ ok: true, ...results, of: people.length });
}

async function agentAction(db: Db, b: Body, by: SentBy): Promise<Response | null> {
  switch (b.action) {
    case "inbox": {
      let q = db.from("yui_mail_threads").select("id, subject, counterpart, status, summary, last_at").order("last_at", { ascending: false })
        .limit(Math.min(Math.max(Number(b.limit) || 30, 1), 200));
      if (typeof b.status === "string" && b.status) q = q.eq("status", b.status);
      if (typeof b.q === "string" && b.q.trim()) {
        const s = b.q.trim().replace(/[%,()]/g, " ").slice(0, 80);
        q = q.or(`subject.ilike.%${s}%,counterpart.ilike.%${s}%,summary.ilike.%${s}%`);
      }
      const { data, error } = await q;
      if (error) throw error;
      return json({ threads: data });
    }
    case "thread": {
      if (!UUID.test(String(b.id ?? ""))) return json({ error: "invalid_thread" }, 400);
      const [{ data: t }, { data: msgs }] = await Promise.all([
        db.from("yui_mail_threads").select("*").eq("id", b.id).maybeSingle(),
        db.from("yui_mail_messages").select("id, direction, from_addr, from_name, to_addrs, cc_addrs, subject, text_body, attachments, spam_score, kind, sent_by, status, error, created_at")
          .eq("thread_id", b.id).order("created_at"),
      ]);
      if (!t) return json({ error: "not_found" }, 404);
      for (const m of msgs ?? []) m.attachments = await signed(db, m.attachments);
      return json({ thread: t, messages: msgs });
    }
    case "reply": {
      if (!UUID.test(String(b.thread_id ?? ""))) return json({ error: "invalid_thread" }, 400);
      const text = str(b.text, 20_000);
      if (!text) return json({ error: "text_required" }, 400);
      const { data: t } = await db.from("yui_mail_threads").select("id, subject, counterpart").eq("id", b.thread_id).maybeSingle();
      if (!t) return json({ error: "not_found" }, 404);
      const { data: last } = await db.from("yui_mail_messages").select("message_id, refs, from_name").eq("thread_id", t.id).eq("direction", "in")
        .order("created_at", { ascending: false }).limit(1).maybeSingle();
      const r = await sendMail(db, {
        to: t.counterpart, toName: last?.from_name ?? null, subject: replySubject(t.subject), text, html: str(b.html, 200_000) || null,
        kind: "reply", sentBy: by, threadId: t.id, inReplyTo: last?.message_id ?? null, refs: last?.refs ?? [],
      });
      await db.from("yui_mail_threads").update({ status: "handled" }).eq("id", t.id);
      return json({ ok: true, ...r });
    }
    case "mark": {
      if (!UUID.test(String(b.thread_id ?? ""))) return json({ error: "invalid_thread" }, 400);
      if (!["new", "working", "handled", "waiting", "ignored", "spam"].includes(b.status)) return json({ error: "invalid_status" }, 400);
      const { error } = await db.from("yui_mail_threads").update({ status: b.status, ...(b.summary ? { summary: str(b.summary, 500) } : {}) }).eq("id", b.thread_id);
      if (error) throw error;
      return json({ ok: true });
    }
    case "rules": {
      const { data } = await db.from("yui_mail_rules").select("id, body, note, written_by, created_at").order("id", { ascending: false }).limit(1).maybeSingle();
      return json({ rules: data });
    }
    case "rules_set": {
      const body = str(b.body, 20_000);
      if (!body) return json({ error: "body_required" }, 400);
      const { data, error } = await db.from("yui_mail_rules").insert({ body, note: str(b.note, 500) || null, written_by: by === "hermes" ? "yui" : "owner" })
        .select("id").single();
      if (error) throw error;
      return json({ ok: true, id: data.id });
    }
    case "contacts": {
      let q = db.from("yui_mail_contacts").select("email, name, promo, confirmed_at, unsubscribed_at, unsubscribed_all_at, bounced_at, complained_at, created_at")
        .order("created_at", { ascending: false }).limit(Math.min(Math.max(Number(b.limit) || 50, 1), 500));
      if (typeof b.q === "string" && b.q.trim()) q = q.ilike("email", `%${b.q.trim().replace(/[%_]/g, "").slice(0, 80)}%`);
      if (typeof b.promo === "boolean") q = q.eq("promo", b.promo);
      const { data, error } = await q;
      if (error) throw error;
      return json({ contacts: data });
    }
    case "contact_set": {
      const email = str(b.email, 254).toLowerCase();
      if (!validAddress(email)) return json({ error: "invalid_email" }, 400);
      const now = new Date().toISOString();
      const patch: Body = { email, updated_at: now };
      if (typeof b.name === "string") patch.name = str(b.name, 160) || null;
      // Yui may take someone off promos; only their own confirmation puts them on.
      if (b.promo === false) Object.assign(patch, { promo: false, unsubscribed_at: now });
      const { error } = await db.from("yui_mail_contacts").upsert(patch, { onConflict: "email" });
      if (error) throw error;
      return json({ ok: true });
    }
    case "campaign":
      return await campaign(db, b, by);
    default:
      return null;
  }
}

async function serverAction(db: Db, b: Body, by: SentBy): Promise<Response | null> {
  switch (b.action) {
    case "request":
      return await request(db, b, by);
    case "template": {
      const to = str(b.to, 254).toLowerCase();
      if (!validAddress(to)) return json({ error: "invalid_email" }, 400);
      const data = (b.data && typeof b.data === "object") ? Object.fromEntries(Object.entries(b.data).map(([k, v]) => [k, String(v).slice(0, 500)])) : {};
      const t = template(String(b.template ?? ""), data);
      if (!t) return json({ error: "unknown_template" }, 400);
      const r = await sendMail(db, { to, toName: data.first_name || null, subject: t.subject, text: t.text, kind: "template", template: b.template, sentBy: by });
      return json({ ok: true, ...r });
    }
    case "send": {
      const to = str(b.to, 254).toLowerCase();
      const subject = str(b.subject, 200), text = str(b.text, 50_000);
      if (!validAddress(to)) return json({ error: "invalid_email" }, 400);
      if (!subject || !text) return json({ error: "subject_and_text_required" }, 400);
      const r = await sendMail(db, {
        to, toName: str(b.name, 160) || null, subject, text, html: str(b.html, 200_000) || null,
        from: senderAddress(b.from), fromName: str(b.from_name, 80) || "Yui", kind: b.kind === "promo" ? "promo" : "new", sentBy: by,
      });
      return json({ ok: true, ...r });
    }
    default:
      return null;
  }
}

async function sweep(db: Db): Promise<Response> {
  const days = Number((await db.rpc("yui_limit", { n: "mail_retention_days" })).data ?? 365);
  const cutoff = new Date(Date.now() - days * 86_400_000).toISOString();
  const { data: old } = await db.from("yui_mail_threads").select("id").lt("last_at", cutoff).limit(500);
  let removed = 0;
  for (const t of old ?? []) {
    const { data: msgs } = await db.from("yui_mail_messages").select("attachments").eq("thread_id", t.id);
    const paths = (msgs ?? []).flatMap((m: { attachments: { path: string }[] }) => (m.attachments ?? []).map((a) => a.path));
    if (paths.length) {
      await db.storage.from("yui-mail").remove(paths);
      removed += paths.length;
    }
  }
  const { data: n } = await db.rpc("yui_mail_retention");
  return json({ ok: true, threads: n, attachments: removed });
}

// Router ----------------------------------------------------------------------------

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const db = admin();
  try {
    if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
    if (url.searchParams.has("in")) {
      if (!same(url.searchParams.get("in") ?? "", env("YUI_MAIL_INBOUND_SECRET"))) return json({ error: "unauthorized" }, 401);
      return await inbound(req, db);
    }
    if (url.searchParams.has("events")) return await events(req, db);
    if (url.searchParams.has("unsub")) {
      await take(db, `mail:ip:${req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() || "?"}`, "mail_public");
      const ok = await unsubscribe(db, url.searchParams.get("unsub") ?? "", url.searchParams.get("all") === "1");
      return json({ ok });
    }
    const native = req.headers.get("x-yui-native");
    let b: Body;
    try {
      b = await req.json();
    } catch {
      return json({ error: "invalid_request" }, 400);
    }
    if (native !== null) {
      if (!same(native, env("YUI_NATIVE_SECRET"))) return json({ error: "unauthorized" }, 401);
      return b.action === "sweep" ? await sweep(db) : json({ error: "unknown_action" }, 400);
    }
    if (b.action === "confirm" || b.action === "unsubscribe") {
      await take(db, `mail:ip:${req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() || "?"}`, "mail_public");
      if (b.action === "confirm") {
        const email = await confirm(db, str(b.token, 80));
        return email ? json({ ok: true, email }) : json({ error: "link_expired" }, 400);
      }
      return json({ ok: await unsubscribe(db, str(b.token, 80), b.all === true) });
    }
    const who = caller(req);
    if (!who) return json({ error: "unauthorized" }, 401);
    const by: SentBy = who === "agent" ? "hermes" : (b.sent_by === "app" ? "app" : b.sent_by === "site" ? "site" : "server");
    const res = (await serverAction(db, b, by)) ?? (await agentAction(db, b, by));
    return res ?? json({ error: "unknown_action" }, 400);
  } catch (e) {
    if (e instanceof MailRefused) return json({ error: e.code }, e.code === "daily_cap" || e.code === "address_cap" ? 429 : 409);
    return failure("yui-mail", e);
  }
});
