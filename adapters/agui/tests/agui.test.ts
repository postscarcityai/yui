// Unit tests for the AG-UI bridge (INT-21): folding runs, the wire client
// against a scripted AG-UI server that replays event streams recorded from
// Microsoft Agent Framework (tests/fixtures/*.sse), and the bridge's turns
// with Yui's side stubbed out. No network beyond 127.0.0.1.
//
//   node --test tests/*.test.ts
import { test, describe, before, after } from "node:test";
import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { AguiError, AguiUnavailable, RunView, runAgent, type AgEvent, type RunAgentInput } from "../src/agui.ts";
import { Bridge, MAX_THREAD, SHOW, State, showLines, trim } from "../src/bridge.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const fixture = (name: string) => readFileSync(join(HERE, "fixtures", name), "utf8");
const events = (sse: string): AgEvent[] => sse.split("\n").filter((l) => l.startsWith("data: ")).map((l) => JSON.parse(l.slice(6)));
const sse = (evs: AgEvent[]) => evs.map((e) => `data: ${JSON.stringify(e)}\n\n`).join("");

// -- the scripted server ------------------------------------------------------------------

/** Replays whatever the test queues, one reply per POST, and keeps every RunAgentInput. */
class Scripted {
  server!: Server;
  url = "";
  inputs: RunAgentInput[] = [];
  replies: ((res: any) => void)[] = [];

  async start(): Promise<void> {
    this.server = createServer((req, res) => {
      let body = "";
      req.on("data", (c) => (body += c));
      req.on("end", () => {
        this.inputs.push(JSON.parse(body));
        const reply = this.replies.shift();
        if (!reply) {
          res.writeHead(500).end("nothing scripted");
          return;
        }
        reply(res);
      });
    });
    await new Promise<void>((r) => this.server.listen(0, "127.0.0.1", r));
    this.url = `http://127.0.0.1:${(this.server.address() as any).port}/`;
  }

  /** A stream written in small pieces, the way a real server flushes. */
  stream(text: string, piece = 37): void {
    this.replies.push((res) => {
      res.writeHead(200, { "content-type": "text/event-stream" });
      let i = 0;
      const next = () => {
        if (i >= text.length) return res.end();
        res.write(text.slice(i, i + piece));
        i += piece;
        setImmediate(next);
      };
      next();
    });
  }

  status(code: number, body = "no"): void {
    this.replies.push((res) => res.writeHead(code, { "content-type": "text/plain" }).end(body));
  }

  run(evs: AgEvent[]): void {
    this.stream(sse(evs));
  }
}

const say = (text: string, id = "m1"): AgEvent[] => [
  { type: "RUN_STARTED", threadId: "t", runId: "r" },
  { type: "TEXT_MESSAGE_START", messageId: id, role: "assistant" },
  { type: "TEXT_MESSAGE_CONTENT", messageId: id, delta: text },
  { type: "TEXT_MESSAGE_END", messageId: id },
  { type: "RUN_FINISHED", threadId: "t", runId: "r" },
];

// -- folding runs ------------------------------------------------------------------------------

describe("RunView", () => {
  test("Agent Framework's recorded run ends on the yui_show call, with no words", () => {
    const v = new RunView();
    for (const e of events(fixture("maf_show.sse"))) v.apply(e);
    assert.equal(v.finished, true);
    assert.equal(v.text(), "");
    const open = v.openCalls();
    assert.equal(open.length, 1);
    assert.equal(open[0].function.name, SHOW);
    assert.equal(showLines(open[0]), "```yui\nWhich fruit? | Apple | Pear | Banana\n```");
    assert.deepEqual(v.thread().map((m) => m.role), ["assistant"], "the call rides on its parent message");
    assert.equal((v.thread()[0] as any).content, undefined, "an empty message has no content key");
  });

  test("the recorded run after the tap: streamed words, nothing open", () => {
    const v = new RunView();
    for (const e of events(fixture("maf_after_tap.sse"))) v.apply(e);
    assert.equal(v.text(), "Great! You chose a pear for lunch. Enjoy your meal!");
    assert.deepEqual(v.openCalls(), []);
  });

  test("chunk events, a server tool with its result, state, interrupts", () => {
    const v = new RunView();
    for (const e of [
      { type: "TEXT_MESSAGE_CHUNK", messageId: "a", role: "assistant", delta: "Checking" },
      { type: "TEXT_MESSAGE_CHUNK", delta: " the weather." },
      { type: "TOOL_CALL_CHUNK", toolCallId: "c1", toolCallName: "weather", parentMessageId: "a", delta: "{\"city\":" },
      { type: "TOOL_CALL_CHUNK", delta: "\"Oslo\"}" },
      { type: "TOOL_CALL_RESULT", messageId: "res", toolCallId: "c1", content: "4C" },
      { type: "TOOL_CALL_CHUNK", toolCallId: "c2", toolCallName: SHOW, delta: "{\"lines\":[\"stat 4C Oslo\"]}" },
      { type: "STATE_SNAPSHOT", snapshot: { city: "Oslo" } },
      { type: "RUN_FINISHED", outcome: { type: "interrupt", interrupts: [{ id: "i1", reason: "confirm", message: "Book it?" }] } },
    ]) v.apply(e);
    assert.equal(v.text(), "Checking the weather.");
    assert.deepEqual(v.openCalls().map((c) => c.id), ["c2"], "the server ran c1; only c2 is the client's");
    assert.equal(showLines(v.openCalls()[0]), "```yui\nstat 4C Oslo\n```", "a list of lines works too");
    assert.deepEqual(v.state, { city: "Oslo" });
    assert.equal(v.interrupts[0].message, "Book it?");
    // c2 names no parent, so it opens a message of its own after c1's result: the order the model saw
    assert.deepEqual(v.thread().map((m) => m.role), ["assistant", "tool", "assistant"]);
    assert.deepEqual(v.thread().map((m: any) => m.toolCalls?.map((c: any) => c.id)), [["c1"], undefined, ["c2"]]);
  });

  test("RUN_ERROR ends the run with its message", () => {
    const v = new RunView();
    v.apply({ type: "RUN_ERROR", message: "model down", code: "E1" });
    assert.equal(v.finished, true);
    assert.deepEqual(v.error, { message: "model down", code: "E1" });
  });

  test("showLines: bare text, an existing fence, a fence of another kind, nothing", () => {
    const c = (args: string) => ({ id: "x", type: "function" as const, function: { name: SHOW, arguments: args } });
    assert.equal(showLines(c("choose Tea|Coffee")), "```yui\nchoose Tea|Coffee\n```", "not JSON: the text itself");
    assert.equal(showLines(c(JSON.stringify({ lines: "```yui\ntimer 5m\n```" }))), "```yui\ntimer 5m\n```");
    assert.equal(showLines(c(JSON.stringify({ lines: "```\ntimer 5m\n```" }))), "```yui\ntimer 5m\n```");
    assert.equal(showLines(c("{}")), "");
  });
});

// -- the wire ------------------------------------------------------------------------------------

describe("runAgent against a scripted AG-UI server", () => {
  const s = new Scripted();
  before(() => s.start());
  after(() => s.server.close());
  const input: RunAgentInput = { threadId: "t", runId: "r", messages: [], tools: [], context: [], state: {}, forwardedProps: {} };

  test("the recorded stream, in 37-byte pieces, gives every event in order", async () => {
    s.stream(fixture("maf_after_tap.sse"));
    const got: string[] = [];
    for await (const e of runAgent(s.url, input)) got.push(e.type);
    assert.deepEqual(got, events(fixture("maf_after_tap.sse")).map((e) => e.type));
    assert.deepEqual(s.inputs.at(-1), input, "the RunAgentInput is POSTed as is");
  });

  test("4xx is the server saying no: AguiError, not a retry", async () => {
    s.status(422, "bad input");
    await assert.rejects(async () => { for await (const _ of runAgent(s.url, input)); }, (e: any) => e instanceof AguiError && e.status === 422);
  });

  test("5xx, a stream cut before RUN_FINISHED, and no server at all: AguiUnavailable", async () => {
    s.status(503);
    await assert.rejects(async () => { for await (const _ of runAgent(s.url, input)); }, AguiUnavailable);
    s.run(say("half").slice(0, 3));
    await assert.rejects(async () => { for await (const _ of runAgent(s.url, input)); }, /before the run finished/);
    await assert.rejects(async () => { for await (const _ of runAgent("http://127.0.0.1:9/", input)); }, AguiUnavailable);
  });

  test("a stream that goes quiet counts as dropped", async () => {
    s.replies.push((res) => { res.writeHead(200, { "content-type": "text/event-stream" }); res.write(sse(say("x").slice(0, 1))); });
    await assert.rejects(async () => { for await (const _ of runAgent(s.url, input, { idle: 0.3 })); }, /no data/);
  });
});

// -- the bridge ----------------------------------------------------------------------------------

describe("bridge turns (Yui stubbed)", () => {
  const s = new Scripted();
  before(() => s.start());
  after(() => s.server.close());

  /** A bridge whose Yui side is in memory: rows in, replies out. */
  function bridge(guide: "system" | "tool" | "context" | "off" = "system") {
    const state = new State(join(mkdtempSync(join(tmpdir(), "yui-agui-")), "s.json"));
    state.data.remotes.ref = { url: s.url, name: "Helper" };
    const b = new Bridge(state, { guide });
    b.guide = { version: "v18", body: "GUIDE: answer with screens" };
    const inbox: any[] = [];
    const sent: { text: string; turn: string[] }[] = [];
    const marks: string[] = [];
    const byId = new Map<string, any>();
    Object.assign(b, {
      fresh: async () => inbox.splice(0).map((r) => (byId.set(r.id, r), r)),
      rowsById: async (_a: string, ids: string[]) => ids.map((i) => byId.get(i)),
      mark: async (ids: string[], col: string) => { marks.push(`${col}:${ids.join(",")}`); return true; },
      flushOutbox: async () => {
        for (const i of state.data.outbox.splice(0)) sent.push({ text: i.row.body, turn: i.row.meta.turn });
        state.save();
      },
      flushAcks: async () => {},
    });
    const agent = { id: "agent-1", name: "Helper", remote_ref: "ref" };
    const row = (id: string, body: string, kind = "text", meta: any = null) => ({ id, agent_id: agent.id, body, kind, meta, created_at: "", delivered_at: null });
    return { b, state, inbox, sent, marks, agent, row };
  }

  test("a turn: guide as a system message, yui_show offered, the screen goes to the phone", async () => {
    const { b, state, inbox, sent, marks, agent, row } = bridge();
    inbox.push(row("r1", "Pick me a fruit"));
    s.stream(fixture("maf_show.sse"));
    await b.turn(agent);
    const inp = s.inputs.at(-1)!;
    assert.equal(inp.threadId, agent.id);
    assert.match(inp.runId, /^yui-[0-9a-f]{32}$/);
    assert.deepEqual(inp.messages.map((m) => m.role), ["system", "user"]);
    assert.equal(inp.messages[0].content, "GUIDE: answer with screens");
    assert.deepEqual(inp.tools.map((t) => t.name), [SHOW]);
    assert.ok(!inp.tools[0].description.includes("GUIDE"), "system mode: the tool description stays short");
    assert.deepEqual(inp.context, []);
    assert.deepEqual(marks, ["delivered_at:r1"]);
    assert.deepEqual(sent, [{ text: "```yui\nWhich fruit? | Apple | Pear | Banana\n```", turn: ["r1"] }]);
    assert.equal(state.data.calls[agent.id][0].function.name, SHOW, "the call waits on the person");
    assert.equal(state.data.inflight[agent.id], undefined);
    assert.deepEqual(state.data.threads[agent.id].map((m) => m.role), ["user", "assistant"], "the guide is not kept in the thread");
  });

  test("the tap goes back as the tool's result; the answer closes the screen; the thread grows", async () => {
    const { b, state, inbox, sent, agent, row } = bridge();
    inbox.push(row("r1", "Pick me a fruit"));
    s.stream(fixture("maf_show.sse"));
    await b.turn(agent);
    const callId = state.data.calls[agent.id][0].id;
    inbox.push(row("r2", "[yui] n1 choose choice=Pear", "event", { id: "n1", preset: "choose", value: { choice: "Pear" } }));
    s.stream(fixture("maf_after_tap.sse"));
    await b.turn(agent);
    const inp = s.inputs.at(-1)!;
    assert.deepEqual(inp.messages.map((m) => m.role), ["system", "user", "assistant", "tool"], "no user message: the tap is the result");
    assert.deepEqual(inp.messages.at(-1), { id: `${inp.runId}-r0`, role: "tool", toolCallId: callId, content: "[yui] n1 choose choice=Pear" });
    assert.equal((inp.messages[2] as any).toolCalls[0].id, callId);
    assert.equal(sent.at(-1)!.text, "Great! You chose a pear for lunch. Enjoy your meal!");
    assert.deepEqual(sent.at(-1)!.turn, ["r2"]);
    assert.equal(state.data.calls[agent.id], undefined);
    assert.deepEqual(state.data.threads[agent.id].map((m) => m.role), ["user", "assistant", "tool", "assistant"]);
    // one more turn: the whole thread goes along
    inbox.push(row("r3", "and for dessert?"));
    s.run(say("Try a sorbet.", "m9"));
    await b.turn(agent);
    assert.deepEqual(s.inputs.at(-1)!.messages.map((m) => m.role), ["system", "user", "assistant", "tool", "assistant", "user"]);
  });

  test("typing instead of tapping closes the call and sends the words", async () => {
    const { b, state, inbox, agent, row } = bridge();
    inbox.push(row("r1", "Pick me a fruit"));
    s.stream(fixture("maf_show.sse"));
    await b.turn(agent);
    inbox.push(row("r2", "none of those, a mango"));
    s.run(say("Mango it is."));
    await b.turn(agent);
    const m = s.inputs.at(-1)!.messages;
    assert.deepEqual(m.slice(-2).map((x) => x.role), ["tool", "user"]);
    assert.match(m.at(-2)!.content as string, /wrote back instead of tapping/);
    assert.equal(m.at(-1)!.content, "none of those, a mango");
    assert.equal(state.data.calls[agent.id], undefined);
  });

  test("with no screen open, a tap (from a fenced reply) is the person's words", async () => {
    const { b, inbox, agent, row } = bridge();
    inbox.push(row("r1", "[yui] n1 choose choice=Tea", "event", { id: "n1" }));
    s.run(say("Tea, good."));
    await b.turn(agent);
    assert.deepEqual(s.inputs.at(-1)!.messages.at(-1), { id: "yui-r1", role: "user", content: "[yui] n1 choose choice=Tea" });
  });

  test("guide modes: in the tool's description, in context, off", async () => {
    for (const [mode, inTool, inCtx, sys] of [["tool", true, false, 0], ["context", false, true, 0], ["off", false, false, 0]] as const) {
      const { b, inbox, agent, row } = bridge(mode);
      inbox.push(row(`g-${mode}`, "hi"));
      s.run(say("hello"));
      await b.turn(agent);
      const inp = s.inputs.at(-1)!;
      assert.equal(inp.tools[0].description.includes("GUIDE: answer with screens"), inTool, mode);
      assert.equal(inp.context.some((c) => c.value === "GUIDE: answer with screens"), inCtx, mode);
      assert.equal(inp.messages.filter((m) => m.role === "system").length, sys, mode);
    }
  });

  test("an unreachable server keeps the turn; the next try is the same run", async () => {
    const { b, state, inbox, sent, agent, row } = bridge();
    inbox.push(row("r1", "hello"));
    s.status(503);
    await assert.rejects(b.turn(agent), AguiUnavailable);
    const first = s.inputs.at(-1)!;
    assert.deepEqual(state.data.inflight[agent.id].turn, ["r1"], "on disk, for the restart");
    assert.equal(sent.length, 0);
    s.run(say("hi!"));
    await b.turn(agent);
    assert.deepEqual(s.inputs.at(-1), first, "same runId, same messages");
    assert.deepEqual(sent, [{ text: "hi!", turn: ["r1"] }]);
  });

  test("a 4xx or RUN_ERROR tells the person once, and the thread stays whole", async () => {
    const { b, state, inbox, sent, agent, row } = bridge();
    inbox.push(row("r1", "hello"));
    s.status(422, "bad input");
    await b.turn(agent);
    assert.match(sent[0].text, /^Helper couldn't finish that\.\n\nIt answered with an error: 422 bad input/);
    inbox.push(row("r2", "again"));
    s.run([{ type: "RUN_STARTED" }, { type: "RUN_ERROR", message: "model down" }]);
    await b.turn(agent);
    assert.equal(sent[1].text, "Helper couldn't finish that.\n\nmodel down");
    assert.deepEqual(state.data.threads[agent.id].map((m) => m.role), ["user", "user"]);
    assert.equal(state.data.inflight[agent.id], undefined);
  });

  test("an interrupt asks the person; their answer goes back in resume; state rides along", async () => {
    const { b, state, inbox, sent, agent, row } = bridge();
    inbox.push(row("r1", "book a table"));
    s.run([{ type: "RUN_STARTED" }, { type: "STATE_SNAPSHOT", snapshot: { step: 1 } },
           { type: "RUN_FINISHED", outcome: { type: "interrupt", interrupts: [{ id: "i1", reason: "confirm", message: "Book for 7pm?" }] } }]);
    await b.turn(agent);
    assert.equal(sent[0].text, "Book for 7pm?");
    inbox.push(row("r2", "yes"));
    s.run(say("Booked."));
    await b.turn(agent);
    const inp = s.inputs.at(-1)!;
    assert.deepEqual(inp.resume, [{ interruptId: "i1", status: "resolved", payload: { text: "yes" } }]);
    assert.deepEqual(inp.state, { step: 1 });
    assert.equal(state.data.interrupts[agent.id], undefined);
  });

  test("the thread keeps its last messages, cut at a person's message", () => {
    const long = Array.from({ length: MAX_THREAD + 5 }, (_, i) => ({ id: `m${i}`, role: (i % 3 ? "assistant" : "user") as any, content: "x" }));
    const t = trim(long);
    assert.ok(t.length <= MAX_THREAD);
    assert.equal(t[0].role, "user");
    assert.equal(t.at(-1)!.id, `m${MAX_THREAD + 4}`);
  });
});
