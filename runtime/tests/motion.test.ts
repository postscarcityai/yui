// MOTION-27: the film maker the native runtime ships (ported from the Hermes plugin's motion.py and motion_hero.py).
import { test } from "node:test";
import assert from "node:assert/strict";
import { block, close, harvest, heroOf, pick, putIn, seeded, split, titleOf } from "../src/motion.ts";

test("the agent's motion line is cut out; a block of ours and a line with scenes under it are left alone", () => {
  const r = split('One line.\n```yui\nmotion "How a heart pumps"\nchoose "Next?" "A"|"B"\n```');
  assert.equal(r.ask, "How a heart pumps");
  assert.equal(r.body, 'One line.\n```yui\nchoose "Next?" "A"|"B"\n```');
  assert.equal(split('x\n```yui\nmotion "Only"\n```').body, "x\n");
  assert.equal(split('```yui\nmotion "T" film=m1 part=1\n=== scene a 3 ===\nx\nend\n```').ask, null);
  assert.equal(split("just words").ask, null);
});

test("scenes are harvested once each, when the next header arrives", () => {
  const t = "=== scene a 3 ===\nline1\n=== scene b 5 ===\nline2";
  const h = harvest(t, 0);
  assert.deepEqual(h.scenes.map((s) => s.name), ["a"]);
  assert.equal(harvest(t, h.done).scenes.length, 0);
  assert.deepEqual(harvest(t + "\n=== end ===\n", h.done).scenes.map((s) => s.name), ["b"]);
});

test("rows: the first carries the title, a scene never holds a bare end line, the close carries +last", () => {
  const b = block("m1", "How it works", 1, { name: "a", dur: 3, code: "x\nend\ny" });
  assert.equal(b, '```yui\nmotion "How it works" film=m1 part=1\n=== scene a 3 ===\nx\ny\nend\n```');
  assert.equal(close("m1", 4), "```yui\nmotion film=m1 part=4 +last\n```");
  assert.equal(titleOf("A. B"), "A");
});

test("the hero: a kit word, a roast beats a chicken, a seeded drawing carries its parts, a weak word loses", () => {
  assert.equal(pick("how a heart pumps blood"), "heart");
  assert.equal(pick("how to roast a chicken with lemon"), "roast");
  assert.equal(pick("a lemon and a heart"), "heart");
  assert.equal(pick("what is inflation"), null);
  const s = seeded("how a camel stores water");
  assert.equal(s?.name, "camel");
  assert.match(s!.define, /^if \(api\.defineThing\) api\.defineThing\("camel", \[/);
  assert.equal(heroOf("string theory"), null);
});

test("the hero is written in after the look call, scene 1 big and drawn on, later scenes smaller and whole", () => {
  const hero = { name: "heart", label: "heart", define: "" };
  const one = putIn("api.look('chalk');\napi.text('x',1,2);", hero, true);
  assert.match(one, /^api\.look\('chalk'\);\nif \(api\.thing\) api\.thing\("heart", api\.w \/ 2, api\.h \* 0\.47, 280, \{k: api\.seg\(t, 0, 1\.2\)\}\);/);
  assert.match(putIn("api.text('x',1,2);", hero, false), /^if \(api\.thing\) api\.thing\("heart".*230, \{k: 1\}\);/);
  assert.equal(putIn("api.thing('heart',1,2,3);", hero, false), "api.thing('heart',1,2,3);");
});
