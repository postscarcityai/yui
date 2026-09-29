// A key per agent (YUI-139 step 2f): one agent runs on Claude, the rest stay on Yui's route (or the person's default key).
import { test } from "node:test";
import assert from "node:assert/strict";
import { PROVIDERS } from "../src/models.ts";
import { runAgent } from "../src/turn.ts";
import { answerControl } from "../src/controls.ts";
import { freshYui, provider, USER } from "./helpers.ts";

const claude = PROVIDERS.find((p) => p.id === "anthropic")!;
const gpt = PROVIDERS.find((p) => p.id === "openai")!;

function spy() {
  const calls: { url: string; auth: string }[] = [];
  const fetchImpl = (async (url: string, init: any) => {
    calls.push({ url: String(url), auth: String(init.headers?.authorization ?? init.headers?.Authorization ?? "") });
    return new Response(JSON.stringify({ choices: [{ message: { role: "assistant", content: "Sure." }, finish_reason: "stop" }], usage: { prompt_tokens: 1, completion_tokens: 1 } }),
                        { status: 200, headers: { "content-type": "application/json" } });
  }) as unknown as typeof fetch;
  return { calls, fetch: fetchImpl };
}

test("ownKey: unset follows the default, yui takes none, a provider takes that provider's key", async () => {
  const { store } = await freshYui({ freeTurns: 1 });
  store.data.keys = { [USER]: { provider: "openai", baseUrl: gpt.url, model: null, key: "sk-gpt" } };
  store.data.moreKeys = { [`${USER}:anthropic`]: { provider: "anthropic", baseUrl: claude.url, model: null, key: "sk-claude" } };
  assert.equal((await store.ownKey(USER))?.key, "sk-gpt");
  assert.equal(await store.ownKey(USER, "yui"), null);
  assert.equal((await store.ownKey(USER, "anthropic"))?.key, "sk-claude");
  assert.equal((await store.ownKey(USER, "openai"))?.key, "sk-gpt");
  assert.equal(await store.ownKey(USER, "gemini"), null, "a pick with no key falls to Yui's");
});

test("one agent on Claude, the others on Yui: only that agent's turns reach Anthropic", async () => {
  const { store, byHandle } = await freshYui({ freeTurns: 5 });
  // No default key; Claude's is held for the one agent that picked it.
  store.data.moreKeys = { [`${USER}:anthropic`]: { provider: "anthropic", baseUrl: claude.url, model: null, key: "sk-claude" } };
  const arnold = await byHandle("arnold");
  const basil = await byHandle("basil");
  await store.updateAgent(arnold.id, { ...arnold.profile, keyUse: "anthropic" });
  const m = spy();
  store.say(arnold.id, "how do I warm up?");
  await runAgent(store, (await store.agent(arnold.id))!.id, { provider, fetch: m.fetch });
  store.say(basil.id, "what is for dinner?");
  await runAgent(store, basil.id, { provider, fetch: m.fetch });
  assert.ok(m.calls[0].url.startsWith(claude.url), "Arnold ran on Claude");
  assert.equal(m.calls[0].auth, "Bearer sk-claude");
  assert.doesNotMatch(m.calls[m.calls.length - 1].url, /anthropic/, "Basil stayed on Yui");
  assert.equal((await store.takeTurn(USER)).ok, true);
});

test("an agent set to yui ignores the person's default key", async () => {
  const { store, byHandle } = await freshYui({ freeTurns: 5 });
  store.data.keys = { [USER]: { provider: "openai", baseUrl: gpt.url, model: null, key: "sk-gpt" } };
  const basil = await byHandle("basil");
  await store.updateAgent(basil.id, { ...basil.profile, keyUse: "yui" });
  const m = spy();
  store.say(basil.id, "hi");
  await runAgent(store, basil.id, { provider, fetch: m.fetch });
  assert.doesNotMatch(m.calls[0].url, /openai/);
});

test("Controls > Model names the key an agent runs on", async () => {
  const { store, byHandle } = await freshYui({ freeTurns: 5 });
  store.data.moreKeys = { [`${USER}:anthropic`]: { provider: "anthropic", baseUrl: claude.url, model: null, key: "sk-claude" } };
  const arnold = await byHandle("arnold");
  await store.updateAgent(arnold.id, { ...arnold.profile, keyUse: "anthropic" });
  const id = store.data.rows.length + "x";
  store.data.rows.push({ id, agent_id: arnold.id, sender: "user", kind: "control", body: "", meta: { v: 1, op: "get", section: "model", id: "model" }, created_at: new Date().toISOString() } as any);
  assert.equal(await answerControl(store, id), true);
  const ans = store.data.rows.find((r) => r.kind === "control" && r.sender !== "user");
  const text = JSON.stringify(ans?.meta);
  assert.match(text, /your own Claude key/);
  assert.match(text, /"key":"anthropic"/);
  assert.doesNotMatch(text, /sk-claude/);
});
