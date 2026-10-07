#!/usr/bin/env node
// MOTION-30 measurement (no live drawings table: a first ask is clean, and the same on every run). Cloned from live_motion29.ts.
// MOTION-29 measurement: unseeded nouns asked of a native agent twice, through the real runtime and OpenRouter, with the learned
// drawings in the real yui_motion_things table (yuigui Supabase). Every ask is a fresh account (a fresh LocalStore); only the
// shared drawings carry over, as they do for people.
//
//   OPENROUTER_API_KEY=... SUPABASE_SERVICE_KEY=... node runtime/scripts/live_motion29.ts --guide <yuigui>/spec/CHANNEL.md \
//        --asks <asks.json> --phase ask1|ask2 --out <dir> [--only noun,noun]
// asks.json = [{noun, ask, ask2}]. ask1: each ask, then the learner for any noun the film drew itself. ask2: the second wording.
// Writes <out>/<noun>-<phase>.json (first scene seconds, model calls, drawing calls, the film's scenes).
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { LocalStore } from "../src/store.ts";
import { starters } from "../src/profiles.ts";
import { openRouter, runAgent } from "../src/turn.ts";
import { harvest, NO_KEPT } from "../src/motion.ts";
import { SupabaseStore } from "../src/supabase.ts";

const { values: o } = parseArgs({ options: { guide: { type: "string" }, asks: { type: "string" }, phase: { type: "string" }, out: { type: "string" }, only: { type: "string" }, live: { type: "boolean" } } });
const key = process.env.OPENROUTER_API_KEY;
if (!key || !o.guide || !o.asks || !o.phase || !o.out) { console.error("Set OPENROUTER_API_KEY and pass --guide --asks --phase --out."); process.exit(2); }
const spec = readFileSync(o.guide, "utf8");
const guide = spec.slice(spec.indexOf("## You are talking to someone in Yui")).trimEnd();
// --live: read the shared drawings (yui_motion_things) so a second ask can hit one; nothing is written to them.
const live = o.live && process.env.SUPABASE_SERVICE_KEY ? new SupabaseStore("https://txuibjxyfpalzvpneqgp.supabase.co", process.env.SUPABASE_SERVICE_KEY) : null;
mkdirSync(o.out, { recursive: true });

class Hybrid extends LocalStore {
  firstAt = 0; sceneAt = 0;
  async doing(rowId: string, text: string | null) { if (text === "Drawing the first scene" && !this.firstAt) this.firstAt = Date.now(); return super.doing(rowId, text); }
  async reply(agent: any, body: string, meta: Record<string, any>) {
    if (meta?.native?.film && meta.native.part === 1 && !this.sceneAt) this.sceneAt = Date.now();
    return super.reply(agent, body, meta);
  }
  async motionKept() { return live ? live.motionKept() : NO_KEPT; }
  async motionClaim() { return false; }
}

const asks: { noun: string; ask: string; ask2: string }[] = JSON.parse(readFileSync(o.asks, "utf8"));
const only = o.only?.split(",");
for (const x of asks.filter((a) => !only || only.includes(a.noun))) {
  const text = o.phase === "ask2" ? x.ask2 : x.ask;
  const store = new Hybrid({}, { guide, freeTurns: 100 });
  for (const p of starters()) await store.createAgent("live-" + x.noun, p);
  const yui = (await store.agents("live-" + x.noun)).find((a) => a.profile.handle === "yui")!;
  const logs: string[] = [];
  const bodies: string[] = [];
  let calls = 0, drew = 0;
  const spy = ((url: string, init: any) => {
    calls++;
    try { const b = JSON.parse(init.body); if (String(b.messages?.[0]?.content ?? "").startsWith("You name the thing")) drew++; } catch { /* not ours */ }
    return fetch(url, init);
  }) as typeof fetch;
  const opts = { provider: openRouter(key), fetch: spy, log: (m: string) => logs.push(m) };
  const t0 = Date.now();
  store.say(yui.id, text);
  const r = await runAgent(store, yui.id, opts);
  const turnS = (Date.now() - t0) / 1000;
  const drewAtAsk = drew;
  const learned: string[] = [];
  
  const film = store.data.rows.filter((row) => row.sender === "agent" && /^```yui\nmotion .*film=/.test(row.body)).sort((a, b) => (a.id < b.id ? -1 : 1));
  for (const row of film) bodies.push(row.body);
  // a row's own closing `end` line is the fence's terminator, not scene code
  const scenes = film.flatMap((row) => harvest(row.body + "\n=== end ===\n", 0).scenes).map((x) => ({ ...x, code: x.code.replace(/\n?end\s*$/, "") }));
  const rec = { noun: x.noun, phase: o.phase, ask: text, film_ask: (logs.find((l) => /: film m[0-9a-f]+, /.test(l)) ?? "").replace(/^.*scene\(s\) for /, ""), first_scene_s: store.sceneAt && store.firstAt ? +((store.sceneAt - store.firstAt) / 1000).toFixed(2) : null,
                turn_s: +turnS.toFixed(1), model_calls: calls, drawing_calls: drewAtAsk, learn_queued: r.learn ?? [], learned, scenes,
                hero: (scenes[0]?.code.match(/api\.thing\("([a-z0-9_]+)"/) ?? [])[1] ?? null, defined: /api\.defineThing\(/.test(scenes[0]?.code ?? ""),
                logs: logs.filter((l) => /film|learner|no scene|no hero/.test(l)) };
  writeFileSync(join(o.out, `${x.noun}-${o.phase}.json`), JSON.stringify(rec, null, 1));
  console.log(o.phase, x.noun, "first", rec.first_scene_s, "s; scenes", scenes.length, "; hero", rec.hero, "; drawing calls", drewAtAsk, "; learn", JSON.stringify(learned));
}
