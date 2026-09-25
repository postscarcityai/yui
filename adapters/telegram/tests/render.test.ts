// Yui Lines -> Telegram (INT-4): every preset lands somewhere, text presets
// read right, questions carry short callback_data, the Mini App link holds
// the whole fence. Run: node --test tests/*.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { PRESETS, parse } from "../src/vendor/yl.mjs";
import { HOW, MemoryStore, appLink, label, render, renderYL, split, statText, type Message } from "../src/render.ts";
import { decodeYL } from "../src/share.ts";

const HUB = process.env.YUIGUI || join(homedir(), "dev/yuigui");
const hasHub = existsSync(join(HUB, "site/lib/yl/samples.mjs"));
const opts = () => ({ store: new MemoryStore() });
const buttons = (m: Message[]) => m.flatMap((x) => x.reply_markup?.inline_keyboard.flat() ?? []);
const appMsg = (m: Message[]) => m.find((x) => x.text.startsWith("<b>Open in Yui</b>"));

// One line per preset, plus custom. The test fails when yl.mjs gains a preset
// this file does not cover.
const LINE: Record<string, string> = {
  timer: "timer 40/20x8 Tabata",
  ask: 'ask "Log this set?"',
  choose: 'choose "What today?" Push|Pull|Legs',
  pick: 'pick "Gear?" Dumbbells|Bench|Bands',
  slide: 'slide "Energy" 1-5',
  form: "form name:text! goal:voice",
  list: "list Today Squat Bench Row +check",
  table: 'table Macros Food|Cal "Eggs|140" "Oats|300"',
  card: 'card "Leg day" "Squat, RDL." cta="Start workout"',
  image: 'image /yl/meal.svg "Dinner"',
  camera: 'camera "Snap your plate"',
  mic: 'mic "What did you eat?"',
  gallery: 'gallery "Shoot" /a.jpg|/b.jpg',
  video: 'video /reel.mp4 "Reel"',
  compare: "compare /before.jpg /after.jpg",
  storyboard: 'storyboard "Reel" /s1.jpg|/s2.jpg',
  chart: 'chart line "Weight" x=Mon|Tue y=181|180',
  stat: "stat 178.9 unit=lb label=Weight delta=-2.3",
  math: 'math "E = mc^2"',
  step: 'step "Start from rest"',
  calc: 'calc "Area" "A = w*h" w=2 h=3',
  deck: 'deck "How it works"\npage "One"\nend',
  page: 'page "Alone"',
  plan: 'plan "Build review"\npage "Pick"\nchoose "Which?" A|B\nend',
  project: 'project "Kiln site" status=Planning',
  narrate: 'narrate "What changed"\npage "One"\nend',
  timeline: 'timeline "This week"\ndone "Shelf" tag=YUI-32\nnow "War room"\nnext "Replies"\nend',
  done: 'done "Shipped it"',
  now: 'now "Building"',
  next: 'next "Later"',
  game: 'game tictactoe "Beat me"',
  flow: 'flow@intake "Website intake"\nflowchart TD\n  %% kind: choose "What are we building?" Site|Shop\n  kind -->|Shop| products[slide Products 1-500]\nend',
  sketch: 'sketch "Card ids" frame=bubble\nrow "Parked t_1 in the backlog" +x note="an id"\nrow\nrow "Install" +button +hi',
  row: 'row "Plain words" +hi',
  after: 'sketch "Fix"\nrow Old +x\nafter Now\nrow New +hi',
  custom: 'custom {"type":"text","text":"hi"}',
};

test("every preset in yl.mjs has a Telegram mapping and a test line", () => {
  for (const p of [...PRESETS, "custom"]) {
    assert.ok(HOW[p], `no HOW for ${p}`);
    assert.ok(LINE[p], `no test line for ${p}`);
  }
});

for (const preset of [...PRESETS, "custom"]) {
  test(`${preset}: rendered, not dropped`, async () => {
    const r = await renderYL(LINE[preset], opts());
    const adds = parse(LINE[preset]).filter((o: any) => o.op === "add");
    assert.equal(adds.filter((a: any) => a.op === "error").length, 0);
    assert.ok(adds.length > 0, "the test line parses");
    for (const a of adds) assert.ok(r.placed[a.id], `${a.preset} ${a.id} placed nowhere`);
    const head = adds[0];
    const how = r.placed[head.id];
    if (HOW[preset] === "app") {
      assert.equal(how, "app");
      const m = appMsg(r.messages)!;
      assert.ok(m, "an Open in Yui message");
      const b = m.reply_markup!.inline_keyboard[0][0];
      assert.equal(b.text, "Open in Yui");
      assert.match(b.web_app!.url, /^https:\/\/www\.yuigui\.com\/tg\?yl=[A-Za-z0-9_-]+$/);
      assert.equal(await decodeYL(new URL(b.web_app!.url).searchParams.get("yl")!), LINE[preset]);
    } else {
      assert.ok(["keyboard", "text"].includes(how), `${preset} went ${how}`);
      assert.equal(appMsg(r.messages), undefined, `${preset} needs no Mini App`);
      assert.ok(r.messages.length >= 1);
    }
    for (const m of r.messages) assert.ok(m.text.length > 0 && m.text.length <= 4096);
    for (const b of buttons(r.messages)) if (b.callback_data) assert.ok(new TextEncoder().encode(b.callback_data).length <= 64);
  });
}

test("every playground sample renders with nothing dropped", { skip: !hasHub && "no yuigui checkout" }, async () => {
  const s = await import(join(HUB, "site/lib/yl/samples.mjs"));
  const all = [...s.SCREENS, ...s.DEMOS, ...s.MEDIA, ...s.SCIENCE, ...s.FLOWS];
  assert.ok(all.length >= 50);
  const seen = new Set<string>();
  for (const x of all) {
    const r = await renderYL(x.yl, opts());
    const ids = parse(x.yl).filter((o: any) => o.op === "add").map((o: any) => { seen.add(o.preset); return o.id; });
    for (const id of ids) {
      // A cleared screen drops its components on purpose, in the app too.
      if (!/(^|\n)\s*(clear|>\S+\s+clear)/.test(x.yl)) assert.ok(r.placed[id], `${x.name}: ${id} placed nowhere`);
    }
    for (const b of buttons(r.messages)) {
      if (b.callback_data) assert.ok(b.callback_data.length <= 64, x.name);
      if (b.web_app) assert.ok(b.web_app.url.length <= 4096, x.name);
    }
    assert.ok(r.messages.length > 0, x.name);
  }
  for (const p of PRESETS) assert.ok(seen.has(p), `samples lack ${p}`);
});

test("the Mini App link opens the same screen with the same ids", async () => {
  const yl = 'say "Pick one"\nchoose Q A|B\ntimer 30';
  const url = new URL((await appLink(yl, { agent: "Coach", bridge: "https://bot.example.com/yui" }))!);
  assert.equal(url.origin + url.pathname, "https://www.yuigui.com/tg");
  assert.equal(url.searchParams.get("agent"), "Coach");
  assert.equal(url.searchParams.get("bridge"), "https://bot.example.com/yui");
  const back = (await decodeYL(url.searchParams.get("yl")!))!;
  assert.deepEqual(parse(back).map((o: any) => o.id), parse(yl).map((o: any) => o.id));
});

test("share codes match yuigui's decoder", { skip: !hasHub && "no yuigui checkout" }, async () => {
  const { decodeYL: siteDecode, encodeYL: siteEncode } = await import(join(HUB, "site/lib/share-code.mjs"));
  const yl = 'timer 40/20x8 Tabata\nchoose "Café?" Oui|Non';
  const url = new URL((await appLink(yl, {}))!);
  assert.equal(await siteDecode(url.searchParams.get("yl")), yl);
  assert.equal(url.searchParams.get("yl"), await siteEncode(yl));
});

test("a screen too big for a link says so instead of a dead button", async () => {
  const big = Array.from({ length: 400 }, (_, i) => `timer ${i + 1}m "Round ${i} ${crypto.randomUUID()}"`).join("\n");
  const r = await renderYL(big, opts());
  const m = appMsg(r.messages)!;
  assert.equal(m.reply_markup, undefined);
  assert.match(m.text, /waiting in the Yui app/);
  assert.ok(r.errors.some((e) => /too big/.test(e)));
});

test("text presets read like the spec", async () => {
  assert.equal(statText({ label: "Weight", value: 178.9, unit: "lb", delta: -2.3 }), "Weight 178.9 lb, down 2.3");
  assert.equal(statText({ label: "Done", value: 80, unit: "%", delta: 5, sub: "this week" }), "Done 80%, up 5 (this week)");
  const list = await renderYL("list Today Squat Bench +check", opts());
  assert.equal(list.messages[0].text, "<b>Today</b>\n☐ Squat\n☐ Bench");
  const num = await renderYL("list Steps Mix Bake +num", opts());
  assert.equal(num.messages[0].text, "<b>Steps</b>\n1. Mix\n2. Bake");
  const table = await renderYL('table Macros Food|Cal "Eggs|140" "Oats|300"', opts());
  assert.equal(table.messages[0].text, "<b>Macros</b>\n<pre>Food  Cal\n----  ---\nEggs  140\nOats  300</pre>");
  const steps = await renderYL('step "Start from rest" title="Falling" tex="d = gt^2/2"\nstep "Solve for t"', opts());
  assert.equal(steps.messages.length, 1);
  assert.equal(steps.messages[0].text, "<b>Falling</b>\n1. Start from rest\n    <code>d = gt^2/2</code>\n2. Solve for t");
  const tl = await renderYL(LINE.timeline, opts());
  assert.equal(tl.messages[0].text, "<b>This week</b>\n✓ Shelf <i>YUI-32</i>\n▶ <b>War room</b>\n○ Replies");
});

test("HTML is escaped", async () => {
  const r = await renderYL('say "<b>hi</b> & bye"', opts());
  assert.equal(r.messages[0].text, "&lt;b&gt;hi&lt;/b&gt; &amp; bye");
});

test("a card with url= is a url button, with only cta= a callback", async () => {
  const a = await renderYL('card "Build 80" "Try it" url=https://testflight.apple.com/x cta=Install', opts());
  assert.deepEqual(a.messages[0].reply_markup!.inline_keyboard, [[{ text: "Install", url: "https://testflight.apple.com/x" }]]);
  const b = await renderYL('card "Leg day" cta="Start workout"', { ...opts(), token: () => "tok" });
  assert.deepEqual(b.messages[0].reply_markup!.inline_keyboard, [[{ text: "Start workout", callback_data: "y:tok:c" }]]);
  const c = await renderYL('card "Just news" "Nothing to do"', opts());
  assert.equal(c.messages[0].reply_markup, undefined);
});

test("questions: buttons, Type your own, Done, and lock", async () => {
  const r = await renderYL('choose "Slot?" "3:00 pm"|"4:00 pm" +other', { ...opts(), token: () => "t1" });
  const kb = r.messages[0].reply_markup!.inline_keyboard;
  assert.deepEqual(kb[0], [{ text: "3:00 pm", callback_data: "y:t1:0" }, { text: "4:00 pm", callback_data: "y:t1:1" }]);
  assert.equal(kb[1][0].text, "Type your own");
  assert.match(kb[1][0].web_app!.url, /^https:\/\/www\.yuigui\.com\/tg\?yl=/);
  const ask = await renderYL('ask "Send it?"', { ...opts(), token: () => "t2" });
  assert.deepEqual(ask.messages[0].reply_markup!.inline_keyboard, [[{ text: "Yes", callback_data: "y:t2:0" }, { text: "No", callback_data: "y:t2:1" }]]);
  const pick = await renderYL('pick "Gear?" A|B submit=Save', { ...opts(), token: () => "t3" });
  assert.deepEqual(pick.messages[0].reply_markup!.inline_keyboard.at(-1), [{ text: "Save", callback_data: "y:t3:d" }]);
  const locked = await renderYL('choose "Table for" 2|4 +lock', opts());
  assert.equal(locked.messages[0].reply_markup, undefined);
  const long = await renderYL('choose "Which?" "A long option label here"|"Another long label there"|C', opts());
  assert.equal(long.messages[0].reply_markup!.inline_keyboard.length, 2, "long labels wrap");
});

test("a whole reply: chat text, fences, an unclosed fence", async () => {
  assert.deepEqual(split("Hi\n```yui\nsay a\n```\nbye"), [{ text: "Hi\n" }, { yl: "say a\n" }, { text: "\nbye" }]);
  assert.deepEqual(split("x\n```yui\nsay cut"), [{ text: "x\n" }, { yl: "say cut" }]);
  const r = await render("Here you go.\n```yui\nchoose Q A|B\ntimer 30\n```\nTell me.", opts());
  assert.deepEqual(r.messages.map((m) => m.text.split("\n")[0]), ["Here you go.", "<b>Q</b>", "<b>Open in Yui</b> for the rest of this screen:", "Tell me."]);
});

test("the Open in Yui message sits where its first component was", async () => {
  const r = await renderYL('say one\ntimer 30\nsay two\nchart line x=a|b y=1|2', opts());
  assert.deepEqual(r.messages.map((m) => m.text.split("\n")[0]), ["one", "<b>Open in Yui</b> for the rest of this screen:", "two"]);
  assert.equal(appMsg(r.messages)!.text, "<b>Open in Yui</b> for the rest of this screen:\n⏱ Timer: 30s\n📈 Chart");
});

test("labels name what waits in the app", () => {
  assert.equal(label({ preset: "timer", props: { work: 40, rest: 20, rounds: 8, label: "Tabata" } }), "Tabata: 40s on, 20s off, 8 rounds");
  assert.equal(label({ preset: "timer", props: { work: 90 } }), "Timer: 1:30");
  assert.equal(label({ preset: "form", props: { fields: [{ key: "name" }, { key: "goal" }] } }), "Form: name, goal");
  assert.equal(label({ preset: "game", props: { kind: "snake" } }), "Play snake");
});

test("menu lines send nothing and a +fold card shows open (YL.md 5, The drawer; 10)", async () => {
  const r = await renderYL('say Drafted.\nmenu backlog@deload "Deload week plan" sub=drafting\nmenu done dana\ncard "Deload" "Lighter sets, more sleep." +fold', opts());
  assert.deepEqual(r.messages.map((m) => m.text), ["Drafted.", "<b>Deload</b>\nLighter sets, more sleep."]);
  assert.deepEqual(r.errors, []);
});
