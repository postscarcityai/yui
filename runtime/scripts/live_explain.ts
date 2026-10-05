#!/usr/bin/env node
// Explain asks through the real runtime and OpenRouter (t_88023cf2): for each ask, one Home turn with the real channel guide,
// then whether the net had to redraw it and how much of what was saved is drawn.
//
//   OPENROUTER_API_KEY=... node runtime/scripts/live_explain.ts --guide <yuigui>/spec/CHANNEL.md [--runs 3] [--json out.json] ["Eli5 string theory" ...]
import { readFileSync, writeFileSync } from "node:fs";
import { parseArgs } from "node:util";
import { LocalStore } from "../src/store.ts";
import { starters } from "../src/profiles.ts";
import { runAgent, openRouter } from "../src/turn.ts";
import { pagesOf } from "../src/teach.ts";

const { values: opt, positionals } = parseArgs({ options: { guide: { type: "string" }, runs: { type: "string", default: "3" }, json: { type: "string" } }, allowPositionals: true });
const key = process.env.OPENROUTER_API_KEY;
if (!key || !opt.guide) {
  console.error("Set OPENROUTER_API_KEY and pass --guide <spec/CHANNEL.md>.");
  process.exit(2);
}
const spec = readFileSync(opt.guide, "utf8");
const guide = spec.slice(spec.indexOf("## You are talking to someone in Yui")).trimEnd();
const asks = positionals.length ? positionals : ["Eli5 string theory", "ELI5 black holes", "Explain inflation to me like I'm five."];
const out: unknown[] = [];
for (const ask of asks) {
  for (let i = 0; i < Number(opt.runs); i++) {
    const store = new LocalStore({}, { guide, freeTurns: 100 });
    for (const p of starters()) await store.createAgent("live", p);
    const yui = (await store.agents("live")).find((a) => a.profile.handle === "yui")!;
    const logs: string[] = [];
    let calls = 0;
    const spy = ((url: string, init: any) => (calls++, fetch(url, init))) as typeof fetch;
    store.say(yui.id, ask);
    const r = await runAgent(store, yui.id, { provider: openRouter(key), fetch: spy, log: (m) => logs.push(m) });
    const saved = store.data.rows.find((x) => x.id === r.replies[0])?.body ?? "";
    const p = pagesOf(saved);
    const redrew = logs.find((l) => l.includes("asking once more to draw it"));
    const kept = logs.some((l) => l.includes("no better"));
    const row = { ask, calls, firstTry: redrew ? redrew.replace(/^[^:]*: /, "") : "drawn", redraw: redrew ? (kept ? "no better, first kept" : "kept") : "none",
                  saved: `${p.pages - p.bare.length}/${p.pages} pages drawn, ${p.decks} deck`, savedBody: saved };
    out.push(row);
    console.log(`${ask} #${i + 1}: first try ${row.firstTry}; redraw ${row.redraw}; saved ${row.saved}`);
  }
}
if (opt.json) writeFileSync(opt.json, JSON.stringify(out, null, 2) + "\n");
