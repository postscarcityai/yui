// t_88023cf2: an explanation is a deck with a drawing on every page; the net under the prompt.
import { test } from "node:test";
import assert from "node:assert/strict";
import { better, explainAsk, hasMotion, keepNotes, owes, pagesOf, redrawNote } from "../src/teach.ts";
import { TEACH_RULES, systemPrompt } from "../src/prompt.ts";
import { starters } from "../src/profiles.ts";
import { runAgent } from "../src/turn.ts";
import * as motion from "../src/motion.ts";
import { fakeModel, freshYui, provider } from "./helpers.ts";

const BARE = `Everything is tiny strings.
\`\`\`yui
>full
deck "String theory"
page "Strings" body="Everything is made of tiny loops of energy."
page "Why it matters" body="One idea could explain gravity and light together."
shapes caption="One string."
shape circle Loop +pulse
choose "Next?" "More"|"Less"
end
\`\`\``;

const DRAWN = `Everything is tiny strings.
\`\`\`yui
>full
deck "String theory"
page "Strings" body="Everything is made of tiny loops of energy."
shapes caption="A loop."
shape circle Loop +pulse
page "Why it matters" body="One idea could explain gravity and light together."
sketch "One idea" frame=bubble
row "Gravity" +hi
row "Light" +hi
choose "Next?" "More"|"Less"
end
\`\`\``;

test("which asks are explanations", () => {
  assert.equal(explainAsk("Eli5 string theory"), "explain");
  assert.equal(explainAsk("How do vaccines work?"), "explain");
  assert.equal(explainAsk("Explain inflation to me like I'm five."), "explain");
  assert.equal(explainAsk("what is a mortgage"), "maybe");
  assert.equal(explainAsk("add milk to my groceries"), null);
});

test("a page with no drawing right after it is found", () => {
  assert.deepEqual(pagesOf(BARE), { decks: 1, pages: 2, bare: ["Strings"] });
  assert.deepEqual(pagesOf(DRAWN), { decks: 1, pages: 2, bare: [] });
  assert.deepEqual(pagesOf("Just words."), { decks: 0, pages: 0, bare: [] });
});

test("owes a redraw only for an explanation that came back undrawn", () => {
  assert.deepEqual(owes("Eli5 string theory", BARE), { why: "deck", bare: ["Strings"] });
  assert.deepEqual(owes("Explain how big the sun is", BARE), { why: "bare", bare: ["Strings"] }, "a size ask keeps the deck check");
    assert.equal(owes("log my run", BARE), null, "not an explanation");
  assert.deepEqual(owes("how do vaccines work", "A vaccine is a practice run for your body. It shows your immune system a harmless piece of a germ so it can learn to fight it."), { why: "no film", bare: [] });
  assert.equal(owes("what is the capital of France", "Paris, the capital of France and its biggest city, sits on the Seine river in the north."), null, "a plain fact stays words");
  assert.equal(owes("explain my week", "Here is it.\n```yui\nplan \"Week\"\npage \"Mon\" body=\"x\"\nchoose \"Ok?\" A|B\nend\n```"), null, "a plan is not an explainer");
});

test("the second try is kept only when it is better", () => {
  assert.equal(better(BARE, DRAWN), true);
  assert.equal(better(DRAWN, BARE), false);
  assert.equal(better("Words only, long enough to be a wall of text for the phone.", DRAWN), true);
  assert.equal(better("Words only.", BARE), false, "a deck with a bare page is still not drawn");
  assert.match(redrawNote({ why: "bare", bare: ["Strings"] }), /"Strings"/);
});

test("notes the first try wrote are not lost in the redraw", () => {
  const first = BARE + "\n```remember\nme: interests = physics\n```";
  assert.ok(keepNotes(first, DRAWN).includes("me: interests = physics"));
  assert.equal(keepNotes(BARE, DRAWN), DRAWN);
});

const SCENES = `=== scene one 3 ===
api.look('chalk');
api.text('Loops', api.w/2, 120, {size:36});
=== scene two 5 ===
api.look('chalk');
api.say('Each hum is a particle', 0.4, 4);
=== end ===`;

const FILM = `String theory says everything is tiny loops. Watch.
\`\`\`yui
motion "String theory: particles are tiny vibrating loops of energy, and each way a loop vibrates is a different particle."
choose "Next?" "More"|"Less"
end
\`\`\``;

test("which answers owe a film", () => {
  assert.equal(hasMotion(FILM), true);
  assert.equal(hasMotion('x\n```yui\nmotion film=m1 part=2 +last\n```'), false, "a block of ours is not the agent's line");
  assert.equal(owes("Eli5 string theory", FILM), null, "a film is done");
  assert.deepEqual(owes("Eli5 string theory", DRAWN), { why: "deck", bare: [] }, "a deck is not a film");
  assert.equal(owes("take me through what string theory is", "Everything is tiny loops of energy that hum, and each hum is a particle you can feel, see or smell.")?.why, "no film");
  assert.equal(owes("Explain how big the sun is", BARE)?.why, "bare", "a how-big ask keeps the deck check");
  assert.equal(owes("Explain how big the sun is", DRAWN), null);
  assert.match(redrawNote({ why: "deck", bare: [] }), /ONE `motion/);
  assert.equal(better(DRAWN, FILM), true);
  assert.equal(better(FILM, DRAWN), false);
});

test("every agent's prompt asks for a film, not a deck, and its example is a motion line", () => {
  const p = systemPrompt(starters()[0], [], "a1");
  assert.ok(p.includes("### Explaining: one line and a film"));
  const ex = [...TEACH_RULES.matchAll(/```yui\n([\s\S]*?)```/g)].map((m) => m[1]);
  assert.equal(ex.length, 1);
  assert.equal(hasMotion("```yui\n" + ex[0] + "```"), true);
  assert.equal(pagesOf("```yui\n" + ex[0] + "```").decks, 0);
  assert.ok(!/[—–]/.test(TEACH_RULES), "no em or en dash");
});

test("a turn redraws a deck as a film once, and keeps it", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const m = fakeModel((c) => {
    const last = String(c.messages[c.messages.length - 1].content);
    if (last.startsWith("[yui] That was a deck")) return FILM;
    if (last.startsWith("You are a motion designer")) return SCENES;
    return DRAWN;
  });
  store.say(yui.id, "Eli5 string theory");
  const r = await runAgent(store, yui.id, { provider, fetch: m.fetch });
  assert.match(String(m.calls[1].messages.at(-1).content), /ONE `motion/);
  assert.equal(m.calls[1].messages.at(-2).role, "assistant", "the model sees its own first try");
  const bodies = r.replies.map((id) => store.data.rows.find((x) => x.id === id)!.body);
  assert.ok(!bodies[0].includes("motion"), "the line is cut out of the words");
  assert.ok(bodies.some((b) => b.includes("deck")) === false);
  assert.equal(bodies.filter((b) => /^```yui\nmotion /.test(b)).length, 3, "two scenes, then the close row");
});

test("a film is one row per scene, the first with the title, the last with +last, the hero written in", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const HEART = FILM.replace("String theory: particles are tiny vibrating loops of energy", "How a heart works: a heart is a pump of four rooms");
  const m = fakeModel((c) => (String(c.messages[0].content).startsWith("You are a motion designer") ? SCENES : HEART));
  store.say(yui.id, "Eli5 how a heart works");
  const r = await runAgent(store, yui.id, { provider, fetch: m.fetch });
  const rows = r.replies.map((id) => store.data.rows.find((x) => x.id === id)!);
  const films = rows.filter((x) => /^```yui\nmotion /.test(x.body)).map((x) => x.body);
  assert.equal(films.length, 3);
  assert.match(films[0], /^```yui\nmotion "How a heart works[^"]*" film=m\w+ part=1\n=== scene one 3 ===/);
  assert.match(films[1], /part=2\n=== scene two 5 ===/);
  assert.match(films[2], /part=3 \+last\n```$/);
  assert.match(films[0], /api\.thing\("heart"/, "the kit draws the hero");
  const calls = m.calls.filter((c) => String(c.messages[0].content).startsWith("You are a motion designer"));
  assert.equal(calls.length, 1);
  assert.match(String(calls[0].messages[0].content), /ASK: How a heart works: a heart is a pump/);
  assert.equal(rows.at(-1)!.body, films[2]);
  assert.equal(m.calls.length, 2, "one turn, one film");
});

test("a film that draws nothing is said in words, and the ask is capped per hour", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const m = fakeModel((c) => (String(c.messages[0].content).startsWith("You are a motion designer") ? "sorry, no" : FILM));
  store.say(yui.id, "Eli5 string theory");
  const r = await runAgent(store, yui.id, { provider, fetch: m.fetch });
  const last = store.data.rows.find((x) => x.id === r.replies.at(-1))!;
  assert.match(last.body, /^```yui\nsay "String theory/);
  assert.equal(motion.allowed("cap-test", 0), true);
  for (let i = 0; i < 7; i++) motion.allowed("cap-test", 1);
  assert.equal(motion.allowed("cap-test", 2), false);
  assert.equal(motion.allowed("cap-test", 3_700_000), true);
});

test("a redraw that is no better is dropped, and a film is not asked twice", async () => {
  const a = await freshYui();
  const m1 = fakeModel(() => BARE);
  a.store.say((await a.byHandle("yui")).id, "Eli5 string theory");
  const r1 = await runAgent(a.store, (await a.byHandle("yui")).id, { provider, fetch: m1.fetch });
  assert.equal(m1.calls.length, 2);
  assert.ok(a.store.data.rows.find((x) => x.id === r1.replies[0])!.body.includes("page \"Strings\""));
  const b = await freshYui();
  const m2 = fakeModel((c) => (String(c.messages[0].content).startsWith("You are a motion designer") ? SCENES : FILM));
  b.store.say((await b.byHandle("yui")).id, "Eli5 string theory");
  await runAgent(b.store, (await b.byHandle("yui")).id, { provider, fetch: m2.fetch });
  // string theory has no body: the drawing call (MOTION-29) is a third call that answers noun null, never a redraw of the film
  assert.equal(m2.calls.filter((c) => !String(c.messages[0].content).startsWith("You name the thing")).length, 2, "the answer and the film, no redraw");
});

test("where and how big keep the deck", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const m = fakeModel(() => DRAWN);
  store.say(yui.id, "Explain how big the sun is");
  await runAgent(store, yui.id, { provider, fetch: m.fetch });
  assert.equal(m.calls.length, 1);
});
