#!/usr/bin/env node
// Yui model bridge (INT-12): any OpenAI-compatible model in Yui. Ollama,
// LM Studio, vLLM, llama.cpp, Gemini (--server gemini, INT-9), or any server
// with /v1/chat/completions.
//
//   node yui-openai.ts models [--server ollama]                  # what the server has
//   node yui-openai.ts try "hi" --model qwen2.5:7b              # one answer, guide included, nothing paired
//   node yui-openai.ts pair 123456 --model qwen2.5:7b [--server ollama | --url URL] [--key-env VAR | --key-stdin]
//   node yui-openai.ts add --model llama3.2 [--name "Llama"]    # one more, no code
//   node yui-openai.ts run
//   node yui-openai.ts status
//
// Runs next to the model server: it dials out to Yui, no open ports.
// Node 22.18+ (runs the TypeScript as is), no dependencies. State (the
// connector token, the models, the turn in flight, the reply outbox) lives in
// ~/.yui/openai.json (mode 600), or --state / $YUI_OPENAI_STATE.
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { ChatClient, ModelError, ModelUnavailable, SERVERS, baseUrl } from "./src/openai.ts";
import { buildMessages } from "./src/thread.ts";
import { Bridge, Refused, State, add, clientFor, connectCall, keyFor, log, pair, refFromName, type Remote } from "./src/bridge.ts";

const USAGE = `usage: yui-openai.ts [--state FILE] <command>
  models [SERVER]                              the models a server offers
  try "text" --model M [SERVER]                one answer with the Yui guide, to see if a model draws screens
  pair <code> --model M [SERVER] [--ref NAME] [--host-name NAME] [MODEL OPTIONS]
                                               claim the code from the app's Add agent
  add --model M [SERVER] [--ref NAME] [--name NAME] [MODEL OPTIONS]
                                               another model on this machine, no code
  run [--interval 2]                           serve every paired model
  status                                       the connector, its agents and their models
  guide                                        print the channel guide (the system message)

SERVER: --server ollama|lmstudio|vllm|llamacpp|openrouter|gemini, or --url http://host:port/v1 (default ollama)
        --key-env VAR   read the key from $VAR when it runs (nothing stored)
        --key-stdin     read the key from stdin once and keep it in the state file (mode 600)
MODEL OPTIONS: --system "text"  --context 4096  --max-tokens N  --temperature T  --no-stream`;

async function readStdin(): Promise<string> {
  let s = "";
  for await (const c of process.stdin) s += c;
  return s.trim();
}

async function main(argv: string[]): Promise<number> {
  const { values: o, positionals: [cmd, arg] } = parseArgs({
    args: argv, allowPositionals: true,
    options: {
      state: { type: "string", default: process.env.YUI_OPENAI_STATE ?? join(homedir(), ".yui/openai.json") },
      server: { type: "string" }, url: { type: "string" }, model: { type: "string" },
      "key-env": { type: "string" }, "key-stdin": { type: "boolean", default: false },
      system: { type: "string" }, "system-file": { type: "string" },
      context: { type: "string" }, "max-tokens": { type: "string" }, temperature: { type: "string" },
      "no-stream": { type: "boolean", default: false },
      ref: { type: "string" }, name: { type: "string" }, "host-name": { type: "string" },
      interval: { type: "string", default: "2" },
      help: { type: "boolean", short: "h" },
    },
  });
  if (o.help || !cmd) {
    console.log(USAGE);
    return cmd || o.help ? 0 : 2;
  }
  const state = new State(o.state!.replace(/^~(?=\/)/, homedir()));

  const num = (v: string | undefined, what: string) => {
    if (v === undefined) return undefined;
    const n = Number(v);
    if (!Number.isFinite(n) || n < 0) throw new Refused(`${what} wants a number, got ${JSON.stringify(v)}`);
    return n;
  };
  const remoteFromArgs = async (): Promise<Remote> => {
    if (o.server && !SERVERS[o.server]) throw new Refused(`--server is one of ${Object.keys(SERVERS).join(", ")}`);
    const preset = SERVERS[o.server ?? (o.url ? "" : "ollama")];
    const url = baseUrl(o.url ?? preset.url);
    const r: Remote = { url, model: o.model ?? "" };
    const keyEnv = o["key-env"] ?? (!o["key-stdin"] ? preset?.keyEnv : undefined);
    if (keyEnv) r.keyEnv = keyEnv;
    if (o["key-stdin"]) r.key = await readStdin();
    const system = o["system-file"] ? readFileSync(o["system-file"], "utf8") : o.system;
    if (system?.trim()) r.system = system.trim();
    const context = num(o.context, "--context"), maxTokens = num(o["max-tokens"], "--max-tokens"), temperature = num(o.temperature, "--temperature");
    if (context || preset?.context) r.context = context || preset.context;
    if (maxTokens) r.maxTokens = maxTokens;
    if (temperature !== undefined) r.temperature = temperature;
    if (o["no-stream"]) r.stream = false;
    return r;
  };

  if (cmd === "models") {
    const r = await remoteFromArgs();
    const names = await clientFor(r).models();
    console.log(names.length ? names.join("\n") : `${r.url} lists no models`);
    return 0;
  }
  if (cmd === "try") {
    if (!arg) throw new Refused(`try needs the words to send, like: try "help me pick lunch" --model <name>`);
    if (!o.model) throw new Refused("try needs --model (see `models`)");
    const r = await remoteFromArgs();
    const g = (await connectCall({ action: "guide" })).guide ?? {};
    const { messages } = buildMessages([], [{ id: "try", sender: "user", kind: "text", body: arg }],
                                       { guide: g.body ?? "", system: r.system, context: r.context, reserve: r.maxTokens });
    const t = Date.now();
    const done = await new ChatClient(r.url, { key: keyFor(r) }).complete(
      { model: r.model, messages, ...(r.maxTokens ? { max_tokens: r.maxTokens } : {}), ...(r.temperature !== undefined ? { temperature: r.temperature } : {}) },
      { stream: r.stream !== false, onDelta: (d) => process.stdout.write(d) });
    if (!done.streamed) process.stdout.write(done.text);
    console.log(`\n\n-- ${r.model}, ${((Date.now() - t) / 1000).toFixed(1)}s${done.streamed ? ", streamed" : ""}, finish ${done.finish}`
      + (done.usage?.prompt_tokens ? `, ${done.usage.prompt_tokens} prompt tokens` : "")
      + `, ${/```yui\n[\s\S]+?\n```/.test(done.text) ? "drew a Yui screen" : "no Yui screen"} (guide ${g.version})`);
    return 0;
  }
  if (cmd === "pair" || cmd === "add") {
    if (!o.model) throw new Refused(`${cmd} needs --model <name> (see \`models\`)`);
    if (cmd === "pair" && !arg) throw new Refused("pair needs the 6-digit code from the app");
    const remote = await remoteFromArgs();
    // A dead server, a refused key or a wrong model fails here, before the code is spent.
    const names = await clientFor(remote).models().catch((e) => {
      throw e instanceof ModelUnavailable ? new Refused(`${e.message}. Is the model server running?`) : e;
    });
    if (names.length && !names.includes(remote.model)) {
      throw new Refused(`${remote.url} has no model ${JSON.stringify(remote.model)}. It has: ${names.join(", ")}`);
    }
    const ref = o.ref ?? refFromName(remote.model);
    const r = cmd === "pair"
      ? await pair(state, arg!, ref, remote, o["host-name"])
      : await add(state, ref, remote, o.name ?? remote.model);
    console.log(`${cmd === "pair" ? "paired" : r.created ? "added" : "updated"}: ${r.agent.name} is ${remote.model} at ${remote.url}. Next: yui-openai.ts run`);
    return 0;
  }
  const b = new Bridge(state, { interval: Number(o.interval) });
  if (cmd === "status") {
    await b.session();
    console.log(`connector: ${state.data.connector?.name} (${state.path})`);
    for (const a of b.agents.values()) {
      const m = state.data.remotes[a.remote_ref];
      console.log(`- ${a.name} (${a.remote_ref}): ${m ? `${m.model} at ${m.url}${m.keyEnv ? `, key from $${m.keyEnv}` : m.key ? ", key in the state file" : ""}` : "no model on this machine"}`
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
    for (const m of Object.values(state.data.remotes)) keyFor(m); // a missing key env fails now, not mid-turn
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
  const known = e instanceof Refused || e instanceof ModelError || e instanceof ModelUnavailable;
  console.error(`yui-openai: ${known ? e.message : e?.stack ?? e}`);
  process.exit(1);
});
