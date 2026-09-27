// The server store speaks PostgREST and Storage: the requests it makes.
import { test } from "node:test";
import assert from "node:assert/strict";
import { SupabaseStore } from "../src/supabase.ts";

function fakeDb(answer: (method: string, path: string, body: any) => any) {
  const calls: { method: string; path: string; body: any; headers: any }[] = [];
  const f = (async (url: string, init: any) => {
    const path = url.replace("https://db.test", "");
    const body = init.body ? JSON.parse(init.body) : undefined;
    calls.push({ method: init.method, path, body, headers: init.headers });
    const out = answer(init.method, path, body);
    if (out instanceof Response) return out;
    return new Response(out === undefined ? "" : JSON.stringify(out), { status: 200 });
  }) as unknown as typeof fetch;
  return { calls, store: new SupabaseStore("https://db.test/", "service-key", f) };
}

const A = "11111111-1111-1111-1111-111111111111";
const U = "22222222-2222-2222-2222-222222222222";

test("an agent is a hosted registry row plus its profile; the row owns the name", async () => {
  const { store, calls } = fakeDb((_m, p) => p.includes("yui_agents")
    ? [{ id: A, user_id: U, name: "Renamed", handle: "gouda", kind: "hosted" }]
    : [{ profile: { name: "Gouda", handle: "gouda", favorites: ["loop"], soul: "s", first: "f" } }]);
  const a = await store.agent(A);
  assert.equal(a!.profile.name, "Renamed");
  assert.match(calls[0].path, /kind=eq\.hosted/);
  assert.equal(calls[0].headers.authorization, "Bearer service-key");
});

test("memory reads the about-you card and this agent's notes", async () => {
  const { store, calls } = fakeDb(() => [{ id: "m1", user_id: U, agent_id: null, kind: "about", key: "name", body: "Sam", updated_at: "t" }]);
  const m = await store.memory(U, A);
  assert.deepEqual(m, [{ id: "m1", userId: U, agentId: null, kind: "about", key: "name", body: "Sam", updatedAt: "t" }]);
  assert.match(calls[0].path, new RegExp(`or=\\(agent_id\\.is\\.null,agent_id\\.eq\\.${A}\\)`));
});

test("saving memory deletes, then upserts by id", async () => {
  const { store, calls } = fakeDb(() => undefined);
  await store.saveMemory(U, [{ id: "m2", agentId: A, kind: "note", body: "likes lo-fi", updatedAt: "t" }], ["m1"]);
  assert.equal(calls[0].method, "DELETE");
  assert.match(calls[0].path, /user_id=eq\..*id=in\.\(m1\)/);
  assert.equal(calls[1].method, "POST");
  assert.match(calls[1].path, /on_conflict=id/);
  assert.equal(calls[1].headers.prefer, "resolution=merge-duplicates,return=minimal");
  assert.deepEqual(calls[1].body[0], { id: "m2", user_id: U, agent_id: A, kind: "note", key: null, body: "likes lo-fi", updated_at: "t" });
});

test("pending: the person's unhandled text and taps, oldest first", async () => {
  const { store, calls } = fakeDb(() => []);
  await store.pending(A);
  assert.match(calls[0].path, /sender=eq\.user&handled_at=is\.null&kind=in\.\(text,event\)&order=created_at\.asc/);
});

test("handled clears the working row too", async () => {
  const { store, calls } = fakeDb(() => undefined);
  await store.markHandled(["r1", "r2"]);
  assert.match(calls[0].path, /id=in\.\(r1,r2\)/);
  assert.equal(calls[0].body.doing, null);
  assert.ok(calls[0].body.handled_at);
});

test("free turns and the lock come from the database", async () => {
  const { store } = fakeDb((_m, p) => p.includes("take_turn") ? [{ ok: false, left_turns: 0, lim: 100 }] : true);
  assert.deepEqual(await store.takeTurn(U), { ok: false, left: 0, limit: 100 });
  assert.equal(await store.lock(A, 300), true);
});

test("routes fall back to GLM when the table is missing", async () => {
  const { store } = fakeDb(() => new Response("nope", { status: 404 }));
  assert.deepEqual(await store.routes(), { text: "z-ai/glm-5.2", vision: "z-ai/glm-5v-turbo" });
});

test("only the person's own uploads get signed", async () => {
  const { store, calls } = fakeDb(() => ({ signedURL: "/object/sign/yui-media/x?token=t" }));
  assert.equal(await store.signMedia("../../etc/passwd"), null);
  assert.equal(await store.signMedia(`${U}/${A}/agent/x.jpg`), null, "not an agent's own files");
  const url = await store.signMedia(`${U}/${A}/user/abc.jpg`);
  assert.equal(url, "https://db.test/storage/v1/object/sign/yui-media/x?token=t");
  assert.equal(calls.length, 1);
});

test("web lookups: the caps and the person's own Firecrawl key come from the database", async () => {
  const { store, calls } = fakeDb((_m, p) => p.includes("take_search") ? [{ ok: false, used: 50, lim: 50, per_turn: 2, why: "month" }]
    : p.includes("search_key_get") ? "fc-theirs" : undefined);
  assert.deepEqual(await store.takeSearch(U, false), { ok: false, used: 50, limit: 50, perTurn: 2, why: "month" });
  assert.match(calls[0].path, /\/rest\/v1\/rpc\/yui_native_take_search$/);
  assert.deepEqual(calls[0].body, { uid: U, own: false });
  assert.equal(await store.searchKey(U), "fc-theirs");
  assert.deepEqual(calls[1].body, { uid: U });
  const none = fakeDb(() => null);
  assert.equal(await none.store.searchKey(U), null);
});
