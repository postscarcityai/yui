#!/usr/bin/env node
// One live turn of each route (NATIVE-1): a text turn and a photo turn,
// through the real runtime and OpenRouter. Prints which model served each,
// that data_collection deny went out, and what came back. Exits 1 on a wrong
// route or an error reply.
//
//   OPENROUTER_API_KEY=... node runtime/scripts/live.ts [--photo URL] [--json out.json]
import { writeFileSync } from "node:fs";
import { parseArgs } from "node:util";
import { LocalStore } from "../src/store.ts";
import { starters } from "../src/profiles.ts";
import { runAgent, openRouter } from "../src/turn.ts";

const { values: opt } = parseArgs({
  options: {
    photo: { type: "string", default: "https://upload.wikimedia.org/wikipedia/commons/a/a3/Eq_it-na_pizza-margherita_sep2005_sml.jpg" },
    json: { type: "string" },
  },
});
const key = process.env.OPENROUTER_API_KEY;
if (!key) {
  console.error("Set OPENROUTER_API_KEY.");
  process.exit(2);
}

const sent: { model: string; deny: boolean; image: boolean }[] = [];
const spy = (async (url: string, init: any) => {
  const body = JSON.parse(init.body);
  const image = body.messages.some((m: any) => Array.isArray(m.content) && m.content.some((p: any) => p.type === "image_url"));
  sent.push({ model: body.model, deny: body.provider?.data_collection === "deny", image });
  return fetch(url, init);
}) as typeof fetch;

const store = new LocalStore({}, { guide: "", freeTurns: 100 });
for (const p of starters()) await store.createAgent("live", p);
const agents = await store.agents("live");
const basil = agents.find((a) => a.profile.handle === "basil") ?? agents[0];

const turns = [
  { name: "text", body: "Give me a quick lunch idea with 30g of protein.", kind: "text" },
  { name: "photo", body: `[yui] c1 camera photo=${opt.photo}`, kind: "event" },
];
const out = [];
for (const t of turns) {
  const n = sent.length;
  const before = new Set(store.data.rows.map((r) => r.id));
  store.say(basil.id, t.body, t.kind);
  const t0 = Date.now();
  await runAgent(store, basil.id, { provider: openRouter(key), fetch: spy });
  const reply = store.data.rows.filter((r) => !before.has(r.id) && r.sender === "agent").map((r) => r.body).join("\n");
  const row = { turn: t.name, asked: sent[n]?.model, calls: sent.length - n, data_collection_deny: sent[n]?.deny, image_part: sent[n]?.image, ms: Date.now() - t0, reply };
  out.push(row);
  console.log(`\n== ${t.name}: model ${row.asked}, deny=${row.data_collection_deny}, image=${row.image_part}, calls=${row.calls}, ${row.ms} ms\n${reply}`);
}
if (opt.json) writeFileSync(opt.json, JSON.stringify(out, null, 1));
const ok = out[0].asked === "z-ai/glm-5.2" && out[1].asked === "z-ai/glm-5v-turbo" && out.every((r) => r.data_collection_deny && r.reply && !/couldn't answer|can't reach/.test(r.reply));
process.exit(ok ? 0 : 1);
