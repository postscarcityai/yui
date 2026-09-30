// Add agent offers the crew by name, one tap each, and never replaces anything (YUI-145).
import { test } from "node:test";
import assert from "node:assert/strict";
import { MAX_NATIVE_AGENTS } from "../src/agents.ts";
import { crewOffer, crewRefusal, describeAgents, readdSort, starter } from "../src/starters.ts";

test("the offer is every starter, Yui first, each by name and role", () => {
  const offer = crewOffer([]);
  assert.deepEqual(offer.map((o) => o.base), ["yui", "arnold", "basil", "gouda", "penny", "quill"]);
  assert.deepEqual(offer.map((o) => o.name), ["Yui", "Arnold", "Basil", "Gouda", "Penny", "Quill"]);
  assert.equal(offer.find((o) => o.base === "arnold")!.role, "Trainer");
  assert.ok(offer.every((o) => o.agentId === null));
});

test("a starter in the list carries its agent; a removed one is offered again", () => {
  const offer = crewOffer([{ agent_id: "a-yui", base: "yui" }, { agent_id: "a-gouda", base: "gouda" }, { agent_id: "a-x", base: null }]);
  assert.equal(offer.find((o) => o.base === "yui")!.agentId, "a-yui");
  assert.equal(offer.find((o) => o.base === "gouda")!.agentId, "a-gouda");
  assert.equal(offer.find((o) => o.base === "basil")!.agentId, null);
});

test("only a starter can be added, and never past the cap", () => {
  assert.equal(starter("basil")!.name, "Basil");
  assert.equal(starter("blank"), null, "blank is not a starter");
  assert.equal(starter("../yui"), null);
  assert.equal(starter(7), null);
  const offer = crewOffer([]);
  assert.equal(crewRefusal(null, "basil", 0), "native_off");
  assert.equal(crewRefusal(offer, "blank", 0), "invalid_base");
  assert.equal(crewRefusal(offer, "basil", MAX_NATIVE_AGENTS), "too_many_agents");
  assert.equal(crewRefusal(offer, "basil", 5), null);
});

test("a re-added starter goes after the crew and above every paired agent", () => {
  // Provisioning put the crew above what the person had (sorts -7..-2), paired at 0 and 1.
  const crew = [-7, -6, -4, -3, -2].map((sort) => ({ kind: "hosted", sort }));
  const paired = [{ kind: "hermes", sort: 0 }, { kind: "mcp", sort: 1 }];
  assert.equal(readdSort([...crew, ...paired]), -1);
  // Paired agents dragged right up against the crew: it still lands above them.
  assert.equal(readdSort([...crew, { kind: "hermes", sort: -2 }]), -3);
  // A new person: only the crew.
  assert.equal(readdSort(crew), -1);
  // Only paired agents left (every native one removed): the top.
  assert.equal(readdSort(paired), -1);
  assert.equal(readdSort([]), 0);
});

test("the offer says what each starter does, so Add agent can show it before the tap (YUI-165)", () => {
  const basil = crewOffer([]).find((o) => o.base === "basil")!;
  assert.equal(basil.tagline, "Eat better without counting everything");
  assert.ok(basil.about);
  assert.equal(basil.can.length, 3);
});

test("a listed agent says what it does: its own words, else its starter's, never a starter's for a custom one", () => {
  const said = describeAgents([
    { agent_id: "a-new", base: "gouda", tagline: "Beats all day", about: "Mine.", can: ["x", "y", "z"] },
    { agent_id: "a-old", base: "gouda" },
    { agent_id: "a-custom", base: "custom", tagline: null, about: null, can: null },
    { agent_id: "a-none", base: null },
  ]);
  assert.equal(said["a-new"].tagline, "Beats all day");
  assert.equal(said["a-old"].tagline, crewOffer([]).find((o) => o.base === "gouda")!.tagline, "made before profiles carried it");
  assert.deepEqual(said["a-custom"], { tagline: null, about: null, can: [] });
  assert.deepEqual(said["a-none"], { tagline: null, about: null, can: [] });
});

test("crewHello names only the crew that joined, and matches the full hello when everyone did", async () => {
  const { crewHello } = await import("../src/starters.ts");
  const all = crewHello(["arnold", "basil", "gouda", "penny", "quill"]);
  const full = (await import("node:fs")).readFileSync(new URL("../profiles/yui/first.yui", import.meta.url), "utf8").trim();
  assert.equal(all, full);
  const two = crewHello(["basil", "penny", "yui"]);
  assert.match(two, /Your crew is here: Basil feeds you and Penny keeps your lists\. Or ask me anything\./);
  assert.match(two, /"Eat better"\|"Plan my week" \+other/);
  assert.doesNotMatch(two, /Arnold|Gouda|Quill/);
  assert.match(crewHello(["yui"]), /just us for now/);
});
