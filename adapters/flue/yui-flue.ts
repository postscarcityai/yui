#!/usr/bin/env node
// Yui channel for Flue (INT-13): pair a Flue app with Yui, from the app's folder.
//
//   node yui-flue.ts pair 123456 [--ref assistant] [--host-name NAME]
//   node yui-flue.ts add --ref reviewer [--name "Reviewer"]   # one more agent, no code
//   node yui-flue.ts status
//   node yui-flue.ts guide
//
// There is no `run`: the Flue app runs the connector itself (channels/yui.ts,
// started from app.ts). State (the connector token, turns in flight, the
// reply outbox) lives in ~/.yui/flue.json (mode 600), or --state / $YUI_FLUE_STATE.
import { parseArgs } from "node:util";
import { connectCall } from "../a2a/src/relay.ts";
import { DEFAULT_STATE, Refused, YuiConnector, add, pair } from "./src/yui.ts";

const USAGE = `usage: yui-flue.ts [--state FILE] <command>
  pair <code> [--ref NAME] [--host-name NAME]  claim the code from the app's Add agent
  add --ref NAME [--name NAME]                 another agent on this connector, no code
  status                                       the connector and its agents
  guide                                        print the channel guide the agent gets`;

async function main(argv: string[]): Promise<number> {
  const { values: o, positionals: [cmd, arg] } = parseArgs({
    args: argv, allowPositionals: true,
    options: {
      state: { type: "string", default: DEFAULT_STATE },
      ref: { type: "string" }, name: { type: "string" }, "host-name": { type: "string" },
      help: { type: "boolean", short: "h" },
    },
  });
  if (o.help || !cmd) {
    console.log(USAGE);
    return cmd || o.help ? 0 : 2;
  }
  if (cmd === "pair") {
    if (!arg) throw new Refused("pair needs the 6-digit code from the app");
    const r = await pair(arg, { ref: o.ref ?? "assistant", state: o.state, hostName: o["host-name"] });
    console.log(`paired: ${r.agent.name} (${o.ref ?? "assistant"}). Next: start the Flue app; channels/yui.ts connects it.`);
    return 0;
  }
  if (cmd === "add") {
    if (!o.ref) throw new Refused("add needs --ref <name>");
    const r = await add(o.ref, { name: o.name, state: o.state });
    console.log(`${r.created ? "added" : "already there"}: ${r.agent.name} (${o.ref})`);
    return 0;
  }
  if (cmd === "status") {
    const c = new YuiConnector({ state: o.state, answer: async () => null });
    await c.session();
    console.log(`connector: ${c.state.data.connector?.name} (${c.state.path})`);
    for (const a of c.agents.values()) {
      console.log(`- ${a.name} (${a.remote_ref})` + (c.state.data.inflight[a.id] ? ", turn in flight" : ""));
    }
    return 0;
  }
  if (cmd === "guide") {
    const g = (await connectCall({ action: "guide" })).guide ?? {};
    console.log(`Yui channel guide ${g.version}\n\n${g.body ?? ""}`);
    return 0;
  }
  console.error(USAGE);
  return 2;
}

main(process.argv.slice(2)).then((code) => process.exit(code), (e) => {
  console.error(`yui-flue: ${e instanceof Refused ? e.message : e?.stack ?? e}`);
  process.exit(1);
});
