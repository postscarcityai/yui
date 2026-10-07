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

// ---- MOTION-29: the hero drawn on demand, and learned ----
import { LocalStore } from "../src/store.ts";
import { NO_KEPT, buildParts, drawNew, learn, learnWords, make, nounId, parseReply, promptFor, worthLearning } from "../src/motion.ts";

const CAMEL = [
  { s: "ellipse", x: 0, y: 6, rx: 34, ry: 18, f: "a2" }, { s: "circle", x: -6, y: -14, r: 12, f: "warn" },
  { s: "poly", p: [[30, -4], [48, -34], [58, -30], [44, 4]], f: "accent", smooth: true }, { s: "rect", x: -20, y: 34, w: 8, h: 30, f: "panel" },
  { s: "rect", x: 20, y: 34, w: 8, h: 30, f: "panel" }, { s: "line", p: [[-30, 20], [30, 20]], w: 1.5 }, { s: "circle", x: 34, y: -36, r: 8, f: "a2" },
];
const reply = (noun: string, parts: unknown = CAMEL) => JSON.stringify({ noun, parts });

test("parts: only the shape vocabulary is read, numbers are clamped, a loose or flat drawing is refused", () => {
  const p = buildParts(CAMEL)!;
  assert.equal(p.length, 7);
  assert.deepEqual(p[5], ["M-30 20 L30 20", 0, "fg", 1.5]);
  assert.equal(buildParts(CAMEL.slice(0, 4)), null, "under five shapes");
  assert.equal(buildParts([...CAMEL.slice(0, 6), { s: "path", d: "M0 0" }]), null, "no free-form paths");
  assert.equal(buildParts([...CAMEL.slice(0, 6), { s: "circle", x: 1, y: 1, r: 4, f: "pink" }]), null, "fills are the kit's");
  assert.equal(buildParts(CAMEL.map((x) => ({ ...x, f: "panel" }))), null, "needs three fills");
  assert.equal((buildParts([...CAMEL.slice(0, 6), { s: "circle", x: 9999, y: 0, r: 4, f: "bad" }])!.at(-1)![0] as string).startsWith("M66"), true);
  assert.equal(nounId("Snare Drum!"), "snare_drum");
  assert.equal(nounId("x"), null);
});

test("the reply: a noun with parts, a kit thing by its name, no body, and junk", () => {
  assert.deepEqual(parseReply(reply("camel")), { name: "camel", label: "camel", parts: buildParts(CAMEL) });
  assert.deepEqual(parseReply(reply("heart", [])), { name: "heart", label: "heart", parts: null });
  assert.deepEqual(parseReply('{"noun":null}'), {});
  assert.equal(parseReply("sorry"), null);
  assert.equal(parseReply(reply("camel", [{ s: "ellipse" }])), null);
  assert.ok(parseReply(reply("camel") + '\n{"another":1}'), "a second object after the first is ignored");
});

test("drawNew: a drawn hero registers itself in the scene, a failure or a slow call is no hero, off is off", async () => {
  const h = await drawNew("how a camel stores water", async () => reply("camel"));
  assert.equal(h?.name, "camel");
  assert.match(h!.define, /^if \(api\.defineThing\) api\.defineThing\("camel", \[\["M/);
  assert.equal(await drawNew("what is inflation", async () => '{"noun":null}'), null);
  assert.equal(await drawNew("x", async () => { throw new Error("down"); }), null);
  assert.equal(await drawNew("x", () => new Promise(() => {}), 20), null, "slow: no hero, and nothing waits");
  process.env.YUI_MOTION_THINGS = "off";
  try { assert.equal(await drawNew("a camel", async () => reply("camel")), null); } finally { delete process.env.YUI_MOTION_THINGS; }
});

test("learned words are narrow: the name and its plural, a two-word name also answers to its last word", () => {
  const re = (w: string) => new RegExp(`\\b(?:${w})\\b`, "i");
  assert.ok(re(learnWords("kayak")!).test("a Kayak trip") && re(learnWords("kayak")!).test("two kayaks"));
  assert.equal(re(learnWords("kayak")!).test("kayak paddle"), true);
  assert.equal(re(learnWords("snare drum")!).test("how a drum works"), true);
  assert.equal(re(learnWords("kayak paddle")!).test("the kayak"), false);
  assert.equal(learnWords("cell"), null);
  assert.equal(learnWords("one two three"), null);
  assert.equal(re(learnWords("pony")!).test("two ponies"), true);
});

test("a kept drawing is a seed hit: the ask finds it, and a film needs no drawing call", async () => {
  const kept = { things: { kayak: { label: "kayak", parts: buildParts(CAMEL)! } }, words: { kayak: learnWords("kayak")! } };
  assert.equal(heroOf("how does a kayak stay upright", kept)?.name, "kayak");
  assert.equal(heroOf("how does a kayak stay upright"), null);
  process.env.YUI_MOTION_LEARN = "off";
  try { assert.equal(heroOf("how does a kayak stay upright", { things: { kayak: kept.things.kayak }, words: { kayak: learnWords("kayak")! } }), null, "learning off: kept words are ignored"); }
  finally { delete process.env.YUI_MOTION_LEARN; }
  const prompts: string[] = [];
  const codes: string[] = [];
  const n = await make("how does a kayak stay upright", "m1", async (p, on) => { prompts.push(p); on("=== scene a 3 ===\napi.look('chalk');\n=== end ==="); },
    async (b) => { codes.push(b); }, async () => {}, { kept, say: async () => { throw new Error("no call needed"); } });
  assert.equal(n, 1);
  assert.match(prompts[0], /ALREADY drawn the hero of this ask, a kayak/);
  assert.match(codes[0], /api\.defineThing\("kayak"/);
});

test("a film draws the noun beside the writer, puts it in scene 1, and tells the learner", async () => {
  let told: unknown = "unset";
  const codes: string[] = [];
  const prompts: string[] = [];
  const n = await make("how a wombat digs a burrow", "m2", async (p, on) => { prompts.push(p); on("=== scene hook 4 ===\napi.look('chalk');\n=== scene two 4 ===\napi.text('x',1,2);\n=== end ==="); },
    async (b) => { codes.push(b); }, async () => {},
    { say: async () => { await new Promise((r) => setTimeout(r, 30)); return reply("sand camel"); }, drew: (h) => { told = h; } });
  assert.equal(n, 2);
  assert.match(prompts[0], /if the ask is about one physical thing with a body/);
  assert.match(codes[0], /api\.defineThing\("sand_camel"[\s\S]*api\.thing\("sand_camel", api\.w \/ 2, api\.h \* 0\.47, 280/);
  assert.match(codes[1], /api\.thing\("sand_camel".*230/);
  assert.equal((told as any).name, "sand_camel");
  assert.equal(worthLearning(told as any, NO_KEPT), true);
  assert.equal(worthLearning({ name: "heart", label: "heart", define: "" }, NO_KEPT), false, "a kit thing");
  assert.equal(worthLearning({ name: "cell", label: "cell", define: "x" }, NO_KEPT), false, "an ambiguous word");
  assert.equal(worthLearning(null, NO_KEPT), false);
});

test("a film whose drawing fails is made without a hero, and nothing is learned", async () => {
  let told: unknown = "unset";
  const codes: string[] = [];
  const n = await make("how a wombat digs a burrow", "m3", async (_p, on) => on("=== scene hook 4 ===\napi.look('chalk');\n=== end ==="),
    async (b) => { codes.push(b); }, async () => {}, { say: async () => { throw new Error("down"); }, drew: (h) => { told = h; } });
  assert.equal(n, 1);
  assert.doesNotMatch(codes[0], /api\.thing/);
  assert.equal(told, null);
});

test("the learner: the store holds the caps, a noun is drawn for the judge, a wrong or empty reply is failed after one retry", async () => {
  const store = new LocalStore();
  assert.equal(await learn("sloth", store.learner(), async () => reply("sloth")), "drawn");
  const r = store.data.motion!.sloth;
  assert.equal(r.status, "drawn");
  assert.equal(r.parts!.length, 7);
  assert.match(r.words!, /sloth/);
  assert.equal((await store.motionKept()).things.sloth, undefined, "not kept until the judge says so");
  assert.equal(await learn("sloth", store.learner(), async () => reply("sloth")), "capped or known", "already drawn");
  let calls = 0;
  assert.equal(await learn("kayak", store.learner(), async () => { calls++; return reply("canoe"); }), "parts named canoe");
  assert.equal(calls, 2, "one retry");
  assert.equal(store.data.motion!.kayak.status, "failed");
  assert.equal(await learn("kayak", store.learner(), async () => reply("kayak")), "drawn", "a second try is allowed once");
  store.data.motion!.kayak.status = "failed";
  assert.equal(await learn("kayak", store.learner(), async () => reply("kayak")), "capped or known", "never a third");
  assert.equal(await learn("cell", store.learner(), async () => reply("cell")), "not learnable");
  assert.equal(await learn("heart", store.learner(), async () => reply("heart")), "not learnable", "the kit has it");
  assert.equal(await learn("anvil", store.learner(), async () => { throw new Error("down"); }), "no parts");
});

test("the learner: 2 in flight, 20 a day, off with YUI_MOTION_LEARN", async () => {
  const store = new LocalStore();
  assert.equal(await store.motionClaim("sloth", 20, 2), true);
  assert.equal(await store.motionClaim("walrus", 20, 2), true);
  assert.equal(await store.motionClaim("anvil", 20, 2), false, "two drawings under way");
  const day = new LocalStore();
  for (let i = 0; i < 3; i++) { await day.motionClaim("n" + "abcdefg"[i], 3, 5); await day.motionPut("n" + "abcdefg"[i], null, null, null, "x"); }
  assert.equal(await day.motionClaim("nzz", 3, 5), false, "the day is used up");
  process.env.YUI_MOTION_LEARN = "off";
  try { assert.equal(await learn("sloth2", new LocalStore().learner(), async () => reply("sloth2")), "off"); } finally { delete process.env.YUI_MOTION_LEARN; }
});

test("the prompt tells the writer a drawing is coming only when the hero is not known yet", () => {
  assert.doesNotMatch(promptFor("x", null), /HERO: if the ask|ALREADY drawn the hero/);
  assert.match(promptFor("x", null, true), /HERO: if the ask/);
});
