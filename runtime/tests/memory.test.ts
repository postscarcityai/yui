// Memory (YUI-140) end to end: what an agent writes, the next turn reads;
// forgetting; notes that stay each agent's own; one about-you card per person;
// connected agents never read it; a Controls edit changes the very next turn.
import { test } from "node:test";
import assert from "node:assert/strict";
import { answerControl } from "../src/controls.ts";
import { applyMemory, notesOf } from "../src/memory.ts";
import { starters } from "../src/profiles.ts";
import { SupabaseStore } from "../src/supabase.ts";
import { runAgent } from "../src/turn.ts";
import { fakeModel, freshYui, provider, system, USER } from "./helpers.ts";

async function ask(store: any, agentId: string, req: Record<string, unknown>) {
  const id = store.say(agentId, "controls", "control");
  store.data.rows.find((r: any) => r.id === id).meta = { v: 1, req: "c", ...req };
  await answerControl(store, id);
  return store.data.rows.filter((r: any) => r.kind === "control" && r.sender === "agent").pop().meta;
}

/** One turn for `agentId` with a model that answers `reply`; returns the "What you remember" part of the prompt it saw. */
async function turn(store: any, agentId: string, say: string, reply = "ok") {
  const m = fakeModel(() => reply);
  store.say(agentId, say);
  await runAgent(store, agentId, { provider, fetch: m.fetch });
  const s = system(m.calls[0]);
  const at = s.indexOf("## What you remember");
  assert.ok(at >= 0, "every native turn carries its memory");
  return s.slice(at).split(/\n## /)[0];
}

test("write, then read: the next turn knows what the last one learned", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const first = await turn(store, yui.id, "I'm Sam", "Hi Sam!\n```remember\nme: name = Sam\nnote: says hi a lot\n```");
  assert.match(first, /About this person: nothing yet/);
  assert.match(first, /Your own notes: none yet/);
  const next = await turn(store, yui.id, "what's my name?");
  assert.match(next, /- name: Sam/);
  assert.match(next, /\[n1\] says hi a lot/);
  assert.equal(store.data.rows.filter((r) => r.sender === "agent").pop()!.body, "ok", "the remember block never shows");
});

test("forget: the agent drops a note and a fact, and the next turn has neither", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  await turn(store, yui.id, "facts", "Noted.\n```remember\nme: city = Lisbon\nnote: first note\nnote: second note\n```");
  await turn(store, yui.id, "forget Lisbon and the first thing", "Done.\n```remember\nforget me city\nforget n1\n```");
  const next = await turn(store, yui.id, "hi");
  assert.doesNotMatch(next, /Lisbon|first note/);
  assert.match(next, /\[n1\] second note/, "numbers close up");
});

test("notes written in one turn keep their order, whatever the ids", () => {
  const ids = ["z", "y", "x"];
  const c = applyMemory([], "a1", [{ op: "note", body: "one" }, { op: "note", body: "two" }, { op: "note", body: "three" }],
                        "2026-09-27T12:00:00.000Z", () => ids.shift()!);
  assert.deepEqual(notesOf(c.put, "a1").map((n) => n.body), ["one", "two", "three"]);
});

test("isolation: each agent's notes are its own, the about-you card is shared", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const basil = await byHandle("basil");
  await turn(store, yui.id, "hi", "Hi.\n```remember\nme: name = Sam\nnote: Yui's note\n```");
  await turn(store, basil.id, "lunch", "Sure.\n```remember\nnote: Basil's note\n```");
  // Basil forgetting his n1 never touches Yui's n1.
  await turn(store, basil.id, "forget that", "Gone.\n```remember\nforget n1\n```");
  const y = await turn(store, yui.id, "again");
  assert.match(y, /\[n1\] Yui's note/);
  assert.doesNotMatch(y, /Basil's note/);
  const b = await turn(store, basil.id, "again");
  assert.match(b, /- name: Sam/, "the card is shared");
  assert.doesNotMatch(b, /Yui's note/);
  // In Controls, Basil lists the card and only his own notes, and can't reach Yui's note by id.
  const yuiNote = store.data.memory.find((m) => m.body === "Yui's note")!;
  const list = (await ask(store, basil.id, { op: "list", section: "memory" })).items;
  assert.deepEqual(list.map((i: any) => i.title), ["name: Sam"]);
  assert.equal((await ask(store, basil.id, { op: "get", section: "memory", id: yuiNote.id })).error, "not_found");
});

test("isolation: another person's Yui never sees yours", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const theirs = await store.createAgent("u2", starters().find((p) => p.handle === "yui")!);
  await turn(store, yui.id, "hi", "Hi.\n```remember\nme: name = Sam\nnote: mine\n```");
  const other = await turn(store, theirs.id, "hi");
  assert.doesNotMatch(other, /Sam|mine/);
  assert.equal((await ask(store, theirs.id, { op: "list", section: "memory" })).items.length, 0);
});

test("a Controls edit changes the very next turn, for every agent", async () => {
  const { store, byHandle } = await freshYui();
  const basil = await byHandle("basil");
  const gouda = await byHandle("gouda");
  await turn(store, basil.id, "hi", "Hi.\n```remember\nme: allergies = peanuts\nnote: likes oats\n```");
  const list = (await ask(store, basil.id, { op: "list", section: "memory" })).items;
  const fact = list.find((i: any) => i.group === "you");
  const note = list.find((i: any) => i.group === "remembers");
  const got = await ask(store, basil.id, { op: "get", section: "memory", id: fact.id });
  assert.equal((await ask(store, basil.id, { op: "put", section: "memory", id: fact.id, rev: got.rev, value: { text: "shellfish" } })).ok, true);
  const n = await ask(store, basil.id, { op: "get", section: "memory", id: note.id });
  assert.equal((await ask(store, basil.id, { op: "put", section: "memory", id: note.id, rev: n.rev, value: { text: "likes rye" } })).ok, true);
  const b = await turn(store, basil.id, "breakfast?");
  assert.match(b, /allergies: shellfish/);
  assert.match(b, /\[n1\] likes rye/);
  assert.doesNotMatch(b, /peanuts|oats/);
  assert.match(await turn(store, gouda.id, "hi"), /allergies: shellfish/, "the card edit reaches every agent");
  // Forget in Controls: gone from the next turn.
  const n2 = await ask(store, basil.id, { op: "get", section: "memory", id: note.id });
  assert.equal((await ask(store, basil.id, { op: "delete", section: "memory", id: note.id, rev: n2.rev, confirmed: true })).deleted, true);
  assert.match(await turn(store, basil.id, "again"), /Your own notes: none yet/);
});

test("connected agents never read memory: no hosted row, no memory request, no model call", async () => {
  const CONNECTED = "33333333-3333-3333-3333-333333333333";
  const paths: string[] = [];
  const db = (async (url: string, init: any) => {
    const path = url.replace("https://db.test", "");
    paths.push(`${init.method} ${path}`);
    if (path.startsWith("/rest/v1/yui_agents")) return new Response("[]", { status: 200 }); // kind=eq.hosted finds nothing
    if (path.startsWith("/rest/v1/rpc/yui_native_lock")) return new Response("true", { status: 200 });
    return new Response("[]", { status: 200 });
  }) as unknown as typeof fetch;
  const store = new SupabaseStore("https://db.test", "service-key", db);
  const m = fakeModel(() => "should not run");
  await runAgent(store, CONNECTED, { provider, fetch: m.fetch });
  assert.equal(m.calls.length, 0);
  assert.ok(paths.some((p) => /yui_agents\?.*kind=eq\.hosted/.test(p)), "the agent is looked up as hosted only");
  assert.equal(paths.some((p) => p.includes("yui_native_memory")), false);
});

test("memory is per person, not per phone: a fresh store on the same data knows everything", async () => {
  const { store, byHandle } = await freshYui();
  const arnold = await byHandle("arnold");
  await turn(store, arnold.id, "hi", "Hi.\n```remember\nme: name = Sam\nnote: squats Mondays\n```");
  const { LocalStore } = await import("../src/store.ts");
  const signedInAgain = new LocalStore(JSON.parse(JSON.stringify(store.data)), { guide: "GUIDE" });
  assert.equal((await signedInAgain.agents(USER)).length, (await store.agents(USER)).length);
  const p = await turn(signedInAgain, arnold.id, "what day is squats?");
  assert.match(p, /- name: Sam/);
  assert.match(p, /squats Mondays/);
});
