// Interop with the official A2A SDK (a2aproject/a2a-python): our client
// against a 1.x server (A2A 1.0) and a 0.3 server. Needs `uv`; skipped
// without it. The first run downloads the SDKs.
//
//   node --test tests/sdk_interop.test.ts
import { test, describe, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { createServer } from "node:net";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { A2AClient, A2AError, TaskView, type Update } from "../src/a2a.ts";

const SDK = join(dirname(fileURLToPath(import.meta.url)), "sdk");
const HAVE_UV = spawnSync("uv", ["--version"]).status === 0;

const SERVERS = [
  { version: "1.0", file: "hello_v1.py", deps: ["a2a-sdk[http-server]>=1.1,<2", "uvicorn", "sse-starlette"],
    answer: (s: string) => `Hello, World! (${s})\n\nRequest is completed!` },
  { version: "0.3", file: "hello_v03.py", deps: ["a2a-sdk[http-server]>=0.3,<0.4", "uvicorn"],
    answer: (s: string) => `Hello from 0.3! (${s})` },
] as const;

const freePort = () => new Promise<number>((resolve) => {
  const s = createServer().listen(0, "127.0.0.1", () => {
    const port = (s.address() as any).port;
    s.close(() => resolve(port));
  });
});

async function collect(it: AsyncIterable<Update>) {
  const view = new TaskView();
  const kinds: string[] = [];
  for await (const u of it) {
    view.apply(u);
    kinds.push(u.kind === "status" ? `status:${u.state}` : u.kind);
  }
  return { view, kinds };
}

for (const srv of SERVERS) {
  describe(`official a2a-sdk server, A2A ${srv.version}`, { skip: !HAVE_UV && "uv not installed" }, () => {
    let proc: ChildProcess;
    let base = "";
    before(async () => {
      const port = await freePort();
      base = `http://127.0.0.1:${port}`;
      proc = spawn("uv", ["run", "--quiet", ...srv.deps.flatMap((d) => ["--with", d]), join(SDK, srv.file), String(port)],
                   { stdio: ["ignore", "ignore", "inherit"] });
      const end = Date.now() + 180_000;
      for (;;) {
        try {
          if ((await fetch(`${base}/.well-known/agent-card.json`)).ok) break;
        } catch {}
        if (Date.now() > end) throw new Error(`${srv.file} never came up`);
        await new Promise((r) => setTimeout(r, 500));
      }
    });
    after(() => proc?.kill());

    test("reads the card and picks the right version", async () => {
      const { client, card } = await A2AClient.fromCard(base);
      assert.equal(client.version, srv.version);
      assert.ok(card.streaming);
      assert.equal(card.skills.length, 1);
    });

    test("send, stream, GetTask, and a finished task refuses a resubscribe", async () => {
      const { client } = await A2AClient.fromCard(base);
      const msg = (text: string) => ({
        messageId: crypto.randomUUID(), role: "user" as const, contextId: crypto.randomUUID(),
        parts: [{ text: "(Yui's channel guide would be here)", metadata: { yui: "channel_guide" } }, { text }],
      });
      const sent = new TaskView();
      sent.apply(await client.send(msg("hi from send")));
      assert.equal(sent.state, "completed");
      assert.equal(sent.text(), srv.answer("hi from send"));

      const { view, kinds } = await collect(client.stream(msg("hi from stream")));
      assert.deepEqual(kinds, ["task", "status:working", "artifact", "status:completed"]);
      assert.equal(view.text(), srv.answer("hi from stream"));

      const t = await client.getTask(view.task!.id);
      assert.equal(t.state, "completed");
      assert.equal(t.artifacts.length, 1);
      await assert.rejects(collect(client.subscribe(t.id)), A2AError);
    });
  });
}
