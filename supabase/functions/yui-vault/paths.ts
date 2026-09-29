// The fixed hosts and the paths each provider may be called on (YUI-34, spec
// VAULT.md section 4). A vault key is only ever sent to HOSTS[provider], to a
// path on that provider's list. Anything else is path_not_allowed.

export const HOSTS: Record<string, string> = {
  fal: "https://fal.run",
  replicate: "https://api.replicate.com",
  elevenlabs: "https://api.elevenlabs.io",
  anthropic: "https://api.anthropic.com",
  openai: "https://api.openai.com",
};

export type Rule = { methods: string[]; re: RegExp };
const SEG = "[A-Za-z0-9][A-Za-z0-9._-]{0,80}";

export const ALLOWED: Record<string, Rule[]> = {
  // fal model endpoints: fal-ai/<app>[/<sub>...]. Queue and storage hosts are other hosts, not reachable.
  fal: [{ methods: ["POST"], re: new RegExp(`^fal-ai/${SEG}(/${SEG}){0,4}$`) }],
  replicate: [
    { methods: ["POST"], re: /^v1\/predictions$/ },
    { methods: ["POST"], re: new RegExp(`^v1/models/${SEG}/${SEG}/predictions$`) },
    { methods: ["GET"], re: new RegExp(`^v1/predictions/${SEG}$`) },
    { methods: ["POST"], re: new RegExp(`^v1/predictions/${SEG}/cancel$`) },
  ],
  elevenlabs: [
    { methods: ["POST"], re: new RegExp(`^v1/text-to-speech/${SEG}(/stream)?$`) },
    { methods: ["POST"], re: /^v1\/sound-generation$/ },
    { methods: ["GET"], re: /^v1\/models$/ },
  ],
  anthropic: [
    { methods: ["POST"], re: /^v1\/messages$/ },
    { methods: ["POST"], re: /^v1\/messages\/count_tokens$/ },
    { methods: ["GET"], re: /^v1\/models$/ },
  ],
  openai: [
    { methods: ["POST"], re: /^v1\/(chat\/completions|responses|embeddings|images\/generations|audio\/speech)$/ },
    { methods: ["GET"], re: /^v1\/models$/ },
  ],
};

// A path is only ever plain segments: no dots-only segments, no encoded
// separators, no query or fragment smuggled in, no empty segment.
export function cleanPath(raw: string): string | null {
  if (!raw || raw.length > 300) return null;
  if (/[%\\?#@:\s\x00-\x1f]/.test(raw)) return null;
  const parts = raw.split("/");
  if (parts.some((p) => p === "" || p === "." || p === "..")) return null;
  return parts.join("/");
}

export function pathAllowed(provider: string, method: string, path: string | null): boolean {
  if (path === null) return false;
  return (ALLOWED[provider] ?? []).some((r) => r.methods.includes(method) && r.re.test(path));
}

// The query string a GET may carry to the provider: plain key=value pairs only.
export function cleanQuery(search: string): string | null {
  if (!search || search === "?") return "";
  return /^\?[A-Za-z0-9_.=&-]{1,200}$/.test(search) ? search : null;
}
