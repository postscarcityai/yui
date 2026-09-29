#!/usr/bin/env node
// YUI-169: SupabaseStore against local Postgres 16 + PostgREST (the YUI-143 kit, setup.sh first).
// Two chats with one agent: history reads one chat, a Stop in one chat does not stop the other,
// a reply with meta.turn lands in the chat it answers, memory is shared, and the push payload names the chat.
//   node chats_native_e2e.ts <worktree>
import { execFileSync } from "node:child_process";
import { createHmac } from "node:crypto";
import { join } from "node:path";
import assert from "node:assert/strict";

const root = process.argv[2];
const { SupabaseStore } = await import(join(root, "runtime/src/supabase.ts"));
const { starters } = await import(join(root, "runtime/src/profiles.ts"));
const { chatOf } = await import(join(root, "runtime/src/handoff.ts"));
const { apnsPayload } = await import(join(root, "supabase/functions/yui-push/payload.ts"));
const UID = "00000000-0000-4000-8000-000000000143";
const b64 = (o: unknown) => Buffer.from(JSON.stringify(o)).toString("base64url");
const head = b64({ alg: "HS256", typ: "JWT" }), claims = b64({ role: "service_role", iss: "local143" });
const SERVICE = `${head}.${claims}.${createHmac("sha256", "yui143-local-jwt-secret-at-least-32-chars").update(`${head}.${claims}`).digest("base64url")}`;
const local = ((url: string, init: any) => fetch(url.replace("http://local.supabase/rest/v1/", "http://localhost:3143/"), init)) as typeof fetch;
const store = new SupabaseStore("http://local.supabase", SERVICE, local);
const sql = (q: string) => execFileSync("docker", ["exec", "yui143-pg", "psql", "-U", "postgres", "-tAq", "-c", q], { encoding: "utf8" }).trim();

await (await local("http://local.supabase/rest/v1/rpc/yui_native_provision", { method: "POST", headers: { authorization: `Bearer ${SERVICE}`, "content-type": "application/json" },
  body: JSON.stringify({ uid: UID, profs: starters().slice(0, 1) }) })).text();
const agent = (await store.agents(UID))[0];
const first = sql(`select id from yui_chats where agent_id='${agent.id}' order by created_at limit 1`);
const second = sql(`insert into yui_chats (user_id, agent_id) values ('${UID}','${agent.id}') returning id`).split("\n")[0];
const say = (chat: string, body: string) => sql(`insert into yui_messages (user_id, agent_id, chat_id, sender, kind, body) values ('${UID}','${agent.id}','${chat}','user','text',$$${body}$$) returning id`).split("\n")[0];
const pend = async () => await store.pending(agent.id);

const a1 = say(first, "chat one: hello");
const p1 = (await pend()).find((r: any) => r.id === a1);
assert.equal(chatOf(p1), first, "pending rows carry their chat");
assert.equal(p1.meta.chat.id, first);
await store.reply(agent, "chat one answer", { turn: [a1] });
await store.markHandled([a1]);
const b1 = say(second, "chat two: hi");
const pb = (await pend()).find((r: any) => r.id === b1);
assert.equal(chatOf(pb), second);
assert.equal(pb.meta.chat.new, true, "the second chat's first row is new");
assert.equal(pb.meta.chat.first, false);
const later = new Date(Date.now() + 60000).toISOString();
const h2 = await store.history(agent.id, later, 60, null, second);
assert.deepEqual(h2.map((r: any) => r.body), ["chat two: hi"], "history reads only the chat of the turn");
const h1 = await store.history(agent.id, later, 60, null, first);
assert.deepEqual(h1.map((r: any) => r.body).slice(-2), ["chat one: hello", "chat one answer"], "the reply landed in chat one through meta.turn");
const hAll = await store.history(agent.id, later, 60, null, null);
assert.equal(hAll.length, h1.length + 1, "no chat named: the whole thread, as before");

// Stop from chat one
const since = new Date(Date.now() - 5000).toISOString();
sql(`insert into yui_messages (user_id, agent_id, chat_id, sender, kind, body, meta) values ('${UID}','${agent.id}','${first}','user','control','stop','{"op":"stop"}')`);
assert.equal(await store.stoppedSince(agent.id, UID, since, first), true);
assert.equal(await store.stoppedSince(agent.id, UID, since, second), false, "a Stop in chat one does not stop chat two");
assert.equal(await store.stoppedSince(agent.id, UID, since, null), true);
// A Stop from an old app (no chat) stops everyone.
sql(`insert into yui_messages (user_id, agent_id, sender, kind, body, meta) values ('${UID}','${agent.id}','user','control','stop','{"op":"stop"}')`);
const stopRow = sql(`select coalesce(chat_id::text,'null') from yui_messages where kind='control' and sender='user' order by created_at desc limit 1`);
console.log("second Stop row chat_id:", stopRow);
const reply = (await store.history(agent.id, later, 60, null, first)).at(-1);
const [row] = await (await local(`http://local.supabase/rest/v1/yui_messages?select=id,chat_id,body,sender,user_id&id=eq.${reply.id}`, { headers: { authorization: `Bearer ${SERVICE}` } })).json();
assert.equal(row.chat_id, first);
console.log("push payload:", JSON.stringify(apnsPayload({ id: agent.id, name: "Yui" }, { id: row.id, body: row.body, chat_id: row.chat_id })));
assert.equal(apnsPayload({ id: agent.id, name: "Yui" }, { id: row.id, body: "x", chat_id: row.chat_id }).chat, first);
assert.equal("chat" in apnsPayload({ id: agent.id, name: "Yui" }, { id: row.id, body: "x" }), false);
console.log("PASS chats native e2e");
