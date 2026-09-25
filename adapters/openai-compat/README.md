# Yui model bridge (INT-12)

Put a model you run yourself into Yui: Ollama, LM Studio, vLLM, llama.cpp's server, or anything else that serves an OpenAI-compatible `/v1/chat/completions`. The model answers with [Yui screens](https://www.yuigui.com/yl), not only text.

The bridge is one small process next to the model server. It dials out to Yui, reads what the person sends, asks the model, and writes the answer into their thread. Nothing listens on a port.

```
 Yui app  <-->  Yui (rows in yui_messages)  <--dials out--  bridge  --/v1/chat/completions-->  your model (localhost)
```

Step 1 of INT-12: it runs on your machine. Cloud endpoints on Yui's hosted connector come later and reuse the same client module.

## Five minutes

Needs Node 22.18 or newer (it runs the TypeScript as is). No dependencies.

1. Start your model server and see what it has:
   ```
   ollama pull qwen2.5:7b
   node yui-openai.ts models
   ```
2. See if the model draws screens with the Yui guide, before you pair anything:
   ```
   node yui-openai.ts try "Help me pick lunch" --model qwen2.5:7b
   ```
   The last line says `drew a Yui screen` or `no Yui screen`.
3. In the Yui app: **Agents > Add agent**. It shows a 6-digit code.
4. Pair this machine with that model, then start the bridge:
   ```
   node yui-openai.ts pair 123456 --model qwen2.5:7b
   node yui-openai.ts run
   ```
5. Say hi in the app.

Another model on the same machine, no new code: `node yui-openai.ts add --model llama3.2 --name "Llama"`. `status` lists them.

## Servers

Ollama is the default. Others by name or by URL:

| | flag | base URL |
| --- | --- | --- |
| Ollama | `--server ollama` | `http://127.0.0.1:11434/v1` |
| LM Studio | `--server lmstudio` | `http://127.0.0.1:1234/v1` |
| vLLM | `--server vllm` | `http://127.0.0.1:8000/v1` |
| llama.cpp | `--server llamacpp` | `http://127.0.0.1:8080/v1` |
| OpenRouter | `--server openrouter` | `https://openrouter.ai/api/v1`, key from `$OPENROUTER_API_KEY` |
| Gemini | `--server gemini` | `https://generativelanguage.googleapis.com/v1beta/openai`, key from `$GEMINI_API_KEY` (a free AI Studio key), `--context` 32768 |
| Grok | `--server grok` | `https://api.x.ai/v1`, key from `$XAI_API_KEY`, model `grok-4.7` unless `--model` says otherwise, `--context` 32768 |
| anything else | `--url http://host:port/v1` | also takes the full `.../chat/completions` URL |

**Keys.** Local servers need none. For one that does, `--key-env NAME` reads the key from that environment variable each time the bridge runs, and nothing is stored. `--key-stdin` reads it once from stdin and keeps it in the state file (mode 600). Never put a key on the command line, in chat or on a board.

**Model options** on `pair` and `add`: `--system "text"` (or `--system-file`) goes before the Yui guide in the system message, `--context 8192` is the model's context window in tokens (default 4096), `--max-tokens`, `--temperature`, and `--no-stream` for servers that stream badly. `add` again with the same `--ref` changes them.

## How a conversation maps

| Yui | chat API |
| --- | --- |
| an agent | one model on one server (`remote_ref` -> base URL and model in the state file) |
| the channel guide | the system message, after your `--system` words |
| the thread | Yui holds it: the newest rows that fit `--context` go in as user and assistant messages, oldest first |
| a turn (the person's messages since the last answer) | one user message, one line each |
| a tap on a screen | its line, `[yui] n1 choose choice=Tea`, as a user message |
| the working row in the app | the model is answering |
| the answer | the assistant message, with any leading `<think>` block taken out |

- **Yui holds the thread.** A chat API remembers nothing, so each turn sends the guide, then as much of the thread as fits, then the new messages. Older rows drop off whole, oldest first, never from the middle. Runs of the same role are joined, because many open models' chat templates want user and assistant to take turns.
- **The context window.** The guide alone is about 2,500 tokens. Ollama and LM Studio load models with 4,096 by default and quietly cut anything longer, so give the model more room if you can (`OLLAMA_CONTEXT_LENGTH=16384 ollama serve`, or the context slider in LM Studio) and tell the bridge the same number with `--context`. The bridge logs when it leaves history out, and when the guide and the turn alone don't fit.
- **Small models.** A 7B model follows the guide for simple screens (choices, lists, timers). Harder layouts need a bigger model. `try` shows you quickly; YUI-10's eval will score each model we list as supported.

## Streams, errors and restarts

- It streams when the server does (Server-Sent Events). A server that answers plain JSON anyway is read as plain; one that refuses with a 400 about streaming is asked plain from then on, and that is remembered.
- A stream that goes quiet for 5 minutes, or breaks, is asked again.
- **The server is down or busy** (connection refused, 429, 5xx): the turn waits and is tried again, backing off up to a minute. After 90 seconds the person reads one line saying the model can't be reached and that their message waits.
- **The server says no** (a bad key, an unknown model, a message too long): the person reads why, once, and the turn is done.
- **Exactly once into Yui**, with the relay's delivery rules, same as the [webhook bridge](../webhook/) and the [A2A bridge](../a2a/): rows are marked delivered when the turn starts and handled once the answer is written, each answer names its rows in `meta.turn`, and answers wait in an outbox on disk until Yui has them.
- **A restart does not send twice.** The turn in flight is on disk. A crash while the model is answering asks the model again after the restart (a chat API has nothing to pick back up), and one answer lands. A crash after the answer was written only marks the turn done.
- One turn at a time per agent; anything sent meanwhile goes in together as the next turn. Several agents run side by side.
- A clean stop (Ctrl-C, SIGTERM) tells Yui, so the app shows the agent offline at once.

State lives in `~/.yui/openai.json` (mode 600): the connector token, the models, the turn in flight and the outbox. `--state` or `$YUI_OPENAI_STATE` moves it. Removing the agent's computer in the app revokes the token.

## The client on its own

`src/openai.ts` is the chat client, `src/thread.ts` builds the messages from the thread, `src/sse.ts` parses the stream. They use only `fetch`, `TextDecoder` and streams, so the same code runs in Node, a Cloudflare Worker or a browser.

```ts
import { ChatClient } from "./src/openai.ts";

const client = new ChatClient("http://127.0.0.1:11434/v1");
const r = await client.complete({ model: "qwen2.5:7b", messages: [{ role: "user", content: "hi" }] },
                                { onDelta: (d) => process.stdout.write(d) });
console.log(r.finish, r.streamed);
```

`ModelUnavailable` means try again (network, 408/409/425/429/5xx, a broken stream); `ModelError` means the server said no, with its status; `StreamRefused` means ask again without streaming.

## Tests

```
node --test tests/client.test.ts                  # client + thread builder against the scripted server (no network)
python3 tests/openai_e2e.py --run stream          # live: pair, turns, taps, history, kill -9, errors (throwaway account)
python3 tests/openai_e2e.py --run ollama          # live with a real model on this Mac (default qwen2.5:7b)
python3 tests/openai_e2e.py --run phone --sim <udid>   # plus the app on a simulator, with screenshots
```

`tests/fake-model.ts` is the scripted server the tests use: no model, fixed answers, streaming or not, with or without a key. `--gemini` makes it answer in the shapes of Gemini's OpenAI-compatible endpoint (`models/` ids, errors in a list, a bad key as 400, thought summaries, a blocked answer), which the bridge copes with (INT-9). `--grok` answers in xAI's shapes (errors as `{"code", "error"}`, a bad key as 400, 403 when the team is out of credits, 429 rate limits, `reasoning_content` before the answer, a `refusal` with no content, a 400 for `stop` and the penalties that reasoning models refuse) (INT-10).
