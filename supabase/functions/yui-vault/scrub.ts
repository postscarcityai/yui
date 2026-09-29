// The key must never reach a log line or an error body (VAULT.md section 4.3).
// Everything the function writes to the console goes through `logger`, which
// scrubs first. `scrub` replaces the key, each half of an id:secret key, and
// anything shaped like a provider key.

const SHAPES = [
  /sk-[A-Za-z0-9_-]{8,}/g,
  /r8_[A-Za-z0-9]{8,}/g,
  /\b[0-9a-fA-F-]{8,}:[A-Za-z0-9]{8,}\b/g,
  /Bearer\s+[A-Za-z0-9._:-]{8,}/gi,
];

export function secretsOf(key: string): string[] {
  const out = new Set<string>();
  if (key.length >= 4) out.add(key);
  for (const part of key.split(/[:\s]+/)) if (part.length >= 6) out.add(part);
  return [...out].sort((a, b) => b.length - a.length);
}

export function scrub(s: string, secrets: string[] = []): string {
  let out = s;
  for (const k of secrets) out = out.split(k).join("[key]");
  for (const re of SHAPES) out = out.replace(re, "[key]");
  return out;
}

export type Sink = (line: string) => void;

// One line per event: name, then plain fields. No bodies, no headers.
export function makeLogger(sink: Sink = (l) => console.log(l)) {
  return (secrets: string[], event: string, fields: Record<string, unknown> = {}) => {
    const rest = Object.entries(fields).map(([k, v]) => `${k}=${String(v).replace(/\s+/g, " ").slice(0, 200)}`).join(" ");
    sink(scrub(`yui-vault ${event} ${rest}`.trim(), secrets));
  };
}
