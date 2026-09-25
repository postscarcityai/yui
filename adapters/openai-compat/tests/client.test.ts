// The model client and the thread builder, against the scripted server in
// tests/fake-model.ts (no network beyond 127.0.0.1, no model).
//   node --test tests/client.test.ts
import assert from "node:assert/strict";
import { after, before, describe, test } from "node:test";
import { ChatClient, ModelError, ModelUnavailable, SERVERS, StreamRefused, baseUrl, errorMessage, splitThinking } from "../src/openai.ts";
import { alternate, buildMessages, toMessage, tokens, type ThreadRow } from "../src/thread.ts";
import { startFake, type Fake } from "./fake-model.ts";

const user = (body: string, extra: Partial<ThreadRow> = {}): ThreadRow => ({ id: body, sender: "user", kind: "text", body, ...extra });
const agent = (body: string, extra: Partial<ThreadRow> = {}): ThreadRow => ({ id: body, sender: "agent", kind: "text", body, ...extra });
const ask = (c: ChatClient, text: string, stream = true, onDelta?: (d: string) => void) =>
  c.complete({ model: "fake-1", messages: [{ role: "system", content: "guide" }, { role: "user", content: text }] }, { stream, onDelta });

describe("client, streaming server", () => {
  let f: Fake;
  let c: ChatClient;
  before(async () => {
    f = await startFake();
    c = new ChatClient(f.url);
  });
  after(() => f.close());

  test("lists the models", async () => {
    assert.deepEqual(await c.models(), ["fake-1", "fake-2"]);
  });
  test("streams, pieces add up, onDelta sees each", async () => {
    const seen: string[] = [];
    const r = await ask(c, "hello", true, (d) => seen.push(d));
    assert.equal(r.text, "You said: hello");
    assert.equal(r.streamed, true);
    assert.equal(r.finish, "stop");
    assert.deepEqual(seen, ["You said: ", "hello"]);
    assert.equal(f.log.at(-1).stream, true);
  });
  test("a ```yui screen comes through as is", async () => {
    const r = await ask(c, "screen");
    assert.equal(r.text, "Pick one:\n```yui\nchoose \"Pick one\" Tea|Coffee\n```");
  });
  test("plain when asked plain", async () => {
    const r = await ask(c, "hello", false);
    assert.equal(r.text, "You said: hello");
    assert.equal(r.streamed, false);
    assert.ok(r.usage?.prompt_tokens);
    assert.equal(f.log.at(-1).stream, false);
  });
  test("a <think> block is taken out of the answer", async () => {
    const r = await ask(c, "think");
    assert.equal(r.text, "Thought it through.");
    assert.equal(r.reasoning, "Let me see. Tea or coffee.");
  });
  test("a stream that breaks halfway is ModelUnavailable, and the next try is whole", async () => {
    await assert.rejects(ask(c, "drop"), (e: any) => e instanceof ModelUnavailable && /stream/.test(e.message));
    assert.equal((await ask(c, "drop")).text, "Whole this time.");
  });
  test("503 is ModelUnavailable (try again), then it answers", async () => {
    await assert.rejects(ask(c, "flaky"), (e: any) => e instanceof ModelUnavailable && /503/.test(e.message));
    assert.equal((await ask(c, "flaky")).text, "Back again.");
  });
  test("400 is a ModelError with the server's words", async () => {
    await assert.rejects(ask(c, "refuse"), (e: any) => e instanceof ModelError && !(e instanceof StreamRefused)
      && e.status === 400 && /maximum context length/.test(e.message));
  });
  test("an unknown model is a ModelError that says what to check", async () => {
    await assert.rejects(c.complete({ model: "nope", messages: [{ role: "user", content: "hi" }] }),
      (e: any) => e instanceof ModelError && e.status === 404 && /not found/.test(e.message) && /model name/.test(e.message));
  });
  test("a quiet stream times out as ModelUnavailable", async () => {
    const slow = new ChatClient(f.url, { idle: 0.5 });
    await assert.rejects(ask(slow, "slow 3"), (e: any) => e instanceof ModelUnavailable && /quiet|no answer/.test(e.message));
  });
  test("a long answer is fine while pieces keep coming", async () => {
    const r = await new ChatClient(f.url, { idle: 1.6 }).complete(
      { model: "fake-1", messages: [{ role: "user", content: "slow 3" }] });
    assert.equal(r.text, "Step 1, step 2, step 3\n\nDone after 3 steps.");
  });
});

describe("client, other servers", () => {
  test("a server that ignores stream: true is read as plain JSON", async () => {
    const f = await startFake({ streaming: false });
    try {
      const r = await ask(new ChatClient(f.url), "hello");
      assert.equal(r.text, "You said: hello");
      assert.equal(r.streamed, false);
    } finally {
      await f.close();
    }
  });
  test("a server that refuses streams says so with StreamRefused", async () => {
    const f = await startFake({ refuseStream: true });
    try {
      const c = new ChatClient(f.url);
      await assert.rejects(ask(c, "hello"), (e: any) => e instanceof StreamRefused);
      assert.equal((await ask(c, "hello", false)).text, "You said: hello");
    } finally {
      await f.close();
    }
  });
  test("a stream with finish_reason but no [DONE] is complete", async () => {
    const f = await startFake({ done: false });
    try {
      assert.equal((await ask(new ChatClient(f.url), "hello")).text, "You said: hello");
    } finally {
      await f.close();
    }
  });
  test("the key goes as a bearer token; a wrong one is a ModelError about the key", async () => {
    const f = await startFake({ key: "sk-test-123" });
    try {
      assert.equal((await ask(new ChatClient(f.url, { key: "sk-test-123" }), "hello")).text, "You said: hello");
      assert.equal(f.log.at(-1).auth, "Bearer sk-test-123");
      await assert.rejects(ask(new ChatClient(f.url, { key: "wrong" }), "hello"),
        (e: any) => e instanceof ModelError && e.status === 401 && /key/.test(e.message));
      await assert.rejects(new ChatClient(f.url).models(), (e: any) => e instanceof ModelError && e.status === 401);
    } finally {
      await f.close();
    }
  });
  test("nothing listening is ModelUnavailable naming the URL", async () => {
    await assert.rejects(ask(new ChatClient("http://127.0.0.1:9/v1"), "hello"),
      (e: any) => e instanceof ModelUnavailable && e.message.includes("127.0.0.1:9/v1"));
  });
});

describe("client, Gemini-shaped server (INT-9)", () => {
  let f: Fake;
  let c: ChatClient;
  before(async () => {
    f = await startFake({ gemini: true, key: "gm-test-key" });
    c = new ChatClient(f.url, { key: "gm-test-key" });
  });
  after(() => f.close());

  test("the preset is Google's OpenAI-compatible base, key from GEMINI_API_KEY, a bigger window", () => {
    assert.equal(SERVERS.gemini.url, "https://generativelanguage.googleapis.com/v1beta/openai");
    assert.equal(baseUrl(`${SERVERS.gemini.url}/`), SERVERS.gemini.url);
    assert.equal(SERVERS.gemini.keyEnv, "GEMINI_API_KEY");
    assert.ok((SERVERS.gemini.context ?? 0) > 4096);
  });
  test("models/ comes off the listed ids, so they match what chat takes", async () => {
    assert.deepEqual(await c.models(), ["fake-1", "fake-2"]);
  });
  test("streams without a role-only opener, the last piece carrying finish and usage", async () => {
    const seen: string[] = [];
    const r = await ask(c, "hello", true, (d) => seen.push(d));
    assert.equal(r.text, "You said: hello");
    assert.deepEqual(seen, ["You said: ", "hello"]);
    assert.equal(r.finish, "stop");
    assert.ok(r.usage?.prompt_tokens);
  });
  test("a screen streams through whole", async () => {
    assert.equal((await ask(c, "screen")).text, "Pick one:\n```yui\nchoose \"Pick one\" Tea|Coffee\n```");
  });
  test("the system message goes as a system role, first", async () => {
    await ask(c, "hello");
    assert.deepEqual(f.log.at(-1).messages.map((m: any) => m.role), ["system", "user"]);
  });
  test("a streamed thought (extra_content.google.thought) is reasoning, not the answer", async () => {
    const seen: string[] = [];
    const r = await ask(c, "thought", true, (d) => seen.push(d));
    assert.equal(r.text, "Tea, then.");
    assert.equal(r.reasoning, "Tea suits the afternoon.");
    assert.deepEqual(seen, ["Tea, ", "then."]);
  });
  test("a plain <thought> block is taken out", async () => {
    const r = await ask(c, "thought", false);
    assert.equal(r.text, "Tea, then.");
    assert.equal(r.reasoning, "Tea suits the afternoon.");
  });
  test("a blocked answer is empty with content_filter, streamed or plain", async () => {
    for (const stream of [true, false]) {
      const r = await ask(c, "blocked", stream);
      assert.equal(r.text, "");
      assert.equal(r.finish, "content_filter");
    }
  });
  test("an error wrapped in a list reads as its message", async () => {
    await assert.rejects(c.complete({ model: "gemini-nope", messages: [{ role: "user", content: "hi" }] }),
      (e: any) => e instanceof ModelError && e.status === 404 && /"gemini-nope" not found/.test(e.message) && !/^\[/.test(e.message));
  });
  test("429 RESOURCE_EXHAUSTED is ModelUnavailable (wait), then it answers", async () => {
    await assert.rejects(ask(c, "quota"), (e: any) => e instanceof ModelUnavailable && /429: Resource has been exhausted/.test(e.message));
    assert.equal((await ask(c, "quota")).text, "Quota back.");
  });
  test("a bad key is Gemini's 400 INVALID_ARGUMENT, and reads as a key problem", async () => {
    const bad = new ChatClient(f.url, { key: "wrong" });
    await assert.rejects(ask(bad, "hello"), (e: any) => e instanceof ModelError && !(e instanceof StreamRefused)
      && e.status === 400 && /turned the key down/.test(e.message) && /API key not valid/.test(e.message));
    await assert.rejects(bad.models(), (e: any) => e instanceof ModelError && /key/.test(e.message));
  });
});

describe("client, Grok-shaped server (INT-10)", () => {
  let f: Fake;
  let c: ChatClient;
  before(async () => {
    f = await startFake({ grok: true, key: "xai-test-key" });
    c = new ChatClient(f.url, { key: "xai-test-key" });
  });
  after(() => f.close());

  test("the preset is xAI's base, key from XAI_API_KEY, a default model, a bigger window", () => {
    assert.equal(SERVERS.grok.url, "https://api.x.ai/v1");
    assert.equal(baseUrl(`${SERVERS.grok.url}/chat/completions`), SERVERS.grok.url);
    assert.equal(SERVERS.grok.keyEnv, "XAI_API_KEY");
    assert.match(SERVERS.grok.model ?? "", /^grok-/);
    assert.ok((SERVERS.grok.context ?? 0) > 4096);
  });
  test("lists the models", async () => {
    assert.deepEqual(await c.models(), ["fake-1", "fake-2"]);
  });
  test("streams, and sends none of the arguments reasoning models refuse", async () => {
    const r = await ask(c, "hello");
    assert.equal(r.text, "You said: hello");
    assert.equal(r.finish, "stop");
    for (const k of ["stop", "presence_penalty", "frequency_penalty"]) assert.ok(!f.log.at(-1).keys.includes(k), k);
  });
  test("a screen streams through whole", async () => {
    assert.equal((await ask(c, "screen")).text, "Pick one:\n```yui\nchoose \"Pick one\" Tea|Coffee\n```");
  });
  test("reasoning_content is reasoning, not the answer, streamed or plain", async () => {
    for (const stream of [true, false]) {
      const seen: string[] = [];
      const r = await ask(c, "reason", stream, (d) => seen.push(d));
      assert.equal(r.text, "Tea, then.");
      assert.equal(r.reasoning, "Tea suits the afternoon.");
      if (stream) assert.deepEqual(seen, ["Tea, ", "then."]);
    }
  });
  test("a refusal with no content is the answer, streamed or plain", async () => {
    for (const stream of [true, false]) {
      const seen: string[] = [];
      const r = await ask(c, "decline", stream, (d) => seen.push(d));
      assert.equal(r.text, "I can't help with that one.");
      if (stream) assert.deepEqual(seen, ["I can't help with that one."]);
    }
  });
  test("an error as {code, error} reads as its message", async () => {
    await assert.rejects(c.complete({ model: "grok-nope", messages: [{ role: "user", content: "hi" }] }),
      (e: any) => e instanceof ModelError && e.status === 404 && /"grok-nope" not found/.test(e.message) && !/Some requested/.test(e.message));
  });
  test("429 is ModelUnavailable (wait), then it answers", async () => {
    await assert.rejects(ask(c, "busy"), (e: any) => e instanceof ModelUnavailable && /429: Rate limit reached/.test(e.message));
    assert.equal((await ask(c, "busy")).text, "Back in line.");
  });
  test("403 out of credits says so, not that the key is bad, and does not wait", async () => {
    await assert.rejects(ask(c, "broke"), (e: any) => e instanceof ModelError && !(e instanceof ModelUnavailable)
      && e.status === 403 && /out of credits/.test(e.message) && !/turned the key down/.test(e.message));
  });
  test("a bad key is xAI's 400, and reads as a key problem", async () => {
    const bad = new ChatClient(f.url, { key: "wrong" });
    await assert.rejects(ask(bad, "hello"), (e: any) => e instanceof ModelError && !(e instanceof StreamRefused)
      && e.status === 400 && /turned the key down/.test(e.message) && /Incorrect API key/.test(e.message));
    await assert.rejects(bad.models(), (e: any) => e instanceof ModelError && /key/.test(e.message));
  });
  test("the fake refuses what Grok's reasoning models refuse", async () => {
    await assert.rejects(c.complete({ model: "fake-1", messages: [{ role: "user", content: "hi" }], stop: ["x"] } as any),
      (e: any) => e instanceof ModelError && e.status === 400 && /not supported on this model: stop/.test(e.message));
  });
});

describe("helpers", () => {
  test("baseUrl takes the endpoint or the base, with or without a slash", () => {
    assert.equal(baseUrl("http://127.0.0.1:11434/v1/"), "http://127.0.0.1:11434/v1");
    assert.equal(baseUrl("http://127.0.0.1:11434/v1/chat/completions"), "http://127.0.0.1:11434/v1");
    assert.equal(baseUrl(" https://openrouter.ai/api/v1 "), "https://openrouter.ai/api/v1");
    assert.throws(() => baseUrl("not a url"));
  });
  test("errorMessage reads the shapes servers use", () => {
    assert.equal(errorMessage('{"error":{"message":"model not found"}}'), "model not found");
    assert.equal(errorMessage('{"error":"bad request"}'), "bad request");
    assert.equal(errorMessage('{"detail":[{"msg":"field required"}]}'), "field required");
    assert.equal(errorMessage("Bad Gateway"), "Bad Gateway");
    assert.equal(errorMessage('[{"error":{"code":400,"message":"API key not valid.","status":"INVALID_ARGUMENT"}}]'), "API key not valid.");
    assert.equal(errorMessage('{"code":"Client specified an invalid argument","error":"Incorrect API key provided: xa***."}'), "Incorrect API key provided: xa***.");
  });
  test("splitThinking only takes a leading block", () => {
    assert.deepEqual(splitThinking("<think>a</think>\nhi"), { text: "\nhi", thinking: "a" });
    assert.deepEqual(splitThinking("hi <think>a</think>"), { text: "hi <think>a</think>", thinking: "" });
    assert.deepEqual(splitThinking("<think>still going"), { text: "", thinking: "still going" });
    assert.deepEqual(splitThinking("<thought>a</thought>hi"), { text: "hi", thinking: "a" });
    assert.deepEqual(splitThinking("<thinking>a</thinking>hi"), { text: "hi", thinking: "a" });
    assert.deepEqual(splitThinking("<thought>a</think>hi"), { text: "", thinking: "a</think>hi" });
  });
});

describe("thread", () => {
  const guide = "## You are talking to someone in Yui\nAnswer with screens.";

  test("the guide is the system message, after the person's own instructions", () => {
    const { messages } = buildMessages([], [user("hi")], { guide, system: "You are Qwen." });
    assert.deepEqual(messages, [{ role: "system", content: `You are Qwen.\n\n${guide}` }, { role: "user", content: "hi" }]);
  });
  test("history goes in oldest first, agent rows as assistant, a tap as its line", () => {
    const history = [user("screen"), agent("```yui\nchoose \"Pick one\" Tea|Coffee\n```")];
    const tap = user("[yui] n1 choose choice=Tea", { kind: "event", meta: { id: "n1", preset: "choose", value: { choice: "Tea" }, echo: "Tea" } });
    const { messages, dropped } = buildMessages(history, [tap], { guide });
    assert.deepEqual(messages.map((m) => m.role), ["system", "user", "assistant", "user"]);
    assert.equal(messages[3].content, "[yui] n1 choose choice=Tea");
    assert.equal(dropped, 0);
  });
  test("a turn of several messages is one user message, in order", () => {
    const { messages } = buildMessages([], [user("first"), user("second")], { guide });
    assert.deepEqual(messages.slice(1), [{ role: "user", content: "first\nsecond" }]);
  });
  test("the newest history that fits the context goes in, never a gap", () => {
    const history = Array.from({ length: 40 }, (_, i) => (i % 2 ? agent : user)(`message ${i} ${"x".repeat(200)}`));
    const { messages, dropped } = buildMessages(history, [user("now")], { guide, context: 1024 + tokens(guide) + 400, reserve: 1024 });
    assert.ok(dropped > 30 && dropped < 40, `dropped ${dropped}`);
    const kept = messages.slice(1, -1);
    assert.ok(kept.length >= 1);
    assert.equal(messages.at(-1)!.content, "now");
    assert.equal(messages[1].role, "user"); // starts with the person
    assert.ok(kept.at(-1)!.content.startsWith("message 39"));
  });
  test("over budget with the turn alone still sends the turn, and says so", () => {
    const r = buildMessages([user("old")], [user("y".repeat(20000))], { guide, context: 2048 });
    assert.equal(r.over, true);
    assert.equal(r.messages.length, 2);
    assert.equal(r.dropped, 1);
  });
  test("the bridge's own status lines stay out; a mention reply is a note", () => {
    assert.equal(toMessage(agent("Qwen can't reach its model", { meta: { bridge: "status" } })), null);
    assert.deepEqual(toMessage(agent("Tea is fine", { meta: { mention_reply: { name: "Bravo" } } })),
                     { role: "user", content: "[yui] Bravo answered: Tea is fine" });
    assert.equal(toMessage(user("   ")), null);
  });
  test("alternate joins runs and starts with the person", () => {
    assert.deepEqual(alternate([{ role: "assistant", content: "a" }, { role: "user", content: "b" }, { role: "user", content: "c" },
                                { role: "assistant", content: "d" }]),
                     [{ role: "user", content: "b\nc" }, { role: "assistant", content: "d" }]);
  });
});
