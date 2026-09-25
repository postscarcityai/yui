// Unit tests for the A2A client: SSE parsing, both protocol versions' shapes,
// and live calls against the scripted agent (tests/echo-agent.ts) in 1.0 and
// 0.3, including picking a task back up. No network beyond 127.0.0.1.
//
//   node --test tests/*.test.ts
import { test, describe, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { SseParser, readSse } from "../src/sse.ts";
import {
  A2AClient, A2AError, A2AUnavailable, TaskView, cardUrls, messageToWire, normState, parseAgentCard,
  pickInterface, updateFromWire, isLangGraph, TASK_NOT_FOUND, type Message, type Update,
} from "../src/a2a.ts";
import { Bridge, State, refFromName } from "../src/bridge.ts";

const HERE = dirname(fileURLToPath(import.meta.url));

// -- SSE ----------------------------------------------------------------------------

describe("SSE parser", () => {
  test("events split across chunks, CRLF, CR and LF line ends", () => {
    const p = new SseParser();
    const got = [
      ...p.push("data: {\"a\""),
      ...p.push(":1}\r"),
      ...p.push("\n\r\n"),
      ...p.push("data: two\rdata: lines\r\r"),
      ...p.push("event: ping\ndata: x\n\n"),
    ];
    assert.deepEqual(got, [
      { event: "message", data: "{\"a\":1}" },
      { event: "message", data: "two\nlines" },
      { event: "ping", data: "x" },
    ]);
  });

  test("comments, id, retry, BOM, one space stripped, empty data skipped", () => {
    const p = new SseParser();
    const got = p.push("﻿: keep-alive\n\nid: 7\nretry: 1500\ndata:  two spaces\n\nevent: e\n\n");
    assert.deepEqual(got, [{ event: "message", data: " two spaces", id: "7", retry: 1500 }]);
  });

  test("a half event at the end of the stream is dropped", async () => {
    const body = new ReadableStream<Uint8Array>({
      start(c) {
        const enc = new TextEncoder();
        c.enqueue(enc.encode("data: whole\n\n"));
        c.enqueue(enc.encode("data: half"));
        c.close();
      },
    });
    const got = [];
    for await (const ev of readSse(body)) got.push(ev.data);
    assert.deepEqual(got, ["whole"]);
  });

  test("a multi-byte character split between chunks survives", async () => {
    const bytes = new TextEncoder().encode("data: café ✓\n\n");
    const body = new ReadableStream<Uint8Array>({
      start(c) {
        c.enqueue(bytes.slice(0, 10));
        c.enqueue(bytes.slice(10));
        c.close();
      },
    });
    const got = [];
    for await (const ev of readSse(body)) got.push(ev.data);
    assert.deepEqual(got, ["café ✓"]);
  });
});

// -- shapes -------------------------------------------------------------------------------

const CARD_10 = {
  name: "Currency Agent", description: "Converts money", version: "2.1.0",
  supportedInterfaces: [
    { url: "https://x.test/grpc", protocolBinding: "GRPC", protocolVersion: "1.0" },
    { url: "https://x.test/v0", protocolBinding: "JSONRPC", protocolVersion: "0.3" },
    { url: "/a2a", protocolBinding: "JSONRPC", protocolVersion: "1.0" },
  ],
  capabilities: { streaming: true },
  skills: [{ id: "fx", name: "Convert", description: "USD to EUR", tags: [] }],
};
const CARD_03 = {
  name: "Old Agent", description: "0.3", url: "https://old.test/rpc", preferredTransport: "JSONRPC",
  protocolVersion: "0.3.0", capabilities: { streaming: false }, skills: [],
};

describe("Agent Card", () => {
  test("1.0 card: prefers the JSON-RPC 1.0 interface, resolves relative URLs", () => {
    const c = parseAgentCard(CARD_10, "https://x.test/.well-known/agent-card.json");
    assert.equal(c.name, "Currency Agent");
    assert.equal(c.streaming, true);
    assert.deepEqual(c.skills.map((s) => s.name), ["Convert"]);
    assert.deepEqual(pickInterface(c), { url: "https://x.test/a2a", version: "1.0" });
  });

  test("0.3 card: url + preferredTransport", () => {
    const c = parseAgentCard(CARD_03);
    assert.equal(c.streaming, false);
    assert.deepEqual(pickInterface(c), { url: "https://old.test/rpc", version: "0.3" });
  });

  test("no JSON-RPC interface: nothing to pick", () => {
    const c = parseAgentCard({ name: "G", supportedInterfaces: [{ url: "x", protocolBinding: "GRPC", protocolVersion: "1.0" }] }, "https://g.test/");
    assert.equal(pickInterface(c), null);
  });

  test("where the card is looked for", () => {
    assert.deepEqual(cardUrls("https://a.test/agents/fx/"), [
      "https://a.test/agents/fx/.well-known/agent-card.json",
      "https://a.test/.well-known/agent-card.json",
      "https://a.test/.well-known/agent.json",
    ]);
    assert.deepEqual(cardUrls("https://a.test/card.json"), ["https://a.test/card.json"]);
  });

  test("remote_ref from a card name fits the registry's rule", () => {
    for (const name of ["Currency Agent", "  Ünïcode!! ", "x".repeat(99), "---"]) {
      assert.match(refFromName(name), /^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/, name);
    }
  });
});

describe("wire shapes", () => {
  const msg: Message = { messageId: "m1", role: "user", contextId: "c1", taskId: "t1",
                         parts: [{ text: "hi", metadata: { yui: "x" } }, { data: { a: 1 } }, { url: "https://f.test/a.png", mediaType: "image/png" }] };

  test("a message in 1.0: member parts, ROLE_USER, no kind", () => {
    assert.deepEqual(messageToWire(msg, "1.0"), {
      messageId: "m1", role: "ROLE_USER", contextId: "c1", taskId: "t1",
      parts: [{ text: "hi", metadata: { yui: "x" } }, { data: { a: 1 } }, { url: "https://f.test/a.png", mediaType: "image/png" }],
    });
  });

  test("a message in 0.3: kind everywhere, role user, file part", () => {
    assert.deepEqual(messageToWire(msg, "0.3"), {
      kind: "message", messageId: "m1", role: "user", contextId: "c1", taskId: "t1",
      parts: [{ kind: "text", text: "hi", metadata: { yui: "x" } }, { kind: "data", data: { a: 1 } },
              { kind: "file", file: { uri: "https://f.test/a.png", mimeType: "image/png" } }],
    });
  });

  test("states from both versions", () => {
    assert.equal(normState("TASK_STATE_INPUT_REQUIRED"), "input-required");
    assert.equal(normState("input-required"), "input-required");
    assert.equal(normState("TASK_STATE_COMPLETED"), "completed");
    assert.equal(normState("cancelled"), "canceled");
    assert.equal(normState("TASK_STATE_UNSPECIFIED"), "unknown");
  });

  test("stream events: 1.0 wrappers and 0.3 kinds read the same", () => {
    const pairs: [any, any][] = [
      [{ statusUpdate: { taskId: "t", contextId: "c", status: { state: "TASK_STATE_WORKING" } } },
       { kind: "status-update", taskId: "t", contextId: "c", status: { state: "working" }, final: false }],
      [{ artifactUpdate: { taskId: "t", contextId: "c", artifact: { artifactId: "a", parts: [{ text: "x" }] }, append: true } },
       { kind: "artifact-update", taskId: "t", contextId: "c", artifact: { artifactId: "a", parts: [{ kind: "text", text: "x" }] }, append: true }],
      [{ task: { id: "t", contextId: "c", status: { state: "TASK_STATE_SUBMITTED" } } },
       { kind: "task", id: "t", contextId: "c", status: { state: "submitted" } }],
      [{ message: { messageId: "m", role: "ROLE_AGENT", parts: [{ text: "pong" }] } },
       { kind: "message", messageId: "m", role: "agent", parts: [{ kind: "text", text: "pong" }] }],
    ];
    for (const [v1, v03] of pairs) assert.deepEqual(updateFromWire(v1), updateFromWire(v03));
  });

  test("1.0 has no `final`: terminal and interrupted states imply it", () => {
    const u = (state: string) => updateFromWire({ statusUpdate: { taskId: "t", contextId: "c", status: { state } } }) as any;
    assert.equal(u("TASK_STATE_WORKING").final, false);
    assert.equal(u("TASK_STATE_COMPLETED").final, true);
    assert.equal(u("TASK_STATE_INPUT_REQUIRED").final, true);
  });
});

describe("TaskView", () => {
  const status = (state: string, text?: string): Update => updateFromWire({ statusUpdate: {
    taskId: "t", contextId: "c",
    status: { state, ...(text ? { message: { messageId: "s", role: "ROLE_AGENT", parts: [{ text }] } } : {}) } } });
  const chunk = (text: string, append: boolean): Update =>
    updateFromWire({ artifactUpdate: { taskId: "t", contextId: "c", artifact: { artifactId: "a", parts: [{ text }] }, append } });

  test("append glues text chunks; a working message does not outlive its status", () => {
    const v = new TaskView();
    for (const u of [status("TASK_STATE_WORKING", "Looking it up"), chunk("Hello", false), chunk(", world", true), status("TASK_STATE_COMPLETED")]) v.apply(u);
    assert.equal(v.settled, true);
    assert.equal(v.text(), "Hello, world");
  });

  test("final status text follows the artifacts, once", () => {
    const v = new TaskView();
    for (const u of [chunk("Report", false), status("TASK_STATE_COMPLETED", "Done.")]) v.apply(u);
    assert.equal(v.text(), "Report\n\nDone.");
    const w = new TaskView();
    for (const u of [chunk("Done.", false), status("TASK_STATE_COMPLETED", "Done.")]) w.apply(u);
    assert.equal(w.text(), "Done.");
  });

  test("a non-append artifact replaces the one with that id", () => {
    const v = new TaskView();
    for (const u of [chunk("draft", false), chunk("final", false), status("TASK_STATE_COMPLETED")]) v.apply(u);
    assert.equal(v.text(), "final");
  });

  test("one update applied to two views appends once in each", () => {
    const snap = updateFromWire({ task: { id: "t", contextId: "c", status: { state: "TASK_STATE_WORKING" },
                                          artifacts: [{ artifactId: "a", parts: [{ text: "Step 1" }] }] } });
    const v = new TaskView();
    const w = new TaskView();
    for (const u of [snap, chunk(", step 2", true), status("TASK_STATE_COMPLETED")]) {
      v.apply(u);
      w.apply(u);
    }
    assert.equal(v.text(), "Step 1, step 2");
    assert.equal(w.text(), "Step 1, step 2");
  });

  test("an answer sent as a working message outlives a bare completed status", () => {
    const v = new TaskView();
    for (const u of [status("TASK_STATE_WORKING"), status("TASK_STATE_WORKING", "Hello there"), status("TASK_STATE_COMPLETED")]) v.apply(u);
    assert.equal(v.text(), "Hello there");
    const w = new TaskView(); // a snapshot from GetTask: the answer is in the history
    w.apply(updateFromWire({ task: { id: "t", contextId: "c", status: { state: "TASK_STATE_COMPLETED" }, history: [
      { messageId: "u", role: "ROLE_USER", parts: [{ text: "hi" }] },
      { messageId: "a", role: "ROLE_AGENT", parts: [{ text: "Hello there" }] }] } }));
    assert.equal(w.text(), "Hello there");
    const f = new TaskView(); // only a completed task falls back; a failed one says why elsewhere
    for (const u of [status("TASK_STATE_WORKING", "Looking it up"), status("TASK_STATE_FAILED")]) f.apply(u);
    assert.equal(f.text(), "");
  });

  test("a plain Message settles the turn", () => {
    const v = new TaskView();
    v.apply(updateFromWire({ message: { messageId: "m", role: "ROLE_AGENT", parts: [{ text: "pong" }] } }));
    assert.equal(v.settled, true);
    assert.equal(v.text(), "pong");
  });
});

// -- failures, with a fake fetch -------------------------------------------------------------

function fakeFetch(handler: (body: any) => Response | Promise<Response>): typeof fetch {
  return (async (_url: any, init: any) => handler(JSON.parse(init.body))) as typeof fetch;
}
const rpc = (result: unknown) => new Response(JSON.stringify({ jsonrpc: "2.0", id: 1, result }), { headers: { "content-type": "application/json" } });
const user = (text: string, taskId?: string): Message =>
  ({ messageId: crypto.randomUUID(), role: "user", parts: [{ text }], contextId: "ctx", ...(taskId ? { taskId } : {}) });

describe("errors", () => {
  test("JSON-RPC error is an A2AError with its code", async () => {
    const c = new A2AClient("http://x.test", "1.0", { fetch: fakeFetch(() =>
      new Response(JSON.stringify({ jsonrpc: "2.0", id: 1, error: { code: -32001, message: "Task not found" } }),
                   { headers: { "content-type": "application/json" } })) });
    await assert.rejects(c.getTask("nope"), (e: any) => e instanceof A2AError && e.code === TASK_NOT_FOUND);
  });

  test("503 and network failures are A2AUnavailable (try again)", async () => {
    const c503 = new A2AClient("http://x.test", "1.0", { fetch: fakeFetch(() => new Response("busy", { status: 503 })) });
    await assert.rejects(c503.send(user("hi")), A2AUnavailable);
    const down = new A2AClient("http://x.test", "1.0", { fetch: (async () => { throw new TypeError("fetch failed"); }) as any });
    await assert.rejects(down.send(user("hi")), A2AUnavailable);
  });

  test("a stream that drops mid-task is A2AUnavailable, after the events it did send", async () => {
    let n = 0;
    const c = new A2AClient("http://x.test", "1.0", { fetch: fakeFetch(() => new Response(new ReadableStream({
      pull(ctl) { // one event, then the socket dies
        if (n++ === 0) ctl.enqueue(new TextEncoder().encode(`data: ${JSON.stringify({ jsonrpc: "2.0", id: 1, result: { task: { id: "t9", status: { state: "TASK_STATE_WORKING" } } } })}\n\n`));
        else ctl.error(new Error("socket hang up"));
      },
    }), { headers: { "content-type": "text/event-stream" } })) });
    const got: Update[] = [];
    await assert.rejects(async () => { for await (const u of c.stream(user("hi"))) got.push(u); }, A2AUnavailable);
    assert.equal(got.length, 1);
    assert.equal((got[0] as any).task.id, "t9");
  });

  test("a silent stream times out as A2AUnavailable", async () => {
    const c = new A2AClient("http://x.test", "1.0", { idleTimeout: 0.3, fetch: (async (_u: any, init: any) => {
      const body = new ReadableStream({ start(ctl) { init.signal.addEventListener("abort", () => ctl.error(init.signal.reason)); } });
      return new Response(body, { headers: { "content-type": "text/event-stream" } });
    }) as any });
    await assert.rejects(async () => { for await (const _ of c.stream(user("hi"))) {} }, /stream dropped/);
  });

  test("a server that answers a stream call with plain JSON still works", async () => {
    const c = new A2AClient("http://x.test", "0.3", { fetch: fakeFetch(() => rpc({ kind: "message", messageId: "m", role: "agent", parts: [{ kind: "text", text: "one shot" }] })) });
    const got: Update[] = [];
    for await (const u of c.stream(user("hi"))) got.push(u);
    assert.equal(got.length, 1);
    assert.equal(got[0].kind, "message");
  });

  test("the request carries A2A-Version 1.0 and PascalCase methods; 0.3 sends no header", async () => {
    const seen: any[] = [];
    const mk = (v: "1.0" | "0.3") => new A2AClient("http://x.test", v, { headers: { authorization: "Bearer k" },
      fetch: (async (_u: any, init: any) => { seen.push({ h: init.headers, b: JSON.parse(init.body) }); return rpc({ id: "t", status: { state: "completed" } }); }) as any });
    await mk("1.0").getTask("t");
    await mk("0.3").getTask("t");
    assert.equal(seen[0].h["A2A-Version"], "1.0");
    assert.equal(seen[0].b.method, "GetTask");
    assert.equal(seen[0].h.authorization, "Bearer k");
    assert.equal(seen[1].h["A2A-Version"], undefined);
    assert.equal(seen[1].b.method, "tasks/get");
  });
});

// -- live, against the scripted agent --------------------------------------------------------------

async function startAgent(args: string[]): Promise<{ proc: ChildProcess; url: string }> {
  const proc = spawn(process.execPath, [join(HERE, "echo-agent.ts"), ...args], { stdio: ["ignore", "pipe", "inherit"] });
  const url = await new Promise<string>((resolve, reject) => {
    proc.stdout!.on("data", (d) => {
      const m = /listening (\S+)/.exec(String(d));
      if (m) resolve(m[1]);
    });
    proc.on("exit", (c) => reject(new Error(`echo agent exited ${c}`)));
  });
  return { proc, url };
}

async function collect(it: AsyncIterable<Update>): Promise<{ view: TaskView; updates: Update[] }> {
  const view = new TaskView();
  const updates: Update[] = [];
  for await (const u of it) {
    updates.push(u);
    view.apply(u);
  }
  return { view, updates };
}

for (const version of ["1.0", "0.3"] as const) {
  describe(`live A2A ${version}`, () => {
    let agent: { proc: ChildProcess; url: string };
    let client: A2AClient;
    before(async () => {
      agent = await startAgent(["--protocol", version]);
      const r = await A2AClient.fromCard(agent.url);
      client = r.client;
      assert.equal(r.card.name, "Echo");
      assert.deepEqual(r.card.skills.map((s) => s.name), ["Echo", "Slow job"]);
    });
    after(() => agent.proc.kill());

    test("the card picks this version", () => assert.equal(client.version, version));

    test("send waits for the answer", async () => {
      const u = await client.send(user("hello"));
      assert.equal(u.kind, "task");
      const v = new TaskView();
      v.apply(u);
      assert.equal(v.state, "completed");
      assert.equal(v.text(), "You said: hello");
    });

    test("stream: working, chunks, then completed", async () => {
      const { view, updates } = await collect(client.stream(user("slow 3")));
      const states = updates.filter((u) => u.kind === "status").map((u: any) => u.state);
      assert.deepEqual(states, ["working", "completed"]);
      assert.equal(updates.filter((u) => u.kind === "artifact").length, 3);
      assert.equal(view.text(), "Step 1, step 2, step 3\n\nDone after 3 steps.");
    });

    test("input-required keeps the task open; the next message finishes it", async () => {
      const first = await collect(client.stream(user("ask")));
      assert.equal(first.view.state, "input-required");
      assert.equal(first.view.text(), "Which color?");
      const second = await collect(client.stream(user("Blue", first.view.task!.id)));
      assert.equal(second.view.task!.id, first.view.task!.id);
      assert.equal(second.view.state, "completed");
      assert.equal(second.view.text(), "Blue it is.");
    });

    test("a plain Message answer", async () => {
      const { view } = await collect(client.stream(user("ping")));
      assert.equal(view.text(), "pong");
    });

    test("resubscribe after walking away mid-task, then GetTask agrees", async () => {
      let taskId = "";
      for await (const u of client.stream(user("slow 4"))) {
        if (u.kind === "task") {
          taskId = u.task.id;
          break; // the bridge died here
        }
      }
      await new Promise((r) => setTimeout(r, 2200));
      const { view, updates } = await collect(client.subscribe(taskId));
      assert.equal(updates[0].kind, "task", "a resubscribe starts with the task as it is now");
      assert.equal(view.state, "completed");
      assert.equal(view.text(), "Step 1, step 2, step 3, step 4\n\nDone after 4 steps.");
      const t = await client.getTask(taskId);
      assert.equal(t.state, "completed");
      assert.equal(t.artifacts[0].parts[0].text, "Step 1, step 2, step 3, step 4");
    });

    test("subscribing to a finished task is an A2AError; an unknown task is TaskNotFound", async () => {
      const u = await client.send(user("done fast"));
      const id = (u as any).task.id;
      await assert.rejects(collect(client.subscribe(id)), (e: any) => e instanceof A2AError && e.code === -32004);
      await assert.rejects(client.getTask("nope"), (e: any) => e instanceof A2AError && e.code === TASK_NOT_FOUND);
    });

    test("failed carries its reason", async () => {
      const { view } = await collect(client.stream(user("fail")));
      assert.equal(view.state, "failed");
      assert.equal(view.text(), "The printer is on fire.");
    });
  });
}

describe("bridge: following a task with no stream", () => {
  let agent: { proc: ChildProcess; url: string };
  after(() => agent?.proc.kill());

  test("an agent without streaming: send returns at once, GetTask polls it to the end", async () => {
    agent = await startAgent(["--protocol", "1.0", "--no-streaming"]);
    const { client, card } = await A2AClient.fromCard(agent.url);
    assert.equal(card.streaming, false);
    const first = await client.send(user("slow 2"), { returnImmediately: true });
    const taskId = (first as any).task.id;
    assert.notEqual((first as any).task.state, "completed");
    const bridge = new Bridge(new State(join(mkdtempSync(join(tmpdir(), "yui-a2a-")), "s.json")));
    const view = new TaskView();
    const t0 = Date.now();
    await bridge.follow(client, taskId, (u) => view.apply(u));
    assert.equal(view.state, "completed");
    assert.equal(view.text(), "Step 1, step 2\n\nDone after 2 steps.");
    assert.ok(Date.now() - t0 < 15000);
    const log = await (await fetch(`${agent.url}/_log`)).json() as any[];
    assert.ok(log.some((l) => l.method === "GetTask"), "it polled");
  });
});

describe("bridge: a LangGraph Agent Server (INT-14)", () => {
  const lgCard = parseAgentCard({
    name: "helper", url: "http://127.0.0.1:1/a2a/x",
    supportedInterfaces: [{ url: "http://127.0.0.1:1/a2a/x", protocolBinding: "JSONRPC", protocolVersion: "1.0" }],
    capabilities: { streaming: true, extensions: [{ uri: "https://langchain.com/a2a/extensions/history-scope/v1" }] },
  }, "http://127.0.0.1:1/.well-known/agent-card.json?assistant_id=x");
  const plain = parseAgentCard({ name: "echo", url: "http://127.0.0.1:1/", capabilities: {} });
  const bridge = new Bridge(new State(join(mkdtempSync(join(tmpdir(), "yui-a2a-")), "s.json")));
  bridge.guide = { version: "v16", body: "GUIDE: choose, ask" };
  const tap = { id: "r2", agent_id: "a", body: "[yui] n1 choose choice=Tea", kind: "event",
                meta: { id: "n1", preset: "choose", value: { choice: "Tea" } } } as any;
  const inflight = { messageId: "m1" } as any;

  test("its card is told apart by LangChain's extensions; the card URL keeps ?assistant_id", () => {
    assert.equal(isLangGraph(lgCard), true);
    assert.equal(isLangGraph(plain), false);
    assert.deepEqual(cardUrls("http://h:1/.well-known/agent-card.json?assistant_id=x"),
                     ["http://h:1/.well-known/agent-card.json?assistant_id=x"]);
  });

  test("one text part (a second would replace it); the guide and taps as keyed data", () => {
    const m = bridge.message("a", [tap], inflight, undefined, lgCard);
    assert.deepEqual(m.parts, [
      { text: "[yui] n1 choose choice=Tea" },
      { data: { yui_channel_guide: { version: "v16", body: "GUIDE: choose, ask" },
                yui_events: [{ id: "n1", preset: "choose", value: { choice: "Tea" }, row: "r2" }] },
        metadata: { yui: "context" } },
    ]);
    const cont = bridge.message("a", [{ ...tap, kind: "text", meta: null }], inflight, "t1", lgCard);
    assert.deepEqual(cont.parts, [{ text: "[yui] n1 choose choice=Tea" }], "continuing a task: no guide, no data");
  });

  test("any other agent: the guide as a marked text part, as before", () => {
    const m = bridge.message("a", [tap], inflight, undefined, plain);
    assert.deepEqual(m.parts.map((p: any) => p.metadata?.yui ?? "text"), ["channel_guide", "text", "event"]);
  });
});
