#!/usr/bin/env node
// Native Yui on your own machine (NATIVE-1): the same runtime the Yui app's
// server runs, with your own model key, keeping everything in one JSON file.
//
//   node runtime/cli.ts chat [--agent yui]          talk; /agents, /use <handle>, /memory, /quit
//   node runtime/cli.ts try "make me a beat" --agent gouda
//   node runtime/cli.ts memory                      what your agents remember
//   node runtime/cli.ts profiles                    the shelf, checked
//
// Model: OpenRouter by default, key from $OPENROUTER_API_KEY. Any other
// OpenAI-compatible server: --url http://127.0.0.1:11434/v1 [--key-env NAME] --model qwen3:8b
// Web search: Firecrawl, key from $FIRECRAWL_API_KEY (no key: agents answer from what they know).
// State: ~/.yui-native/state.json (--state to change). Delete it to start over.
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { createInterface } from "node:readline/promises";
import { parseArgs } from "node:util";
import { fileURLToPath } from "node:url";
import { LocalStore, type LocalData } from "./src/store.ts";
import { crew, starters, checkProfile } from "./src/profiles.ts";
import { learnNoun, runAgent, runJob, runScheduled, openRouter, type Provider } from "./src/turn.ts";
import { aboutOf, notesOf } from "./src/memory.ts";
import { extract } from "./src/directives.ts";
import type { NativeAgent } from "./src/types.ts";

const USER = "local";
const search = { key: process.env.FIRECRAWL_API_KEY || undefined };
const here = dirname(fileURLToPath(import.meta.url));

const { values: opt, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    agent: { type: "string", default: "yui" },
    state: { type: "string", default: join(homedir(), ".yui-native", "state.json") },
    url: { type: "string" },
    "key-env": { type: "string" },
    model: { type: "string" },
    "vision-model": { type: "string" },
    verbose: { type: "boolean", short: "v", default: false },
  },
});
const [cmd = "chat", ...rest] = positionals;

function guide(): string {
  const p = join(here, "..", "hermes-plugin", "yui", "CHANNEL.md");
  return existsSync(p) ? readFileSync(p, "utf8").replace(/^<!--[^\n]*-->\n/, "") : "";
}

function provider(): Provider {
  if (opt.url) {
    const key = opt["key-env"] ? process.env[opt["key-env"]] : undefined;
    return { url: opt.url, ...(key ? { key } : {}) };
  }
  const key = process.env.OPENROUTER_API_KEY;
  if (!key) {
    console.error("Set OPENROUTER_API_KEY, or point at another server with --url (and --key-env if it needs a key).");
    process.exit(2);
  }
  return openRouter(key);
}

function open(): LocalStore {
  let data: Partial<LocalData> = {};
  try {
    data = JSON.parse(readFileSync(opt.state!, "utf8"));
  } catch {}
  const store = new LocalStore(data, { guide: guide(), freeTurns: 1e9 });
  store.onChange = () => {
    mkdirSync(dirname(opt.state!), { recursive: true });
    const tmp = `${opt.state}.tmp`;
    writeFileSync(tmp, JSON.stringify(store.data, null, 1), { mode: 0o600 });
    renameSync(tmp, opt.state!);
  };
  // Check-ins run in your own time zone.
  store.data.timezones = { ...(store.data.timezones ?? {}), [USER]: Intl.DateTimeFormat().resolvedOptions().timeZone };
  if (opt.model || opt["vision-model"]) {
    store.data.routes = { text: opt.model ?? "z-ai/glm-5.2", vision: opt["vision-model"] ?? opt.model ?? "z-ai/glm-5v-turbo" };
  }
  return store;
}

async function ensureCrew(store: LocalStore): Promise<NativeAgent[]> {
  let mine = await store.agents(USER);
  if (!mine.length) {
    for (const p of starters()) await store.createAgent(USER, p);
    mine = await store.agents(USER);
    console.log(`Made your crew: ${mine.map((a) => a.profile.name).join(", ")}.`);
  }
  return mine;
}

async function pick(store: LocalStore, handle: string): Promise<NativeAgent> {
  const mine = await store.agents(USER);
  const a = mine.find((x) => x.profile.handle === handle.replace(/^@/, ""));
  if (!a) {
    console.error(`No agent @${handle}. You have: ${mine.map((x) => "@" + x.profile.handle).join(" ")}`);
    process.exit(2);
  }
  return a;
}

/** Check-ins that came due while you were away or typing. */
async function dueCheckins(store: LocalStore, pv: Provider) {
  for (const s of store.due(Date.now())) {
    const before = new Set(store.data.rows.map((r) => r.id));
    await runScheduled(store, s.id, { provider: pv, search, log: opt.verbose ? (m) => console.error(`  · ${m}`) : undefined });
    for (const row of store.data.rows.filter((r) => !before.has(r.id) && r.sender === "agent")) {
      console.log(`\n${(await store.agent(row.agent_id))?.profile.name ?? "Agent"} (check-in): ${row.body}\n`);
    }
  }
}

/** Runs one message through the agent and prints what came back. */
async function turn(store: LocalStore, agent: NativeAgent, text: string, pv: Provider): Promise<void> {
  store.say(agent.id, text);
  const before = new Set(store.data.rows.map((r) => r.id));
  const o = { provider: pv, search, log: opt.verbose ? (m: string) => console.error(`  · ${m}`) : undefined };
  const r = await runAgent(store, agent.id, o);
  // Work queued by the answer (a meal's macros) runs right after it, as on the server.
  for (const j of r.jobs) await runJob(store, j, o);
  for (const n of r.learn ?? []) await learnNoun(store, n, o);
  const fresh = store.data.rows.filter((row) => !before.has(row.id) && row.sender === "agent");
  for (const row of fresh) {
    const who = (await store.agent(row.agent_id))?.profile.name ?? "Agent";
    console.log(`\n${who}: ${row.body}\n`);
  }
  if (!r.turns) console.log("(nothing to answer)");
}

function showMemory(store: LocalStore) {
  const about = aboutOf(store.data.memory.filter((m) => m.userId === USER));
  console.log(about.length ? "About you:" : "About you: nothing yet.");
  for (const a of about) console.log(`  ${a.key}: ${a.body}`);
  for (const [id, a] of Object.entries(store.data.agents)) {
    const notes = notesOf(store.data.memory, id);
    if (notes.length) console.log(`${a.profile.name}'s notes:\n${notes.map((n, i) => `  [n${i + 1}] ${n.body}`).join("\n")}`);
  }
}

async function main() {
  if (cmd === "profiles") {
    for (const [base, p] of Object.entries(crew())) {
      const bad = checkProfile(p);
      console.log(`${bad.length ? "✗" : "✓"} ${base.padEnd(8)} ${p.name} (${p.role}), v${p.version}, favorites ${p.favorites.join(" ")}${bad.length ? `\n    ${bad.join("; ")}` : ""}`);
      if (!extract(p.first).text.includes("```yui")) console.log("    first answer has no screen");
    }
    return;
  }
  const store = open();
  await ensureCrew(store);
  if (cmd === "memory") return showMemory(store);
  const pv = provider();
  if (cmd === "try") {
    const text = rest.join(" ").trim();
    if (!text) throw new Error('try needs a message: node runtime/cli.ts try "hello"');
    return turn(store, await pick(store, opt.agent!), text, pv);
  }
  if (cmd !== "chat") throw new Error(`unknown command ${cmd}`);

  let agent = await pick(store, opt.agent!);
  const first = store.data.rows.filter((r) => r.agent_id === agent.id);
  if (first.length === 1) console.log(`\n${agent.profile.name}: ${first[0].body}\n`);
  console.log(`Talking to ${agent.profile.name}. /agents, /use <handle>, /memory, /quit`);
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  const clock = setInterval(() => dueCheckins(store, pv).catch((e) => console.error(e.message)), 30_000);
  await dueCheckins(store, pv);
  for (;;) {
    const line = (await rl.question("you> ")).trim();
    if (!line) continue;
    if (line === "/quit" || line === "/exit") break;
    if (line === "/memory") { showMemory(store); continue; }
    if (line === "/agents") {
      for (const a of await store.agents(USER)) console.log(`  @${a.profile.handle.padEnd(10)} ${a.profile.name} (${a.profile.role || "custom"}) v${a.profile.version}`);
      continue;
    }
    const use = line.match(/^\/use\s+@?(\S+)/);
    if (use) {
      agent = await pick(store, use[1]);
      console.log(`Now talking to ${agent.profile.name}.`);
      continue;
    }
    await turn(store, agent, line, pv);
    agent = (await store.agent(agent.id)) ?? agent; // a blank agent may have become someone
  }
  clearInterval(clock);
  rl.close();
}

main().catch((e) => {
  console.error(e?.message ?? e);
  process.exit(1);
});
