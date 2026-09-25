#!/usr/bin/env node
// Yui A2A bridge (INT-18): add any A2A agent to Yui by its Agent Card.
//
//   node yui-a2a.ts card https://agent.example.com              # what the card says
//   node yui-a2a.ts pair 123456 --card https://agent.example.com [--ref name] [--header "authorization: Bearer ..."]
//   node yui-a2a.ts add --card https://other.example.com [--name "Other"]   # one more, no code
//   node yui-a2a.ts run
//   node yui-a2a.ts status
//
// Runs next to nothing: it dials out to Yui and to the agent, no open ports.
// Node 22.18+ (runs the TypeScript as is), no dependencies. State (the
// connector token, the cards, tasks in flight, the reply outbox) lives in
// ~/.yui/a2a.json (mode 600), or --state / $YUI_A2A_STATE.
import { homedir } from "node:os";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { A2AClient } from "./src/a2a.ts";
import { Bridge, Refused, State, add, connectCall, log, pair, refFromName, type Remote } from "./src/bridge.ts";

const USAGE = `usage: yui-a2a.ts [--state FILE] <command>
  card <url>                                   read an Agent Card: name, protocol, skills
  pair <code> --card URL [--ref NAME] [--header "K: V"] [--host-name NAME]
                                               claim the code from the app's Add agent
  add --card URL [--ref NAME] [--name NAME] [--header "K: V"]
                                               another agent on this machine, no code
  run [--interval 2] [--no-guide]              serve every paired agent
  status                                       the connector, its agents and their cards
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

async function readCard(url: string, hdrs?: Record<string, string>) {
  const { client, card, cardUrl } = await A2AClient.fromCard(url, { headers: hdrs });
  return { client, card, remote: { card: cardUrl, headers: hdrs, name: card.name } as Remote };
}

function describe(card: { name: string; description: string; streaming: boolean; skills: { name: string; description?: string }[] }, client: A2AClient): string {
  const skills = card.skills.map((s) => `  - ${s.name}${s.description ? `: ${s.description}` : ""}`).join("\n");
  return `${card.name}: ${card.description}\nA2A ${client.version} at ${client.url}${card.streaming ? ", streaming" : ", no streaming"}`
    + (skills ? `\nskills:\n${skills}` : "");
}

async function main(argv: string[]): Promise<number> {
  const { values: o, positionals: [cmd, arg] } = parseArgs({
    args: argv, allowPositionals: true,
    options: {
      state: { type: "string", default: process.env.YUI_A2A_STATE ?? join(homedir(), ".yui/a2a.json") },
      card: { type: "string" }, ref: { type: "string" }, name: { type: "string" },
      header: { type: "string", multiple: true }, "host-name": { type: "string" },
      interval: { type: "string", default: "2" }, "no-guide": { type: "boolean", default: false },
      help: { type: "boolean", short: "h" },
    },
  });
  if (o.help || !cmd) {
    console.log(USAGE);
    return cmd || o.help ? 0 : 2;
  }
  const state = new State(o.state!.replace(/^~(?=\/)/, homedir()));
  const hdrs = headers(o.header);

  if (cmd === "card") {
    if (!arg) throw new Refused("card needs the agent's URL");
    const { client, card } = await readCard(arg, hdrs);
    console.log(describe(card, client));
    return 0;
  }
  if (cmd === "pair" || cmd === "add") {
    if (!o.card) throw new Refused(`${cmd} needs --card <agent URL>`);
    if (cmd === "pair" && !arg) throw new Refused("pair needs the 6-digit code from the app");
    const { client, card, remote } = await readCard(o.card, hdrs); // a bad URL fails here, before the code is spent
    const ref = o.ref ?? refFromName(card.name);
    const r = cmd === "pair"
      ? await pair(state, arg!, ref, remote, o["host-name"])
      : await add(state, ref, remote, o.name ?? card.name);
    console.log(`${cmd === "pair" ? "paired" : r.created ? "added" : "already there"}: ${r.agent.name} is ${card.name} `
      + `(A2A ${client.version}). Next: yui-a2a.ts run`);
    return 0;
  }
  const b = new Bridge(state, { interval: Number(o.interval), guide: !o["no-guide"] });
  if (cmd === "status") {
    await b.session();
    console.log(`connector: ${state.data.connector?.name} (${state.path})`);
    for (const a of b.agents.values()) {
      const remote = state.data.remotes[a.remote_ref];
      console.log(`- ${a.name} (${a.remote_ref}): ${remote ? remote.card : "no card on this machine"}`
        + (state.data.inflight[a.id] ? `, task in flight ${state.data.inflight[a.id].taskId ?? "(sending)"}` : ""));
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
  console.error(`yui-a2a: ${e instanceof Refused ? e.message : e?.stack ?? e}`);
  process.exit(1);
});
