// YUI-186: Quill's tools. Learn a topic (a lesson deck ending in a quiz, its cards kept), cards with spaced review,
// walk me through a problem one step a page, and his default screens (What you're studying, Next review, Progress).
// Every test goes through runAgent on the store a person's rows go through (not a demo memory), every reply is read
// by the real Yui Lines parser, and a relaunch reads everything back from the saved data. The model is asked only
// for a lesson or a problem's steps, as JSON; everything else is answered from his tables.
import { test } from "node:test";
import assert from "node:assert/strict";
import { runAgent } from "../src/turn.ts";
import { LocalStore } from "../src/store.ts";
import { clock, fromSeeds } from "../src/tables.ts";
import { homeLines } from "../src/home.ts";
import { crew } from "../src/profiles.ts";
import { LESSON_PROMPT, PROBLEM_PROMPT, RATE_OPTS, dueCards, parseLesson, parseProblem, progressScreen, reviewScreen, schedule, studyAsks,
         studyingScreen } from "../src/study.ts";
import { fakeModel, freshYui, provider, system } from "./helpers.ts";
// @ts-ignore: the parser the app and the site share, as the MCP server ships it
import { parse } from "../../supabase/functions/yui-mcp/yl.mjs";

const MON = Date.parse("2026-09-28T16:00:00Z"); // Monday, noon in New York
const now = () => MON;
const clk = clock(MON, "America/New_York");
const noModel = () => fakeModel(() => {
  throw new Error("no model call expected");
});
const agentRows = (store: any, id: string) => store.data.rows.filter((r: any) => r.agent_id === id && r.sender === "agent");
const lastReply = (store: any, id: string) => agentRows(store, id).at(-1);
const fence = (body: string) => body.match(/```yui\n([\s\S]*?)\n```/)![1];
const words = (body: string) => body.replace(/```yui[\s\S]*$/, "").trim();
const idsOf = (ops: any[]) => Object.fromEntries(ops.filter((o: any) => o.op === "add" && o.id && !/^n\d+$/.test(o.id)).map((o: any) => [o.id, o.preset]));
const homeIds = () => idsOf(parse(homeLines(crew().quill.home!).join("\n"), {}));

/** Parses a reply's lines as the app would, with lasting ids known; fails on any error line. */
function lines(body: string, known: Record<string, string> = homeIds()) {
  const ops = parse(fence(body), known);
  const bad = ops.filter((o: any) => o.op === "error" || o.error);
  assert.deepEqual(bad, [], `parses clean:\n${fence(body)}`);
  return ops;
}

/** An event row as the app sends it: the line, and {id, preset, value} in its meta. */
function tap(store: any, agentId: string, id: string, preset: string, value: Record<string, unknown>) {
  const rowId = store.say(agentId, `[yui] ${id} ${preset}`, "event");
  store.data.rows.find((r: any) => r.id === rowId)!.meta = { id, preset, value };
  return rowId;
}

async function quillYui() {
  const y = await freshYui();
  y.store.data.timezones = { u1: "America/New_York" };
  const quill = await y.byHandle("quill");
  return { ...y, quill };
}
async function run(store: any, id: string, m = noModel()) {
  await runAgent(store, id, { provider, fetch: m.fetch, now });
  assert.equal(m.calls.length, 0, "no model turn");
  return lastReply(store, id);
}
const cardRows = async (store: any, id: string) => {
  const t = (await store.tables(id)).tables.review;
  return Object.fromEntries(t.order.map((k: string) => [k, t.rows[k]]));
};

const LESSON = JSON.stringify({
  title: "Photosynthesis", subject: "Biology",
  pages: [
    { title: "Plants make food from light", body: "Leaves catch sunlight and turn it into sugar." },
    { title: "What goes in", points: ["Water from the roots", "Carbon dioxide from the air", "Light from the sun"] },
    { title: "The recipe", body: "Six of each go in; sugar and oxygen come out.", tex: "6CO_2 + 6H_2O \\rightarrow C_6H_{12}O_6 + 6O_2" },
    { title: "Where it happens", body: "In chloroplasts, the green parts of leaf cells." },
  ],
  quiz: [
    { q: "What gas do plants take in?", options: ["Oxygen", "Carbon dioxide", "Nitrogen"], answer: "Carbon dioxide", why: "They breathe in CO2 and give out oxygen." },
    { q: "Where does it happen?", options: ["Roots", "Chloroplasts", "Flowers"], answer: "Chloroplasts", why: "Chloroplasts hold the chlorophyll." },
    { q: "What comes out?", options: ["Sugar and oxygen", "Water", "Soil"], answer: "Sugar and oxygen" },
  ],
  cards: [
    { front: "What do plants make in photosynthesis?", back: "Sugar (glucose)" },
    { front: "Which gas do plants take in?", back: "Carbon dioxide" },
    { front: "Which gas do plants give out?", back: "Oxygen" },
    { front: "Where does photosynthesis happen?", back: "Chloroplasts" },
    { front: "What catches the light?", back: "Chlorophyll" },
  ],
});
const PROBLEM = JSON.stringify({
  title: "Solve 2x + 3 = 11", subject: "Algebra", result: "x = 4",
  steps: [
    { title: "Take away 3", body: "Get the x term alone: take 3 from both sides.", tex: "2x + 3 - 3 = 11 - 3", ask: "What is 11 - 3?", options: ["7", "8", "14"], answer: "8", why: "11 take away 3 is 8." },
    { title: "Divide by 2", body: "Now 2x = 8. Divide both sides by 2.", tex: "\\frac{2x}{2} = \\frac{8}{2}", ask: "So x is?", options: ["4", "6", "16"], answer: "4", why: "8 split in two is 4." },
  ],
});

test("Quill's home draws exactly what his tools draw from his starter tables: studying, next review, progress", () => {
  const home = homeLines(crew().quill.home!);
  const s = fromSeeds(crew().quill.tables);
  const pages = home.slice(home.indexOf(">2"));
  assert.deepEqual(pages, [">2", ...studyingScreen(s, clk), "save studying", ">3", ...reviewScreen(s, clk), "save next review",
                           ">4", ...progressScreen(s, clk), "save progress"]);
  const ops = parse(home.join("\n"), {});
  assert.deepEqual(ops.filter((o: any) => o.op === "error"), []);
  assert.equal(idsOf(ops).due, "stat", "the due count, big on Next review");
  assert.equal(idsOf(ops)["review-start"], "card");
  assert.equal(idsOf(ops).studied, "chart");
  assert.equal(dueCards(s, clk).length, 8, "the starter deck is due now");
});

test("Review my cards: one full-screen plan, how it works first, each card's front with its answer and a rating, one Send", async () => {
  const { store, quill } = await quillYui();
  store.say(quill.id, "Review my cards");
  const r = await run(store, quill.id);
  const ops = lines(r.body);
  const plan = ops.find((o: any) => o.preset === "plan");
  assert.equal(plan.id, "review");
  assert.ok(!plan.props?.inline, "full screen");
  const steps = ops.filter((o: any) => o.in === "review");
  assert.equal(steps[0].preset, "page", "how it works first");
  const cards = steps.filter((o: any) => o.preset === "choose");
  assert.equal(cards.length, 8);
  assert.deepEqual(cards[0].props.options, RATE_OPTS);
  assert.equal(cards[0].id, "c-c1");
  assert.equal(cards[0].props.title, "Capital of Japan?");
  assert.match(cards[0].props.q ?? cards[0].props.question ?? "", /Tokyo/);
});

test("spaced review: again comes back today, hard tomorrow, good and easy further out each time", () => {
  assert.deepEqual(schedule(1, "Again", clk), { box: 1, due: "2026-09-28" });
  assert.deepEqual(schedule(1, "Hard", clk), { box: 2, due: "2026-09-29" });
  assert.deepEqual(schedule(1, "Good", clk), { box: 2, due: "2026-09-29" });
  assert.deepEqual(schedule(1, "Easy", clk), { box: 3, due: "2026-10-01" });
  assert.deepEqual(schedule(3, "Good", clk), { box: 4, due: "2026-10-05" });
  assert.deepEqual(schedule(5, "Hard", clk), { box: 5, due: "2026-10-06" });
  assert.deepEqual(schedule(6, "Easy", clk), { box: 6, due: "2026-11-02" });
  assert.deepEqual(schedule(4, "Again", clk), { box: 1, due: "2026-09-28" });
});

test("the review's Send rates every card, keeps the session, and patches all three pages in place", async () => {
  const { store, quill } = await quillYui();
  const plan: Record<string, string> = { "c-c1": "Again", "c-c2": "Hard", "c-c3": "Good", "c-c4": "Easy" };
  for (const k of ["c5", "c6", "c7", "c8"]) plan[`c-${k}`] = "Good";
  tap(store, quill.id, "review", "plan", { plan });
  const r = await run(store, quill.id);
  assert.equal(words(r.body), "Saved: 8 cards reviewed, 1 to see again today. 1 still due.");
  const ops = lines(r.body);
  assert.ok(!ops.some((o: any) => o.op === "clear"), "patches, not a redraw: the home is this one");
  const patched = ops.filter((o: any) => o.op === "patch").map((o: any) => o.target ?? o.id);
  for (const id of ["studying", "decks", "due", "review-start", "streak", "studied", "learned"]) assert.ok(patched.includes(id), `patches ${id}`);
  assert.match(fence(r.body), /^~due 1 "Cards due today"/m);
  assert.match(fence(r.body), /^~streak 1 /m);
  assert.match(fence(r.body), /^~studied bar "Cards reviewed" x=Tue\|Wed\|Thu\|Fri\|Sat\|Sun\|Today y=0\|0\|0\|0\|0\|0\|8$/m);
  const c = await cardRows(store, quill.id);
  assert.deepEqual([c.c1.Box, c.c1.Due, c.c2.Box, c.c2.Due, c.c4.Box, c.c4.Due], [1, "2026-09-28", 2, "2026-09-29", 3, "2026-10-01"]);
  assert.equal(c.c3.Rated, "Good");
  assert.equal(c.c3.Reps, 1);
  const sessions = (await store.tables(quill.id)).tables.sessions;
  assert.deepEqual(Object.values(sessions.rows)[0], { Day: "2026-09-28", Kind: "Review", Deck: "World capitals", Cards: 8, Right: 7, Of: 8 });
  // What's due now: the one card rated again, answered in one line with the review under it.
  store.say(quill.id, "What should I review next?");
  const n = await run(store, quill.id);
  assert.match(words(n.body), /^1 card due today, from World capitals\./);
  assert.equal(lines(n.body).filter((o: any) => o.preset === "choose").length, 1);
});

test("nothing due: one line with when the next review is, and a card to learn something new", async () => {
  const { store, quill } = await quillYui();
  const plan = Object.fromEntries(["c1", "c2", "c3", "c4", "c5", "c6", "c7", "c8"].map((k) => [`c-${k}`, "Good"]));
  tap(store, quill.id, "review", "plan", { plan });
  await run(store, quill.id);
  store.say(quill.id, "What should I review next?");
  assert.equal(words((await run(store, quill.id)).body), "Nothing due today. Next review: tomorrow, 8 cards.");
  store.say(quill.id, "quiz me");
  const q = await run(store, quill.id);
  assert.match(words(q.body), /^Nothing to review today\. Next review: tomorrow, 8 cards\./);
  assert.match(fence(q.body), /cta="Learn something new"/);
});

test("Learn a topic: the words open one full-screen plan, the questions last; the Send writes one lesson deck ending in a quiz", async () => {
  const { store, quill } = await quillYui();
  store.say(quill.id, "Teach me photosynthesis");
  const open = await run(store, quill.id);
  const ops = lines(open.body);
  const plan = ops.find((o: any) => o.preset === "plan");
  assert.equal(plan.id, "learn");
  const steps = ops.filter((o: any) => o.in === "learn");
  assert.deepEqual(steps.map((o: any) => o.preset), ["page", "choose", "choose"], "the topic was said, so no topic question");
  assert.deepEqual(steps.slice(1).map((o: any) => o.id), ["time", "know"]);
  assert.equal(open.meta.native.topic, "photosynthesis");
  // The Send: the model writes the lesson once, as JSON.
  const m = fakeModel(() => LESSON);
  tap(store, quill.id, "learn", "plan", { plan: { time: "5 minutes", know: "Nothing yet" } });
  await runAgent(store, quill.id, { provider, fetch: m.fetch, now });
  assert.equal(m.calls.length, 1, "one model call");
  assert.equal(system(m.calls[0]), LESSON_PROMPT);
  assert.match(String(m.calls[0].messages[1].content), /Topic: photosynthesis\nTime: 5 minutes \(4 pages, 3 quiz questions, 5 cards\)\nWhat they know: Nothing yet/);
  const r = lastReply(store, quill.id);
  assert.equal(r.meta.native.studytool, "learned");
  assert.equal(words(r.body), "Here's Photosynthesis in a 5 minute lesson. A 3 question quiz at the end. 5 cards go in your review, first one tomorrow.");
  const lo = lines(r.body);
  const deck = lo.find((o: any) => o.preset === "deck");
  assert.equal(deck.id, "lesson-photosynthesis");
  assert.ok(deck.props.full, "on the stage");
  const members = lo.filter((o: any) => o.in === "lesson-photosynthesis");
  assert.deepEqual(members.map((o: any) => o.preset), ["page", "page", "page", "math", "page", "choose", "choose", "choose"], "the quiz is last");
  assert.equal(members[5].props.answer, "Carbon dioxide");
  // The cards are kept, first due tomorrow; the deck is on What you're studying.
  const c = await cardRows(store, quill.id);
  const fresh = Object.values(c).filter((x: any) => x.Deck === "Photosynthesis") as any[];
  assert.equal(fresh.length, 5);
  assert.ok(fresh.every((x) => x.Due === "2026-09-29" && x.Box === 1));
  assert.match(fence(r.body), /^~studying "Photosynthesis" "5 cards\. None due today\." sub="Biology" cta="Learn more"$/m);
  assert.match(fence(r.body), /^~decks title="Your decks" "Photosynthesis, 5 cards"\|"World capitals, 8 cards"$/m);
  const used = (u: any) => Object.values(u?.turns ?? {}).reduce((a: number, n: any) => a + n, 0);
  assert.equal(used(store.data.users.u1), 1, "the lesson took one free turn; opening the plan took none");
});

test("the lesson's quiz: each answer is quiet; the deck's done keeps the score and patches Progress", async () => {
  const { store, quill } = await quillYui();
  store.say(quill.id, "Teach me photosynthesis");
  await run(store, quill.id);
  tap(store, quill.id, "learn", "plan", { plan: { time: "5 minutes", know: "The basics" } });
  await runAgent(store, quill.id, { provider, fetch: fakeModel(() => LESSON).fetch, now });
  const before = agentRows(store, quill.id).length;
  const q1 = tap(store, quill.id, "quiz-photosynthesis-1", "choose", { choice: "Carbon dioxide", correct: true });
  await run(store, quill.id);
  assert.equal(agentRows(store, quill.id).length, before, "a quiz answer says nothing");
  assert.ok(store.data.rows.find((r: any) => r.id === q1).handled_at);
  tap(store, quill.id, "lesson-photosynthesis", "deck", { done: true, pages: 7, score: 2, of: 3 });
  const r = await run(store, quill.id);
  assert.equal(words(r.body), "2 of 3. Nice. Photosynthesis is in your review, first cards tomorrow.");
  assert.match(fence(r.body), /^~last-quiz "2\/3" "Last quiz" sub="Photosynthesis"$/m);
  const t = (await store.tables(quill.id)).tables;
  assert.equal(t.decks.rows.photosynthesis.Score, "2 of 3");
  assert.equal(Object.values(t.sessions.rows).filter((x: any) => x.Kind === "Quiz").length, 1);
});

test("a lesson that isn't JSON gets one more ask; a topic from the first answer opens the plan", async () => {
  const { store, quill } = await quillYui();
  tap(store, quill.id, "learn-subject", "choose", { choice: "Science" });
  const open = await run(store, quill.id);
  assert.match(words(open.body), /^Let's learn Science\./);
  let n = 0;
  const m = fakeModel(() => (n++ ? LESSON : "Sure! Here's a lesson about science..."));
  tap(store, quill.id, "learn", "plan", { plan: { time: "10 minutes", know: "The basics" } });
  await runAgent(store, quill.id, { provider, fetch: m.fetch, now });
  assert.equal(m.calls.length, 2);
  assert.match(String(m.calls[1].messages.at(-1).content), /JSON object only/);
  assert.match(lastReply(store, quill.id).body, /deck@lesson-photosynthesis/);
  // "Teach me" alone is still a question for Quill himself.
  const { rest } = studyAsks([{ id: "r", sender: "user", kind: "text", body: "teach me", meta: {}, created_at: "" } as any]);
  assert.equal(rest.length, 1);
});

test("Walk me through a problem: a plan asks for it; one step a page, the next shows only once the step is answered", async () => {
  const { store, quill } = await quillYui();
  store.say(quill.id, "Walk me through a problem");
  const open = await run(store, quill.id);
  const ops = lines(open.body);
  assert.equal(ops.find((o: any) => o.preset === "plan").id, "problem");
  assert.deepEqual(ops.filter((o: any) => o.in === "problem").map((o: any) => o.preset), ["page", "form", "choose"]);
  const m = fakeModel(() => PROBLEM);
  tap(store, quill.id, "problem", "plan", { plan: { question: { problem: "Solve 2x + 3 = 11" }, size: "Small steps" } });
  await runAgent(store, quill.id, { provider, fetch: m.fetch, now });
  assert.equal(m.calls.length, 1);
  assert.equal(system(m.calls[0]), PROBLEM_PROMPT);
  const s1 = lastReply(store, quill.id);
  assert.equal(words(s1.body), "Solve 2x + 3 = 11, in 2 steps. Answer each one and the next shows.");
  const o1 = lines(s1.body);
  const key = o1.find((o: any) => o.preset === "choose").id.replace(/^step-|-1$/g, "");
  assert.deepEqual(o1.map((o: any) => o.preset), ["page", "math", "choose"], "step 1 only");
  assert.match(fence(s1.body), /^page "Step 1 of 2: Take away 3"/);
  // A wrong answer: the right one and why, then step 2.
  tap(store, quill.id, `step-${key}-1`, "choose", { choice: "7", correct: false });
  const s2 = await run(store, quill.id);
  assert.equal(words(s2.body), "Not quite: it's 8. 11 take away 3 is 8.");
  assert.match(fence(s2.body), /^page "Step 2 of 2: Divide by 2"/);
  // Changing the old answer moves nothing.
  const n = agentRows(store, quill.id).length;
  tap(store, quill.id, `step-${key}-1`, "choose", { choice: "8", correct: true, changed: true });
  await run(store, quill.id);
  assert.equal(agentRows(store, quill.id).length, n);
  tap(store, quill.id, `step-${key}-2`, "choose", { choice: "4", correct: true });
  const done = await run(store, quill.id);
  assert.equal(words(done.body), "Right. Solved: x = 4. You got 1 of 2 steps.");
  assert.match(fence(done.body), /^~last-quiz "1\/2" "Last quiz" sub="Algebra"$/m);
  const t = (await store.tables(quill.id)).tables;
  assert.equal(t.problems.rows[key].Done, true);
  assert.deepEqual(Object.values(t.steps.rows).map((x: any) => [x.Given, x.Right]), [["7", false], ["4", true]]);
});

test("the JSON readers keep only what draws: options that hold the answer, pages with titles", () => {
  const l = parseLesson(JSON.stringify({ title: "X", pages: [{ title: "" }, { title: "One" }], quiz: [{ q: "?", options: ["a", "b"], answer: "c" }], cards: [] }))!;
  assert.deepEqual([l.pages.length, l.quiz.length], [1, 0]);
  assert.equal(parseLesson("no json"), null);
  assert.equal(parseProblem(JSON.stringify({ steps: [{ ask: "?", options: ["1"], answer: "1" }] })), null, "a step needs two options");
});

test("kill and relaunch: cards, due days and the page shape live in the store; switching agents five times keeps them", async () => {
  const { store, quill } = await quillYui();
  tap(store, quill.id, "review", "plan", { plan: { "c-c1": "Again", "c-c2": "Good" } });
  await run(store, quill.id);
  const again = new LocalStore(JSON.parse(JSON.stringify(store.data)), { guide: "GUIDE", freeTurns: 100 });
  for (let i = 0; i < 5; i++) {
    for (const h of ["penny", "quill"]) assert.ok((await again.agents("u1")).some((a) => a.profile.handle === h));
  }
  again.say(quill.id, "What should I review next?");
  const r = await run(again, quill.id);
  assert.match(words(r.body), /^7 cards due today/, "c2 went to tomorrow through the relaunch");
  tap(again, quill.id, "review", "plan", { plan: { "c-c1": "Good" } });
  const t = await run(again, quill.id);
  assert.doesNotMatch(fence(t.body), /^>\d clear/m, "patched, not drawn again: the shape was kept");
  assert.equal((await cardRows(again, quill.id)).c1.Box, 2);
});

test("a Quill from before YUI-186 gets his new tables and columns once, keeps his cards, and his pages are drawn once", async () => {
  const { store, quill } = await quillYui();
  const t = await store.tables(quill.id);
  store.data.tables = { ...(store.data.tables ?? {}), [quill.id]: t };
  t.tables = { ...fromSeeds(crew().quill.tables).tables };
  for (const n of ["sessions", "problems", "steps"]) delete t.tables[n];
  t.tables.review.cols = t.tables.review.cols.slice(0, 5);
  t.tables.review.rows = { c1: { Front: "Capital of Peru?", Back: "Lima", Deck: "World capitals", Box: 2, Due: "2026-09-27" } };
  t.tables.review.order = ["c1"];
  const agent = (await store.agent(quill.id))!;
  agent.profile = { ...agent.profile, home: '>2\ncard@studying "World capitals" "8 cards, all new." sub=Geography cta="Quiz me"\nsave studying', seeded: true };
  await store.updateAgent(quill.id, agent.profile);
  tap(store, quill.id, "review", "plan", { plan: { "c-c1": "Good" } });
  const r = await run(store, quill.id);
  const f = fence(r.body);
  assert.match(f, /^>2 clear\n>2\ncard@studying /m, "every page drawn once");
  assert.match(f, />3 clear\n>3\n/);
  assert.match(f, />4 clear\n>4\n/);
  lines(r.body, {});
  const after = (await store.tables(quill.id)).tables;
  assert.deepEqual(after.review.cols.map((c: any) => c.name), ["Front", "Back", "Deck", "Box", "Due", "Rated", "Reviewed", "Reps"]);
  assert.ok(after.sessions && after.problems && after.steps);
  assert.equal(after.review.rows.c1.Box, 3);
  store.say(quill.id, "Review my cards");
  await run(store, quill.id);
  tap(store, quill.id, "review", "plan", { plan: {} });
  assert.doesNotMatch((await run(store, quill.id)).body, /clear/, "then patches");
});

test("a model turn that writes a card patches his pages", async () => {
  const { store, quill } = await quillYui();
  const m = fakeModel(() => "Added.\n```yui\nput review peru Front=\"Capital of Peru?\" Back=Lima Deck=\"World capitals\" Box=1\n```");
  store.say(quill.id, "make me a card for the capital of Peru");
  await runAgent(store, quill.id, { provider, fetch: m.fetch, now });
  assert.equal(m.calls.length, 1);
  const r = lastReply(store, quill.id);
  assert.match(fence(r.body), /^~due 9 "Cards due today"/m);
});
