// The model client and the thread builder, against the scripted server in
// tests/fake-model.ts (no network beyond 127.0.0.1, no model).
//   node --test tests/client.test.ts
import assert from "node:assert/strict";
import { after, before, describe, test } from "node:test";
import { ChatClient, ModelError, ModelUnavailable, SERVERS, StreamRefused, baseUrl, errorMessage, retryAfter, splitThinking } from "../src/openai.ts";
import { SMALL_GUIDE, asYui, firstScreen } from "../src/fences.ts";
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

describe("client, Meta-shaped server (INT-11)", () => {
  let f: Fake;
  let c: ChatClient;
  // Meta's keys carry "|" between their parts; this one only has the shape.
  const key = "LLM|test|meta-key";
  before(async () => {
    f = await startFake({ meta: true, key });
    c = new ChatClient(f.url, { key });
  });
  after(() => f.close());

  test("the preset is Meta's base, key from MODEL_API_KEY, Muse Spark by default, a bigger window; muse is the same", () => {
    assert.equal(SERVERS.meta.url, "https://api.meta.ai/v1");
    assert.equal(baseUrl(`${SERVERS.meta.url}/chat/completions`), SERVERS.meta.url);
    assert.equal(SERVERS.meta.keyEnv, "MODEL_API_KEY");
    assert.match(SERVERS.meta.model ?? "", /^muse-spark-/);
    assert.ok((SERVERS.meta.context ?? 0) > 4096);
    assert.equal(SERVERS.muse, SERVERS.meta);
  });
  test("lists the models, the key with its | goes through whole", async () => {
    assert.deepEqual(await c.models(), ["fake-1", "fake-2"]);
    assert.equal(f.log.length, 0);
    await ask(c, "hello");
    assert.equal(f.log.at(-1).auth, `Bearer ${key}`);
  });
  test("streams, and sends none of the arguments Muse Spark refuses", async () => {
    const r = await ask(c, "hello");
    assert.equal(r.text, "You said: hello");
    assert.equal(r.finish, "stop");
    for (const k of ["stop", "n", "logit_bias", "reasoning_effort"]) assert.ok(!f.log.at(-1).keys.includes(k), k);
  });
  test("a screen streams through whole", async () => {
    assert.equal((await ask(c, "screen")).text, "Pick one:\n```yui\nchoose \"Pick one\" Tea|Coffee\n```");
  });
  test("the redacted, empty reasoning_content changes nothing, streamed or plain", async () => {
    for (const stream of [true, false]) {
      const seen: string[] = [];
      const r = await ask(c, "reason", stream, (d) => seen.push(d));
      assert.equal(r.text, "Tea, then.");
      assert.equal(r.reasoning, "");
      if (stream) assert.deepEqual(seen, ["Tea, ", "then."]);
    }
  });
  test("a bad key is 401 invalid_api_key, and reads as a key problem", async () => {
    const bad = new ChatClient(f.url, { key: "wrong" });
    await assert.rejects(ask(bad, "hello"), (e: any) => e instanceof ModelError && e.status === 401 && /turned the key down/.test(e.message));
    await assert.rejects(bad.models(), (e: any) => e instanceof ModelError && /key/.test(e.message));
  });
  test("an unknown model reads as not found, with Meta's message", async () => {
    await assert.rejects(c.complete({ model: "muse-nope", messages: [{ role: "user", content: "hi" }] }),
      (e: any) => e instanceof ModelError && e.status === 404 && /`muse-nope` does not exist/.test(e.message) && /Check the model name/.test(e.message));
  });
  test("a 404 with no body still says not found", async () => {
    const wrong = new ChatClient(`${f.url}/nope`, { key });
    await assert.rejects(ask(wrong, "hello"), (e: any) => e instanceof ModelError && e.status === 404 && /not found \(Not Found\)/.test(e.message));
  });
  test("429 waits as long as Retry-After says, then it answers", async () => {
    await assert.rejects(ask(c, "busy"), (e: any) => e instanceof ModelUnavailable && e.retryAfter === 2 && /429: Rate limit exceeded/.test(e.message));
    assert.equal((await ask(c, "busy")).text, "Back in line.");
  });
  test("402 billing_error says the account is out of funds, and does not wait", async () => {
    await assert.rejects(ask(c, "broke"), (e: any) => e instanceof ModelError && !(e instanceof ModelUnavailable)
      && e.status === 402 && /out of credits/.test(e.message) && !/turned the key down/.test(e.message));
  });
  test("403 for a model the key can't use says so, not that the key is bad", async () => {
    await assert.rejects(ask(c, "locked"), (e: any) => e instanceof ModelError && e.status === 403
      && /no access to this model/.test(e.message) && !/turned the key down/.test(e.message));
  });
  test("a content policy 400 reads as the safety filter, not a broken request", async () => {
    await assert.rejects(ask(c, "unsafe"), (e: any) => e instanceof ModelError && !(e instanceof StreamRefused)
      && e.status === 400 && /safety filter/.test(e.message) && /another way/.test(e.message));
  });
  test("a thread over the window says which knob to turn", async () => {
    await assert.rejects(ask(c, "long"), (e: any) => e instanceof ModelError && e.status === 400 && /must fit/.test(e.message) && /Lower --context/.test(e.message));
  });
  test("504 gateway_timeout on a plain answer does not retry and says to stream; streamed it answers", async () => {
    await assert.rejects(ask(c, "timeout", false), (e: any) => e instanceof ModelError && !(e instanceof ModelUnavailable)
      && e.status === 504 && /--no-stream/.test(e.message));
    assert.equal((await ask(c, "timeout")).text, "Streamed in time.");
  });
  test("an error event mid-stream (overloaded) is ModelUnavailable, then it answers", async () => {
    await assert.rejects(ask(c, "overload"), (e: any) => e instanceof ModelUnavailable && /overloaded/.test(e.message));
    assert.equal((await ask(c, "overload")).text, "Calm again.");
  });
  test("the fake refuses what Muse Spark refuses", async () => {
    for (const extra of [{ stop: ["x"] }, { n: 2 }, { logit_bias: {} }, { reasoning_effort: "none" }]) {
      await assert.rejects(c.complete({ model: "fake-1", messages: [{ role: "user", content: "hi" }], ...extra } as any),
        (e: any) => e instanceof ModelError && e.status === 400 && /is not supported with this model/.test(e.message));
    }
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
  test("retryAfter reads seconds or a date, and ignores the rest", () => {
    assert.equal(retryAfter("2"), 2);
    assert.equal(retryAfter(null), undefined);
    assert.equal(retryAfter("soon"), undefined);
    assert.ok((retryAfter(new Date(Date.now() + 5000).toUTCString()) ?? 0) >= 4);
    assert.equal(retryAfter("99999"), 3600);
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

describe("small models (INT-23)", () => {
  const screen = 'choose "Drink" Tea|Coffee';
  test("a yml, yaml or plain fence that opens with a Yui Line becomes a yui fence", () => {
    for (const tag of ["yml", "yaml", "", "YAML", "text"]) {
      assert.equal(asYui(`Sure:\n\`\`\`${tag}\n${screen}\n\`\`\`\nEnjoy`), `Sure:\n\`\`\`yui\n${screen}\n\`\`\`\nEnjoy`, tag);
    }
  });
  test("a mode line or an id on the first line counts", () => {
    assert.equal(asYui('```yml\n>full\ndeck "Hi"\n```'), '```yui\n>full\ndeck "Hi"\n```');
    assert.equal(asYui('```yaml\nchoose@drink "Drink" Tea|Coffee\n```'), '```yui\nchoose@drink "Drink" Tea|Coffee\n```');
  });
  test("code, yui fences and prose in a fence are left alone", () => {
    for (const t of ['```js\nchoose("x")\n```', `\`\`\`yui\n${screen}\n\`\`\``, "```yml\nname: tea\nchoose: yes\n```", "```\nnothing here\n```", "no fence at all"]) {
      assert.equal(asYui(t), t);
    }
  });
  test("two fences: only the Yui one is retagged", () => {
    assert.equal(asYui(`\`\`\`yml\nname: x\n\`\`\`\n\`\`\`yml\n${screen}\n\`\`\``), `\`\`\`yml\nname: x\n\`\`\`\n\`\`\`yui\n${screen}\n\`\`\``);
  });
  test("a model that forgot the fence: bare Yui Lines get one, a lone yui line above goes", () => {
    assert.equal(asYui("yui\ntimer 5m Plank"), "```yui\ntimer 5m Plank\n```");
    assert.equal(asYui("timer 5m Plank"), "```yui\ntimer 5m Plank\n```");
    assert.equal(asYui('How sore?\nslide "How sore?" 1-5 Fresh|Wrecked'), 'How sore?\n```yui\nslide "How sore?" 1-5 Fresh|Wrecked\n```');
    assert.equal(asYui(`${screen}\ntimer 5m Plank`), `\`\`\`yui\n${screen}\ntimer 5m Plank\n\`\`\``);
  });
  test("a line in single backticks is fenced", () => {
    assert.equal(asYui('`slide "How sore?" 1-5 Fresh|Wrecked`'), '```yui\nslide "How sore?" 1-5 Fresh|Wrecked\n```');
  });
  test("the yui tag inside a plain fence moves out", () => {
    assert.equal(asYui("```\nyui\ntimer 5m Plank\n```"), "```yui\ntimer 5m Plank\n```");
  });
  test("a yui fence that never closes is closed", () => {
    assert.equal(asYui(`How sore?\n\`\`\`yui\n${screen}`), `How sore?\n\`\`\`yui\n${screen}\n\`\`\``);
    assert.equal(asYui(`\`\`\`yui\n${screen}\n\`\`\``), `\`\`\`yui\n${screen}\n\`\`\``);
  });
  test("a stray [yui] marker line is dropped", () => {
    assert.equal(asYui(`\`\`\`yui\n${screen}\n\`\`\`\n[yui]`), `\`\`\`yui\n${screen}\n\`\`\`\n`);
    assert.equal(asYui('[ yui ]\nslide "How sore?" 1-5 Fresh|Wrecked'), '```yui\nslide "How sore?" 1-5 Fresh|Wrecked\n```');
    assert.equal(asYui("[/yui]\nHow sore are you?"), "How sore are you?");
  });
  test("a role label in front of a bubble is stripped (INT-27)", () => {
    const fence = `\`\`\`yui\n${screen}\n\`\`\``;
    // the real llama3.2:3b answer from the Drink screen
    assert.equal(asYui(`${fence}\n[Response:] What do you want to drink?`), `${fence}\nWhat do you want to drink?`);
    assert.equal(asYui(`${fence}\nResponse: Pick one.`), `${fence}\nPick one.`);
    assert.equal(asYui(`Assistant: Here you go.\n${fence}`), `Here you go.\n${fence}`);
    assert.equal(asYui(`[Assistant] Here you go.\n${fence}`), `Here you go.\n${fence}`);
    assert.equal(asYui(`${fence}\n[yui] What can I get you?`), `${fence}\nWhat can I get you?`);
    assert.equal(asYui(`${fence}\n[yui]Timed out after 5 minutes!`), `${fence}\nTimed out after 5 minutes!`);
  });
  test("a label with nothing after it drops the bubble", () => {
    const fence = `\`\`\`yui\n${screen}\n\`\`\``;
    assert.equal(asYui(`${fence}\n[Response:]`), fence);
    assert.equal(asYui("[Response:]"), "");
  });
  test("a label inside a quoted or fenced line stays", () => {
    for (const t of ["> Response: this was quoted", '"Response: hi" is what it said', "He wrote [Response:] in the log", "Answer: 42", "Reply: later", "The Assistant: a film"]) {
      assert.equal(asYui(t), t);
    }
    assert.equal(asYui("```text\nResponse: keep\n```"), "```text\nResponse: keep\n```");
  });
  test("after a tap, back-to-back screens keep the first (INT-27)", () => {
    const a = `\`\`\`yui\n${screen}\n\`\`\``;
    const b = '```yui\nask "How are you today?" Good|Bad\n```';
    const c = '```yui\nform "Introduce yourself" name:~\n```';
    assert.equal(firstScreen(`${a}\n\n${b}\n\n${c}`), a);
    assert.equal(firstScreen(`${a}\n${b}`), a);
    assert.equal(firstScreen(a), a);
    assert.equal(firstScreen(`Nice.\n${a}\nSay more\n${b}`), `Nice.\n${a}\nSay more\n${b}`); // prose between: both stay
    assert.equal(firstScreen(`${a}\n\nDone.`), `${a}\n\nDone.`);
    assert.equal(firstScreen("no screens here"), "no screens here");
  });
  const chat = (c: ChatClient, text: string) => c.complete({ model: "fake-1", messages: [{ role: "system", content: "guide" }, { role: "user", content: text }] }, { stream: true });
  const ask = "Sunlight enters a raindrop and bends. It splits into colors, bounces off the back, and exits. We see the colors as a rainbow.";
  test("a film ask is repaired: unquoted, split over lines, open quote, bare, wrong fence (INT-28)", () => {
    const good = `How a rainbow forms.\n\`\`\`yui\nmotion "${ask}"\n\`\`\``;
    assert.equal(asYui(good), good);
    assert.equal(asYui(`How a rainbow forms.\n\`\`\`yui\nmotion ${ask}\n\`\`\``), good); // unquoted
    assert.equal(asYui(`How a rainbow forms.\n\`\`\`yui\nmotion "Sunlight enters a raindrop and bends.\nIt splits into colors, bounces off the back, and exits.\nWe see the colors as a rainbow."\n\`\`\``), good); // split
    assert.equal(asYui(`How a rainbow forms.\n\`\`\`yui\nmotion ${ask.replace(". It", ".\nIt")}\n\`\`\``), good); // unquoted and split
    assert.equal(asYui(`How a rainbow forms.\n\`\`\`yui\nmotion "${ask}`), good); // quote and fence left open
    assert.equal(asYui(`How a rainbow forms.\n\`\`\`yui\nmotion "${ask}\n\`\`\``), good); // quote left open
    assert.equal(asYui(`How a rainbow forms.\nmotion "${ask}"`), good); // no fence
    assert.equal(asYui(`How a rainbow forms.\nmotion ${ask}`), good); // no fence, no quotes
    assert.equal(asYui(`How a rainbow forms.\n\`\`\`yml\nmotion "${ask}"\n\`\`\``), good); // wrong tag
    assert.equal(asYui(good.replace("```yui\n", "```\n")), good);
    assert.equal(asYui(`How.\n\`\`\`yui\nmotion "It says \"hi\" twice. Then it stops."\n\`\`\``), `How.\n\`\`\`yui\nmotion "It says 'hi' twice. Then it stops."\n\`\`\``);
    assert.equal(asYui(`Why.\n\`\`\`yui\nmotion ${ask}\nchoose "Quiz" A|B\n\`\`\``), `Why.\n\`\`\`yui\nmotion "${ask}"\nchoose "Quiz" A|B\n\`\`\``); // the next Yui Line stays its own
  });
  test("a film reply keeps one short line and the film, never the prose a small model adds (INT-28)", () => {
    const film = `\`\`\`yui\nmotion "${ask}"\n\`\`\``;
    assert.equal(asYui(`How a rainbow forms.\n${film}\n"Light bends."\n"Colors split."\nTap to continue`), `How a rainbow forms.\n${film}`);
    assert.equal(asYui(`${film}\n"Light is made of colors."\n"They bend."`), film);
    assert.equal(asYui(`How.\nIt is long.\n${film}`), `How.\n${film}`);
    const quiz = '```yui\nchoose "Quiz" A|B\n```';
    assert.equal(asYui(`How.\n${film}\nNice.\n${quiz}`), `How.\n${film}\n${quiz}`); // the quiz under the film stays
    const card = 'Here.\n```yui\ncard "Plan" body="Hi"\n```\nMore words below.';
    assert.equal(asYui(card), card); // no film: untouched
  });
  test("a dropped film opener is put back for an explain question, replayed from llama3.2:3b (INT-29)", async () => {
    const f = await startFake();
    try {
      const c = new ChatClient(f.url);
      const replay = async (name: string) => (await chat(c, `replay ${name}`)).text;
      const film = (a: string) => `Here's how it works.\n\`\`\`yui\nmotion "${a}"\n\`\`\``;
      const q = "how does a rainbow form?";
      assert.equal(asYui(await replay("strayQuote"), q),
        film("Sunlight enters a raindrop and bends. It splits into colors, hits a tiny water particle, reflects again, bounces off. We see the colors as a rainbow."));
      assert.equal(asYui(await replay("quotedLines"), "how does a bill become law?"),
        film("First, Congress proposes a bill. It's sent to the President for signature or veto. Awaits Presidential decision or signing into law."));
      assert.equal(asYui(await replay("bracketLines"), "how does a bill become law?"),
        film("Congress sends it to committee review. it goes through committee markup and vote. Passed with majority vote in both House and Senate."));
      assert.equal(asYui(await replay("quoteWord"), q),
        film("A water droplet acts as a lens, bending sunlight. Refraction occurred due to change in speed of light inside water. The separated colors spread out, forming an arc shape."));
      assert.equal(asYui(await replay("wholeQuote"), "how does a bill become law?"),
        film("President signs the bill after Senate approval. Congress votes in favor with required majority. Proposed bill passes both houses."));
      assert.equal(asYui(await replay("curlyQuote"), "explain compound interest like I'm five"),
        film("Imagine your piggy bank is magic. Every year, the money makes more money!"));
      assert.equal(asYui(await replay("bracketMotion"), "how does a bill become law?"),
        film("A President signs a bill into law after Senate and House votes. The president vetoes the bill which then goes to override vote. If both houses approve, it becomes law."));
      assert.equal(asYui(await replay("tickMotion"), q),
        film("Light is refracted through water droplets in the air. It's reflected back, forming a spectrum. Water droplets act like tiny prisms. They filter sunlight into its color components."));
      assert.equal(asYui(await replay("bracketMotion"), "log my run"), asYui(await replay("bracketMotion"))); // no explain question, no repair
      // no explain question, no repair: the same reply stays what it was
      for (const name of ["strayQuote", "quotedLines", "bracketLines"]) assert.equal(asYui(await replay(name), "what is on my list?"), asYui(await replay(name)));
      assert.ok(!asYui(await replay("strayQuote"), "log my sleep").includes("```"));
      // a normal text answer (no quote marks, no brackets) is never made a film
      const plain = await replay("plainAnswer");
      assert.equal(asYui(plain, q), plain);
      assert.equal(asYui(plain, "explain compound interest like I'm five"), plain);
    } finally { await f.close(); }
  });
  test("facts above a one-scrap film go into its ask, replayed from llama3.2:3b (INT-29)", async () => {
    const f = await startFake();
    try {
      const c = new ChatClient(f.url);
      const replay = async (name: string) => (await chat(c, `replay ${name}`)).text;
      const q = "how does a rainbow form?";
      assert.equal(asYui(await replay("splitFilm"), q),
        'Here\'s how it works.\n```yui\nmotion "It splits into colors, bounces off the back, and exits. We see the colors as a rainbow slowly spreads."\n```');
      assert.equal(asYui(await replay("splitFilm3"), q),
        'Here\'s how it works.\n```yui\nmotion "Sunlight enters a raindrop and bends. It passes through water droplets in the air at a shallow angle. The colors separate by wavelength, resulting in our visible spectrum. A prism of sunlight is refracted."\n```');
      // the same words above the fence and in the film's ask (gemma4:e4b): one copy, under the plain lead
      const echo = await replay("echoFilm");
      assert.equal(asYui(echo, "how does a bill become law?"), echo.replace(/^[^\n]*\n/, "Here's how it works.\n"));
      assert.equal(asYui(echo, "log my run"), echo);
      // a lead-in above the film is a lead-in, not a fact: untouched; so is any reply to a question that is not an explain
      const lead = await replay("leadFilm");
      assert.equal(asYui(lead, q), lead);
      assert.equal(asYui(await replay("splitFilm"), "log my run"), asYui(await replay("splitFilm")));
      // a film with 2 to 4 sentences of its own is never touched
      const own = `It bends.\n\`\`\`yui\nmotion "${ask}"\n\`\`\``;
      assert.equal(asYui(own, q), own);
    } finally { await f.close(); }
  });
  test("the film repair skips what is not a dropped ask (INT-29)", () => {
    const q = "why is the sky blue?";
    const one = '"Air scatters blue light."'; // one sentence: not 2 to 4
    assert.equal(asYui(one, q), one);
    const five = ["One is here.", "Two is here.", "Three is here.", "Four is here.", "Five is here."].join(" ") + '"';
    assert.equal(asYui(five, q), five);
    const long = `${"word ".repeat(40).trim()}. ${"word ".repeat(45).trim()}."`; // 85 words
    assert.equal(asYui(long, q), long);
    const fenced = 'Why.\n```yui\ncard "Sky" body="Blue"\n```';
    assert.equal(asYui(fenced, q), fenced);
    assert.equal(asYui('"Blue wins." A reply with a quote. And a closed pair "here".', q), '"Blue wins." A reply with a quote. And a closed pair "here".'); // quotes paired: not a stray
    // a card's lines under an explain question are not a film either
    assert.equal(asYui('card "Sky" body="Blue"\ntimer 5m Look up', q), '```yui\ncard "Sky" body="Blue"\ntimer 5m Look up\n```');
  });
  test("an unknown preset with a quoted ask is not guessed into a motion (INT-29)", async () => {
    const f = await startFake();
    try {
      const c = new ChatClient(f.url);
      const sign = (await chat(c, "replay signLine")).text;
      assert.equal(asYui(sign, "how does a bill become law?"), sign);
      assert.ok(!asYui(sign, "how does a bill become law?").includes("motion"));
    } finally { await f.close(); }
  });
  test("an attribute on the line under its component joins it, replayed from llama3.2:3b (INT-29)", async () => {
    const f = await startFake();
    try {
      const c = new ChatClient(f.url);
      const orphan = (await chat(c, "replay orphanBody")).text;
      assert.equal(asYui(orphan), '```yui\ncard "Grow Money" body="Money + more Money = Even More Money!"\n```');
      assert.equal(asYui('```yui\ncard "Plan"\n  body="Hi"\n  cta="Go"\nstat 5 Count\n```'), '```yui\ncard "Plan" body="Hi" cta="Go"\nstat 5 Count\n```');
      const same = '```yui\ncard "Plan" body="Hi"\nstat 5 Count\n```';
      assert.equal(asYui(same), same);
      const prose = 'Hi.\nbody="not in a fence"'; // outside a fence nothing joins
      assert.equal(asYui(prose), prose);
    } finally { await f.close(); }
  });
  test("options on the line under a choice are joined (INT-28)", () => {
    assert.equal(asYui('```yui\nchoose "Drink"\n  Tea|Coffee\n```'), '```yui\nchoose "Drink" Tea|Coffee\n```');
    assert.equal(asYui('```yui\npick@gear "Gear"\n Dumbbells|Bands \n```'), '```yui\npick@gear "Gear" Dumbbells|Bands\n```');
    const same = '```yui\nchoose "Drink" Tea|Coffee\nlist Today "Squat"\n```';
    assert.equal(asYui(same), same);
    assert.equal(asYui('```yui\nchoose "Drink" \nTea|Coffee \n```'), '```yui\nchoose "Drink" Tea|Coffee\n```');
    const apart = '```yui\nchoose "Drink"\nlist Today "Squat"\n```'; // a Yui Line under it is its own line
    assert.equal(asYui(apart), apart);
  });
  test("motion prose and code are left alone (INT-28)", () => {
    for (const t of ["motion blur is nice", "Motion sickness is caused by a mismatch of what you see and feel", "```js\nmotion x y z a b c\n```"]) {
      assert.equal(asYui(t), t);
    }
  });
  test("the short guide teaches the film line (INT-28)", () => {
    assert.match(SMALL_GUIDE, /motion "/);
    assert.match(SMALL_GUIDE, /ONE short line, then ONE motion line/);
    assert.ok(SMALL_GUIDE.includes(`motion "${ask}"`)); // the example is the ask the repair tests use
  });
  test("prose that starts with a head word is not fenced", () => {
    for (const t of ["list of things I like", "Show me what you have", "timer is a good idea", "pick one and tell me", "next week we ask again", "I will choose tea 2 times"]) {
      assert.equal(asYui(t), t);
    }
  });
  const big = "g".repeat(9000); // about 2,570 tokens, like the live guide
  test("a small window gets the short guide, a roomy one the full guide", () => {
    const small = buildMessages([], [user("hi")], { guide: big }).messages[0].content as string;
    assert.equal(small, SMALL_GUIDE);
    assert.ok(tokens(SMALL_GUIDE) < 900, `${tokens(SMALL_GUIDE)} tokens`);
    const roomy = buildMessages([], [user("hi")], { guide: big, context: 16384 }).messages[0].content as string;
    assert.equal(roomy, big);
    const tiny = buildMessages([], [user("hi")], { guide: "short guide" }).messages[0].content;
    assert.equal(tiny, "short guide");
  });
  test("the live guide (~10k tokens) gets the short one on 8k and 16k windows and keeps the thread (INT-26)", () => {
    const live = "g".repeat(35700);
    const hist = [user("hello"), agent("You said: hello"), user("screen"), agent("Pick one:\n```yui\nchoose \"Pick one\" Tea|Coffee\n```")];
    for (const context of [8192, 16384]) {
      const r = buildMessages(hist, [user("[yui] n1 choose choice=Tea")], { guide: live, context });
      assert.equal(r.messages[0].content, SMALL_GUIDE);
      assert.equal(r.dropped, 0);
      assert.deepEqual(r.messages.slice(1).map((m) => m.role), ["user", "assistant", "user", "assistant", "user"]);
    }
    assert.equal(buildMessages([], [user("hi")], { guide: live, context: 65536 }).messages[0].content, live);
  });
  test("an oversized old thread loses its oldest turns, never all of them (INT-26)", () => {
    const hist = Array.from({ length: 40 }, (_, i) => (i % 2 ? agent : user)(`turn ${i} ` + "w".repeat(1200)));
    const r = buildMessages(hist, [user("now")], { guide: "g".repeat(35700), context: 8192, reserve: 1024 });
    assert.ok(r.dropped > 0 && r.dropped < 40, `dropped ${r.dropped}`);
    assert.equal(r.over, false);
    assert.match(String(r.messages[r.messages.length - 2].content), /^turn 39 /);
  });
  test("the short guide leaves room for the thread on the default window", () => {
    const r = buildMessages([user("a".repeat(700)), agent("b".repeat(700))], [user("now")], { guide: big });
    assert.equal(r.over, false);
    assert.equal(r.dropped, 0);
  });
});
