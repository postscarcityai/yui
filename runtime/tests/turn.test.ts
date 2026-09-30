// Whole turns on a local store with a scripted model: memory that lasts, the
// crew, Yui making agents, a blank agent making itself, photos, caps, locks.
import { test } from "node:test";
import assert from "node:assert/strict";
import { LocalStore } from "../src/store.ts";
import { openRouter, runAgent, runJob, unend } from "../src/turn.ts";
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
  assert.equal(blank.profile.tagline, "Anything you want it to be");
  const m = fakeModel(() => 'I\'m Chef Luna now. Let\'s cook.\n```agents\nself name="Chef Luna" color=butter favorites=list,timer,camera tagline="Dinner without the stress" can="Plan dinner|Use my fridge|Quick lunch" soul="You are Chef Luna, a cooking coach."\n```');
  store.say(blank.id, "[yui] n1 choose choice=Cooking");
  await runAgent(store, blank.id, { provider, fetch: m.fetch });
  assert.match(system(m.calls[0]), /Becoming yourself/);
  const now = (await store.agent(blank.id))!.profile;
  assert.equal(now.name, "Chef Luna");
  assert.equal(now.blank, false);
  assert.deepEqual(now.favorites, ["list", "timer", "camera"]);
  // What it does is its own now; nothing of the blank's words is left (YUI-165).
  assert.equal(now.tagline, "Dinner without the stress");
  assert.deepEqual(now.can, ["Plan dinner", "Use my fridge", "Quick lunch"]);
  assert.equal(now.about, undefined);
  // Once set up, it can't rewrite itself again.
  const m2 = fakeModel(() => 'Ok.\n```agents\nself name="Someone else"\n```');
  store.say(blank.id, "be someone else");
  await runAgent(store, blank.id, { provider, fetch: m2.fetch });
  assert.equal((await store.agent(blank.id))!.profile.name, "Chef Luna");
});

test("a photo goes to the model that sees, as an image part", async () => {
  const { store, byHandle } = await freshYui();
  const basil = await byHandle("arnold"); // Basil logs a meal photo behind the scenes (meals.test.ts)
  const m = fakeModel(() => "About 600 kcal, I'm fairly sure.");
  store.say(basil.id, "[yui] c1 camera photo=https://img.test/plate.jpg", "event");
  await runAgent(store, basil.id, { provider, fetch: m.fetch });
  assert.equal(m.calls[0].model, "z-ai/glm-5v-turbo");
  const last = lastUser(m.calls[0]);
  assert.equal(last.content[0].type, "text");
  assert.deepEqual(last.content[1], { type: "image_url", image_url: { url: "https://img.test/plate.jpg" } });
});

test("twelve photos in one turn all reach the model; a 13th is left out and the model hears it", async () => {
  const { store, byHandle } = await freshYui();
  const basil = await byHandle("arnold"); // Basil logs a meal photo behind the scenes (meals.test.ts)
  const m = fakeModel(() => "Twelve plates.");
  store.say(basil.id, "these", "text");
  const urls = Array.from({ length: 13 }, (_, i) => `https://img.test/p${i + 1}.jpg`);
  store.data.rows.at(-1)!.meta = { photos: urls };
  await runAgent(store, basil.id, { provider, fetch: m.fetch });
  const parts = lastUser(m.calls[0]).content;
  const got = parts.filter((p: any) => p.type === "image_url").map((p: any) => p.image_url.url);
  assert.deepEqual(got, urls.slice(1), "the newest 12");
  assert.match(parts[0].text, /1 more photo came with this turn; you see only the newest 12/);
});

test("a composer photo (meta.photos, as the app sends it) reaches the model that sees", async () => {
  const { store, byHandle } = await freshYui();
  const basil = await byHandle("arnold"); // Basil logs a meal photo behind the scenes (meals.test.ts)
  const m = fakeModel(() => "Salmon and greens, about 550 kcal.");
  store.say(basil.id, "Lunch", "text");
  store.data.rows.at(-1)!.meta = { photos: ["https://img.test/salmon.jpg"] };
  await runAgent(store, basil.id, { provider, fetch: m.fetch });
  const parts = lastUser(m.calls[0]).content;
  assert.deepEqual(parts.filter((p: any) => p.type === "image_url"), [{ type: "image_url", image_url: { url: "https://img.test/salmon.jpg" } }]);
});

test("snap and say (YUI-166): the spoken words and the photo reach the meal job in one call (YUI-103)", async () => {
  const { store, byHandle } = await freshYui();
  const basil = await byHandle("basil");
  const m = fakeModel(() => JSON.stringify({ food: true, title: "Eggs", sure: "Clear.", question: null,
    items: [{ food: "Eggs, fried in butter", portion: "2 eggs", cal: 250, protein: 12, carbs: 1, fat: 22 }] }));
  store.say(basil.id, "Two eggs in a lot of butter", "text");
  store.data.rows.at(-1)!.meta = { photos: ["https://img.test/eggs.jpg"] };
  const r = await runAgent(store, basil.id, { provider, fetch: m.fetch });
  await runJob(store, r.jobs[0], { provider, fetch: m.fetch });
  assert.equal(m.calls.length, 1, "one call, not one for the photo and one for the words");
  const parts = lastUser(m.calls[0]).content;
  assert.match(parts.find((p: any) => p.type === "text").text, /They said: "Two eggs in a lot of butter"/);
  assert.deepEqual(parts.filter((p: any) => p.type === "image_url"), [{ type: "image_url", image_url: { url: "https://img.test/eggs.jpg" } }]);
});

test("snap and say from an agent's camera +say: the words ride the event with the photo to the meal job", async () => {
  const { store, byHandle } = await freshYui();
  const basil = await byHandle("basil");
  const m = fakeModel(() => JSON.stringify({ food: true, title: "Eggs", sure: "Clear.", question: null,
    items: [{ food: "Eggs", portion: "2 eggs", cal: 250, protein: 12, carbs: 1, fat: 22 }] }));
  store.say(basil.id, '[yui] c1 camera photo=https://img.test/eggs.jpg words="Two eggs in a lot of butter"', "event");
  const r = await runAgent(store, basil.id, { provider, fetch: m.fetch });
  await runJob(store, r.jobs[0], { provider, fetch: m.fetch });
  const parts = lastUser(m.calls[0]).content;
  assert.match(parts.find((p: any) => p.type === "text").text, /They said: "Two eggs in a lot of butter"/);
  assert.deepEqual(parts.filter((p: any) => p.type === "image_url"), [{ type: "image_url", image_url: { url: "https://img.test/eggs.jpg" } }]);
});

test("a photo the model can't fetch goes again as bytes, once", async () => {
  const { store, byHandle } = await freshYui();
  const basil = await byHandle("arnold"); // Basil logs a meal photo behind the scenes (meals.test.ts)
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

test("answers lose their em and en dashes where the person reads them (YUI-163)", async () => {
  const { undash } = await import("../src/turn.ts");
  assert.equal(undash("Arnold's your trainer — tap Arnold and tell him your goals."),
    "Arnold's your trainer. Tap Arnold and tell him your goals.");
  assert.equal(undash("Those questions on screen will get us started — tap through them."),
    "Those questions on screen will get us started. Tap through them.");
  assert.equal(undash("Squats, lunges – and a plank."), "Squats, lunges, and a plank.");
  assert.equal(undash("Rest 3–5 minutes"), "Rest 3-5 minutes");
  assert.equal(undash("Ready when you are —\n— one\n— two"), "Ready when you are.\n- one\n- two");
  assert.equal(undash("No dashes here."), "No dashes here.");
  const yl = "Pick one — quick.\n```yui\ncard \"Leg day\" body=\"Squats — then lunges\" url=https://ex.com/a—b\nchoose \"Split?\" Push|Pull\n```";
  assert.equal(undash(yl),
    "Pick one, quick.\n```yui\ncard \"Leg day\" body=\"Squats, then lunges\" url=https://ex.com/a—b\nchoose \"Split?\" Push|Pull\n```");
  const code = "```python\nx = 'a — b'\n```";
  assert.equal(undash(code), code, "code fences are left alone");
});

test("a turn's written answer has no dashes", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const m = fakeModel(() => "Arnold's your trainer — tap Arnold.");
  store.say(yui.id, "Who trains me?");
  const r = await runAgent(store, yui.id, { provider, fetch: m.fetch });
  assert.equal(store.data.rows.find((x) => x.id === r.replies[0])!.body, "Arnold's your trainer. Tap Arnold.");
  assert.match(system(m.calls[0]), /Never use an em dash/);
});

// YUI-161: GLM 5.2 wrote \n inside a quoted say; YL reads \n as the letter n, so the app showed "nn".
const BASIL = "```yui\nsay \"A few dinners that skip peanuts:\\n\\n\u2022 Grilled chicken with greens\\n\u2022 Salmon with rice\\n\\nWant a recipe?\"\nchoose \"Pick one\" Chicken|Salmon\n```";

test("a line break written as \\n inside a quoted say becomes real lines, bullets a list (YUI-161)", async () => {
  const { unbreak } = await import("../src/turn.ts");
  assert.equal(unbreak(BASIL),
    "```yui\nsay \"A few dinners that skip peanuts:\"\nlist \"Grilled chicken with greens\" \"Salmon with rice\"\nsay \"Want a recipe?\"\nchoose \"Pick one\" Chicken|Salmon\n```");
  assert.equal(unbreak("```yui\n>2 say@top \"Step one\\n1. Warm up\\n2) Squat 5x5\"\n```"),
    "```yui\n>2 say@top \"Step one\"\n>2 list \"Warm up\" \"Squat 5x5\" +num\n```", "route and id kept, numbers become +num");
  assert.equal(unbreak("```yui\nsay First line\\nSecond \"line\"\n```"), "```yui\nsay First line\\nSecond \"line\"\n```",
    "an unquoted say with a quote in it is left alone");
  assert.equal(unbreak("```yui\nsay Hi there\\nsee you\n```"), "```yui\nsay \"Hi there\"\nsay \"see you\"\n```");
  assert.equal(unbreak("```yui\ncard \"Dinner\" body=\"Chicken\\n\\n\u2022 Salmon\\nRice.\\nDone\"\n```"),
    "```yui\ncard \"Dinner\" body=\"Chicken. Salmon. Rice. Done\"\n```", "a break in any other string is a space");
  const kept = "```yui\nsay \"She said \\\"hi\\\" and left a \\\\ here\"\n```";
  assert.equal(unbreak(kept), kept, "other escapes stay as written");
  const prose = "Use \\n in the regex.\n```python\nprint('a\\nb')\n```";
  assert.equal(unbreak(prose), prose, "prose and other fences are left alone");
});

test("a native turn's \\n in a say reaches the thread as lines", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const m = fakeModel(() => BASIL);
  store.say(yui.id, "Dinner ideas?");
  const r = await runAgent(store, yui.id, { provider, fetch: m.fetch });
  const body = store.data.rows.find((x) => x.id === r.replies[0])!.body;
  assert.ok(!body.includes("\\n"), body);
  assert.match(body, /^list "Grilled chicken with greens" "Salmon with rice"$/m);
  assert.match(system(m.calls[0]), /never write \\n/);
});

// YUI-162: GLM 5.2 could think through the whole budget and answer nothing.
function thinker(answers: Array<{ content: string; finish: string; thought?: number }>) {
  const calls: any[] = [];
  const fetchImpl = (async (_url: string, init: any) => {
    const body = JSON.parse(init.body);
    calls.push(body);
    const a = answers[Math.min(calls.length - 1, answers.length - 1)];
    return new Response(JSON.stringify({ choices: [{ message: { role: "assistant", content: a.content, reasoning: "hmm ".repeat(50) }, finish_reason: a.finish }],
                                         ...(a.thought ? { usage: { completion_tokens: 3000, completion_tokens_details: { reasoning_tokens: a.thought } } } : {}) }),
                        { status: 200, headers: { "content-type": "application/json" } });
  }) as unknown as typeof fetch;
  return { calls, fetch: fetchImpl };
}

test("on OpenRouter the thinking gets its own cap, on top of the answer's room", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const m = thinker([{ content: "Rome rose, then it fell.", finish: "stop" }]);
  store.say(yui.id, "explain the rise and fall of Rome");
  await runAgent(store, yui.id, { provider: openRouter("k"), fetch: m.fetch });
  assert.equal(m.calls.length, 1);
  assert.deepEqual(m.calls[0].reasoning, { max_tokens: 1000 });
  assert.equal(m.calls[0].max_tokens, 3000, "2000 for the answer plus 1000 to think");
  assert.equal(m.calls[0].provider.data_collection, "deny");
});

test("thought until it ran out of room: asks once more without thinking and uses that answer", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const m = thinker([{ content: "", finish: "length" }, { content: "Rome rose on roads and fell on money.", finish: "stop" }]);
  store.say(yui.id, "explain the rise and fall of Rome");
  const r = await runAgent(store, yui.id, { provider: openRouter("k"), fetch: m.fetch });
  assert.equal(m.calls.length, 2, "one retry, no more");
  assert.deepEqual(m.calls[1].reasoning, { enabled: false });
  assert.deepEqual(m.calls[1].messages, m.calls[0].messages, "the same conversation");
  const reply = store.data.rows.find((x) => x.id === r.replies[0])!;
  assert.equal(reply.body, "Rome rose on roads and fell on money.");
});

test("still empty after the retry: the ran-out-of-room line is the last resort", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const m = thinker([{ content: "", finish: "length" }]);
  store.say(yui.id, "explain everything");
  const r = await runAgent(store, yui.id, { provider: openRouter("k"), fetch: m.fetch });
  assert.equal(m.calls.length, 2);
  const reply = store.data.rows.find((x) => x.id === r.replies[0])!;
  assert.match(reply.body, /ran out of room/);
});

test("another server gets no reasoning field; its retry asks for a shorter answer", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const m = thinker([{ content: "", finish: "length" }, { content: "Short answer.", finish: "stop" }]);
  store.say(yui.id, "explain the rise and fall of Rome");
  const r = await runAgent(store, yui.id, { provider, fetch: m.fetch });
  assert.equal(m.calls.length, 2);
  assert.equal(m.calls[0].reasoning, undefined);
  assert.equal(m.calls[0].max_tokens, 2000);
  assert.match(m.calls[1].messages.at(-1).content, /ran out of room while thinking/);
  assert.equal(store.data.rows.find((x) => x.id === r.replies[0])!.body, "Short answer.");
});

test("half a sentence after thinking most of the budget counts as no answer", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const m = thinker([{ content: 'Rome grew, then crumbled.\n```yui\ndeck "Rome, rise and fall', finish: "length", thought: 2958 },
                     { content: "Rome grew on roads and law, and fell on money and borders.", finish: "stop" }]);
  store.say(yui.id, "explain the rise and fall of Rome");
  const r = await runAgent(store, yui.id, { provider: openRouter("k"), fetch: m.fetch });
  assert.equal(m.calls.length, 2);
  assert.deepEqual(m.calls[1].reasoning, { enabled: false });
  assert.match(store.data.rows.find((x) => x.id === r.replies[0])!.body, /fell on money/);
});

test("a long answer that ran long without much thinking is kept, no retry", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const m = thinker([{ content: "Rome rose and", finish: "length", thought: 300 }]);
  store.say(yui.id, "explain the rise and fall of Rome");
  await runAgent(store, yui.id, { provider: openRouter("k"), fetch: m.fetch });
  assert.equal(m.calls.length, 1);
});

// YUI-135: Gouda once answered a beat ask with nothing the person could see, and the turn closed silently.
test("an answer with nothing to see asks once more and keeps what it noted", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const m = thinker([{ content: "```remember\nnote: likes lo-fi\n```", finish: "stop" },
                     { content: "Here's a chill one.\n```yui\nloop 76 \"Chill\" p=x...x.x.\n```", finish: "stop" }]);
  store.say(yui.id, "make me a chill lo-fi beat");
  const r = await runAgent(store, yui.id, { provider: openRouter("k"), fetch: m.fetch });
  assert.equal(m.calls.length, 2, "one retry, no more");
  assert.deepEqual(m.calls[1].reasoning, { enabled: false });
  assert.match(m.calls[1].messages.at(-1).content, /nothing the person can see/);
  const body = store.data.rows.find((x) => x.id === r.replies[0])!.body;
  assert.match(body, /^loop 76/m);
  assert.doesNotMatch(body, /remember/);
  assert.ok(store.data.memory.some((x: any) => /likes lo-fi/.test(x.body)), "the note from the first try is kept");
});

test("an empty answer that stopped normally is asked again too", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const m = thinker([{ content: "  ", finish: "stop" }, { content: "Sure.\n```yui\nsay \"Hi\"\n```", finish: "stop" }]);
  store.say(yui.id, "hi");
  const r = await runAgent(store, yui.id, { provider, fetch: m.fetch });
  assert.equal(m.calls.length, 2);
  assert.equal(m.calls[1].reasoning, undefined);
  assert.match(store.data.rows.find((x) => x.id === r.replies[0])!.body, /^Sure\./);
});

test("a search block left after the lookups ran out is asked again, and a turn never ends silent", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const m = thinker([{ content: "```search\nlo-fi beat bpm\n```", finish: "stop" }]);
  store.say(yui.id, "make me a chill lo-fi beat");
  const r = await runAgent(store, yui.id, { provider, fetch: m.fetch });
  assert.ok(m.calls.length >= 3, "the lookup note, then one retry");
  assert.match(m.calls.at(-1).messages.at(-1).content, /nothing the person can see/);
  assert.match(store.data.rows.find((x) => x.id === r.replies[0])!.body, /couldn't put an answer together/);
});

test("an end with no plan, deck or other group open leaves the answer; a real plan keeps its end", async () => {
  assert.equal(unend('Sure.\n```yui\nchoose "Next?" A|B\nend\n```'), 'Sure.\n```yui\nchoose "Next?" A|B\n```');
  const plan = 'Hi.\n```yui\nplan "Week"\nchoose "Days?" 2|3\nend\n```';
  assert.equal(unend(plan), plan);
  assert.equal(unend('```js\nend\n```'), '```js\nend\n```');
});

test("options wrapped onto their own lines join the choose they belong to", () => {
  assert.equal(unend('Ok.\n```yui\nchoose "How?"\n"Upper body"|"Gentle legs" +other\n```'),
               'Ok.\n```yui\nchoose "How?" "Upper body"|"Gentle legs" +other\n```');
  assert.equal(unend('```yui\nchoose "How?"\n"See a pro"\n"Upper body"\n```'), '```yui\nchoose "How?" "See a pro" "Upper body"\n```');
});

test("a flag wrapped onto its own line joins the list it belongs to", () => {
  assert.equal(unend('```yui\nlist "This week" "Dentist" "Report"\n+check\n```'), '```yui\nlist "This week" "Dentist" "Report" +check\n```');
});

test("markdown in an answer becomes Yui Lines, never raw stars on the phone (t_a88dc3b5)", async () => {
  const { unmark } = await import("../src/turn.ts");
  // Basil's answer on build 244, shortened: bullets and bold in the chat text, a choose below.
  const basil = "Here's what I can do for you:\n\n- **Build meal plans** around your goal.\n- **Log meals from a photo.** Snap your plate.\n"
    + "- **Grocery lists** you can check off.\n\nWant to start with any of these?\n```yui\nchoose \"Where to start?\" \"Plan my meals\"|\"Log a meal\"\n```";
  assert.equal(unmark(basil), "```yui\nsay \"Here's what I can do for you:\"\n"
    + "list \"Build meal plans around your goal.\" \"Log meals from a photo. Snap your plate.\" \"Grocery lists you can check off.\"\n"
    + "say \"Want to start with any of these?\"\nchoose \"Where to start?\" \"Plan my meals\"|\"Log a meal\"\n```");
  // No yui block: one is made. Headings are says, numbered runs a numbered list, *italics* lose their stars.
  assert.equal(unmark("## Today\n1. Squat 5x5\n2. Bench 5x5\n\nThat's it, *easy*."),
    "```yui\nsay \"Today\"\nlist \"Squat 5x5\" \"Bench 5x5\" +num\nsay \"That's it, easy.\"\n```");
  // Words after the block go to its end; a quote inside becomes an apostrophe.
  assert.equal(unmark("```yui\ncard \"Plan\"\n```\n- the \"easy\" one\n- the hard one"),
    "```yui\ncard \"Plan\"\nlist \"the 'easy' one\" \"the hard one\"\n```");
  // Bold inside a yui string loses its stars.
  assert.equal(unmark("```yui\nsay \"**Rest** 2 minutes\"\n```"), "```yui\nsay \"Rest 2 minutes\"\n```");
  // Plain prose, one numbered aside and other code fences are left alone.
  for (const t of ["Rest 2 minutes. 1) stretch first.", "Hi Sam.", "```js\n- **x**\n```", "3 * 4 * 5 is 60."]) assert.equal(unmark(t), t);
});

test("an answer over 4 short pages is merged, never split into 7 (t_a88dc3b5)", async () => {
  const { unsprawl } = await import("../src/turn.ts");
  assert.equal(unsprawl("One.\n\nTwo.\n\nThree.\n\nFour.\n\nFive."), "One. Two.\n\nThree.\n\nFour.\n\nFive.");
  const says = "```yui\n" + ["a", "b", "c", "d", "e", "f"].map((x) => `say "${x}"`).join("\n") + "\nlist \"x\"\n```";
  assert.equal(unsprawl(says), "```yui\nsay \"a. b. c\"\nsay \"d\"\nsay \"e\"\nsay \"f\"\nlist \"x\"\n```");
  const deck = "```yui\ndeck \"T\"\n" + [1, 2, 3, 4, 5].map((n) => `page "P${n}" body="Body ${n}."`).join("\n") + "\nend\n```";
  assert.match(unsprawl(deck), /page "P1" body="Body 1\. P2\. Body 2\."\npage "P3"/);
  // Three or more loose stat tiles are one table: the stage plays each tile as a page.
  assert.equal(unsprawl('Roughly 505 kcal.\n```yui\nstat 505kcal Calories sub="a guess"\nstat 19g Protein\nstat 54g Carbs\nstat 23g Fat\n```'),
    'Roughly 505 kcal.\n```yui\ntable Macros Item|Amount "Calories|505kcal (a guess)" "Protein|19g" "Carbs|54g" "Fat|23g"\n```');
  // A quoted table title moves to name=, so the header stays the header.
  assert.equal(unsprawl('```yui\ntable "Two eggs, toast" Item|Kcal "Eggs|140"\n```'), '```yui\ntable name="Two eggs, toast" Item|Kcal "Eggs|140"\n```');
  // A row with its quote closed before the pipes is one row again.
  assert.equal(unsprawl('```yui\ntable Breakfast Item|Kcal "Eggs (2 large)"|140 "Toast|160"\n```'),
    '```yui\ntable Breakfast Item|Kcal "Eggs (2 large)|140" "Toast|160"\n```');
  const two = '```yui\nstat 178.9lb Weight delta=-2.3\nstat "24M km2" "A sixth of the land"\n```';
  assert.equal(unsprawl(two), two);
  // Four or fewer, or pages too long to share, stay as written.
  const four = "```yui\nsay \"a\"\nsay \"b\"\nsay \"c\"\nsay \"d\"\n```";
  assert.equal(unsprawl(four), four);
  const long = Array.from({ length: 6 }, (_, i) => `Paragraph ${i} ` + "word ".repeat(30).trim() + ".").join("\n\n");
  assert.equal(unsprawl(long), long);
});

test("a whole turn: Basil's markdown answer reaches the phone as a list (t_a88dc3b5)", async () => {
  const { store, byHandle } = await freshYui();
  const basil = await byHandle("basil");
  const m = fakeModel(() => "Here's what I can do:\n\n- **Meal plans**\n- **Macros from a photo**\n```yui\nchoose \"Start?\" Plan|Log\n```");
  store.say(basil.id, "What can you do for me?");
  const r = await runAgent(store, basil.id, { provider, fetch: m.fetch });
  const reply = store.data.rows.find((x) => x.id === r.replies[0])!;
  assert.doesNotMatch(reply.body, /\*\*|^- /m);
  assert.match(reply.body, /list "Meal plans" "Macros from a photo"/);
  assert.match(system(m.calls[0]), /No markdown anywhere/);
});

test("a tap on Yui's hello always ends in the Open card for that agent, whatever the model wrote (YUI-231)", async () => {
  const tap = '[yui] n1 choose choice="Get fit"';
  // The model forgets the card entirely.
  const a = await freshYui();
  const yui = await a.byHandle("yui");
  const arnold = await a.byHandle("arnold");
  a.store.say(yui.id, tap);
  const r = await runAgent(a.store, yui.id, { provider, fetch: fakeModel(() => "Arnold is your trainer. Tap Arnold.").fetch });
  const reply = a.store.data.rows.find((x) => x.id === r.replies[0])!;
  assert.match(reply.body, /card "Arnold" body="Trainer\. [^"]*" url=yui:\/\/agent\/arnold cta="Open Arnold"/);
  assert.equal((reply.body.match(/url=yui:\/\/agent\//g) ?? []).length, 1);
  assert.equal(r.turns, 2, "Arnold is handed the turn");
  assert.ok(a.store.data.rows.some((x) => x.agent_id === arnold.id && x.sender === "agent" && x.id !== undefined && r.replies.includes(x.id)), "and answers in his own thread");
  // The model wrote its own broken card (a /thread link with braces): replaced, never doubled.
  const b = await freshYui();
  const y2 = await b.byHandle("yui");
  b.store.say(y2.id, tap);
  const r2 = await runAgent(b.store, y2.id, { provider, fetch: fakeModel(() => 'Tap Arnold.\n```yui\ncard Arnold "Your trainer" url=yui://agent/{arnold}/thread cta="Open Arnold"\n```').fetch });
  const b2 = b.store.data.rows.find((x) => x.id === r2.replies[0])!.body;
  assert.equal((b2.match(/url=yui:\/\/agent\//g) ?? []).length, 1);
  assert.match(b2, /url=yui:\/\/agent\/arnold cta="Open Arnold"/);
  // Other words are the model's: no card.
  const c = await freshYui();
  const y3 = await c.byHandle("yui");
  c.store.say(y3.id, "What can you do?");
  const r3 = await runAgent(c.store, y3.id, { provider, fetch: fakeModel(() => "Plenty.").fetch });
  assert.doesNotMatch(c.store.data.rows.find((x) => x.id === r3.replies[0])!.body, /url=yui:\/\/agent\//);
});

test("a person who writes during a hand-off is answered before the lock goes (t_a88dc3b5)", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const basil = await byHandle("basil");
  const m = fakeModel((c) => (system(c).includes("You are Basil") ? "Here you go.\n```yui\ntable Macros Item|Amount \"Calories|505 kcal\"\n```"
    : "Basil does macros.\n```handoff\nbasil \"Wants a breakfast's macros\"\n```"));
  store.say(yui.id, "Macros for two eggs?");
  const mine = store.say(basil.id, "And break down a banana too.");
  // Basil's own wake runs first and finds nothing it can take (the hand-off holds the lock in real life); here the
  // hand-off simply runs first.
  await runAgent(store, yui.id, { provider, fetch: m.fetch });
  const row = store.data.rows.find((x) => x.id === mine)!;
  assert.ok(row.handled_at, "Basil answered the person's own message too");
  assert.ok(store.data.rows.some((x) => x.sender === "agent" && Array.isArray(x.meta?.turn) && x.meta.turn.includes(mine)));
});

test("a line that can't sit in a deck moves after it, so the deck still draws (t_a88dc3b5)", async () => {
  const { undeck } = await import("../src/turn.ts");
  const gouda = "Hi.\n```yui\ndeck \"About me\"\npage \"Who\" body=\"x\"\nshapes\nshape circle You\npage \"What\" body=\"y\"\nlist \"My jobs\" \"Beats\" \"Theory\"\nend\n```";
  assert.equal(undeck(gouda), "Hi.\n```yui\ndeck \"About me\"\npage \"Who\" body=\"x\"\nshapes\nshape circle You\npage \"What\" body=\"y\"\nend\nlist \"My jobs\" \"Beats\" \"Theory\"\n```");
  const fine = "```yui\ndeck \"T\"\npage \"A\"\nsketch frame=bubble\nrow \"x\" +x\nend\nend\nchoose \"Q?\" A|B\n```";
  assert.equal(undeck(fine), fine);
});
