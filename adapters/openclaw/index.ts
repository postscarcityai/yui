// Yui channel plugin for OpenClaw (INT-1): an OpenClaw agent talks in Yui the
// way a Hermes agent does. Same relay contract (yuigui/spec/RELAY.md).
//
//   openclaw plugins install ./yui/adapters/openclaw
//   openclaw yui pair 123456 [--agent main]
//   openclaw gateway restart
import { defineChannelPluginEntry } from "openclaw/plugin-sdk/channel-core";
import { resolveYuiAccount } from "./src/accounts.js";
import { yuiPlugin } from "./src/channel.js";
import { Connector, fetchGuide, pair, pickAgent, State } from "./src/client.js";
import { setYuiRuntime } from "./src/runtime.js";

function registerYuiCli(api: any) {
  api.registerCli(
    ({ program, config }: any) => {
      const yui = program.command("yui").description("Pair this OpenClaw with the Yui app");
      const state = () => new State(resolveYuiAccount(config ?? api.config).stateFile);
      yui.command("pair <code>")
        .description("claim the 6-digit code from the Yui app's Add agent")
        .option("--agent <id>", "the OpenClaw agent that answers in Yui", "main")
        .option("--host-name <name>", "how this computer shows in the app")
        .action(async (code: string, o: { agent: string; hostName?: string }) => {
          const r = await pair(state(), code, o.agent, o.hostName);
          console.log(`paired: ${r.agent.name} on ${r.connector.name}, answered by OpenClaw agent "${o.agent}".`);
          console.log("Next: openclaw gateway restart");
        });
      yui.command("status")
        .description("show the connector and its agents")
        .action(async () => {
          const s = state();
          const c = new Connector(s);
          await c.session();
          const agents = [...c.agents.values()].map((a) => `${a.name} -> ${a.remote_ref}`).join(", ") || "none";
          console.log(`connector: ${s.data.connector?.name} (${s.path}); guide ${c.guide.version}; agents: ${agents}`);
        });
      yui.command("guide")
        .description("print the Yui channel guide your agent reads each turn")
        .action(async () => {
          const g = await fetchGuide();
          console.log(`Yui channel guide ${g.version}\n\n${g.body}`);
        });
      yui.command("send <text>")
        .description("send a message into a Yui thread (a handoff, with a push)")
        .option("--to <agent>", "Yui agent id, handle or OpenClaw agent id")
        .action(async (text: string, o: { to?: string }) => {
          const c = new Connector(state());
          await c.session();
          const a = pickAgent(c.agents, o.to);
          if (!a) throw new Error(`no Yui agent ${JSON.stringify(o.to)} on this connector`);
          console.log(JSON.stringify({ message_id: await c.send(a.id, text), agent: a.name }));
        });
    },
    { descriptors: [{ name: "yui", description: "Pair this OpenClaw with the Yui app", hasSubcommands: true }] },
  );
}

export default defineChannelPluginEntry({
  id: "yui",
  name: "Yui",
  description: "Yui channel: your OpenClaw agent on your iPhone, with real screens",
  plugin: yuiPlugin,
  setRuntime: setYuiRuntime,
  registerCliMetadata: registerYuiCli,
});
