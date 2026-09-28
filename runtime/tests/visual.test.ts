// Every agent's own quiet visual (YUI-180): the crew's defaults, the rule the
// stage follows, and what the list tells the app.
import { test } from "node:test";
import assert from "node:assert/strict";
import { crew, loadProfile, starters } from "../src/profiles.ts";
import { visualAgents } from "../src/starters.ts";
import { FALLBACK_VISUAL, lastVisual, stageVisual, visualDefault, visualLine, VISUAL_STRENGTH } from "../src/visual.ts";

const fence = (...lines: string[]) => "Here you go.\n```yui\n" + lines.join("\n") + "\n```";

test("every starter ships a quiet default: never full, never quick", () => {
  const picks = Object.fromEntries(starters().map((p) => [p.base, p.visual && [p.visual.look, p.visual.hears]]));
  assert.deepEqual(picks, {
    yui: ["orb", "voice"], arnold: ["waves", "music"], basil: ["bloom", "voice"],
    gouda: ["grain", "music"], penny: ["aurora", "off"], quill: ["orb", "voice"],
  });
  for (const p of starters()) {
    assert.ok(VISUAL_STRENGTH[p.visual!.strength] <= 0.7, `${p.base} draws at dim or lower`);
    assert.ok(["slow", "even"].includes(p.visual!.pace), `${p.base} is slow or even`);
  }
  assert.equal(crew().quill.visual!.strength, "faint", "Quill is study: low motion so it never distracts");
  assert.equal(crew().blank.visual, undefined, "a blank agent has no pick: it gets the fallback");
});

test("defaults resolve: own profile, else its starter's, else the soft orb", () => {
  assert.deepEqual(visualDefault(crew().basil), crew().basil.visual);
  assert.deepEqual(visualDefault({}, crew().gouda), crew().gouda.visual, "a crew agent made before defaults gets its starter's");
  assert.deepEqual(visualDefault(null), FALLBACK_VISUAL);
  assert.deepEqual(FALLBACK_VISUAL, { look: "orb", hears: "voice", strength: "faint", pace: "slow" });
  const s = stageVisual(visualDefault(crew().arnold), null);
  assert.deepEqual(s, { from: "default", look: "waves", tone: "accent", react: "music", strength: 0.7, pace: "even" });
});

test("the agent's own visual line wins over its default, at the strength it asked for", () => {
  const own = lastVisual([fence("say \"Breathe\""), fence("visual aurora react=voice", "say \"In for four\"")]);
  assert.deepEqual(own, { look: "aurora", react: "voice" });
  assert.deepEqual(stageVisual(visualDefault(crew().yui), own), { from: "agent", look: "aurora", tone: "accent", react: "voice", strength: 1 });
  assert.equal(stageVisual(FALLBACK_VISUAL, lastVisual([fence("visual")])).look, "orb", "`visual` alone is the orb");
});

test("off sticks: later turns without a visual line keep it off, a new line brings one back", () => {
  const def = visualDefault(crew().penny);
  const off = [fence("visual off"), fence("say \"Done\""), "no fence at all"];
  assert.deepEqual(stageVisual(def, lastVisual(off)), { from: "off", off: true });
  assert.equal(stageVisual(def, lastVisual([...off, fence("visual grain")])).from, "agent");
  assert.deepEqual(stageVisual(def, null, true), { from: "person", off: true }, "the person's Settings switch beats everything");
  assert.deepEqual(stageVisual(def, { look: "bloom" }, true), { from: "person", off: true });
});

test("a line that is not a whole visual never counts", () => {
  assert.equal(visualLine("visual sparkle"), null);
  assert.equal(visualLine("visual orb speed=2"), null);
  assert.equal(visualLine("visual orb react=loud"), null);
  assert.equal(visualLine("visuals orb"), null);
  assert.deepEqual(visualLine("visual waves tone=#4DA8FF react=music"), { look: "waves", tone: "#4DA8FF", react: "music" });
  assert.equal(lastVisual([fence("visual orb"), fence("visual sparkle")])!.look, "orb", "a bad line leaves the last good one");
});

test("a profile's visual is checked like the rest of it", () => {
  const files = (visual: unknown) => (f: string) => ({
    "profile.json": JSON.stringify({ name: "Tutor", handle: "tutor", role: "Spanish", color: "mint", favorites: ["ask"], visual }),
    "soul.md": "You are a patient tutor.",
    "first.yui": "Hola!\n```yui\nask \"Where are you now?\"\n```",
  } as Record<string, string>)[f] ?? null;
  assert.deepEqual(loadProfile("tutor", files({ look: "grain" })).visual, { look: "grain", hears: "voice", strength: "dim", pace: "slow" }, "the quiet choices fill in");
  assert.throws(() => loadProfile("tutor", files({ look: "sparkle" })), /visual look must be one of/);
  assert.throws(() => loadProfile("tutor", files({ look: "orb", strength: "full" })), /a default is never full/);
  assert.throws(() => loadProfile("tutor", files({ look: "orb", pace: "quick" })), /never runs quick/);
  assert.throws(() => loadProfile("tutor", files({ look: "orb", hears: "loud" })), /visual hears must be one of/);
});

test("the list tells the app each native agent's visual, with the line it would be", () => {
  const out = visualAgents([
    { agent_id: "a1", base: "gouda", visual: crew().gouda.visual },
    { agent_id: "a2", base: "quill" }, // made before defaults: its starter's
    { agent_id: "a3", base: "custom" }, // made by Yui, no pick
    { agent_id: "a4", base: "custom", visual: { look: "aurora", hears: "mic", strength: "faint", pace: "slow", tone: "sky" } },
  ]);
  assert.deepEqual(out.a1.visual, { look: "grain", hears: "music", strength: "dim", pace: "even", tone: "accent", line: "visual grain react=music" });
  assert.equal(out.a2.visual.line, "visual orb");
  assert.equal(out.a2.visual.strength, "faint");
  assert.deepEqual(out.a3.visual, { look: "orb", hears: "voice", strength: "faint", pace: "slow", tone: "accent", line: "visual orb" });
  assert.equal(out.a4.visual.line, "visual aurora tone=sky react=mic");
});
