// Test helpers: a scripted model behind a fake fetch, and a fresh local Yui.
import { LocalStore } from "../src/store.ts";
import { starters } from "../src/profiles.ts";
import type { Provider } from "../src/turn.ts";

export const USER = "u1";

export interface Call { model: string; messages: any[]; body: any }

/** answer(call) returns the model's text, or a number for an HTTP error status. */
export function fakeModel(answer: (c: Call) => string | number) {
  const calls: Call[] = [];
  const fetchImpl = (async (_url: string, init: any) => {
    const body = JSON.parse(init.body);
    const call = { model: body.model, messages: body.messages, body };
    calls.push(call);
    const a = answer(call);
    if (typeof a === "number") return new Response(JSON.stringify({ error: { message: `status ${a}` } }), { status: a });
    return new Response(JSON.stringify({ choices: [{ message: { role: "assistant", content: a }, finish_reason: "stop" }],
                                         usage: { prompt_tokens: 10, completion_tokens: 5 } }),
                        { status: 200, headers: { "content-type": "application/json" } });
  }) as unknown as typeof fetch;
  return { calls, fetch: fetchImpl };
}

export const provider: Provider = { url: "http://model.test/v1", key: "k", extra: { provider: { data_collection: "deny" } } };

export async function freshYui(opts: { freeTurns?: number } = {}) {
  const store = new LocalStore({}, { guide: "GUIDE", freeTurns: opts.freeTurns ?? 100 });
  for (const p of starters()) await store.createAgent(USER, p);
  const byHandle = async (h: string) => (await store.agents(USER)).find((a) => a.profile.handle === h)!;
  return { store, byHandle };
}

export const system = (c: Call) => String(c.messages[0].content);
export const lastUser = (c: Call) => c.messages[c.messages.length - 1];
