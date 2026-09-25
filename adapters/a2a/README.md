# Yui A2A bridge (INT-18)

Add any [A2A](https://a2a-protocol.org) agent to Yui by its Agent Card: agents built with Google's ADK, LangGraph, CrewAI, Microsoft Agent Framework, or anything else that serves `/.well-known/agent-card.json`.

The bridge is one small process on your computer. It dials out to Yui and to the agent. Each message the person sends becomes an A2A message, and the agent's answer becomes a message in their thread. Nothing listens on a port.

```
 Yui app  <-->  Yui (rows in yui_messages)  <--dials out--  bridge  --A2A-->  the agent (its card URL)
```

Step 1 of INT-18: it runs on your machine. The hosted version (a Cloudflare Durable Object, so you don't run anything) comes later and uses the same client module.

## Five minutes

Needs Node 22.18 or newer (it runs the TypeScript as is). No dependencies.

1. See what the agent says about itself:
   ```
   node yui-a2a.ts card https://your-agent.example.com
   ```
2. In the Yui app: **Agents > Add agent**. It shows a 6-digit code.
3. Pair this machine, pointing at the agent:
   ```
   node yui-a2a.ts pair 123456 --card https://your-agent.example.com
   ```
   If the agent wants a key: `--header "authorization: Bearer <key>"`. It stays in `~/.yui/a2a.json` (mode 600) on this machine.
4. Start the bridge:
   ```
   node yui-a2a.ts run
   ```
5. Say hi in the app.

More agents on the same machine, no new code: `node yui-a2a.ts add --card <url>`. `status` lists them.

## How a conversation maps

| Yui | A2A |
| --- | --- |
| an agent | one remote agent, found by its card (`remote_ref` -> card URL in the state file) |
| its thread | one context: `contextId` = the Yui agent's id |
| a turn (the person's messages since the last answer) | one message, `messageId` fixed by the rows it carries |
| the working row in the app | the task is `submitted` or `working` |
| the answer | the task's text artifacts, then its final status message if it adds something |
| the agent asks something back | `input-required`: the question lands, and the person's next message continues that task |
| a tap on a screen | the tap's line as text, plus its JSON as a data part |

- **The channel guide goes in as a context part.** On the first message of every new task, the Yui channel guide travels as a text part with `metadata: {"yui": "channel_guide", "version": ...}`, before the person's words. An agent that passes it to its model can answer with [Yui screens](https://www.yuigui.com/yl). One that ignores it still works: its answers show as chat.
- **Text parts become the message.** File parts show as their link. Data parts are skipped for now.
- **Failed, rejected, canceled:** the person reads one line saying so, then the agent's reason.
- **`auth-required`:** the person reads that the agent needs a sign-in. Keys per agent are YUI-34.

## Streams, drops and restarts

- If the card says `streaming`, the bridge uses `SendStreamingMessage` (`message/stream` on 0.3) and reads the Server-Sent Events. Otherwise it sends with `returnImmediately` and follows the task with `GetTask`, backing off to every 30 seconds.
- **A dropped stream is picked back up** with `SubscribeToTask` (`tasks/resubscribe`), then `GetTask` if the agent can't stream it.
- **A restart does not send the turn again.** The running task's id is on disk as soon as the agent names it. After a crash, the bridge resubscribes to that task and writes its answer once. If it died in the moment between sending and hearing the task id, it sends the same message again with the same `messageId`.
- **Exactly once into Yui**, with the relay's delivery rules: the person's rows are marked delivered when the turn starts and handled once the answer is written; every answer names its rows in `meta.turn`; replies wait in an outbox on disk until Yui has them. Same as the [webhook bridge](../webhook/).
- One turn at a time per agent. Anything the person sends meanwhile goes in together as the next turn. Several agents run side by side.

## Versions

Speaks the JSON-RPC binding of both:

| | A2A 1.0 | A2A 0.3 |
| --- | --- | --- |
| send | `SendMessage` | `message/send` |
| stream | `SendStreamingMessage` | `message/stream` |
| pick a task back up | `SubscribeToTask` | `tasks/resubscribe` |
| read a task | `GetTask` | `tasks/get` |
| card | `supportedInterfaces[]` | `url`, `preferredTransport`, `additionalInterfaces` |

When a card lists both, 1.0 wins. 1.0 calls carry `A2A-Version: 1.0`. The gRPC and HTTP+JSON bindings are not supported yet; a card with neither JSON-RPC version is refused at `pair` with a clear message.

## The client on its own

`src/a2a.ts` is the A2A client, and `src/sse.ts` the event stream parser. They only use `fetch`, `TextDecoder` and streams, so the same code runs in Node, a Cloudflare Worker or a browser.

```ts
import { A2AClient, TaskView } from "./src/a2a.ts";

const { client, card } = await A2AClient.fromCard("https://agent.example.com");
const view = new TaskView();
for await (const u of client.stream({ messageId: crypto.randomUUID(), role: "user", parts: [{ text: "hi" }] })) {
  view.apply(u);
}
console.log(card.name, view.state, view.text());
```

`client.send`, `client.stream`, `client.subscribe(taskId)`, `client.getTask(taskId)` and `client.cancel(taskId)` return one version-free shape. `A2AUnavailable` means try again (network, 5xx, a dropped stream); `A2AError` means the agent said no, with its JSON-RPC code.

## Tests

```
node --test tests/client.test.ts        # the client: SSE, both versions, resubscribe (no network)
node --test tests/sdk_interop.test.ts   # against the official a2a-sdk servers, 1.x and 0.3 (needs uv)
python3 tests/a2a_e2e.py                # live: pair, turns, a long task, kill -9 mid-task (throwaway account)
python3 tests/a2a_e2e.py --protocol 1.0 --sim <udid>   # plus the app on a simulator, with screenshots
python3 tests/a2a_e2e.py --protocol adk # live with a real Google ADK agent (tests/sdk/adk_agent.py on Ollama qwen2.5:7b; needs uv)
python3 tests/a2a_e2e.py --protocol langgraph # live with a LangGraph graph on LangGraph's Agent Server (tests/sdk/langgraph_agent.py, no model; needs uv)
python3 tests/a2a_e2e.py --protocol crewai # live with a CrewAI agent (tests/sdk/crewai_agent.py on Ollama qwen2.5:7b; needs uv)
python3 tests/a2a_e2e.py --protocol maf # live with a Microsoft Agent Framework agent (tests/sdk/maf_agent.py on Ollama qwen2.5:7b; needs uv)
```

**ADK and Gemini agents (INT-9).** `tests/sdk/adk_agent.py` is a Google ADK agent served over A2A by ADK's own `to_a2a`. It shows how an ADK agent uses Yui's guide: a `before_model_callback` moves the part marked `{"yui": "channel_guide"}` into the model's instructions. It runs on local Ollama through LiteLLM with no key; `ADK_MODEL=gemini-2.5-flash` with `GEMINI_API_KEY` runs it on Gemini.

**LangGraph agents (INT-14).** LangGraph's Agent Server (`langgraph dev`, and LangSmith deployments) serves every graph over A2A at `/a2a/{assistant_id}`; pair by `'.../.well-known/agent-card.json?assistant_id=<id>'`. It keeps only one text part per message and drops part metadata, so for a card with LangChain's A2A extensions the bridge sends the guide and taps as a data part, `{"yui_channel_guide": {version, body}, "yui_events": [...]}`, which LangGraph hands the graph as state keys. `tests/sdk/langgraph_agent.py` declares them and draws a screen from the guide, no model.

**CrewAI agents (INT-15).** CrewAI's A2A server support is an `A2AServerConfig` on the agent (its card from `agent.to_agent_card(url)`) and `crewai.a2a.utils.task.execute`, one A2A task as one CrewAI task; the A2A SDK's Starlette app serves it (A2A 0.3, streaming). CrewAI joins every text part into the task's description and drops part metadata, so `tests/sdk/crewai_agent.py` takes the part marked `{"yui": "channel_guide"}` out of the message and puts it in the agent's backstory (CrewAI's system prompt) before CrewAI runs. No bridge change. Local Ollama through LiteLLM, no key; `CREWAI_MODEL` picks another. A crew run as a script uses the webhook bridge instead: `../webhook/python/crewai_crew.py`.

**Microsoft Agent Framework agents (INT-16).** Agent Framework, AutoGen's successor, hosts an agent with `A2AExecutor` (`agent-framework-a2a`, a beta) on the A2A SDK 1.x server, so A2A 1.0. The executor joins every text part into the person's words and gives each request an empty session, so `tests/sdk/maf_agent.py` puts the part marked `{"yui": "channel_guide"}` in the run's `instructions` option (appended to the agent's own instructions) and keeps one session per `contextId`. Without streaming the executor sends the answer as a `working` status message and completes with none; `TaskView` falls back to that message (or the last agent message in a `GetTask` history) when a completed task has nothing else to show. Local Ollama through `agent-framework-ollama`, no key; `MAF_MODEL` picks another. Allow the betas by name, not with `--prerelease=allow` (that pulls httpx 1.0.dev, which the A2A SDK cannot import).

`tests/echo-agent.ts` is the scripted A2A agent the tests use: no model, fixed answers, either version, streaming or not.
