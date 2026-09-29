// What a call costs, in cents, when the provider does not say (none of these
// five puts a dollar figure in its response). Estimates, kept conservative:
// the provider's own limit on the key is the backstop (VAULT.md section 6).
//
// PRICED must match yui_vault_priced() in migration 20260930000000: a provider
// with no entry here cannot be granted until the owner confirms a limit.

export const PRICED = ["fal", "anthropic", "openai"];

// deno-lint-ignore no-explicit-any
type Json = any;

const cents = (usd: number) => usd * 100;

// USD per million tokens [input, output], first prefix that matches wins.
const ANTHROPIC: [string, number, number][] = [
  ["claude-haiku", 1, 5],
  ["claude-sonnet", 3, 15],
  ["claude-opus", 15, 75],
];
const ANTHROPIC_DEFAULT: [number, number] = [15, 75];
const OPENAI: [string, number, number][] = [
  ["gpt-4o-mini", 0.15, 0.6],
  ["gpt-4o", 2.5, 10],
  ["gpt-4.1-mini", 0.4, 1.6],
  ["gpt-4.1", 2, 8],
  ["gpt-5-mini", 0.25, 2],
  ["gpt-5", 1.25, 10],
  ["text-embedding-3-small", 0.02, 0],
  ["text-embedding-3-large", 0.13, 0],
];
const OPENAI_DEFAULT: [number, number] = [10, 40];

// fal, USD per image or per run. Video and audio endpoints cost far more.
const FAL: [string, number][] = [
  ["fal-ai/flux/schnell", 0.003],
  ["fal-ai/flux/dev", 0.025],
  ["fal-ai/flux-pro", 0.05],
  ["fal-ai/flux-realism", 0.03],
  ["fal-ai/recraft", 0.04],
  ["fal-ai/ideogram", 0.08],
];
const FAL_VIDEO = /video|kling|veo|minimax|luma|runway|hunyuan|wan|ltx|music|lipsync/;

function rate(table: [string, number, number][], fallback: [number, number], model: string): [number, number] {
  for (const [p, i, o] of table) if (model.startsWith(p)) return [i, o];
  return fallback;
}

const tokensFromBytes = (n: number) => Math.ceil(n / 3);

function tokenCost(inRate: number, outRate: number, inTok: number, outTok: number): number {
  return cents((inTok * inRate + outTok * outRate) / 1e6);
}

// The hold taken before the call: what it could cost at most, roughly.
// Never below 1 cent.
export function estimateCents(provider: string, method: string, path: string, body: Json | null, bodyBytes: number): number {
  const b = body && typeof body === "object" ? body : {};
  const model = typeof b.model === "string" ? b.model : "";
  let c = 1;
  switch (provider) {
    case "fal": {
      const n = Math.min(Math.max(Number(b.num_images) || 1, 1), 8);
      const unit = FAL_VIDEO.test(path) ? 1.0 : (FAL.find(([p]) => path.startsWith(p))?.[1] ?? 0.1);
      c = cents(unit) * n;
      break;
    }
    case "anthropic": {
      if (method === "GET" || path.endsWith("count_tokens")) return 1;
      const [i, o] = rate(ANTHROPIC, ANTHROPIC_DEFAULT, model);
      const maxTok = Math.min(Math.max(Number(b.max_tokens) || 4096, 1), 64000);
      c = tokenCost(i, o, tokensFromBytes(bodyBytes), maxTok);
      break;
    }
    case "openai": {
      if (method === "GET") return 1;
      if (path.endsWith("images/generations")) {
        c = cents(0.2) * Math.min(Math.max(Number(b.n) || 1, 1), 4);
      } else if (path.endsWith("audio/speech")) {
        c = cents((typeof b.input === "string" ? b.input.length : bodyBytes) * 30 / 1e6);
      } else {
        const [i, o] = rate(OPENAI, OPENAI_DEFAULT, model);
        const maxTok = Math.min(Math.max(Number(b.max_completion_tokens ?? b.max_tokens ?? b.max_output_tokens) || 4096, 1), 64000);
        c = tokenCost(i, o, tokensFromBytes(bodyBytes), path.endsWith("embeddings") ? 0 : maxTok);
      }
      break;
    }
    case "replicate":
      c = 10; // unpriced: the owner's provider-side limit is the guard
      break;
    case "elevenlabs":
      c = 5;
      break;
  }
  return Math.max(1, Math.ceil(c));
}

// The cost once the answer is in: token counts from the provider's usage
// block where it gives one, otherwise the hold. A refused or failed call costs
// nothing. text: the answer's JSON, or the tail of a stream.
export function finalCents(provider: string, method: string, path: string, body: Json | null, status: number, text: string, hold: number): number {
  if (status < 200 || status >= 300) return 0;
  if (method === "GET" && provider !== "elevenlabs") return 0;
  if (provider === "fal") return hold;
  if (provider === "anthropic" || provider === "openai") {
    const b = body && typeof body === "object" ? body : {};
    const model = typeof b.model === "string" ? b.model : "";
    // The largest count seen in the text: a stream repeats the running total.
    const maxOf = (names: string[]) => {
      let m = 0;
      for (const n of names) for (const x of text.matchAll(new RegExp(`"${n}"\\s*:\\s*(\\d+)`, "g"))) m = Math.max(m, Number(x[1]));
      return m;
    };
    const inTok = maxOf(["input_tokens", "prompt_tokens"]) +
      Math.round(maxOf(["cache_creation_input_tokens"]) * 1.25) + Math.round(maxOf(["cache_read_input_tokens"]) * 0.1);
    const outTok = maxOf(["output_tokens", "completion_tokens"]);
    if (inTok + outTok === 0) return hold;
    const [i, o] = provider === "anthropic" ? rate(ANTHROPIC, ANTHROPIC_DEFAULT, model) : rate(OPENAI, OPENAI_DEFAULT, model);
    return Math.max(1, Math.ceil(tokenCost(i, o, inTok, outTok)));
  }
  return hold;
}
