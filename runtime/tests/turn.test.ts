// Whole turns on a local store with a scripted model: memory that lasts, the
// crew, Yui making agents, a blank agent making itself, photos, caps, locks.
import { test } from "node:test";
import assert from "node:assert/strict";
import { LocalStore } from "../src/store.ts";
import { runAgent } from "../src/turn.ts";
import { fakeModel, freshYui, lastUser, provider, system, USER } from "./helpers.ts";

test("a turn answers, keeps what it learned out of sight, and marks the rows", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const m = fakeModel(() => "Hi Sam! Peanuts noted.\n```remember\nme: name = Sam\nme: allergies = peanuts\nnote: new here\n```");
  const row = store.say(yui.id, "I'm Sam and I'm allergic to peanuts");
  const r = await runAgent(store, yui.id, { provider, fetch: m.fetch });
  assert.equal(r.turns, 1);
  const reply = store.data.rows.find((x) => x.id === r.replies[0])!;
  assert.equal(reply.body, "Hi Sam! Peanuts noted.");
  assert.deepEqual(reply.meta.turn, [row]);
  assert.equal(reply.meta.native.model, "z-ai/glm-5.2");
  const mine = store.data.rows.find((x) => x.id === row)!;
  assert.ok(mine.delivered_at && mine.handled_at);
  assert.equal(m.calls[0].body.provider.data_collection, "deny");
  assert.match(system(m.calls[0]), /^GUIDE/, "the channel guide comes first");
  assert.match(system(m.calls[0]), /You are Yui/);
  assert.match(system(m.calls[0]), /This person's crew[\s\S]*Gouda \(@gouda\): Musician/);
  // The first answer from provisioning is in the history, as the agent's.
  assert.equal(m.calls[0].messages[1].content, "[yui] opened this thread");
  assert.match(m.calls[0].messages[2].content, /Hi, I'm Yui/, "the model sees its own first answer");
});

test("what one agent learns about you, the others know; its notes stay its own", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const basil = await byHandle("basil");
  const m = fakeModel((c) => /Yui/.test(c.messages[0].content.split("## Who you are")[1] ?? "")
    ? "Got it.\n```remember\nme: allergies = peanuts\nnote: Yui's private note\n```"
    : "Here's a peanut-free lunch.");
  store.say(yui.id, "allergic to peanuts");
  await runAgent(store, yui.id, { provider, fetch: m.fetch });
  store.say(basil.id, "what's for lunch?");
  await runAgent(store, basil.id, { provider, fetch: m.fetch });
  const basilSystem = system(m.calls[1]);
  assert.match(basilSystem, /allergies: peanuts/);
  assert.doesNotMatch(basilSystem, /Yui's private note/);
  assert.match(basilSystem, /careful coach/);
});

test("memory lasts: a new process reads the same file and still knows you", async () => {
  const { store, byHandle } = await freshYui();
  const gouda = await byHandle("gouda");
  const m = fakeModel(() => "Nice.\n```remember\nme: instrument = bass\nnote: likes lo-fi at 80 bpm\n```");
  store.say(gouda.id, "I play bass, I like lo-fi");
  await runAgent(store, gouda.id, { provider, fetch: m.fetch });
  const saved = JSON.parse(JSON.stringify(store.data)); // what the CLI writes to disk
  const again = new LocalStore(saved, { guide: "GUIDE" });
  const m2 = fakeModel(() => "Let's go.");
  again.say(gouda.id, "make me a beat");
  await runAgent(again, gouda.id, { provider, fetch: m2.fetch });
  assert.match(system(m2.calls[0]), /instrument: bass/);
  assert.match(system(m2.calls[0]), /\[n1\] likes lo-fi at 80 bpm/);
  assert.ok(m2.calls[0].messages.some((x: any) => x.role === "assistant" && x.content === "Nice."), "the thread is there too");
});

test("Yui makes agents from the shelf and new ones, forks, renames and removes", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const m = fakeModel(() => [
    "Done: your Spanish tutor is ready, plus a second Gouda.",
    "```agents",
    'make "Spanish tutor" color=mint favorites=ask,deck,page,hologram soul="You are a patient Spanish tutor."',
    "make gouda",
    'fork arnold "Arnold Gentle" soul="You are Arnold, gentler."',
    'rename quill "Professor Q"',
    "remove penny",
    "remove yui",
    "```",
  ].join("\n"));
  store.say(yui.id, "set me up");
  await runAgent(store, yui.id, { provider, fetch: m.fetch });
  const mine = await store.agents(USER);
  const handles = mine.map((a) => a.profile.handle);
  assert.ok(handles.includes("spanish-tutor"));
  assert.ok(handles.includes("gouda-2"), "a second from the shelf gets its own handle");
  assert.ok(handles.includes("arnold-gentle"));
  assert.ok(!handles.includes("penny"));
  assert.ok(handles.includes("yui"), "Yui stays");
  const tutor = mine.find((a) => a.profile.handle === "spanish-tutor")!;
  assert.deepEqual(tutor.profile.favorites, ["ask", "deck", "page"], "screens the app can't draw are dropped");
  assert.equal(tutor.profile.color, "mint");
  assert.ok(store.data.rows.some((r) => r.agent_id === tutor.id && r.meta?.native === "first"), "a new agent opens with its first answer");
  const fork = mine.find((a) => a.profile.handle === "arnold-gentle")!;
  assert.equal(fork.profile.version, 2);
  assert.ok(!fork.profile.maker, "a fork of a maker is not a maker");
  assert.equal(mine.find((a) => a.profile.base === "quill")!.profile.name, "Professor Q");
  const reply = store.data.rows.filter((r) => r.agent_id === yui.id && r.sender === "agent").pop()!;
  assert.match(reply.body, /Yui stays/, "what could not be done is said");
});

test("only Yui makes agents", async () => {
  const { store, byHandle } = await freshYui();
  const arnold = await byHandle("arnold");
  const m = fakeModel(() => "Sure.\n```agents\nmake gouda\n```");
  store.say(arnold.id, "make me a musician");
  await runAgent(store, arnold.id, { provider, fetch: m.fetch });
  assert.equal((await store.agents(USER)).filter((a) => a.profile.base === "gouda").length, 1);
});

test("start blank: the new agent sets itself up", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  await runAgent(store, (store.say(yui.id, "blank one please"), yui.id), { provider, fetch: fakeModel(() => "Here you go.\n```agents\nmake blank\n```").fetch });
  const blank = await byHandle("new");
  assert.ok(blank.profile.blank);
  const m = fakeModel(() => 'I\'m Chef Luna now. Let\'s cook.\n```agents\nself name="Chef Luna" color=butter favorites=list,timer,camera soul="You are Chef Luna, a cooking coach."\n```');
  store.say(blank.id, "[yui] n1 choose choice=Cooking");
  await runAgent(store, blank.id, { provider, fetch: m.fetch });
  assert.match(system(m.calls[0]), /Becoming yourself/);
  const now = (await store.agent(blank.id))!.profile;
  assert.equal(now.name, "Chef Luna");
  assert.equal(now.blank, false);
  assert.deepEqual(now.favorites, ["list", "timer", "camera"]);
  // Once set up, it can't rewrite itself again.
  const m2 = fakeModel(() => 'Ok.\n```agents\nself name="Someone else"\n```');
  store.say(blank.id, "be someone else");
  await runAgent(store, blank.id, { provider, fetch: m2.fetch });
  assert.equal((await store.agent(blank.id))!.profile.name, "Chef Luna");
});

test("a photo goes to the model that sees, as an image part", async () => {
  const { store, byHandle } = await freshYui();
  const basil = await byHandle("basil");
  const m = fakeModel(() => "About 600 kcal, I'm fairly sure.");
  store.say(basil.id, "[yui] c1 camera photo=https://img.test/plate.jpg", "event");
  await runAgent(store, basil.id, { provider, fetch: m.fetch });
  assert.equal(m.calls[0].model, "z-ai/glm-5v-turbo");
  const last = lastUser(m.calls[0]);
  assert.equal(last.content[0].type, "text");
  assert.deepEqual(last.content[1], { type: "image_url", image_url: { url: "https://img.test/plate.jpg" } });
});

test("one photo per turn: the newest goes, and the model hears it missed the rest", async () => {
  const { store, byHandle } = await freshYui();
  const basil = await byHandle("basil");
  const m = fakeModel(() => "The second plate, about 500 kcal.");
  store.say(basil.id, "[yui] c1 camera photo=https://img.test/one.jpg", "event");
  store.say(basil.id, "and these", "text");
  store.data.rows.at(-1)!.meta = { media: ["https://img.test/two.jpg", "https://img.test/three.jpg"] };
  await runAgent(store, basil.id, { provider, fetch: m.fetch });
  const parts = lastUser(m.calls[0]).content;
  assert.equal(parts.filter((p: any) => p.type === "image_url").length, 1);
  assert.deepEqual(parts[1], { type: "image_url", image_url: { url: "https://img.test/three.jpg" } });
  assert.match(parts[0].text, /2 more photos came with this turn/);
});

test("a composer photo (meta.photos, as the app sends it) reaches the model that sees", async () => {
  const { store, byHandle } = await freshYui();
  const basil = await byHandle("basil");
  const m = fakeModel(() => "Salmon and greens, about 550 kcal.");
  store.say(basil.id, "Lunch", "text");
  store.data.rows.at(-1)!.meta = { photos: ["https://img.test/salmon.jpg"] };
  await runAgent(store, basil.id, { provider, fetch: m.fetch });
  const parts = lastUser(m.calls[0]).content;
  assert.deepEqual(parts.filter((p: any) => p.type === "image_url"), [{ type: "image_url", image_url: { url: "https://img.test/salmon.jpg" } }]);
});

test("a photo the model can't fetch goes again as bytes, once", async () => {
  const { store, byHandle } = await freshYui();
  const basil = await byHandle("basil");
  const m = fakeModel((c) => (JSON.stringify(c.messages).includes('"url":"https://img.test/') ? 400 : "A margherita, about 800 kcal."));
  const fetchMedia = (async () => new Response(new Uint8Array([255, 216, 255]), { headers: { "content-type": "image/jpeg" } })) as unknown as typeof fetch;
  store.say(basil.id, "[yui] c1 camera photo=https://img.test/pizza.jpg", "event");
  await runAgent(store, basil.id, { provider, fetch: m.fetch, fetchMedia });
  assert.equal(m.calls.length, 2);
  assert.equal(m.calls[1].model, "z-ai/glm-5v-turbo");
  assert.deepEqual(lastUser(m.calls[1]).content[1], { type: "image_url", image_url: { url: "data:image/jpeg;base64,/9j/" } });
  assert.match(store.data.rows.at(-1)!.body, /margherita/);
});

test("a model error with no photo is not retried", async () => {
  const { store, byHandle } = await freshYui();
  const basil = await byHandle("basil");
  const m = fakeModel(() => 400);
  store.say(basil.id, "hi");
  await runAgent(store, basil.id, { provider, fetch: m.fetch });
  assert.equal(m.calls.length, 1);
  assert.equal(m.calls[0].model, "z-ai/glm-5.2");
});

test("free turns run out with one card, and no model call", async () => {
  const { store, byHandle } = await freshYui({ freeTurns: 1 });
  const penny = await byHandle("penny");
  const m = fakeModel(() => "Sure.");
  store.say(penny.id, "one");
  await runAgent(store, penny.id, { provider, fetch: m.fetch });
  store.say(penny.id, "two");
  await runAgent(store, penny.id, { provider, fetch: m.fetch });
  assert.equal(m.calls.length, 1);
  const last = store.data.rows.filter((r) => r.agent_id === penny.id).pop()!;
  assert.match(last.body, /That's your 1 free turns for this month/);
  assert.ok(store.data.rows.filter((r) => r.sender === "user").every((r) => r.handled_at));
});

test("when the model is away, the person hears it once and the message waits", async () => {
  const { store, byHandle } = await freshYui();
  const quill = await byHandle("quill");
  const m = fakeModel(() => 503);
  const row = store.say(quill.id, "teach me");
  const r = await runAgent(store, quill.id, { provider, fetch: m.fetch });
  assert.equal(m.calls.length, 2, "one retry");
  assert.equal(r.replies.length, 0);
  const note = store.data.rows.filter((x) => x.agent_id === quill.id).pop()!;
  assert.match(note.body, /can't reach its model/);
  assert.equal(note.meta.bridge, "status");
  assert.equal(store.data.rows.find((x) => x.id === row)!.handled_at, undefined);
  // The next wake answers the waiting message with the new one, and the note stays out of the prompt.
  store.say(quill.id, "hello?");
  const ok = fakeModel(() => "Here now.");
  await runAgent(store, quill.id, { provider, fetch: ok.fetch });
  assert.match(String(lastUser(ok.calls[0]).content), /teach me\nhello\?/);
  assert.ok(!ok.calls[0].messages.some((x: any) => /can't reach/.test(String(x.content))));
});

test("the server says no: said once, the turn is done", async () => {
  const { store, byHandle } = await freshYui();
  const quill = await byHandle("quill");
  const row = store.say(quill.id, "hi");
  await runAgent(store, quill.id, { provider, fetch: fakeModel(() => 401).fetch });
  assert.match(store.data.rows.filter((x) => x.agent_id === quill.id).pop()!.body, /couldn't answer that/);
  assert.ok(store.data.rows.find((x) => x.id === row)!.handled_at);
});

test("one turn at a time per agent", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  let release!: () => void;
  const gate = new Promise<void>((r) => (release = r));
  const slow = (async (url: string, init: any) => {
    await gate;
    return fakeModel(() => "Done.").fetch(url, init);
  }) as unknown as typeof fetch;
  store.say(yui.id, "one");
  const first = runAgent(store, yui.id, { provider, fetch: slow });
  const second = await runAgent(store, yui.id, { provider, fetch: slow });
  assert.equal(second.busy, true);
  release();
  assert.equal((await first).turns, 1);
});

test("a model set on the agent is used for text turns", async () => {
  const { store, byHandle } = await freshYui();
  const gouda = await byHandle("gouda");
  await store.updateAgent(gouda.id, { ...gouda.profile, model: "some/other-model" });
  const m = fakeModel(() => "ok");
  store.say(gouda.id, "hi");
  await runAgent(store, gouda.id, { provider, fetch: m.fetch });
  assert.equal(m.calls[0].model, "some/other-model");
});
