// YUI-184: Gouda's tools. Learn a song and play along (slow it down, loop the hard bar), the practice log, saved
// sessions, and his pages (Looper, Chords, Keys, Practice), all answered by the runtime from his tables with no model
// turn. Every test goes through runAgent on the store a person's rows go through (not a demo memory), and every reply
// is read by the real Yui Lines parser.
import { test } from "node:test";
import assert from "node:assert/strict";
import { runAgent } from "../src/turn.ts";
import { LocalStore } from "../src/store.ts";
import { clock, fromSeeds } from "../src/tables.ts";
import { homeLines } from "../src/home.ts";
import { crew } from "../src/profiles.ts";
import { KEY_OPTS, SPEED_OPTS, chordsScreen, guessKey, keyShift, keysScreen, lessonChords, looperScreen, musicAsks, drawnShape, practiceScreen, readChords, screenLines, tunerLines,
         readKey, streak, transpose } from "../src/music.ts";
import { fakeModel, freshYui, provider } from "./helpers.ts";
// @ts-ignore: the parser the app and the site share, as the MCP server ships it
import { parse } from "../../supabase/functions/yui-mcp/yl.mjs";

const MON = Date.parse("2026-09-28T16:00:00Z"); // noon in New York
const now = () => MON;
const noModel = () => fakeModel(() => {
  throw new Error("no model call expected");
});
const agentRows = (store: any, id: string) => store.data.rows.filter((r: any) => r.agent_id === id && r.sender === "agent");
const lastReply = (store: any, id: string) => agentRows(store, id).at(-1);
const fence = (body: string) => body.match(/```yui\n([\s\S]*?)\n```/)![1];
const turnsUsed = (store: any) => Object.values(store.data.users?.u1?.turns ?? {}).reduce((a: number, b: any) => a + b, 0);

/** The ids a home leaves on its pages, as the app hands them to the parser. */
function homeIds(): Record<string, string> {
  const ops = parse(homeLines(crew().gouda.home!).join("\n"), {});
  return Object.fromEntries(ops.filter((o: any) => o.op === "add" && o.id && !/^n\d+$/.test(o.id)).map((o: any) => [o.id, o.preset]));
}

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

async function goudaYui() {
  const y = await freshYui();
  y.store.data.timezones = { u1: "America/New_York" };
  const gouda = await y.byHandle("gouda");
  return { ...y, gouda };
}

async function run(store: any, id: string) {
  const m = noModel();
  await runAgent(store, id, { provider, fetch: m.fetch, now });
  assert.equal(m.calls.length, 0, "no model turn");
  return lastReply(store, id);
}

/** The ids on the phone once a song is on Chords. */
const lessonIds = () => ({ ...homeIds(), speed: "choose", bar: "choose" });

const LEARN = { song: "Stand By Me", key: "As written", speed: "75%" };

async function learned() {
  const y = await goudaYui();
  tap(y.store, y.gouda.id, "learn", "plan", { plan: LEARN });
  const r = await run(y.store, y.gouda.id);
  return { ...y, reply: r };
}

test("Gouda's home draws exactly what his tools draw from his starter tables: Looper, Chords, Keys, Practice", () => {
  const home = homeLines(crew().gouda.home!);
  const s = fromSeeds(crew().gouda.tables);
  const clk = clock(MON, "UTC");
  const pages = home.slice(home.indexOf(">2"));
  assert.deepEqual(pages, [">2", ...looperScreen(s), "save looper", ">3", ...chordsScreen(s), "save chords", ">4", ...keysScreen(s), "save keys",
                           ">5", ...practiceScreen(s, clk), "save practice", ">6", ...tunerLines().slice(3)]);
  assert.deepEqual(home.filter((l) => l.startsWith("menu")).map((l) => l.match(/"([^"]+)"/)![1]), ["Tune up", "Jam", "Log practice", "Learn a song"]);
  const ops = parse(home.join("\n"), {});
  assert.deepEqual(ops.filter((o: any) => o.op === "error"), []);
  const ids = homeIds();
  for (const [id, preset] of Object.entries({ looper: "loop", chords: "chords", keys: "keys", click: "metronome", streak: "stat", "practice-chart": "chart" })) {
    assert.equal(ids[id], preset, id);
  }
});

test("Tune up opens the tuner screen with no turn, and the tuner is the last screen (YUI-200)", () => {
  const home = homeLines(crew().gouda.home!);
  const tune = home.find((l) => l.startsWith("menu shortcut@tune"))!;
  assert.match(tune, /show=tuner/);
  assert.doesNotMatch(tune, /say=/, "no words go to the model");
  const screens = home.filter((l) => /^>\d+$/.test(l)).map((l) => Number(l.slice(1)));
  assert.equal(screens.at(-1), 6);
  assert.equal(home.at(-1), "save tuner");
  assert.deepEqual(parse(home.join("\n"), {}).filter((o: any) => o.op === "error"), []);
  const s = fromSeeds(crew().gouda.tables);
  const clk = clock(MON, "UTC");
  // A new Gouda already has it: nothing more is drawn. A Gouda from before gets it once, the shortcut with it.
  assert.equal(drawnShape({ home: crew().gouda.home }), "v2;none");
  assert.deepEqual(screenLines(s, clk, "v2;none", []).lines, []);
  const up = screenLines(s, clk, "v1;none", []);
  assert.deepEqual(up.lines, tunerLines(), "only the tuner and its shortcut, no page redrawn");
  assert.equal(up.shape, "v2;none");
  assert.deepEqual(screenLines(s, clk, up.shape, []).lines, []);
  assert.ok(screenLines(s, clk, undefined, []).lines.join("\n").includes(">6\ntuner@tuner"), "the first draw ends with the tuner");
});

test("Learn a song: the shortcut's words open one full-screen flow, what happens first, the questions last, one Send", async () => {
  const { store, gouda } = await goudaYui();
  store.say(gouda.id, "Learn a song");
  const ops = lines((await run(store, gouda.id)).body);
  const plan = ops.find((o: any) => o.preset === "plan");
  assert.equal(plan.id, "learn");
  assert.equal(plan.props.submit, "Let's play");
  const steps = ops.filter((o: any) => o.in === "learn");
  assert.equal(steps[0].preset, "page", "what happens first");
  assert.deepEqual(steps.slice(1).map((o: any) => o.id), ["song", "own", "key", "speed"], "the questions last");
  assert.deepEqual(steps[1].props.options.slice(0, 4), ["Stand By Me", "Three Little Birds", "Let It Be", "Knockin' on Heaven's Door"]);
  assert.deepEqual(steps[3].props.options, KEY_OPTS);
  assert.deepEqual(steps[4].props.options, SPEED_OPTS);
  const say = (body: string) => musicAsks([{ id: "x", sender: "user", kind: "text", body, meta: {}, created_at: "" } as any], fromSeeds(crew().gouda.tables)).asks[0];
  for (const w of ["learn a song", "Teach me a song's chords", "I want to learn a new song."]) assert.equal(say(w)?.kind, "learn", w);
  assert.equal(say("teach me let it be")?.kind, "learn", "a song he knows by name");
  assert.equal((say("teach me let it be") as any).song, "let it be");
  assert.equal(say("teach me about modes"), undefined, "theory goes to Gouda");
  assert.equal(say("make me a beat"), undefined);
  // Learn a song by name puts that one first.
  store.say(gouda.id, "teach me Let It Be");
  const o2 = lines((await run(store, gouda.id)).body);
  assert.equal(o2.find((o: any) => o.id === "song").props.options[0], "Let It Be");
});

test("the Send puts the song on Chords: its chords, the click at the chosen speed, a speed and a bar to loop; Keys follows the key", async () => {
  const { store, gouda, reply } = await learned();
  assert.match(reply.body, /^Stand By Me is on your Chords page: 8 bars in A, the click at 89\./);
  const f = fence(reply.body);
  assert.match(f, /\n?>3 clear\n>3\ncard@lesson "Stand By Me" "Key of A, 8 bars\. Click at 89, 75% of 118\."/, "Chords drawn again for the song");
  assert.match(f, /chords@chords "A"\|"F#m"\|"D"\|"E" "Stand By Me" \+inline/);
  assert.match(f, /metronome@click 89 "Stand By Me"/);
  assert.match(f, /choose@bar "Loop a bar" "Whole song"\|"Bar 1: A"\|"Bar 2: A"\|"Bar 3: F#m"/);
  assert.match(f, /~keys A major "Keys, in A" \+inline/, "Keys patched to the song's key");
  assert.match(f, /~next-up "Next: Stand By Me at 89"/);
  assert.doesNotMatch(f, />2 clear|>4 clear|>5 clear/, "only Chords moves");
  const ops = lines(reply.body);
  assert.deepEqual(ops.find((o: any) => o.id === "chords" && o.op === "add").props.chords, ["A", "F#m", "D", "E"]);
  const t = await store.tables(gouda.id);
  assert.deepEqual({ ...t.tables.studio.rows.now }, { Song: "Stand By Me", Tonic: "A", Bpm: 118, Speed: 75, Chords: "A|A|F#m|F#m|D|E|A|A", Bar: 0 });
  assert.equal(t.tables.songs.rows["stand-by-me"].Status, "Learning");
  assert.equal(turnsUsed(store), 0, "no free turn spent");
});

test("slow it down and loop the hard bar: patches on Chords that never move the person; Whole song brings it back", async () => {
  const { store, gouda } = await learned();
  tap(store, gouda.id, "speed", "choose", { choice: "Half" });
  let r = await run(store, gouda.id);
  assert.match(r.body, /^Stand By Me at 59 now\./);
  let f = fence(r.body);
  assert.match(f, /~click 59 "Stand By Me"/);
  assert.match(f, /~lesson "Stand By Me" "Key of A, 8 bars\. Click at 59, 50% of 118\."/);
  assert.doesNotMatch(f, />\d clear/, "nothing moves the person");
  lines(r.body, lessonIds());
  tap(store, gouda.id, "bar", "choose", { choice: "Bar 5: D" });
  r = await run(store, gouda.id);
  assert.match(r.body, /^Looping bar 5 of Stand By Me/);
  f = fence(r.body);
  assert.match(f, /~chords "D"\|"E" "Stand By Me, bar 5" \+inline/);
  assert.match(f, /~next-up "Next: bar 5 of Stand By Me" "Loop it at 59/);
  assert.doesNotMatch(f, />\d clear/);
  assert.deepEqual(lines(r.body, lessonIds()).find((o: any) => o.target === "chords").props.chords, ["D", "E"]);
  tap(store, gouda.id, "bar", "choose", { choice: "Whole song" });
  r = await run(store, gouda.id);
  assert.match(fence(r.body), /~chords "A"\|"F#m"\|"D"\|"E" "Stand By Me"/);
  assert.equal((await store.tables(gouda.id)).tables.studio.rows.now.Bar, 0);
});

test("pasted chords: bars read from a chart, moved to the easiest guitar key, kept as a song; an unknown title asks for its chords", async () => {
  const { store, gouda } = await goudaYui();
  tap(store, gouda.id, "learn", "plan", { plan: { song: "My own chords", own: { name: "Riptide", chords: "| Bbm Ab | Eb Eb |\n| Bbm Ab | Eb |", bpm: 100 }, key: "Easiest on guitar", speed: "Full speed" } });
  const r = await run(store, gouda.id);
  assert.match(r.body, /^Riptide is on your Chords page: 4 bars in Am, the click at 100\./);
  assert.match(fence(r.body), /chords@chords "Am"\|"G"\|"D" "Riptide"/);
  const t = await store.tables(gouda.id);
  assert.equal(t.tables.songs.rows.riptide.Chords, "Bbm Ab|Eb Eb|Bbm Ab|Eb", "the song as they wrote it");
  assert.equal(t.tables.studio.rows.now.Chords, "Am G|D D|Am G|D");
  lines(r.body);
  // A song he has no chords for: a form for them, then the lesson.
  tap(store, gouda.id, "learn", "plan", { plan: { song: "Wonderwall", key: "As written", speed: "Full speed" } });
  const ask = await run(store, gouda.id);
  assert.match(ask.body, /I don't have the chords for Wonderwall yet/);
  const form = lines(ask.body).find((o: any) => o.preset === "form");
  assert.equal(form.id, "learn-paste");
  tap(store, gouda.id, "learn-paste", "form", { form: { chords: "Em7 G Dsus4 A7sus4", name: "Wonderwall" } });
  const done = await run(store, gouda.id);
  assert.match(done.body, /^Wonderwall is on your Chords page: 4 bars in Em/);
});

test("the practice log: a short flow, the click logs itself, words log too; streak, this week and what's next patched", async () => {
  const { store, gouda } = await learned();
  store.say(gouda.id, "Log practice");
  const open = lines((await run(store, gouda.id)).body);
  assert.equal(open.find((o: any) => o.preset === "plan").id, "practiced");
  const steps = open.filter((o: any) => o.in === "practiced");
  assert.equal(steps[0].preset, "page");
  assert.deepEqual(steps.slice(1).map((o: any) => o.id), ["minutes", "what", "feel"]);
  assert.equal(steps[2].props.options[0], "Stand By Me", "the song they're learning first");
  tap(store, gouda.id, "practiced", "plan", { plan: { minutes: "20 min", what: ["Stand By Me", "Scales"], feel: "Nailed it" } });
  let r = await run(store, gouda.id);
  assert.match(r.body, /^Logged 20 minutes: Stand By Me, Scales\./);
  let f = fence(r.body);
  assert.match(f, /~streak "1 day" "Streak"/);
  assert.match(f, /~week-min "20 min" "This week"/);
  assert.match(f, /~practice-chart bar "Minutes a day" x=Mon\|Tue\|Wed\|Thu\|Fri\|Sat\|Sun y=20\|0\|0\|0\|0\|0\|0/);
  assert.match(f, /~click 100 "Stand By Me"/, "nailed it: the next run is a notch faster (85% of 118)");
  assert.doesNotMatch(f, />\d clear/);
  lines(r.body, lessonIds());
  // The click stopped after 3 minutes logs itself; under 10 seconds the app sends nothing.
  tap(store, gouda.id, "click", "metronome", { bpm: 100, beats: 4, sub: 1, seconds: 184 });
  r = await run(store, gouda.id);
  assert.match(r.body, /^Logged 3 minutes: Stand By Me\./);
  assert.match(fence(r.body), /~week-min "23 min"/);
  store.say(gouda.id, "I practiced 15 minutes on scales");
  r = await run(store, gouda.id);
  assert.match(r.body, /^Logged 15 minutes: Scales\./);
  const rows = Object.values((await store.tables(gouda.id)).tables.practice.rows) as any[];
  assert.deepEqual(rows.map((x) => x.Minutes), [20, 3, 15]);
  assert.ok(rows.every((x) => x.Day === "2026-09-28"));
  assert.equal(turnsUsed(store), 0);
});

test("sessions: the Looper's Send opens a save flow, the Send keeps it by name on the Looper, Open a beat brings any back", async () => {
  const { store, gouda } = await goudaYui();
  const mine = { bpm: 88, swing: 20, steps: 8, rows: ["kick", "snare", "clap", "hat"], p: ["x..xx...", "..x...x.", "", "xxxxxxxx"] };
  tap(store, gouda.id, "looper", "loop", mine);
  const ask = lines((await run(store, gouda.id)).body);
  assert.equal(ask.find((o: any) => o.preset === "plan").id, "keep");
  const steps = ask.filter((o: any) => o.in === "keep");
  assert.equal(steps[0].preset, "page");
  assert.match(steps[0].props.body, /88 bpm, swing 20, 8 steps\. Kick, snare and hat\./);
  assert.deepEqual(steps.slice(1).map((o: any) => o.id), ["name", "then"]);
  tap(store, gouda.id, "keep", "plan", { plan: { name: { name: "Night drive" }, then: "Keep it on my Looper" } });
  let r = await run(store, gouda.id);
  assert.match(r.body, /^Saved Night drive\. It's on your Looper\./);
  let f = fence(r.body);
  assert.match(f, /~looper 88 "Night drive" p=x\.\.xx\.\.\.\|\.\.x\.\.\.x\.\|\|xxxxxxxx swing=20 rows=kick\|snare\|clap\|hat \+inline/);
  assert.match(f, /~sessions "Open a beat" "Night drive"\|"Lazy Sunday"/);
  lines(r.body);
  tap(store, gouda.id, "sessions", "choose", { choice: "Boom bap" });
  r = await run(store, gouda.id);
  assert.match(r.body, /^Boom bap is on your Looper, 90 bpm\./);
  assert.match(fence(r.body), /~looper 90 "Boom bap" p=x\.\.\.x\.x\./);
  store.say(gouda.id, "open night drive");
  r = await run(store, gouda.id);
  assert.match(r.body, /^Night drive is on your Looper, 88 bpm\./);
  // A drum take saves the same way, cut to the looper's 16 steps; a loop in the chat still goes to Gouda.
  tap(store, gouda.id, "n1", "drums", { take: true, bpm: 88, steps: 32, rows: ["kick", "snare"], p: ["x.......x.x.....x.......x.x.....", "....x.......x......."] });
  const take = lines((await run(store, gouda.id)).body).filter((o: any) => o.in === "keep");
  assert.match(take[0].props.title, /Your take/);
  assert.match(take[0].props.body, /16 steps/);
  assert.equal(musicAsks([{ id: "x", sender: "user", kind: "event", body: "[yui] n1 loop", meta: { id: "n1", preset: "loop", value: mine }, created_at: "" } as any]).asks.length, 0);
  const s = (await store.tables(gouda.id)).tables.sessions;
  assert.equal(s.rows["s-night-drive"].Pattern, "x..xx...|..x...x.||xxxxxxxx");
  assert.ok(s.rows.draft, "the take waits to be named");
});

test("Keys: a scale tap locks the keyboard with a patch", async () => {
  const { store, gouda } = await goudaYui();
  tap(store, gouda.id, "scale", "choose", { choice: "Blues" });
  const r = await run(store, gouda.id);
  assert.match(fence(r.body), /~keys C blues "Keys" \+inline/);
  assert.equal((await store.tables(gouda.id)).tables.studio.rows.keys.Scale, "blues");
});

test("kill and relaunch: the lesson, the log and the page shape live in the store, and a new process picks them up", async () => {
  const { store, gouda } = await learned();
  tap(store, gouda.id, "practiced", "plan", { plan: { minutes: "10 min", what: ["Stand By Me"], feel: "Rough" } });
  await run(store, gouda.id);
  const again = new LocalStore(JSON.parse(JSON.stringify(store.data)), { guide: "GUIDE", freeTurns: 100 });
  tap(again, gouda.id, "bar", "choose", { choice: "Bar 3: F#m" });
  const r = await run(again, gouda.id);
  assert.match(r.body, /^Looping bar 3 of Stand By Me/);
  assert.doesNotMatch(fence(r.body), />\d clear/, "patched, not drawn again: the shape was kept");
  assert.match(fence(r.body), /~streak "1 day"/, "the log came through the relaunch");
  // And back to the first process: the other agents' threads left alone, Gouda's state still there.
  for (const h of ["basil", "arnold", "gouda", "basil", "gouda"]) assert.ok((await again.agents("u1")).some((a) => a.profile.handle === h));
});

test("a Gouda from before YUI-184 gets his tables and his songs' chords once, keeps his own, and his pages are drawn once", async () => {
  const { store, gouda } = await goudaYui();
  const t = store.data.tables![gouda.id];
  for (const n of ["practice", "sessions", "studio"]) delete t.tables[n];
  // His songs as they were: no Chords column, one of his own, one starter taken off.
  const songs = t.tables.songs;
  songs.cols = songs.cols.filter((c: any) => c.name !== "Chords");
  for (const k of songs.order) delete songs.rows[k].Chords;
  delete songs.rows["let-it-be"];
  songs.order = songs.order.filter((k: string) => k !== "let-it-be");
  songs.rows["my-tune"] = { Title: "My tune", Scale: "D", Bpm: 100, Status: "Writing" };
  songs.order.push("my-tune");
  store.data.agents[gouda.id].profile.home = 'menu shortcut@tune "Tune up" say="Tune my guitar"\nmenu shortcut@jam "Jam" say="Make me a beat to jam on"\n>2\nloop@looper 92 "Looper" p=x...x...|..x...x.|........|x.x.x.x. +inline\nsave looper';
  tap(store, gouda.id, "learn", "plan", { plan: { song: "Three Little Birds", key: "Up a step", speed: "Full speed" } });
  const r = await run(store, gouda.id);
  assert.match(r.body, /^Three Little Birds is on your Chords page: 8 bars in B/);
  const f = fence(r.body);
  for (const n of [2, 3, 4, 5]) assert.match(f, new RegExp(`>${n} clear\\n>${n}\\n`), `page ${n} drawn once`);
  lines(r.body);
  const t1 = await store.tables(gouda.id);
  assert.ok(t1.tables.practice && t1.tables.sessions && t1.tables.studio);
  assert.equal(t1.tables.songs.rows["three-little-birds"].Chords, "A|A|D|A|A|E|D|A");
  assert.equal(t1.tables.songs.rows["let-it-be"], undefined, "a song he took off stays off");
  assert.equal(t1.tables.songs.rows["my-tune"].Title, "My tune");
  tap(store, gouda.id, "speed", "choose", { choice: "75%" });
  assert.doesNotMatch(fence((await run(store, gouda.id)).body), />\d clear/, "after that, patches");
});

test("a model turn that writes his practice log gets Practice patched under its answer", async () => {
  const { store, gouda } = await goudaYui();
  const m = fakeModel(() => "Nice work.\n```yui\nput practice Day=2026-09-28 Minutes=25 What=\"Ear training\"\n```");
  store.say(gouda.id, "did 25 min of ear training today");
  await runAgent(store, gouda.id, { provider, fetch: m.fetch, now });
  const body = lastReply(store, gouda.id).body;
  assert.match(fence(body), /~week-min "25 min" "This week"/);
  lines(body);
});

test("pieces: chords read from a chart, transposed, keys guessed and moved, bars looped, streaks counted", () => {
  assert.deepEqual(readChords("Am F C G"), ["Am", "F", "C", "G"]);
  assert.deepEqual(readChords("| C G | Am F |\nVerse: C - G - F"), ["C G", "Am F", "C", "G", "F"]);
  assert.deepEqual(readChords("Em7, G, Dsus4, A7sus4, Cadd9, D/F#"), ["Em7", "G", "Dsus4", "A7sus4", "Cadd9", "D/F#"]);
  assert.equal(transpose("F#m7", 3, false), "Am7");
  assert.equal(transpose("D/F#", -2, true), "C/E");
  assert.equal(transpose("Bbm", -1, false), "Am");
  assert.deepEqual(guessKey(["Am", "F"]), { root: "A", minor: true });
  assert.deepEqual(readKey("C minor"), { root: "C", minor: true });
  assert.equal(keyShift({ root: "Bb", minor: true }, "Easiest on guitar"), -1);
  assert.equal(keyShift({ root: "F", minor: false }, "Easiest on guitar"), -1, "F to E, the nearest open key");
  assert.equal(keyShift({ root: "G", minor: false }, "Easiest on guitar"), 0);
  const l = { song: "S", key: "C", bpm: 100, speed: 100, bars: ["C", "C", "F", "G"], bar: 1 };
  assert.deepEqual(lessonChords(l).chords, ["C", "F"], "a one-chord bar loops with the next chord so it moves");
  const s = fromSeeds(crew().gouda.tables);
  s.tables.practice.rows = { a: { Day: "2026-09-27", Minutes: 10 }, b: { Day: "2026-09-26", Minutes: 5 }, c: { Day: "2026-09-24", Minutes: 5 } } as any;
  s.tables.practice.order = ["a", "b", "c"];
  assert.equal(streak(s, clock(MON, "UTC")), 2, "up to yesterday when today has none yet");
});
