// An agent's home (YUI-168, yuigui spec/HOME.md): home.yui in each starter, its checks,
// the row written once, the ids of the person's other agents, and the prompt that keeps it current.
import { test } from "node:test";
import assert from "node:assert/strict";
import { checkHome, homeBody, homesToWrite, homeLines } from "../src/home.ts";
import { crew, loadProfile } from "../src/profiles.ts";
import { homePrompt } from "../src/prompt.ts";
import { cards } from "../src/handoff.ts";
import { runAgent } from "../src/turn.ts";
import { fakeModel, freshYui, provider, system } from "./helpers.ts";

const shortcuts = (home: string) => homeLines(home).filter((l) => l.startsWith("menu shortcut"))
  .map((l) => l.match(/"([^"]+)"/)![1]);

test("every starter has a home: its shortcuts in chip order and its starter screens (card YUI-168)", () => {
  const want: Record<string, { chips: string[]; pages: string[] }> = {
    arnold: { chips: ["Start a workout", "My split", "Log a workout", "Progress"], pages: ["2", "3", "4"] },
    basil: { chips: ["Plan my meals", "Log a meal", "This week", "Grocery list"], pages: ["2", "3", "4"] },
    gouda: { chips: ["Learn a song", "Log practice", "Jam", "Tune up"], pages: ["2", "3", "4", "5", "6"] },
    penny: { chips: ["Plan my week", "Add a to-do", "What's next?", "Evening review"], pages: ["2", "3"] },
    quill: { chips: ["Review my cards", "Learn something new", "Walk me through a problem", "What's due?"], pages: ["2", "3", "4"] },
    yui: { chips: ["Add an agent", "What's new"], pages: ["2"] },
  };
  for (const [b, w] of Object.entries(want)) {
    const home = crew()[b].home!;
    assert.ok(home, `${b} has a home`);
    // The chips show newest first, so the file lists them last to first.
    assert.deepEqual(shortcuts(home).reverse(), w.chips, `${b}: chips`);
    assert.deepEqual(homeLines(home).filter((l) => /^>\d+$/.test(l)).map((l) => l.slice(1)), w.pages, `${b}: pages`);
    assert.deepEqual(checkHome(home), [], b);
  }
  assert.equal(crew().blank.home, undefined, "a blank agent writes its own");
  // Arnold's This week and Today's workout; Gouda's instruments sit on their pages ready to play.
  assert.match(crew().arnold.home!, /save this week[\s\S]*>3[\s\S]*card@today "Today's workout"/);
  for (const i of ["loop@looper", "chords@chords", "keys@keys"]) assert.match(crew().gouda.home!, new RegExp(`${i} .*\\+inline`));
  assert.match(crew().basil.home!, /say="Log a meal: "/, "Log a meal fills the composer to finish");
});

test("the checks turn down a home with too few or too many chips, a chat route, a clear or an em dash", () => {
  const two = 'menu shortcut "A"\nmenu shortcut "B"\n';
  assert.deepEqual(checkHome(two + ">2\nlist x"), []);
  assert.match(checkHome('menu shortcut "A"\n>2\nlist x').join(), /2 to 4 shortcuts, has 1/);
  assert.match(checkHome(two + 'menu shortcut "C"\nmenu shortcut "D"\nmenu shortcut "E"\n>2\nlist x').join(), /has 5/);
  assert.match(checkHome(two + ">full\nlist x").join(), /not >full/);
  assert.match(checkHome(two + "list x").join(), /at least one starter screen/);
  assert.match(checkHome(two + ">2\n>2 clear").join(), /never clears/);
  assert.match(checkHome(two + '>2\ncard "A — B"').join(), /no em dashes/);
  const files = (home: string) => (f: string) => ({
    "profile.json": JSON.stringify({ name: "T", favorites: [] }), "soul.md": "Kind.", "first.yui": "Hi.\n```yui\nask Go\n```", "home.yui": home,
  } as Record<string, string>)[f] ?? null;
  assert.throws(() => loadProfile("t", files('menu shortcut "A"\n>2\nlist x')), /^Error: t: home.yui needs 2 to 4 shortcuts/);
  assert.equal(loadProfile("t", files("# a comment\n" + two + ">2\nlist x")).home, "# a comment\n" + two.trim() + "\n>2\nlist x");
});

test("the row's body: comments out, the person's agents filled in, a line for one they don't have left out", () => {
  const body = homeBody(crew().yui, { arnold: "a-1", basil: "b-2", gouda: "g-3", penny: "p-4" })!;
  assert.ok(body.startsWith("```yui\nmenu shortcut@new") && body.endsWith("\n```"));
  assert.doesNotMatch(body, /^#/m);
  assert.match(body, /url=yui:\/\/agent\/a-1\/thread/);
  assert.doesNotMatch(body, /Quill/, "no Quill in this list, so no card for Quill");
  assert.doesNotMatch(body, /\{/);
  assert.equal(homeBody({}), null);
});

test("homes to write: each native agent once, a crew agent from before homes gets its starter's", () => {
  const rows = [
    { agent_id: "y", base: "yui" },
    { agent_id: "a", base: "arnold", home_at: "2026-09-27T20:00:00Z" },
    { agent_id: "b", base: "basil", home: null },
    { agent_id: "c", base: "custom" },
    { agent_id: "l", base: "custom", home: 'menu shortcut "A"\nmenu shortcut "B"\n>2\nlist x' },
  ];
  const out = homesToWrite(rows, (b) => crew()[b]?.home);
  assert.deepEqual(out.map((h) => h.agentId), ["y", "b", "l"], "Arnold's is written, a custom agent without one gets none");
  assert.match(out[0].body, /yui:\/\/agent\/a\/thread/, "Yui's crew page opens the person's own Arnold");
  assert.match(out[1].body, /list@aisle-produce title="Produce" "Spinach"\|"Berries" \+check/);
});

test("a new agent's thread opens on its home, then its hello; the model sees its home to keep it current", async () => {
  const { store, byHandle } = await freshYui();
  const arnold = await byHandle("arnold");
  const rows = store.data.rows.filter((r) => r.agent_id === arnold.id);
  assert.deepEqual(rows.map((r) => r.meta?.native), ["home", "first"]);
  assert.match(rows[0].body, /^```yui\nmenu shortcut@progress "Progress" show="progress"\n[\s\S]*menu shortcut@split "My split" show="this week"/);
  assert.ok(arnold.profile.home_at, "written once");

  store.say(arnold.id, "I did legs today", "text");
  const m = fakeModel(() => "Logged.\n```yui\n~days \"Thu Legs\" +check\n```");
  await runAgent(store, arnold.id, { provider, fetch: m.fetch });
  const s = system(m.calls[0]);
  assert.match(s, /### Your home\n/);
  assert.match(s, /list@days title="This week"/);
  assert.match(s, /Never send the whole home again/);
});

test("the home prompt: a crew agent from before homes uses its starter's; custom and blank agents have none", () => {
  const { home: _, ...old } = crew().basil;
  assert.match(homePrompt(old)!, /stat@kcal/);
  assert.equal(homePrompt({ ...crew().blank, base: "custom" }), null);
  assert.equal(homePrompt(crew().blank), null);
});

test("Arnold's kickoff builds a split: days, which days, how to split them (or his own), gear, injuries", () => {
  const a = crew().arnold;
  const screen = a.first.match(/```yui\n([\s\S]+?)\n```/)![1].split("\n");
  assert.equal(screen[0], 'plan "Build your split"');
  assert.match(screen[1], /^choose "How many days a week\?" 2\|3\|4\|5\|6$/);
  assert.match(screen[2], /^pick "Which days\?" Mon\|Tue\|Wed\|Thu\|Fri\|Sat\|Sun$/);
  assert.match(screen[3], /"Push, pull, legs"\|"Upper, lower"\|"Full body"\|"Build my own" \+other$/);
  assert.match(screen[4], /^pick "What do you have\?"/);
  assert.match(screen[5], /^choose "Any injuries or conditions\?"/);
  assert.equal(screen[6], "end");
  assert.match(a.soul, /plan "Your days"/, "his own split: a choose per day");
  assert.match(a.soul, /~days "Mon Push" "Wed Pull"/, "and This week is patched from it");
});

test("Yui's crew cards open an agent, they are not hand-offs (YUI-144)", () => {
  const home = homeBody(crew().yui, { arnold: "a-1", basil: "b-2", gouda: "g-3", penny: "p-4", quill: "q-5" });
  assert.match(home!, /yui:\/\/agent\/a-1\/thread/);
  assert.deepEqual(cards(home!.includes("```yui") ? home! : "```yui\n" + home + "\n```"), []);
  assert.deepEqual(cards('```yui\ncard "Basil" body="x" url=yui://agent/basil\n```').map((c) => c.target), ["basil"]);
});
