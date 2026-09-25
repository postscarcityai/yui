// Round trips: a button tap comes back as the exact line the phone sends
// (spec/RELAY.md "App to agent: events"), with the app's rules for changed
// answers, repeats, picks and quizzes. Run: node --test tests/*.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { MemoryStore, renderYL, type Message } from "../src/render.ts";
import { replies, tap } from "../src/taps.ts";

async function screen(yl: string) {
  const store = new MemoryStore();
  let n = 0;
  const r = await renderYL(yl, { store, token: () => `t${++n}` });
  const press = async (label: string, msg = 0) => {
    const b = kb(r.messages[msg]).find((x) => x.text === label || x.text.endsWith(` ${label}`) || x.text.startsWith(label));
    assert.ok(b?.callback_data, `no button "${label}"`);
    const t = await tap(b.callback_data, store);
    if (t?.keyboard) r.messages[msg] = { ...r.messages[msg], reply_markup: { inline_keyboard: t.keyboard } };
    return t;
  };
  return { r, store, press };
}
const kb = (m: Message) => m.reply_markup?.inline_keyboard.flat() ?? [];

test("choose: the tap is the phone's line, and a change says changed", async () => {
  const { r, press } = await screen('say "Which?"\nchoose "What today?" Push|Pull|Legs');
  const a = await press("Legs", 1);
  assert.equal(a!.line, "[yui] n2 choose choice=Legs");
  assert.deepEqual(a!.event, { id: "n2", preset: "choose", choice: "Legs" });
  assert.equal(a!.echo, "Legs");
  assert.equal(a!.toast, "Sent: Legs");
  assert.deepEqual(kb(r.messages[1]).map((b) => b.text), ["Push", "Pull", "✓ Legs"]);
  assert.equal((await press("Legs", 1))!.toast, "Already sent");
  const b = await press("Pull", 1);
  assert.equal(b!.line, "[yui] n2 choose changed choice=Pull");
  assert.deepEqual(kb(r.messages[1]).map((b) => b.text), ["Push", "✓ Pull", "Legs"]);
});

test("ask: answer=, quoted when it has a space, default Yes|No", async () => {
  const s = await screen('ask "Send the invite now?" "Yes, send"|"Not yet"');
  assert.equal((await s.press("Not yet"))!.line, '[yui] n1 ask answer="Not yet"');
  const d = await screen('ask "Log this set?"');
  assert.equal((await d.press("Yes"))!.line, "[yui] n1 ask answer=Yes");
});

test("an explicit @id is the event id", async () => {
  const s = await screen('choose@split "Split?" Push|Pull');
  assert.equal((await s.press("Push"))!.line, "[yui] split choose choice=Push");
});

test("a graded quiz carries correct", async () => {
  const s = await screen('choose "Where is mRNA read?" Nucleus|Cytoplasm answer=Cytoplasm');
  assert.equal((await s.press("Nucleus"))!.line, "[yui] n1 choose choice=Nucleus correct=false");
  assert.equal((await s.press("Cytoplasm"))!.line, "[yui] n1 choose changed choice=Cytoplasm correct");
});

test("pick: toggles in place, Done sends the picks in tap order", async () => {
  const { r, press } = await screen('pick "What gear do you have?" Dumbbells|Bench|Bands|"Pull-up bar"');
  assert.equal((await press("Done"))!.toast, "Pick at least one");
  const t = await press("Bands");
  assert.equal(t!.event, undefined);
  assert.equal(t!.toast, "");
  await press("Dumbbells");
  assert.deepEqual(kb(r.messages[0]).map((b) => b.text), ["☐ Dumbbells".replace("☐", "☑"), "☐ Bench", "☑ Bands", "☐ Pull-up bar", "Done (2)"]);
  const d = await press("Done");
  assert.equal(d!.line, "[yui] n1 pick picked=Bands|Dumbbells");
  assert.equal(d!.echo, "Bands, Dumbbells");
  assert.equal((await press("Done"))!.toast, "Already sent");
  await press("Bands"); await press("Bands"); // off and on again: same set
  assert.equal((await press("Done"))!.toast, "Already sent");
  await press("Pull-up bar");
  assert.equal((await press("Done"))!.line, '[yui] n1 pick changed picked=Dumbbells|Bands|"Pull-up bar"');
});

test("pick: max= stops at the limit, a graded pick carries correct", async () => {
  const m = await screen("pick Two? A|B|C max=2");
  await m.press("A"); await m.press("B");
  assert.equal((await m.press("C"))!.toast, "Up to 2");
  assert.equal((await m.press("Done"))!.line, "[yui] n1 pick picked=A|B");
  const q = await screen('pick "Which are primes?" 2|4|5 answer=2|5');
  await q.press("5"); await q.press("2");
  assert.equal((await q.press("Done"))!.line, "[yui] n1 pick correct picked=5|2");
});

test("card cta: the tap sends cta, every time, like the app", async () => {
  const s = await screen('card "Leg day" "Squat, RDL." cta="Start workout"');
  const a = await s.press("Start workout");
  assert.equal(a!.line, '[yui] n1 card cta="Start workout"');
  assert.equal(a!.echo, "Start workout");
  assert.equal((await s.press("Start workout"))!.line, '[yui] n1 card cta="Start workout"');
});

test("a screen brought back with show carries saved", async () => {
  const s = await screen("choose Q A|B\nsave warm\nclear\nshow warm");
  const t = await s.press("A");
  assert.equal(t!.line, "[yui] n1 choose choice=A saved=warm");
});

test("taps from two screens stay apart", async () => {
  const store = new MemoryStore();
  const one = await renderYL("choose One? A|B", { store });
  const two = await renderYL("choose Two? A|B", { store });
  const a = await tap(kb(one.messages[0])[0].callback_data!, store);
  const b = await tap(kb(two.messages[0])[1].callback_data!, store);
  assert.equal(a!.line, "[yui] n1 choose choice=A");
  assert.equal(b!.line, "[yui] n1 choose choice=B");
  const tokens = [...store.map.keys()];
  assert.equal(new Set(tokens).size, 2);
  for (const t of tokens) assert.match(t, /^[A-Za-z0-9_-]{8}$/);
});

test("not ours, stale or malformed callback_data is ignored", async () => {
  const s = await screen("choose Q A|B");
  assert.equal(await tap("", s.store), null);
  assert.equal(await tap("other-plugin:1", s.store), null);
  assert.equal(await tap("y:nope:0", s.store), null);
  assert.equal(await tap("y:t1:9", s.store), null);
  assert.equal(await tap("y:t1:d", s.store), null);
  assert.equal(await tap("y:t1:0:extra", s.store), null);
});

test("callback_data stays under Telegram's 64 bytes with many options", async () => {
  const opts = Array.from({ length: 40 }, (_, i) => `o${i}`).join("|");
  const s = await screen(`pick Many ${opts}`);
  for (const b of kb(s.r.messages[0])) assert.ok(new TextEncoder().encode(b.callback_data!).length <= 64);
  assert.equal((await s.press("o39"))!.toast, "");
});

test("replies: the toast, then the new buttons on the tapped message", async () => {
  const s = await screen("choose Q A|B");
  const t = await s.press("B");
  const calls = replies({ id: "cb1", message: { chat: { id: 42 }, message_id: 7 } }, t);
  assert.deepEqual(calls[0], { method: "answerCallbackQuery", params: { callback_query_id: "cb1", text: "Sent: B" } });
  assert.equal(calls[1].method, "editMessageReplyMarkup");
  assert.deepEqual(calls[1].params.reply_markup, { inline_keyboard: [[{ text: "A", callback_data: "y:t1:0" }, { text: "✓ B", callback_data: "y:t1:1" }]] });
  assert.deepEqual(replies({ id: "cb2" }, null), [{ method: "answerCallbackQuery", params: { callback_query_id: "cb2" } }]);
});
