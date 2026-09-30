// VIS-3: the native crew's one-line gate. The cases are hermes-plugin/tests/test_oneline.py, ported.
import { test } from "node:test";
import assert from "node:assert/strict";
import { clip, gate, LINE_WORDS, measure, oneLineMode, rewrite, violates } from "../src/oneline.ts";
import { runAgent } from "../src/turn.ts";
import { fakeModel, freshYui, provider } from "./helpers.ts";

const WALL = "You're right, I misread you. You meant the left drawer, not TestFlight.\n\n"
  + "The drawer had stopped updating. One card with badly saved text crashed every refresh, so a finished card stayed under Now. "
  + "I fixed the crash and the drawer is current again.\n\n"
  + "```yui\nsketch \"Left drawer\" frame=phone\nrow \"Daily release  ·  Now\" +hi\n```\n\n"
  + "A new card covers the rest. It is on the board and not built yet.";

test("measure counts words, bubbles and the picture", () => {
  const m = measure(WALL);
  assert.equal(m.bubbles, 3);
  assert.ok(m.picture);
  assert.ok(m.words > 50);
});

test("one line and a picture is fine; no prose and a code fence are left alone", () => {
  const body = "Yes, build 160.\n```yui\nsketch \"Build\" frame=bubble\nrow \"160: newest\" +hi\n```";
  assert.equal(violates(measure(body)), false);
  assert.equal(rewrite(body), null);
  assert.equal(rewrite("```yui\ntimer 5m Plank\n```"), null);
  assert.equal(rewrite("Run it like this. ".repeat(12) + "\n\n```bash\nls\n```"), null);
});

test("a wall becomes one line and its picture", () => {
  const n = rewrite(WALL)!;
  const m = measure(n);
  assert.equal(m.bubbles, 1);
  assert.ok(m.words <= LINE_WORDS);
  assert.ok(m.picture);
  assert.ok(n.startsWith("You're right, I misread you."));
  assert.ok(n.includes('sketch "Left drawer"'));
});

test("prose only gets a sketch", () => {
  const n = rewrite("The board is fine. Three cards run, two are blocked on a pick, and the site deploy is green. "
    + "The blocked ones need your call. Nothing else is waiting on you today.")!;
  assert.ok(n.startsWith("The board is fine."));
  assert.ok(n.includes("```yui\nsketch "));
  assert.ok(measure(n).picture);
  assert.equal(measure(n).bubbles, 1);
});

test("the question is kept", () => {
  const n = rewrite("Done with the fix. " + "It touched several files and the tests pass. ".repeat(4) + "Want it in the next build?")!;
  assert.ok(n.split("\n")[0].includes("Want it in the next build?"));
});

test("a second bubble in a turn is picture only", () => {
  const n = rewrite("Here is the rest of it.\n```yui\nstat 12 Cards\n```", 1)!;
  assert.equal(measure(n).bubbles, 0);
  assert.ok(n.includes("stat 12 Cards"));
});

test("filler leads go, even on a short reply", () => {
  assert.ok(rewrite("So, the drawer is fixed. " + "It was a crash in one card. ".repeat(6))!.startsWith("The drawer is fixed."));
  assert.ok(rewrite("Got it. Short text plus a drawing.\n```yui\nsketch \"Rule\" frame=bubble\nrow \"Text + drawing\" +hi\n```")!
    .startsWith("Short text plus a drawing."));
});

test("an image is not a drawing; a clip never ends in an ellipsis", () => {
  assert.equal(measure("Here.\n```yui\nimage /tmp/a.png Shot\n```").picture, false);
  const c = clip("one two three four five six seven eight nine ten, eleven twelve thirteen", 10);
  assert.ok(!c.includes("…"));
  assert.ok(c.split(" ").length <= 10);
});

test("modes: shadow keeps the reply, on sends the rewrite, off skips; counts only", () => {
  const s = gate(WALL, 0, "shadow");
  assert.equal(s.body, WALL);
  assert.equal(s.action, "would-rewrite");
  const o = gate(WALL, 0, "on");
  assert.notEqual(o.body, WALL);
  assert.equal(o.after!.bubbles, 1);
  assert.equal(gate(WALL, 0, "off").body, WALL);
  assert.equal(oneLineMode("on"), "on");
  assert.equal(oneLineMode("nope"), "shadow");
  assert.equal(oneLineMode(undefined), "shadow");
});

test("a native turn: shadow saves the wall and counts it; on saves one line", async () => {
  for (const mode of ["shadow", "on"] as const) {
    const { store, byHandle } = await freshYui();
    const yui = await byHandle("yui");
    store.say(yui.id, "How is my week?");
    const m = fakeModel(() => WALL);
    await runAgent(store, yui.id, { provider, fetch: m.fetch, oneLine: mode });
    const row = store.data.rows.filter((r: any) => r.agent_id === yui.id && r.sender === "agent").pop() as any;
    assert.ok(row, "a reply was saved");
    assert.equal(row.meta.native.oneline.action, mode === "on" ? "rewrote" : "would-rewrite");
    assert.equal(row.meta.native.oneline.bubbles, 3);
    if (mode === "on") assert.equal(measure(row.body).bubbles, 1);
    else assert.ok(row.body.includes("A new card covers the rest."));
  }
});
