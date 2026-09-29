// A person's own key at every stop (YUI-139 step 2): each provider runs a text turn and a photo turn on their
// own key and model, never on Yui's OpenRouter, and the key stays out of every row.
import { test } from "node:test";
import assert from "node:assert/strict";
import { PROVIDERS, keyModel, providerLabel } from "../src/models.ts";
import { runAgent } from "../src/turn.ts";
import { freshYui, provider, USER } from "./helpers.ts";

const KEY = "sk-stub-own-key-9999";

/** A model behind a fetch that records each url, model and bearer. */
function spy(text = "Sure.") {
  const calls: { url: string; model: string; auth: string }[] = [];
  const fetchImpl = (async (url: string, init: any) => {
    calls.push({ url: String(url), model: JSON.parse(init.body).model, auth: String(init.headers?.authorization ?? init.headers?.Authorization ?? "") });
    return new Response(JSON.stringify({ choices: [{ message: { role: "assistant", content: text }, finish_reason: "stop" }], usage: { prompt_tokens: 1, completion_tokens: 1 } }),
                        { status: 200, headers: { "content-type": "application/json" } });
  }) as unknown as typeof fetch;
  return { calls, fetch: fetchImpl };
}

test("every preset key needs no model id and has a seeing default", () => {
  for (const id of ["anthropic", "openai", "gemini", "xai"]) {
    const p = PROVIDERS.find((x) => x.id === id)!;
    assert.equal(p.needsModel, false, id);
    assert.ok(p.model && p.vision, `${id} has a text and a seeing default`);
    assert.match(p.url, /^https:\/\//);
    assert.ok(p.keyUrl?.startsWith("https://"), `${id} says where to make a key`);
  }
  assert.match(PROVIDERS.find((p) => p.id === "anthropic")!.plan!, /Claude Pro/);
  assert.match(PROVIDERS.find((p) => p.id === "openai")!.plan!, /ChatGPT Plus/);
});

test("a model they named wins, else the provider's default (the seeing one for a photo)", () => {
  assert.equal(keyModel("xai", "grok-mini", true), "grok-mini");
  assert.equal(keyModel("xai", null, false), PROVIDERS.find((p) => p.id === "xai")!.model);
  assert.equal(keyModel("groq", null, true), null); // no default: the caller's route
  assert.equal(providerLabel("anthropic"), "Claude");
  assert.equal(providerLabel("custom"), "computer");
});

for (const p of PROVIDERS.filter((x) => ["anthropic", "openai", "gemini", "xai"].includes(x.id))) {
  test(`${p.label}: a text turn and a photo turn run on their key, never Yui's OpenRouter`, async () => {
    const { store, byHandle } = await freshYui({ freeTurns: 1 });
    store.data.keys = { [USER]: { provider: p.id, baseUrl: p.url, model: null, key: KEY } };
    const basil = await byHandle("arnold");
    const m = spy();
    store.say(basil.id, "what should I eat before a run?");
    await runAgent(store, basil.id, { provider, fetch: m.fetch });
    store.say(basil.id, "[yui] c1 camera photo=https://img.test/plate.jpg", "event");
    await runAgent(store, basil.id, { provider, fetch: m.fetch });
    assert.ok(m.calls.length >= 2);
    for (const c of m.calls) {
      assert.ok(c.url.startsWith(p.url), `${c.url} is ${p.label}'s`);
      assert.doesNotMatch(c.url, /openrouter|model\.test/);
      assert.equal(c.auth, `Bearer ${KEY}`);
    }
    assert.equal(m.calls[0].model, p.model);
    assert.equal(m.calls[m.calls.length - 1].model, p.vision);
    assert.equal((await store.takeTurn(USER)).ok, true, "own key took no free turn");
    assert.ok(!JSON.stringify(store.data.rows).includes(KEY), "the key is in no row");
  });
}

test("OpenRouter signs in with a tap, and My computer may need no key", () => {
  const or = PROVIDERS.find((p) => p.id === "openrouter")!;
  assert.equal(or.signIn, true);
  const mine = PROVIDERS.find((p) => p.id === "custom")!;
  assert.equal(mine.label, "My computer");
  assert.equal(mine.keyless, true);
  assert.equal(mine.needsModel, true);
  assert.ok(!PROVIDERS.some((p) => p.id !== "openrouter" && p.signIn), "paste stays for the rest");
});
