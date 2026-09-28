// What Yui knows about Yui: the brand kit the site publishes at /brand.json (yuigui
// site/lib/brand.mjs), built from the same files the site renders: posts, releases,
// what shipped, what is being built, the backlog, features, pages and the logos.
// Plus two hands: read a page on the site or the repos, and fetch a file to attach.
import { htmlToText, SITE } from "./mail.ts";
import type { Attachment } from "./send.ts";

// deno-lint-ignore no-explicit-any
export type Kit = Record<string, any>;

let cached: { at: number; kit: Kit | null; llms: string } | null = null;

/** The kit, fetched at most every ten minutes per instance. Falls back to llms.txt alone. */
export async function kit(fetcher: typeof fetch = fetch): Promise<{ kit: Kit | null; llms: string }> {
  if (cached && Date.now() - cached.at < 10 * 60_000) return cached;
  const get = async (p: string) => {
    try {
      const r = await fetcher(`${SITE}${p}`, { signal: AbortSignal.timeout(8000) });
      return r.ok ? await r.text() : null;
    } catch {
      return null;
    }
  };
  const [k, llms] = await Promise.all([get("/brand.json"), get("/llms.txt")]);
  let parsed: Kit | null = null;
  try {
    parsed = k ? JSON.parse(k) : null;
  } catch { /* an HTML error page */ }
  cached = { at: Date.now(), kit: parsed, llms: llms ?? "" };
  return cached;
}

export function resetKitCache() {
  cached = null;
}

export interface Hit {
  kind: string;
  title: string;
  date?: string;
  url?: string;
  text: string;
  score: number;
}

/** Everything in the kit as searchable entries. */
export function entries(k: Kit): Hit[] {
  const out: Hit[] = [];
  const add = (kind: string, title: string, text: string, url?: string, date?: string) =>
    out.push({ kind, title: String(title ?? ""), text: String(text ?? ""), url, date, score: 0 });
  for (const p of k.posts ?? []) add(`post (${p.tag})`, p.title, p.dek, p.url, p.date);
  for (const r of k.releases ?? []) add("release", `Build ${r.build}`, (r.changes ?? []).join("; "), `${SITE}/changelog`, r.date);
  for (const s of k.shipped ?? []) add("shipped", s.title, `${s.card ?? ""} ${s.short ?? ""}`, s.url, s.date);
  for (const c of k.building ?? []) add("building now", c.title, `${c.key} ${c.summary ?? ""}`, `${SITE}/board`);
  for (const c of k.up_next ?? []) add("up next", c.title, `${c.key} ${c.summary ?? ""}`, `${SITE}/board`);
  for (const c of k.backlog ?? []) add("backlog", c.title, `${c.key} ${c.summary ?? ""}`, `${SITE}/board`);
  for (const c of k.agent_cards ?? []) add("card for contributors", c.title, `${c.key} ${c.goal ?? ""}`, `${SITE}/contribute`);
  for (const f of k.features ?? []) add("feature", f.title, `${f.lede ?? ""} ${(f.items ?? []).join("; ")}`, `${SITE}/mockups`);
  for (const p of k.pages ?? []) add("page", p.title, p.about, p.url);
  for (const a of k.assets ?? []) add("brand file", a.name, `${a.kind} ${a.shape} background ${a.background} logo image png`, a.url);
  return out;
}

const STOP = new Set(["the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "is", "are", "what", "how", "me", "my", "our", "we", "yui", "with", "about"]);

export function search(k: Kit, query: string, kind?: string, limit = 8): Hit[] {
  const words = query.toLowerCase().split(/[^a-z0-9.]+/).filter((w) => w.length > 1 && !STOP.has(w));
  const pool = entries(k).filter((e) => !kind || e.kind.startsWith(kind));
  if (!words.length) return pool.slice(0, limit);
  for (const e of pool) {
    const title = e.title.toLowerCase(), text = e.text.toLowerCase();
    e.score = words.reduce((s, w) => s + (title.includes(w) ? 3 : 0) + (text.includes(w) ? 1 : 0), 0);
  }
  return pool.filter((e) => e.score > 0).sort((a, b) => b.score - a.score || (b.date ?? "").localeCompare(a.date ?? "")).slice(0, limit)
    .map((e) => ({ ...e, text: e.text.length > 400 ? e.text.slice(0, 399) + "…" : e.text }));
}

/** A short picture of now, for every prompt: the newest posts and releases, what is being built, the square logos. */
export function snapshot(k: Kit | null, llms: string): string {
  if (!k) return llms ? `The site's own summary (llms.txt):\n${llms.slice(0, 6000)}` : "";
  const lines: string[] = [];
  const a = k.about ?? {};
  lines.push(`${a.one_line ?? ""} ${a.stage ?? ""}`.trim());
  if (a.links) lines.push("Links: " + Object.entries(a.links).map(([n, u]) => `${n} ${u}`).join(", "));
  if (k.voice?.length) lines.push("Brand voice: " + k.voice.join(" "));
  if (k.colors) lines.push("Colors: " + Object.entries(k.colors).map(([n, c]) => `${n} ${c}`).join(", "));
  lines.push("Newest posts:\n" + (k.posts ?? []).slice(0, 6).map((p: Kit) => `- ${p.date} ${p.title} (${p.tag}) ${p.url}`).join("\n"));
  lines.push("Newest releases:\n" + (k.releases ?? []).slice(0, 3).map((r: Kit) => `- build ${r.build}, ${r.date}: ${(r.changes ?? []).slice(0, 4).join("; ")}`).join("\n"));
  if (k.release_in_progress) lines.push(`Release in progress: ${k.release_in_progress.version} (${k.release_in_progress.status}): ` + (k.release_in_progress.cards ?? []).map((c: Kit) => `${c.title} [${c.status}]`).join("; "));
  lines.push("Building now: " + (k.building ?? []).map((c: Kit) => c.title).join("; "));
  lines.push("Up next: " + (k.up_next ?? []).map((c: Kit) => c.title).join("; "));
  const squares = (k.assets ?? []).filter((x: Kit) => String(x.shape).startsWith("square")).map((x: Kit) => `${x.name} (${x.background}) ${x.url}`);
  if (squares.length) lines.push("Square logos you can attach:\n" + squares.map((s: string) => `- ${s}`).join("\n"));
  lines.push(`Counts: ${(k.posts ?? []).length} posts, ${(k.releases ?? []).length} releases, ${(k.shipped ?? []).length} shipped items, ${(k.backlog ?? []).length} backlog cards, ${(k.features ?? []).length} feature groups. Search them with brand_search.`);
  return lines.join("\n\n");
}

const READABLE = /^https:\/\/(www\.)?yuigui\.com\/|^https:\/\/github\.com\/postscarcityai\/|^https:\/\/raw\.githubusercontent\.com\/postscarcityai\//;
const ATTACHABLE = /^https:\/\/(www\.)?yuigui\.com\/[A-Za-z0-9._~\/-]+\.(png|jpe?g|webp|gif|pdf|svg|mp4)$/i;
const TYPES: Record<string, string> = { png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", webp: "image/webp", gif: "image/gif", pdf: "application/pdf", svg: "image/svg+xml", mp4: "video/mp4" };
export const ATTACH_MAX = 7 * 1024 * 1024;

/** A page on the site or the repos, as text. Anywhere else is refused. */
export async function readPage(url: string, fetcher: typeof fetch = fetch): Promise<string> {
  if (!READABLE.test(url)) return "Refused: only pages on yuigui.com and github.com/postscarcityai can be read.";
  try {
    const r = await fetcher(url, { signal: AbortSignal.timeout(10_000), headers: { "user-agent": "Yui mail" } });
    if (!r.ok) return `That page answered ${r.status}.`;
    const type = r.headers.get("content-type") ?? "";
    const body = await r.text();
    const text = type.includes("html") ? htmlToText(body) : body;
    return text.length > 12_000 ? text.slice(0, 12_000) + "\n[cut]" : text;
  } catch (e) {
    return `Couldn't read it: ${String(e)}`;
  }
}

/** A file on yuigui.com, fetched to go with an email. */
export async function fetchAttachment(url: string, fetcher: typeof fetch = fetch): Promise<Attachment | string> {
  if (!ATTACHABLE.test(url)) return "Refused: attach files from yuigui.com only (png, jpg, webp, gif, pdf, svg, mp4).";
  try {
    const r = await fetcher(url, { signal: AbortSignal.timeout(15_000) });
    if (!r.ok) return `That file answered ${r.status}.`;
    const buf = new Uint8Array(await r.arrayBuffer());
    if (buf.length > ATTACH_MAX) return "Too big to attach (over 7 MB). Send the link instead.";
    let bin = "";
    for (let i = 0; i < buf.length; i += 0x8000) bin += String.fromCharCode(...buf.subarray(i, i + 0x8000));
    const ext = url.split(".").pop()!.toLowerCase();
    return { filename: url.split("/").pop()!, type: TYPES[ext] ?? "application/octet-stream", content: btoa(bin), size: buf.length, source: url };
  } catch (e) {
    return `Couldn't fetch it: ${String(e)}`;
  }
}
