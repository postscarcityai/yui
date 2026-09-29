// Looking things up for native agents (YUI-142): Firecrawl search and fetch.
// Yui's own Firecrawl key gives each person a free number of lookups a month
// (yui_limits); a person's own key, added in Settings, lifts that cap.
// The model never calls Firecrawl itself: it writes a `search` or `fetch`
// block, the turn runs it here and hands back plain text plus the sources.

export interface Source {
  title: string;
  url: string;
}

export interface Found {
  text: string; // what the model reads
  sources: Source[];
}

/** Firecrawl said no: a bad key (401), no credits left (402), too many at once (429), or down. */
export class LookupError extends Error {
  status: number;
  constructor(message: string, status = 0) {
    super(message);
    this.status = status;
  }
}

const API = "https://api.firecrawl.dev/v2";
const PAGE_CHARS = 6000; // a fetched page, cut to fit the prompt

export class Firecrawl {
  private key: string;
  private fetchImpl: typeof fetch;
  private base: string;
  constructor(key: string, fetchImpl: typeof fetch = fetch, base = API) {
    this.key = key;
    this.fetchImpl = fetchImpl;
    this.base = base;
  }

  /** Web results for one query: title, link and a line each. */
  async search(query: string, limit = 5): Promise<Found> {
    const d = await this.post("/search", { query: query.slice(0, 200), limit });
    // v2 answers {data: {web: [...]}}, v1 {data: [...]}.
    const hits: any[] = Array.isArray(d?.data) ? d.data : d?.data?.web ?? [];
    const sources: Source[] = [];
    const lines: string[] = [];
    for (const h of hits.slice(0, limit)) {
      const url = String(h?.url ?? "");
      if (!/^https?:\/\//.test(url)) continue;
      const title = oneLine(h?.title || h?.metadata?.title || hostOf(url), 120);
      sources.push({ title, url });
      lines.push(`${sources.length}. ${title}\n   ${url}\n   ${oneLine(h?.description ?? h?.snippet ?? "", 300)}`);
    }
    return { text: lines.length ? lines.join("\n") : "No results.", sources };
  }

  /** One page as markdown, main content only, cut to fit. */
  async fetchPage(url: string): Promise<Found> {
    if (!safeUrl(url)) throw new LookupError("that isn't a web address I can open");
    const d = await this.post("/scrape", { url, formats: ["markdown"], onlyMainContent: true, timeout: 20000 });
    const md = String(d?.data?.markdown ?? "").trim();
    const title = oneLine(d?.data?.metadata?.title || hostOf(url), 120);
    const cut = md.length > PAGE_CHARS ? `${md.slice(0, PAGE_CHARS)}\n[cut: the page goes on]` : md;
    return { text: `${title}\n${url}\n\n${cut || "(the page had no text)"}`, sources: [{ title, url }] };
  }

  /** Whether the key works, without spending a credit. */
  async check(): Promise<string | null> {
    try {
      const r = await this.fetchImpl(`${this.base}/team/credit-usage`, {
        headers: { authorization: `Bearer ${this.key}` }, signal: AbortSignal.timeout(10_000),
      });
      await r.body?.cancel();
      if (r.status === 401 || r.status === 403) return "Firecrawl turned this key down";
      if (!r.ok) return `Firecrawl answered ${r.status}`;
      return null;
    } catch {
      return "couldn't reach Firecrawl";
    }
  }

  private async post(path: string, body: Record<string, unknown>): Promise<any> {
    let r: Response;
    try {
      r = await this.fetchImpl(`${this.base}${path}`, {
        method: "POST",
        headers: { "content-type": "application/json", authorization: `Bearer ${this.key}` },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(30_000),
      });
    } catch {
      throw new LookupError("couldn't reach the web just now");
    }
    if (!r.ok) {
      await r.body?.cancel();
      throw new LookupError(WHY[r.status] ?? `the search service answered ${r.status}`, r.status);
    }
    const d = await r.json().catch(() => null);
    if (d?.success === false) throw new LookupError(oneLine(String(d?.error ?? "the lookup failed"), 120));
    return d;
  }
}

const WHY: Record<number, string> = {
  401: "the Firecrawl key was turned down",
  402: "the Firecrawl key is out of credits",
  429: "too many lookups at once",
};

/** http(s) only, and never a private address (Firecrawl fetches it, but a link to localhost is never what anyone meant). */
export function safeUrl(u: string): boolean {
  let url: URL;
  try {
    url = new URL(u);
  } catch {
    return false;
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") return false;
  const h = url.hostname.toLowerCase();
  return !!h && h.includes(".") && !/^(localhost|127\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.|\[|0\.)/.test(h)
    && !h.endsWith(".local") && !h.endsWith(".internal");
}

/** The sources the answer does not already link, as card lines (at most three). */
export function sourceCards(body: string, sources: Source[]): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const s of sources) {
    if (seen.has(s.url) || body.includes(s.url) || !s.url.startsWith("https://")) continue;
    seen.add(s.url);
    out.push(`card ${q(s.title)} sub=${q(hostOf(s.url))} cta=Read url="${s.url.replace(/"/g, "%22").replace(/\s/g, "%20")}"`);
    if (out.length === 3) break;
  }
  return out;
}

/** The invite when the free lookups are used up: add your own Firecrawl key in Settings (never in chat). */
export function searchInvite(why: "month" | "day", limit: number): string {
  const body = why === "month"
    ? `Yui looks up ${limit} things a month for you for free. Add your own Firecrawl key in Settings and lookups have no limit.`
    : "That's today's free lookups. They come back tomorrow, or add your own Firecrawl key in Settings for no limit.";
  return `card "Free web searches used" body=${q(body)} cta="Open Settings" url=yui://settings/search`;
}

/** A lookup on a key with no web search of its own runs on Yui's free allowance (20 a day): the card says so. */
export function searchOnYui(provider: string): string {
  return `card "Looked up on Yui" body=${q(`Your ${provider} key has no web search, so that lookup used Yui's free ones (20 a day).`)}`;
}

function q(s: string): string {
  return `"${s.replace(/"/g, "'").replace(/\s+/g, " ").trim()}"`;
}

function oneLine(s: string, max: number): string {
  const t = String(s).replace(/\s+/g, " ").trim();
  return t.length > max ? `${t.slice(0, max - 1)}…` : t;
}

export function hostOf(u: string): string {
  try {
    return new URL(u).hostname.replace(/^www\./, "");
  } catch {
    return u.slice(0, 60);
  }
}
