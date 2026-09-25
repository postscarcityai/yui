// Server-Sent Events parser (WHATWG "event stream" format), runtime-neutral:
// a ReadableStream of bytes in, one object per dispatched event out. Works on
// Node 22, Cloudflare Workers and browsers; no Node APIs.

export interface SseEvent {
  event: string; // "message" unless the server named it
  data: string; // data lines joined with "\n"
  id?: string;
  retry?: number;
}

/** Feed it text in any chunking; it hands back the events each chunk completes. */
export class SseParser {
  private buf = "";
  private data: string[] = [];
  private event = "";
  private id: string | undefined;
  private retry: number | undefined;
  private first = true;

  push(chunk: string): SseEvent[] {
    if (this.first && chunk) { // a leading byte order mark is not part of the stream
      if (chunk.charCodeAt(0) === 0xfeff) chunk = chunk.slice(1);
      this.first = false;
    }
    this.buf += chunk;
    const out: SseEvent[] = [];
    // Lines end with \r\n, \n or \r. A lone \r at the end may be half of \r\n: wait for more.
    let start = 0;
    for (let i = 0; i < this.buf.length; i++) {
      const c = this.buf[i];
      if (c !== "\n" && c !== "\r") continue;
      if (c === "\r" && i === this.buf.length - 1) break;
      const line = this.buf.slice(start, i);
      if (c === "\r" && this.buf[i + 1] === "\n") i++;
      start = i + 1;
      const ev = this.line(line);
      if (ev) out.push(ev);
    }
    this.buf = this.buf.slice(start);
    return out;
  }

  /** End of stream: a half-built event with no blank line after it is dropped, per the spec. */
  end(): SseEvent[] {
    this.buf = "";
    this.data = [];
    this.event = "";
    return [];
  }

  private line(line: string): SseEvent | null {
    if (line === "") return this.dispatch();
    if (line.startsWith(":")) return null; // comment, keep-alive
    const colon = line.indexOf(":");
    const field = colon < 0 ? line : line.slice(0, colon);
    let value = colon < 0 ? "" : line.slice(colon + 1);
    if (value.startsWith(" ")) value = value.slice(1);
    if (field === "data") this.data.push(value);
    else if (field === "event") this.event = value;
    else if (field === "id") { if (!value.includes("\0")) this.id = value; }
    else if (field === "retry") { if (/^\d+$/.test(value)) this.retry = Number(value); }
    return null;
  }

  private dispatch(): SseEvent | null {
    if (!this.data.length) {
      this.event = "";
      return null;
    }
    const ev: SseEvent = { event: this.event || "message", data: this.data.join("\n") };
    if (this.id !== undefined) ev.id = this.id;
    if (this.retry !== undefined) ev.retry = this.retry;
    this.data = [];
    this.event = "";
    return ev;
  }
}

/** Every event in a byte stream, in order. `onChunk` runs on every read (idle timers).
 *  Leaving the loop early cancels the stream, so the connection closes. */
export async function* readSse(body: ReadableStream<Uint8Array>, onChunk?: () => void): AsyncGenerator<SseEvent> {
  const parser = new SseParser();
  const decoder = new TextDecoder();
  const reader = body.getReader();
  let finished = false;
  try {
    for (;;) {
      const { value, done } = await reader.read();
      onChunk?.();
      if (done) break;
      yield* parser.push(decoder.decode(value, { stream: true }));
    }
    finished = true;
    yield* parser.push(decoder.decode());
    yield* parser.end();
  } finally {
    if (!finished) await reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}
