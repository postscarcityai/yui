// Profiles, the runtime's own blocks, and memory: the pure parts.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { checkProfile, crew, shelf, starters } from "../src/profiles.ts";
import { agentLine, extract, memoryLine } from "../src/directives.ts";
import { applyMemory, MAX_NOTES, memoryPrompt, notesOf } from "../src/memory.ts";
import type { MemoryItem } from "../src/types.ts";

test("every built-in profile passes its own check", () => {
  for (const [base, p] of Object.entries(crew())) assert.deepEqual(checkProfile(p), [], base);
});

test("everyone starts with Yui first, then the crew", () => {
  assert.deepEqual(starters().map((p) => p.handle), ["yui", "arnold", "basil", "gouda", "penny", "quill"]);
  assert.ok(crew().yui.maker);
  assert.ok(crew().arnold.careful && crew().basil.careful);
  assert.ok(shelf().some((p) => p.blank), "start blank is on the shelf");
  assert.ok(!shelf().some((p) => p.handle === "yui"), "Yui is not on the shelf");
});

test("a profile with an unknown screen, a bad color or no first screen is turned down", () => {
  const p = { ...crew().gouda, favorites: ["loop", "hologram"], color: "red" as any, first: "hi" };
  const bad = checkProfile(p).join(" | ");
  assert.match(bad, /hologram/);
  assert.match(bad, /color/);
  assert.match(bad, /fence/);
});

test("the build output is current", () => {
  execFileSync("node", [new URL("../scripts/build.mjs", import.meta.url).pathname, "--check"], { stdio: "pipe" });
});

test("remember and agents blocks leave the reply", () => {
  const r = extract("Nice to meet you, Sam.\n```remember\nme: name = Sam\nnote: wants to run a 5k\n```\n```yui\nsay Hi\n```\n```agents\nmake gouda\n```");
  assert.equal(r.text, "Nice to meet you, Sam.\n\n```yui\nsay Hi\n```");
  assert.deepEqual(r.memory, [{ op: "about", key: "name", body: "Sam" }, { op: "note", body: "wants to run a 5k" }]);
  assert.deepEqual(r.agents, [{ op: "make", target: "gouda", args: {} }]);
});

test("memory lines", () => {
  assert.deepEqual(memoryLine("me: Allergies = peanuts, shellfish"), { op: "about", key: "allergies", body: "peanuts, shellfish" });
  assert.deepEqual(memoryLine("forget n3"), { op: "forget_note", ref: "n3" });
  assert.deepEqual(memoryLine("forget me allergies"), { op: "forget_about", key: "allergies" });
  assert.equal(memoryLine("remember everything"), null);
});

test("agent lines: shelf, new, fork, rename, remove, self", () => {
  assert.deepEqual(agentLine("make gouda"), { op: "make", target: "gouda", args: {} });
  const m = agentLine('make "Spanish tutor" color=mint favorites=ask,deck soul="You are \\"Profe\\", patient."')!;
  assert.equal(m.name, "Spanish tutor");
  assert.equal(m.target, undefined);
  assert.deepEqual(m.args, { color: "mint", favorites: "ask,deck", soul: 'You are "Profe", patient.' });
  assert.deepEqual(agentLine('fork arnold "Arnold 2" soul="gentler"'), { op: "fork", target: "arnold", name: "Arnold 2", args: { soul: "gentler" } });
  assert.deepEqual(agentLine('rename quill "Professor Q"'), { op: "rename", target: "quill", name: "Professor Q", args: {} });
  assert.deepEqual(agentLine("remove penny"), { op: "remove", target: "penny", args: {} });
  assert.equal(agentLine("rename quill"), null);
  assert.equal(agentLine("launch rockets"), null);
  assert.deepEqual(agentLine('self name="Luna" color=butter'), { op: "self", args: { name: "Luna", color: "butter" } });
});

let n = 0;
const id = () => `m${++n}`;

test("memory: notes, facts, forgetting, and the prompt numbers", () => {
  let items: MemoryItem[] = [];
  const apply = (ops: any[], agent = "a1") => {
    const c = applyMemory(items, agent, ops, `2026-09-27T00:00:${String(n).padStart(2, "0")}Z`, id);
    const gone = new Set([...c.drop, ...c.put.map((p) => p.id)]);
    items = [...items.filter((i) => !gone.has(i.id)), ...c.put];
  };
  apply([{ op: "note", body: "trains mornings" }, { op: "note", body: "Trains mornings" }, { op: "about", key: "name", body: "Sam" }]);
  assert.equal(notesOf(items, "a1").length, 1, "the same note twice is kept once");
  apply([{ op: "about", key: "name", body: "Samantha" }, { op: "note", body: "5k in May" }]);
  assert.equal(items.filter((i) => i.kind === "about").length, 1, "a fact is replaced, not added");
  const prompt = memoryPrompt(items, "a1");
  assert.match(prompt, /- name: Samantha/);
  assert.match(prompt, /\[n1\] trains mornings/);
  assert.match(prompt, /\[n2\] 5k in May/);
  assert.doesNotMatch(memoryPrompt(items, "a2"), /trains mornings/, "notes are the agent's own");
  assert.match(memoryPrompt(items, "a2"), /Samantha/, "the about-you card is shared");
  apply([{ op: "forget_note", ref: "n1" }, { op: "forget_about", key: "name" }]);
  assert.deepEqual(notesOf(items, "a1").map((x) => x.body), ["5k in May"]);
  assert.equal(items.some((i) => i.kind === "about"), false);
  apply(Array.from({ length: MAX_NOTES + 5 }, (_, i) => ({ op: "note", body: `note ${i}` })));
  assert.equal(notesOf(items, "a1").length, MAX_NOTES, "the oldest notes make room");
});

test("a remember block with no fence at the end of a reply is taken, not shown (GLM, YUI-141)", () => {
  const reply = "```yui\nstat@kcal1 720kcal Calories\n```\n\nremember\nnote: [n2] meal1 - poke bowl, ~720kcal\n";
  const x = extract(reply);
  assert.equal(x.text, "```yui\nstat@kcal1 720kcal Calories\n```");
  assert.equal(x.memory.length, 1);
  // A word in the middle of the text is only a word.
  assert.equal(extract("Things to remember\nabout lunch").text, "Things to remember\nabout lunch");
  assert.equal(extract("I'll search\nfor it").text, "I'll search\nfor it");
});
