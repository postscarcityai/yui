// t_88023cf2: an explanation is a deck with a drawing on every page; the net under the prompt.
import { test } from "node:test";
import assert from "node:assert/strict";
import { better, explainAsk, keepNotes, owes, pagesOf, redrawNote } from "../src/teach.ts";
import { TEACH_RULES, systemPrompt } from "../src/prompt.ts";
import { starters } from "../src/profiles.ts";
import { runAgent } from "../src/turn.ts";
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
  assert.deepEqual(owes("Eli5 string theory", BARE), { why: "bare", bare: ["Strings"] });
  assert.equal(owes("Eli5 string theory", DRAWN), null);
  assert.equal(owes("log my run", BARE), null, "not an explanation");
  assert.deepEqual(owes("how do vaccines work", "A vaccine is a practice run for your body. It shows your immune system a harmless piece of a germ so it can learn to fight it."), { why: "no deck", bare: [] });
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

test("every agent's prompt carries the teaching block, and its examples are drawn on every page", () => {
  const p = systemPrompt(starters()[0], [], "a1");
  assert.ok(p.includes("### Explaining: draw every page"));
  const decks = [...TEACH_RULES.matchAll(/```yui\n([\s\S]*?)```/g)].map((m) => m[1]);
  assert.equal(decks.length, 3);
  for (const d of decks) {
    const p = pagesOf("```yui\n" + d + "```");
    assert.equal(p.decks, 1);
    assert.ok(p.pages >= 2 && p.pages <= 4);
    assert.deepEqual(p.bare, []);
    for (const b of d.matchAll(/body="([^"]*)"/g)) assert.ok(b[1].split(/\s+/).length <= 25, b[1]);
  }
  assert.ok(!/[—–]/.test(TEACH_RULES), "no em or en dash");
});

test("a turn redraws an undrawn explanation once, and keeps it", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const m = fakeModel((c) => (String(c.messages[c.messages.length - 1].content).startsWith("[yui] Pages with no drawing") ? DRAWN : BARE));
  const row = store.say(yui.id, "Eli5 string theory");
  const r = await runAgent(store, yui.id, { provider, fetch: m.fetch });
  assert.equal(m.calls.length, 2);
  assert.match(String(m.calls[1].messages.at(-1).content), /"Strings"/);
  assert.equal(m.calls[1].messages.at(-2).role, "assistant", "the model sees its own first try");
  const reply = store.data.rows.find((x) => x.id === r.replies[0])!;
  assert.ok(reply.body.includes('sketch "One idea"'));
  assert.ok(row);
});

test("a redraw that is no better is dropped, and a drawn answer is not asked twice", async () => {
  const a = await freshYui();
  const m1 = fakeModel(() => BARE);
  a.store.say((await a.byHandle("yui")).id, "Eli5 string theory");
  const r1 = await runAgent(a.store, (await a.byHandle("yui")).id, { provider, fetch: m1.fetch });
  assert.equal(m1.calls.length, 2);
  assert.ok(a.store.data.rows.find((x) => x.id === r1.replies[0])!.body.includes("page \"Strings\""));
  const b = await freshYui();
  const m2 = fakeModel(() => DRAWN);
  b.store.say((await b.byHandle("yui")).id, "Eli5 string theory");
  await runAgent(b.store, (await b.byHandle("yui")).id, { provider, fetch: m2.fetch });
  assert.equal(m2.calls.length, 1);
});
