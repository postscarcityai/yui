// Mailbox operations shared by the API (index.ts: Hermes Yui, the server) and the
// hosted Yui's own tools (brain.ts). One place, so both hands work the same way.
import { senderAddress } from "./mail.ts";
import { type Attachment, MailRefused, sendMail, type SentBy } from "./send.ts";

// deno-lint-ignore no-explicit-any
type Db = any;
const str = (v: unknown, n: number) => (typeof v === "string" ? v.trim().slice(0, n) : "");
export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export async function listThreads(db: Db, o: { status?: unknown; q?: unknown; limit?: unknown }) {
  let q = db.from("yui_mail_threads").select("id, subject, counterpart, status, summary, last_at").order("last_at", { ascending: false })
    .limit(Math.min(Math.max(Number(o.limit) || 30, 1), 200));
  if (typeof o.status === "string" && o.status) q = q.eq("status", o.status);
  if (typeof o.q === "string" && o.q.trim()) {
    const s = o.q.trim().replace(/[%,()]/g, " ").slice(0, 80);
    q = q.or(`subject.ilike.%${s}%,counterpart.ilike.%${s}%,summary.ilike.%${s}%`);
  }
  const { data, error } = await q;
  if (error) throw error;
  return data ?? [];
}

async function signed(db: Db, atts: { name: string; path?: string; url?: string; type: string; size: number }[]) {
  return await Promise.all((atts ?? []).map(async (a) => {
    if (!a.path) return { name: a.name, type: a.type, size: a.size, url: a.url ?? null };
    const { data } = await db.storage.from("yui-mail").createSignedUrl(a.path, 3600);
    return { name: a.name, type: a.type, size: a.size, url: data?.signedUrl ?? null };
  }));
}

export async function readThread(db: Db, id: string) {
  if (!UUID.test(id)) return null;
  const [{ data: t }, { data: msgs }] = await Promise.all([
    db.from("yui_mail_threads").select("*").eq("id", id).maybeSingle(),
    db.from("yui_mail_messages").select("id, direction, from_addr, from_name, to_addrs, cc_addrs, subject, text_body, attachments, spam_score, kind, sent_by, status, error, created_at")
      .eq("thread_id", id).order("created_at"),
  ]);
  if (!t) return null;
  for (const m of msgs ?? []) m.attachments = await signed(db, m.attachments);
  return { thread: t, messages: msgs ?? [] };
}

export async function listContacts(db: Db, o: { q?: unknown; promo?: unknown; limit?: unknown }) {
  let q = db.from("yui_mail_contacts").select("email, name, promo, confirmed_at, unsubscribed_at, unsubscribed_all_at, bounced_at, complained_at, created_at")
    .order("created_at", { ascending: false }).limit(Math.min(Math.max(Number(o.limit) || 50, 1), 500));
  if (typeof o.q === "string" && o.q.trim()) q = q.ilike("email", `%${o.q.trim().replace(/[%_]/g, "").slice(0, 80)}%`);
  if (typeof o.promo === "boolean") q = q.eq("promo", o.promo);
  const { data, error } = await q;
  if (error) throw error;
  return data ?? [];
}

export async function currentRules(db: Db) {
  const { data } = await db.from("yui_mail_rules").select("id, body, note, written_by, created_at").order("id", { ascending: false }).limit(1).maybeSingle();
  return data;
}

export async function setRules(db: Db, body: string, note: string, writtenBy: string): Promise<number> {
  const b = str(body, 20_000);
  if (!b) throw new MailRefused("body_required");
  const { data, error } = await db.from("yui_mail_rules").insert({ body: b, note: str(note, 500) || null, written_by: writtenBy }).select("id").single();
  if (error) throw error;
  return data.id;
}

/** News to everyone who asked for it and hasn't stopped it. Stops at the daily cap. */
export async function campaign(
  db: Db, o: { subject?: unknown; text?: unknown; html?: unknown; from?: unknown; limit?: unknown; dry_run?: unknown; attachments?: Attachment[] }, by: SentBy,
) {
  const subject = str(o.subject, 200), text = str(o.text, 50_000);
  if (!subject || !text) throw new MailRefused("subject_and_text_required");
  const max = Math.min(Math.max(Number(o.limit) || 5000, 1), 5000);
  const { data: people, error } = await db.from("yui_mail_contacts").select("email, name")
    .eq("promo", true).is("unsubscribed_at", null).is("unsubscribed_all_at", null).is("bounced_at", null).is("complained_at", null)
    .order("email").limit(max);
  if (error) throw error;
  if (o.dry_run) return { ok: true, dry_run: true, would_send: people.length };
  const results = { sent: 0, refused: {} as Record<string, number>, failed: 0 };
  for (const p of people) {
    try {
      await sendMail(db, {
        to: p.email, toName: p.name, subject, text, html: str(o.html, 200_000) || null, from: senderAddress(typeof o.from === "string" ? o.from : "yui"),
        kind: "promo", sentBy: by, attachments: o.attachments,
      });
      results.sent++;
    } catch (e) {
      if (e instanceof MailRefused) {
        results.refused[e.code] = (results.refused[e.code] ?? 0) + 1;
        if (e.code === "daily_cap" || e.code === "mail_off" || e.code === "no_postal_address") break;
      } else results.failed++;
    }
  }
  return { ok: true, ...results, of: people.length };
}
