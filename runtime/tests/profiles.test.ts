// The profile folder format (YUI-133): the loader, its checks, and Yui's own first turn.
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { crew, loadProfile, PROFILE_FILES } from "../src/profiles.ts";
import { extract } from "../src/directives.ts";
import { runAgent } from "../src/turn.ts";
import { fakeModel, freshYui, provider, system } from "./helpers.ts";

const dir = new URL("../profiles/", import.meta.url).pathname;
const fromDisk = (base: string) => (f: string) => (existsSync(join(dir, base, f)) ? readFileSync(join(dir, base, f), "utf8") : null);
const files = (over: Record<string, string | null> = {}) => {
  const base: Record<string, string | null> = {
    "profile.json": JSON.stringify({ name: "Tutor", handle: "tutor", role: "Spanish", version: 2, color: "mint", favorites: ["deck", "ask"] }),
    "soul.md": "You are a patient Spanish tutor.\n",
    "first.yui": "Hola! Where are you now?\n```yui\nchoose \"Your level\" New|Some|Fluent\n```\n",
  };
  const all = { ...base, ...over };
  return (f: string) => all[f] ?? null;
};

test("every folder in profiles/ loads, and the baked crew is exactly what the folders say", () => {
  const bases = readdirSync(dir).filter((b) => !b.startsWith("."));
  assert.deepEqual(bases.sort(), Object.keys(crew()).sort());
  for (const b of bases) assert.deepEqual(loadProfile(b, fromDisk(b)), crew()[b], b);
});

test("a folder loads into a profile with defaults filled in", () => {
  const p = loadProfile("tutor", files());
  assert.equal(p.name, "Tutor");
  assert.equal(p.version, 2);
  assert.equal(p.model, "default");
  assert.equal(p.soul, "You are a patient Spanish tutor.");
  assert.ok(p.first.startsWith("Hola!") && p.first.endsWith("```"));
  assert.equal(p.shelf, undefined, "flags only appear when set");
});

test("a missing file is named", () => {
  assert.throws(() => loadProfile("tutor", files({ "soul.md": null, "first.yui": null })), /tutor: missing soul\.md, first\.yui/);
  assert.deepEqual([...PROFILE_FILES], ["profile.json", "soul.md", "first.yui"]);
});

test("broken profile.json says which folder", () => {
  assert.throws(() => loadProfile("tutor", files({ "profile.json": "{ name: " })), /^Error: tutor\/profile\.json:/);
});

test("the checks turn down a bad handle, version, color, favorite, soul or first screen", () => {
  const meta = (m: object) => files({ "profile.json": JSON.stringify({ name: "T", favorites: [], ...m }) });
  assert.throws(() => loadProfile("tutor", meta({ handle: "Tutor Bot" })), /handle "Tutor Bot"/);
  assert.throws(() => loadProfile("tutor", meta({ version: 0 })), /version/);
  assert.throws(() => loadProfile("tutor", meta({ color: "red" })), /color must be one of/);
  assert.throws(() => loadProfile("tutor", meta({ favorites: ["hologram"] })), /favorites not drawn by the app: hologram/);
  assert.throws(() => loadProfile("tutor", files({ "soul.md": "  " })), /soul\.md is empty/);
  assert.throws(() => loadProfile("tutor", files({ "soul.md": "x".repeat(4001) })), /over 4000/);
  assert.throws(() => loadProfile("tutor", files({ "soul.md": "Kind — and quick." })), /no em dashes/);
});

test("a first answer is a line of text and a real screen", () => {
  assert.throws(() => loadProfile("tutor", files({ "first.yui": "Hola!" })), /needs a ```yui fence/);
  assert.throws(() => loadProfile("tutor", files({ "first.yui": "Hola!\n```yui\nhologram \"Hi\"\n```" })), /opens with "hologram"/);
  assert.throws(() => loadProfile("tutor", files({ "first.yui": "```yui\nchoose \"Level\" A|B\n```" })), /line of text before its screen/);
});

test("Yui is a helper and a maker, and her first answer asks a real question on a screen", () => {
  const yui = crew().yui;
  assert.equal(yui.role, "Helper and maker");
  assert.ok(yui.maker && !yui.shelf);
  assert.match(yui.soul, /helper and their maker/);
  const { text } = extract(yui.first);
  const screen = text.match(/```yui\n([\s\S]+?)\n```/)![1];
  assert.match(screen, /^choose "Where do you want to start\?" .+\+other$/);
});

test("Yui answers a first turn locally, from her own folder", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const opened = store.data.rows.filter((r) => r.agent_id === yui.id);
  assert.equal(opened.length, 1, "Yui opens the thread with her first answer");
  assert.equal(opened[0].body, crew().yui.first);

  store.say(yui.id, "[yui] q1 choose choice=\"Plan my week\"", "event");
  const m = fakeModel(() => "Let's plan it.\n```yui\nplan \"Your week\"\nlist \"Must do\" +check\nend\n```");
  const r = await runAgent(store, yui.id, { provider, fetch: m.fetch });
  assert.equal(r.turns, 1);
  const s = system(m.calls[0]);
  assert.match(s, /## Who you are: Yui, helper and maker\n\nYou are Yui, the first agent/);
  assert.match(s, /Screens you reach for first: `choose`, `plan`, `list`, `card`, `shapes`/);
  const reply = store.data.rows.find((x) => x.id === r.replies[0])!;
  assert.match(reply.body, /```yui\nplan "Your week"/);
});
