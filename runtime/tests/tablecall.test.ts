// YUI-171: the one tables call any agent reaches (tablecall.ts), on the same store a native agent keeps.
import { test } from "node:test";
import assert from "node:assert/strict";
import { callLines, holdAsk, holdTap, holdingLine, readNote, refuseCall, replyRead, rowsText, runLines, runReply, settleHold } from "../src/tablecall.ts";
import { diff, emptyStore } from "../src/tables.ts";

const CTX = { today: "2026-09-27", now: "2026-09-27T12:30" };
const ids = () => { let n = 0; return () => `id${n++}`; };

function made() {
  return runLines(callLines(`table create foods Food:text Cal:number:kcal Protein:number:g
put foods oats Food=Oats Cal=300 Protein=10
put foods eggs Food="Two eggs" Cal=140 Protein=12
put foods Food=Toast Cal=80 Protein=3`), emptyStore(), CTX, ids()).store;
}

test("lines run in order: writes land, a query hands the rows back", () => {
  const r = runLines(callLines("table create meals Day:date Food:text Cal:number\nput meals Day=today Food=Oats Cal=300\nquery meals"),
                     emptyStore(), CTX, ids());
  assert.equal(r.failed.length, 0, JSON.stringify(r.failed));
  assert.equal(r.ok.length, 3);
  assert.equal(r.results.length, 1);
  assert.deepEqual(r.results[0].cols.map((c) => c.name), ["Day", "Food", "Cal"]);
  assert.deepEqual(r.results[0].rows, [["2026-09-27", "Oats", 300]]);
  assert.equal(r.results[0].count, 1);
  assert.deepEqual(r.read, ["meals"]);
});

test("where, sort and limit are the store's own", () => {
  const r = runLines(["query foods sort=-Protein limit=2"], made(), CTX, ids());
  assert.deepEqual(r.results[0].rows.map((x) => x[0]), ["Two eggs", "Oats"]);
  assert.equal(r.results[0].count, 3);
  const w = runLines(["query foods where=Food~oat"], made(), CTX, ids());
  assert.deepEqual(w.results[0].rows.map((x) => x[0]), ["Oats"]);
  assert.match(rowsText(r.results[0]), /^foods\nkey \| Food \| Cal \(kcal\) \| Protein \(g\)\neggs \| Two eggs/);
});

test("a refused line says why and writes nothing; the rest still run", () => {
  const r = runLines(["put foods Cal=abc", "put foods Food=Rice Cal=200", "query nope", "hello there"], made(), CTX, ids());
  assert.equal(r.failed.length, 3);
  assert.match(r.failed[0].error, /Cal/);
  assert.equal(r.failed[1].error, "No table called nope yet");
  assert.match(r.failed[2].error, /Not a table line/);
  assert.equal(r.store.tables.foods.order.length, 4);
});

test("another agent's store hears 'No table called foods yet'", () => {
  const r = runLines(["query foods"], emptyStore(), CTX, ids());
  assert.deepEqual(r.failed, [{ line: "query foods", error: "No table called foods yet" }]);
});

test("deletes never run on the agent's say: held with a Delete or Keep ask, applied only on the tap", () => {
  const s = made();
  const r = runLines(["put foods oats +delete", "table drop nothing"], s, CTX, ids());
  assert.equal(r.store, s, "nothing changed yet");
  assert.equal(r.failed[0].error, "No table called nothing yet");
  assert.ok(r.held);
  assert.match(r.held!.id, /^del-/);
  assert.equal(r.held!.ask, "Delete Oats from foods?");
  assert.equal(holdAsk(r.held!), "```yui\nchoose@" + r.held!.id + ' "Delete Oats from foods?" Delete|Keep\n```');
  assert.deepEqual(holdTap(`[yui] ${r.held!.id} choose choice=Delete`), { id: r.held!.id, choice: "Delete" });
  assert.deepEqual(holdTap(`[yui] ${r.held!.id} choose choice=Keep`), { id: r.held!.id, choice: "Keep" });
  assert.equal(holdTap("[yui] n1 choose choice=Delete"), null);
  const done = settleHold(s, r.held!.lines, CTX);
  assert.equal(done.done, 1);
  assert.deepEqual(done.store.tables.foods.order, ["eggs", "r1"]);
  assert.deepEqual(diff(s, done.store).dropRows, [{ table: "foods", key: "oats" }]);
});

test("a delete of a row that is not there is refused, not held", () => {
  const r = runLines(["put foods nope +delete"], made(), CTX, ids());
  assert.equal(r.held, null);
  assert.match(r.failed[0].error, /No row nope/);
});

test("a fence comes off, # notes and blanks are skipped; more than 50 lines is refused whole", () => {
  assert.deepEqual(callLines("```yui\nquery foods\n\n# a note\n```"), ["query foods"]);
  assert.equal(refuseCall(Array(50).fill("query foods")), null);
  assert.match(refuseCall(Array(51).fill("query foods"))!, /50 at most/);
});

test("a query asks for 500 rows at most", () => {
  let s = runLines(["table create n V:number"], emptyStore(), CTX, ids()).store;
  s = runLines(Array.from({ length: 50 }, (_, i) => `put n V=${i}`), s, CTX, ids()).store;
  const big = runLines(["query n limit=9999"], s, CTX, ids());
  assert.equal(big.results[0].rows.length, 50);
  const dflt = runLines(["query n limit=10"], s, CTX, ids());
  assert.equal(dflt.results[0].rows.length, 10);
});

test("a whole reply works like a native answer: queries drawn, words gone", () => {
  const r = runReply("Logged.\n```yui\nput foods Food=Rice Cal=200\nquery foods sort=-Cal limit=2 as table\n```", made(), CTX, ids());
  assert.doesNotMatch(r.text, /^put |^query /m);
  assert.match(r.text, /```yui\ntable name=/);
  assert.equal(r.wrote, 1);
});

test("what the agent holds, one line", () => {
  assert.equal(holdingLine(emptyStore()), "[yui] tables (none yet)");
  assert.equal(holdingLine(made()), "[yui] tables foods(3 rows: Food, Cal, Protein)");
});

test("a reply of query lines alone is a read; anything else for the person is not (step 3)", () => {
  assert.deepEqual(replyRead("```yui\nquery foods sort=-Protein limit=2\n```"), ["query foods sort=-Protein limit=2"]);
  assert.deepEqual(replyRead("```tables\nfoods where=Food~oat\n```"), ["query foods where=Food~oat"]);
  assert.deepEqual(replyRead("query foods"), ["query foods"]); // loose, gathered into a yui block
  assert.equal(replyRead("Here you go.\n```yui\nquery foods\n```"), null);
  assert.equal(replyRead("```yui\nquery foods\ncard \"Hi\"\n```"), null);
  assert.equal(replyRead("```yui\nput foods Food=Rice Cal=200\n```"), null);
  assert.equal(replyRead("Just words."), null);
  const r = runLines(replyRead("```yui\nquery foods sort=-Protein limit=2\nquery nope\n```")!, made(), CTX, ids());
  const note = readNote(r);
  assert.match(note, /^\[yui\] Your tables:\n\nfoods\nkey \| Food/);
  assert.match(note, /Refused "query nope": No table called nope yet\./);
  assert.match(note, /\[yui\] Answer the person now/);
});
