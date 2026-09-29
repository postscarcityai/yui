// YUI-169: several chats per agent. A turn reads only the chat it answers; memory stays the agent's;
// a row with no chat (an old app) still sees the whole thread; a fresh chat opens with `[yui] chat new`;
// a Stop in one chat leaves the other chats' work alone.
import { test } from "node:test";
import assert from "node:assert/strict";
import { runAgent } from "../src/turn.ts";
import { chatOf, oneThread } from "../src/handoff.ts";
import { stopTurns } from "../src/stop.ts";
import type { LocalStore } from "../src/store.ts";
import { fakeModel, freshYui, provider, USER } from "./helpers.ts";

const A = "aaaaaaaa-0000-4000-8000-000000000001";
const B = "bbbbbbbb-0000-4000-8000-000000000002";

/** A person's row as the database stamps it: chat_id and meta.chat {id, first, new}. No chat: an old row. */
function sayIn(store: LocalStore, agentId: string, body: string, chat: string | null, flags: { first?: boolean; new?: boolean } = {}) {
  const id = store.say(agentId, body);
  const row = store.data.rows.find((r) => r.id === id)!;
  if (chat) {
    row.chat_id = chat;
    row.meta = { chat: { id: chat, first: flags.first ?? false, new: flags.new ?? false } };
  }
  return id;
}

/** One turn on the newest waiting row(s); the text of every message the model saw. */
async function ask(store: LocalStore, agentId: string, reply = "ok") {
  const m = fakeModel(() => reply);
  await runAgent(store, agentId, { provider, fetch: m.fetch });
  const call = m.calls[0];
  return { call, seen: call.messages.map((x: any) => (typeof x.content === "string" ? x.content : JSON.stringify(x.content))).join("\n") };
}

test("history is read from the chat of the turn only", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const a1 = sayIn(store, yui.id, "chat A: protein on rest days", A, { first: true });
  await ask(store, yui.id, "chat A answer about protein");
  sayIn(store, yui.id, "chat B: what should I pack for a trip", B, { new: true });
  await ask(store, yui.id, "chat B answer about packing");
  sayIn(store, yui.id, "chat B: and shoes?", B);
  const { seen } = await ask(store, yui.id);
  assert.ok(seen.includes("chat B: what should I pack"), "its own chat is in the history");
  assert.ok(seen.includes("chat B answer about packing"), "the agent's replies in its chat are in the history");
  assert.ok(!seen.includes("protein on rest days"), "another chat's message is not");
  assert.ok(!seen.includes("chat A answer about protein"), "another chat's reply is not");
  const reply = store.data.rows.filter((r) => r.sender === "agent" && r.kind === "text").pop()!;
  assert.equal(chatOf(reply), B, "the reply lands in the chat it answered");
  assert.ok(store.data.rows.find((r) => r.id === a1));
});

test("memory is the agent's: a note kept in one chat is in the prompt of another", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  sayIn(store, yui.id, "remember I like green tea", A, { first: true });
  await ask(store, yui.id, "Noted.\n```remember\nnote: likes green tea\n```");
  assert.equal(store.data.memory.length, 1);
  sayIn(store, yui.id, "what do you know about me", B, { new: true });
  const { call } = await ask(store, yui.id);
  assert.ok(String(call.messages[0].content).includes("likes green tea"), "the new chat's system prompt carries the memory");
  assert.ok(!call.messages.slice(1).some((m: any) => String(m.content).includes("green tea")), "but not the other chat's messages");
});

test("a row with no chat (an old app) still sees the agent's whole thread", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  sayIn(store, yui.id, "old thread one", A, { first: true });
  await ask(store, yui.id, "old answer one");
  sayIn(store, yui.id, "old thread two", B);
  await ask(store, yui.id, "old answer two");
  sayIn(store, yui.id, "from an old app", null);
  const { seen } = await ask(store, yui.id);
  for (const t of ["old thread one", "old answer one", "old thread two", "old answer two"]) assert.ok(seen.includes(t), `sees ${t}`);
});

test("`[yui] chat new` leads the turn only when the chat is new and not the first", async () => {
  const cases: [string, { first?: boolean; new?: boolean } | null, boolean][] = [
    ["a new second chat", { new: true, first: false }, true],
    ["the first chat, new", { new: true, first: true }, false],
    ["a chat with history", { new: false, first: false }, false],
    ["an old row with no chat", null, false],
  ];
  for (const [name, flags, expected] of cases) {
    const { store, byHandle } = await freshYui();
    const yui = await byHandle("yui");
    sayIn(store, yui.id, "hello there", flags ? B : null, flags ?? {});
    const { call } = await ask(store, yui.id);
    const user = call.messages.filter((m: any) => m.role === "user");
    const first = String(user[0].content);
    assert.equal(first.startsWith("[yui] chat new\n"), expected, name);
    assert.equal(call.messages.filter((m: any) => String(m.content).includes("[yui] chat new")).length, expected ? 1 : 0, `${name}: one line, no more`);
    if (expected) assert.ok(first.includes("hello there"), "the line rides on the person's own text");
  }
});

test("one turn answers one chat: rows of two chats are answered apart", async () => {
  const rows = [
    { id: "1", sender: "user", kind: "text", body: "a", created_at: "t", chat_id: A },
    { id: "2", sender: "user", kind: "text", body: "b", created_at: "t", chat_id: B },
    { id: "3", sender: "user", kind: "text", body: "c", created_at: "t", meta: { chat: { id: A } } },
  ];
  assert.deepEqual(oneThread(rows).map((r) => r.id), ["1", "3"]);
});

test("Stop in one chat leaves the other chat's work alone", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const since = new Date(Date.now() - 1000).toISOString();
  const ra = sayIn(store, yui.id, "in chat A", A, { first: true });
  const rb = sayIn(store, yui.id, "in chat B", B);
  const stopId = store.id("row");
  store.data.rows.push({ id: stopId, agent_id: yui.id, sender: "user", kind: "control", body: "stop", chat_id: A,
                         meta: { op: "stop", chat: { id: A, first: false, new: false } }, created_at: new Date().toISOString() } as any);
  assert.equal(await store.stoppedSince(yui.id, USER, since, A), true, "chat A hears its Stop");
  assert.equal(await store.stoppedSince(yui.id, USER, since, B), false, "chat B does not");
  assert.equal(await store.stoppedSince(yui.id, USER, since), true, "no chat named: any Stop counts, as before");
  const stop = store.data.rows.find((r) => r.id === stopId)! as any;
  const r = await stopTurns(store, yui, { ...stop, user_id: USER });
  assert.equal(r.rows, 1);
  assert.ok(store.data.rows.find((x) => x.id === ra)!.handled_at, "chat A's waiting row is handled");
  assert.ok(!store.data.rows.find((x) => x.id === rb)!.handled_at, "chat B's waiting row is still waiting");
});

test("a Stop with no chat (an old app) stops every chat's waiting rows", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const ra = sayIn(store, yui.id, "in chat A", A);
  const rb = sayIn(store, yui.id, "in chat B", B);
  const stopId = store.id("row");
  store.data.rows.push({ id: stopId, agent_id: yui.id, sender: "user", kind: "control", body: "stop", meta: { op: "stop" },
                         created_at: new Date().toISOString() } as any);
  const r = await stopTurns(store, yui, { ...(store.data.rows.find((x) => x.id === stopId)! as any), user_id: USER });
  assert.equal(r.rows, 2);
  assert.ok(store.data.rows.find((x) => x.id === ra)!.handled_at && store.data.rows.find((x) => x.id === rb)!.handled_at);
});
