# Yui AG-UI bridge (INT-21)

Add any agent served over [AG-UI](https://docs.ag-ui.com) to Yui by its URL: Microsoft Agent Framework (`add_agent_framework_fastapi_endpoint`), CopilotKit runtimes, Mastra, Pydantic AI, LangGraph's AG-UI adapter, or anything else that takes a `RunAgentInput` and streams AG-UI events back.

The bridge is one small process on your computer. It dials out to Yui and to the agent. Each turn the person sends becomes one AG-UI run, and Yui screens are a tool the agent calls. Nothing listens on a port.

```
 Yui app  <-->  Yui (rows in yui_messages)  <--dials out--  bridge  --AG-UI run-->  the agent (its endpoint URL)
```

Step 1 of INT-21: it runs on your machine. The hosted version comes with the A2A bridge's (INT-20) and uses the same client module.

## Five minutes

Needs Node 22.18 or newer (it runs the TypeScript as is). No dependencies.

1. See that the agent answers:
   ```
   node yui-agui.ts check http://127.0.0.1:8000/
   ```
2. In the Yui app: **Agents > Add agent**. It shows a 6-digit code.
3. Pair this machine, pointing at the agent:
   ```
   node yui-agui.ts pair 123456 --url http://127.0.0.1:8000/ --name "My agent"
   ```
   `pair` runs the agent once first, so a wrong URL fails before the code is spent. If the agent wants a key: `--header "authorization: Bearer <key>"`. It stays in `~/.yui/agui.json` (mode 600) on this machine.
4. Start the bridge:
   ```
   node yui-agui.ts run
   ```
5. Say hi in the app.

More agents on the same machine, no new code: `node yui-agui.ts add --url <url> --name <name>`. `status` lists them.

## How a conversation maps

| Yui | AG-UI |
| --- | --- |
| an agent | one endpoint (`remote_ref` -> URL in the state file) |
| its thread | one thread: `threadId` = the Yui agent's id. AG-UI servers keep nothing between runs, so the bridge keeps the messages (the last 60) and sends them with every run |
| a turn (the person's messages since the last answer) | one run, `runId` fixed by the rows it carries |
| the working row in the app | the run is streaming |
| the answer | the assistant's text, then any screens |
| a screen | the agent calls the frontend tool `yui_show(lines)`; the run ends there and the lines go to the phone as a ` ```yui ` fence |
| a tap on that screen | the result of that `yui_show` call, in the next run: `[yui] n1 pick choice=Tea` |
| typing instead of tapping | the call's result says so (`Shown. They wrote back instead of tapping`), then the words as a user message |
| the agent pauses for the person (`RUN_FINISHED` with an interrupt) | its message lands; the person's next message goes back in `resume` and as words |
| `RUN_ERROR` or a 4xx | the person reads one line saying so, then the reason; no retry loop |
| `STATE_SNAPSHOT` | kept and sent back as `state` on the next run |

**Screens are a tool, not a trick.** `yui_show` is AG-UI's own human-in-the-loop pattern: a client tool is declaration-only on the server, so when the model calls it the run ends and the client does the work. Agents that write a ` ```yui ` fence in their text (what the channel guide teaches) still work; their taps come back as the person's words, as on every other channel.

**Where the guide rides.** `--guide system` (the default) sends the Yui channel guide as a system message at the top of every run; it is never stored in the thread. `--guide tool` puts it in `yui_show`'s description, the one part every AG-UI server is sure to hand the model. `--guide context` uses AG-UI's `context` array. Microsoft Agent Framework drops `context` unless A2UI is on, so it is not the default. `--guide off` sends nothing.

## Streams, drops and restarts

- **Exactly once into Yui**, with the relay's delivery rules (the A2A bridge's `relay.ts`, shared, not copied): the person's rows are marked delivered when the turn starts and handled once the answer is written; every answer names its rows in `meta.turn`; replies wait in an outbox on disk until Yui has them.
- **A run can't be rejoined**, so a dropped stream, a 5xx or a crash runs the turn again: the turn is on disk before the run starts, the thread only moves on when a run settles (in the same save as the reply), and the second run has the same `runId` and the same messages.
- A stream that stays silent for 5 minutes counts as dropped.
- One turn at a time per agent. Anything the person sends meanwhile goes in together as the next turn. Several agents run side by side.

## The client on its own

`src/agui.ts` is the AG-UI client: `runAgent(url, input)` POSTs one `RunAgentInput` and yields its events; `RunView` folds them into the assistant's words, the tool calls left for the client, interrupts and state. It uses only `fetch` and the A2A bridge's SSE parser, so it runs in Node, a Cloudflare Worker or a browser.

```ts
import { RunView, runAgent } from "./src/agui.ts";

const view = new RunView();
for await (const e of runAgent("http://127.0.0.1:8000/", {
  threadId: "t1", runId: crypto.randomUUID(), messages: [{ id: "u1", role: "user", content: "hi" }],
  tools: [], context: [], state: {}, forwardedProps: {},
})) view.apply(e);
console.log(view.text(), view.openCalls());
```

`AguiUnavailable` means try again (network, 5xx, a stream that ended before `RUN_FINISHED`); `AguiError` means the server refused the request (4xx).

## Tests

```
node --test tests/agui.test.ts   # folding runs, the wire, the bridge's turns (a scripted server replaying Agent Framework's recorded events)
python3 tests/agui_e2e.py        # live: a Microsoft Agent Framework AG-UI endpoint on Ollama qwen2.5:7b (needs uv), throwaway account
```

**Microsoft Agent Framework (INT-16, INT-21).** `tests/sdk/maf_agui_agent.py` is Agent Framework's own AG-UI hosting with nothing added: `add_agent_framework_fastapi_endpoint(app, agent, "/")` on FastAPI, an agent whose instructions never mention Yui, local Ollama through `agent-framework-ollama`, no key; `MAF_MODEL` picks another model. It honours client system messages, hands the model `yui_show` as a declaration-only tool, ends the run on the call (`TOOL_CALL_START`, `TOOL_CALL_ARGS`, `TOOL_CALL_END`, then `RUN_FINISHED`) and takes the tap back as a `tool` message. It also sends a `MESSAGES_SNAPSHOT`; the bridge keeps its own thread from the events instead, since not every server sends one. `tests/fixtures/*.sse` are two of its runs, recorded.
