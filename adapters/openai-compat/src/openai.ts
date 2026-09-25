// A client for any OpenAI-compatible chat API (INT-12): Ollama, LM Studio,
// vLLM, llama.cpp's server, OpenRouter, and the cloud APIs that copy
// /v1/chat/completions. Runtime-neutral (fetch, TextDecoder, streams), so the
// hosted step runs the same code in a Durable Object.
//
// Only the part of the API every server agrees on: model, messages (system,
// user, assistant, plain text), stream, temperature, max_tokens. Nothing
// vendor-specific is sent unless the caller adds it.
import { readSse } from "./sse.ts";

export interface ChatMessage {
  role: "system" | "user" | "assistant";
  content: string;
}

export interface ChatRequest {
  model: string;
  messages: ChatMessage[];
  temperature?: number;
  max_tokens?: number;
}

export interface Completion {
  text: string; // the answer, with any <think> block taken out
  reasoning: string; // what the model thought, when the server or the text says so
  finish: string | null; // stop, length, ...
  streamed: boolean; // true when the answer came as a stream
  usage?: { prompt_tokens?: number; completion_tokens?: number };
}

/** Try again later: the network, a 408/409/425/429/5xx, a stream that stopped short. */
export class ModelUnavailable extends Error {}

/** The server said no for this request: bad key, unknown model, too long. Retrying won't help. */
export class ModelError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

/** The server does not stream (it said so with a 400). Send the same request plain. */
export class StreamRefused extends ModelError {}

/** Local servers people run, by the port they ship with. */
export const SERVERS: Record<string, { url: string; keyEnv?: string }> = {
  ollama: { url: "http://127.0.0.1:11434/v1" },
  lmstudio: { url: "http://127.0.0.1:1234/v1" },
  vllm: { url: "http://127.0.0.1:8000/v1" },
  llamacpp: { url: "http://127.0.0.1:8080/v1" },
  openrouter: { url: "https://openrouter.ai/api/v1", keyEnv: "OPENROUTER_API_KEY" },
};

/** "http://host:11434/v1/" or ".../v1/chat/completions" -> "http://host:11434/v1". */
export function baseUrl(url: string): string {
  let u = url.trim().replace(/\/+$/, "");
  u = u.replace(/\/chat\/completions$/, "").replace(/\/+$/, "");
  new URL(u); // throws on nonsense
  return u;
}

export interface ClientOptions {
  key?: string; // sent as Authorization: Bearer
  headers?: Record<string, string>;
  fetch?: typeof fetch;
  idle?: number; // seconds a stream may go quiet (and a plain answer may take), default 300
}

export class ChatClient {
  url: string;
  private key?: string;
  private headers: Record<string, string>;
  private fetch: typeof fetch;
  private idle: number;

  constructor(url: string, opts: ClientOptions = {}) {
    this.url = baseUrl(url);
    this.key = opts.key || undefined;
    this.headers = opts.headers ?? {};
    this.fetch = opts.fetch ?? fetch;
    this.idle = opts.idle ?? 300;
  }

  private async call(method: string, path: string, body: unknown, ctl: AbortController): Promise<Response> {
    let r: Response;
    try {
      r = await this.fetch(`${this.url}${path}`, {
        method,
        body: body === undefined ? undefined : JSON.stringify(body),
        headers: {
          ...(body === undefined ? {} : { "content-type": "application/json" }),
          accept: "application/json, text/event-stream",
          ...(this.key ? { authorization: `Bearer ${this.key}` } : {}),
          ...this.headers,
        },
        signal: ctl.signal,
      });
    } catch (e: any) {
      throw new ModelUnavailable(ctl.signal.aborted ? `no answer from ${this.url} in ${this.idle}s` : `can't reach ${this.url} (${reason(e)})`);
    }
    if (r.ok) return r;
    const text = await r.text().catch(() => "");
    const msg = errorMessage(text) || r.statusText || `HTTP ${r.status}`;
    if ([408, 409, 425, 429].includes(r.status) || r.status >= 500) throw new ModelUnavailable(`${r.status}: ${msg}`);
    if (r.status === 400 && /stream/i.test(msg)) throw new StreamRefused(r.status, msg);
    throw new ModelError(r.status, explain(r.status, msg));
  }

  /** The model names the server offers (GET /models). */
  async models(): Promise<string[]> {
    const ctl = new AbortController();
    const t = setTimeout(() => ctl.abort(), 20_000);
    try {
      const r = await this.call("GET", "/models", undefined, ctl);
      const data: any = await r.json().catch(() => null);
      return ((data?.data ?? []) as any[]).map((m) => String(m.id)).filter(Boolean);
    } finally {
      clearTimeout(t);
    }
  }

  /** One answer. With stream, reads Server-Sent Events and calls onDelta per piece;
   *  a server that answers plain JSON anyway is read as plain. */
  async complete(req: ChatRequest, opts: { stream?: boolean; onDelta?: (text: string) => void } = {}): Promise<Completion> {
    const stream = opts.stream ?? true;
    const ctl = new AbortController();
    let timer = setTimeout(() => ctl.abort(), this.idle * 1000);
    const poke = () => {
      clearTimeout(timer);
      timer = setTimeout(() => ctl.abort(), this.idle * 1000);
    };
    try {
      const r = await this.call("POST", "/chat/completions", { ...req, stream }, ctl);
      const type = r.headers.get("content-type") ?? "";
      if (stream && type.includes("text/event-stream") && r.body) {
        return await this.readStream(r.body, poke, ctl, opts.onDelta);
      }
      let data: any;
      try {
        data = await r.json();
      } catch {
        throw new ModelUnavailable(ctl.signal.aborted ? `no answer from ${this.url} in ${this.idle}s` : "the server sent something that isn't JSON");
      }
      if (data?.error) throw new ModelError(r.status, errorMessage(JSON.stringify(data)));
      const choice = data?.choices?.[0];
      if (!choice) throw new ModelError(r.status, "the answer had no choices");
      const m = choice.message ?? {};
      return finish(String(m.content ?? choice.text ?? ""), String(m.reasoning_content ?? m.reasoning ?? ""),
                    choice.finish_reason ?? null, false, data.usage);
    } finally {
      clearTimeout(timer);
    }
  }

  private async readStream(body: ReadableStream<Uint8Array>, poke: () => void, ctl: AbortController,
                           onDelta?: (text: string) => void): Promise<Completion> {
    let text = "";
    let reasoning = "";
    let fin: string | null = null;
    let done = false;
    let usage: Completion["usage"];
    try {
      for await (const ev of readSse(body, poke)) {
        if (ev.data === "[DONE]") {
          done = true;
          break;
        }
        let chunk: any;
        try {
          chunk = JSON.parse(ev.data);
        } catch {
          continue; // a keep-alive or a line the server should not have sent
        }
        if (chunk.error) {
          const msg = errorMessage(JSON.stringify(chunk));
          if (/overload|rate|capacity|timeout|unavailable/i.test(msg)) throw new ModelUnavailable(msg);
          throw new ModelError(200, msg);
        }
        if (chunk.usage) usage = chunk.usage;
        const choice = chunk.choices?.[0];
        if (!choice) continue;
        const d = choice.delta ?? {};
        if (d.reasoning_content || d.reasoning) reasoning += d.reasoning_content ?? d.reasoning;
        if (typeof d.content === "string" && d.content) {
          text += d.content;
          onDelta?.(d.content);
        }
        if (choice.finish_reason) fin = choice.finish_reason;
      }
    } catch (e) {
      if (e instanceof ModelError || e instanceof ModelUnavailable) throw e;
      throw new ModelUnavailable(ctl.signal.aborted ? `the stream went quiet for ${this.idle}s` : `the stream broke: ${reason(e)}`);
    }
    // Some servers end without [DONE] but with a finish_reason; neither means it stopped short.
    if (!done && !fin) throw new ModelUnavailable(ctl.signal.aborted ? `the stream went quiet for ${this.idle}s` : "the stream stopped before the answer finished");
    return finish(text, reasoning, fin, true, usage);
  }
}

/** Takes a leading <think>...</think> (Qwen 3, DeepSeek R1 and friends) out of the answer. */
export function splitThinking(text: string): { text: string; thinking: string } {
  const m = text.match(/^\s*<think>([\s\S]*?)(?:<\/think>|$)/);
  if (!m) return { text, thinking: "" };
  return { text: text.slice(m[0].length), thinking: m[1].trim() };
}

function finish(raw: string, reasoning: string, fin: string | null, streamed: boolean, usage?: any): Completion {
  const { text, thinking } = splitThinking(raw);
  return { text: text.trim(), reasoning: (reasoning || thinking).trim(), finish: fin, streamed, ...(usage ? { usage } : {}) };
}

function reason(e: any): string {
  return String(e?.cause?.code ?? e?.cause?.message ?? e?.message ?? e);
}

/** {"error": {"message": ...}} (OpenAI, Ollama, vLLM), {"error": "..."} (llama.cpp), {"detail": ...}, or the text. */
export function errorMessage(text: string): string {
  try {
    const d = JSON.parse(text);
    const e = d?.error ?? d?.detail ?? d?.message;
    if (typeof e === "string") return e;
    if (e?.message) return String(e.message);
    if (Array.isArray(e) && e[0]?.msg) return String(e[0].msg);
  } catch {}
  return text.trim().slice(0, 300);
}

function explain(status: number, msg: string): string {
  if (status === 401 || status === 403) return `the server turned the key down (${status}: ${msg})`;
  if (status === 404) return `not found (${msg}). Check the model name and the base URL`;
  return `${status}: ${msg}`;
}
