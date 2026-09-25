#!/usr/bin/env node
// Yui AG-UI bridge (INT-21): add any agent served over AG-UI to Yui by its URL.
// Microsoft Agent Framework, CopilotKit runtimes, Mastra, Pydantic AI and
// LangGraph's AG-UI adapter all serve it.
//
//   node yui-agui.ts check http://127.0.0.1:8000/          # one hello run: does it answer?
//   node yui-agui.ts pair 123456 --url http://127.0.0.1:8000/ [--name "My agent"] [--header "authorization: Bearer ..."]
//   node yui-agui.ts add --url http://other.example.com/agui --name "Other"   # one more, no code
//   node yui-agui.ts run [--guide system|tool|context|off]
//   node yui-agui.ts status
//
// Runs next to nothing: it dials out to Yui and to the agent, no open ports.
// Node 22.18+ (runs the TypeScript as is), no dependencies. State (the
// connector token, the endpoints, each thread's messages, the reply outbox)
// lives in ~/.yui/agui.json (mode 600), or --state / $YUI_AGUI_STATE.
import { homedir } from "node:os";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { RunView, runAgent } from "./src/agui.ts";
import { Bridge, Refused, State, add, connectCall, log, pair, refFromName, showTool, type GuideMode, type Remote } from "./src/bridge.ts";

const USAGE = `usage: yui-agui.ts [--state FILE] <command>
  check <url> [--header "K: V"]               one hello run: what the agent says and which events it sends
  pair <code> --url URL [--name NAME] [--ref REF] [--header "K: V"] [--host-name NAME]
                                               claim the code from the app's Add agent
  add --url URL [--name NAME] [--ref REF] [--header "K: V"]
                                               another agent on this machine, no code
  run [--interval 2] [--guide system|tool|context|off]
                                               serve every paired agent
  status                                       the connector, its agents and their endpoints
  guide                                        print the channel guide the agent gets`;

function headers(list: string[] | undefined): Record<string, string> | undefined {
  if (!list?.length) return undefined;
  const out: Record<string, string> = {};
  for (const h of list) {
    const i = h.indexOf(":");
    if (i < 1) throw new Refused(`--header wants "Name: value", got ${JSON.stringify(h)}`);
    out[h.slice(0, i).trim().toLowerCase()] = h.slice(i + 1).trim();
  }
  return out;
}

function endpoint(url: string | undefined): string {
  if (!url) throw new Refused("needs --url <the agent's AG-UI endpoint>");
  let u: URL;
  try {
    u = new URL(url);
  } catch {
    throw new Refused(`not a URL: ${url}`);
  }
  if (!/^https?:$/.test(u.protocol)) throw new Refused(`AG-UI runs over http(s), got ${u.protocol}`);
  return u.href;
}

/** A short run with no history: proves the URL speaks AG-UI before a code is spent. */
async function check(url: string, hdrs?: Record<string, string>): Promise<{ view: RunView; types: string[] }> {
  const view = new RunView();
  const types: string[] = [];
  try {
    for await (const e of runAgent(url, {
      threadId: `yui-check-${Date.now()}`, runId: `yui-check-${Date.now()}`,
      messages: [{ id: "hello", role: "user", content: "Say hello in five words or fewer." }],
      tools: [showTool()], context: [], state: {}, forwardedProps: {},
    }, { headers: hdrs, idle: 120 })) {
      view.apply(e);
      if (!types.includes(e.type)) types.push(e.type);
    }
  } catch (e: any) {
    throw new Refused(`no AG-UI agent answered at ${url}: ${e?.message ?? e}`);
  }
  if (view.error) throw new Refused(`the agent ran and failed: ${view.error.message}`);
  return { view, types };
}

async function main(argv: string[]): Promise<number> {
  const { values: o, positionals: [cmd, arg] } = parseArgs({
    args: argv, allowPositionals: true,
    options: {
      state: { type: "string", default: process.env.YUI_AGUI_STATE ?? join(homedir(), ".yui/agui.json") },
      url: { type: "string" }, ref: { type: "string" }, name: { type: "string" },
      header: { type: "string", multiple: true }, "host-name": { type: "string" },
      interval: { type: "string", default: "2" }, guide: { type: "string", default: "system" },
      "no-check": { type: "boolean", default: false },
      help: { type: "boolean", short: "h" },
    },
  });
  if (o.help || !cmd) {
    console.log(USAGE);
    return cmd || o.help ? 0 : 2;
  }
  const state = new State(o.state!.replace(/^~(?=\/)/, homedir()));
  const hdrs = headers(o.header);

  if (cmd === "check") {
    const url = endpoint(arg ?? o.url);
    const { view, types } = await check(url, hdrs);
    console.log(`AG-UI at ${url}: ${JSON.stringify(view.text() || "(no words)")}\nevents: ${types.join(", ")}`);
    return 0;
  }
  if (cmd === "pair" || cmd === "add") {
    const url = endpoint(o.url);
    if (cmd === "pair" && !arg) throw new Refused("pair needs the 6-digit code from the app");
    if (!o["no-check"]) await check(url, hdrs); // a wrong URL fails here, before the code is spent
    const name = o.name ?? new URL(url).hostname;
    const ref = o.ref ?? refFromName(o.name ?? "agui");
    const remote: Remote = { url, headers: hdrs, ...(o.name ? { name: o.name } : {}) };
    const r = cmd === "pair" ? await pair(state, arg!, ref, remote, o["host-name"]) : await add(state, ref, remote, name);
    console.log(`${cmd === "pair" ? "paired" : r.created ? "added" : "already there"}: ${r.agent.name} is the AG-UI agent at ${url}. `
      + "Next: yui-agui.ts run");
    return 0;
  }
  const mode = o.guide as GuideMode;
  if (!["system", "tool", "context", "off"].includes(mode)) throw new Refused(`--guide is system, tool, context or off, not ${mode}`);
  const b = new Bridge(state, { interval: Number(o.interval), guide: mode });
  if (cmd === "status") {
    await b.session();
    console.log(`connector: ${state.data.connector?.name} (${state.path})`);
    for (const a of b.agents.values()) {
      const remote = state.data.remotes[a.remote_ref];
      const n = state.data.threads[a.id]?.length ?? 0;
      console.log(`- ${a.name} (${a.remote_ref}): ${remote ? remote.url : "no endpoint on this machine"}`
        + (remote ? `, ${n} message(s) in the thread` : "")
        + (state.data.calls[a.id] ? ", a screen waiting on a tap" : "")
        + (state.data.inflight[a.id] ? ", a turn in flight" : ""));
    }
    return 0;
  }
  if (cmd === "guide") {
    const g = (await connectCall({ action: "guide" })).guide ?? {};
    console.log(`Yui channel guide ${g.version}\n\n${g.body ?? ""}`);
    return 0;
  }
  if (cmd === "run") {
    const done = new Promise<void>((resolve) => {
      for (const sig of ["SIGINT", "SIGTERM"] as const) {
        process.once(sig, async () => { await b.stop(); log("stopped"); resolve(); });
      }
    });
    await Promise.race([b.run().then(() => done), done]);
    return 0;
  }
  console.error(USAGE);
  return 2;
}

main(process.argv.slice(2)).then((code) => process.exit(code), (e) => {
  console.error(`yui-agui: ${e instanceof Refused ? e.message : e?.stack ?? e}`);
  process.exit(1);
});
