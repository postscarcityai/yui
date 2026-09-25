# Yui channel for Flue (INT-13)

A [Flue](https://flueframework.com) agent talks in Yui, and answers with screens: buttons, pickers, forms, timers, cards. Flue is the TypeScript agent framework from the Astro team (`withastro/flue`); this is a Flue channel for it.

```
 Yui app  <-->  Yui (rows in yui_messages)  <--dials out--  your Flue app (Node)  -->  init(Agent).dispatch()
```

The Flue app dials out to Yui, so there is no public webhook and no open port. Each turn the person sends goes to your Flue agent through `init().dispatch()`, and the settled reply goes back into their thread, once.

## Five minutes

Needs Node 22.18 or newer. Until `yui-flue` is on npm, add it from this folder: `"yui-flue": "file:<path>/adapters/flue"`.

1. Hand the blueprint to your coding agent, the way `flue add channel` does:
   ```
   cat blueprint/channel--yui.md | claude
   ```
   It writes `channels/yui.ts` (marked `// flue-blueprint: channel/yui@1`), starts the connector from `app.ts`, and wraps your agent's instructions with `withYuiGuide()`.
2. In the Yui app: **Agents > Add agent**. It shows a 6-digit code.
3. From your Flue project: `node <path>/adapters/flue/yui-flue.ts pair 123456 --ref assistant`
4. Start the app: `vite dev`, or `vite build && node dist/server.mjs`.
5. Say hi in Yui.

`example/` is a whole Flue app wired this way: one agent on local Ollama (`qwen2.5:7b`, no key), whose own instructions never mention Yui.

## What is here

| | |
| --- | --- |
| `blueprint/channel--yui.md` | the Flue blueprint, in Flue's own format (JSON frontmatter, primary-file marker, Upgrade Guide) |
| `src/yui.ts` | the connector: `createYuiConnector` (dial out), `createYuiChannel` (signed ingress), `withYuiGuide`, `yuiGuide` |
| `yui-flue.ts` | `pair`, `add`, `status`, `guide` |
| `example/` | a Flue 2.x app on the Node target using it |
| `tests/` | `channel.test.ts` (no network), `flue_e2e.py` (live) |

The Yui side is not a copy: `src/yui.ts` extends `YuiRelay` from `../a2a/src/relay.ts`, the same relay code the A2A bridge runs (session, delivered and handled acks, the outbox on disk, `meta.turn`, presence). `src/yui.ts` does not import `@flue/runtime`; the project's `channels/yui.ts` owns the dispatch, as Flue channels do.

## How a turn maps

| Yui | Flue |
| --- | --- |
| a Yui agent | one agent instance, `id: yui:<Yui agent id>` |
| a turn (the person's messages since the last answer) | one `dispatch()` of a `user` message, the messages one per line |
| a tap on a screen | its `[yui] <id> <preset> key=value` line in that text |
| the answer | `read(receipt).text` |
| the channel guide | the agent's instructions, through `withYuiGuide()` |
| the turn's rows | `idempotencyKey`, stable for those rows |

- **One Flue conversation per Yui thread**, so the agent remembers the thread.
- **A user message, not a signal.** Flue channels usually dispatch signals, since Slack or GitHub threads have many people. A Yui thread is one person and their own agent.
- **A failed run** (`AgentRunError`) becomes one short line to the person; any other error retries the same turn later with the same key.

## Exactly once

The connector keeps the relay's delivery rules (`spec/RELAY.md`, Delivery): the person's rows are marked delivered when the turn starts and handled once the answer is written; every answer names its rows in `meta.turn`; answers wait in an outbox on disk until Yui has them. The turn in flight is on disk before the dispatch. After a crash it goes out again with the same idempotency key: with a durable `db.ts` Flue converges on the first submission, and with the default in-memory store the agent runs it again. Either way the answer lands once. One turn at a time per Yui agent; anything sent meanwhile goes in together as the next turn.

## Pushed turns

`createYuiChannel({ secret, answer })` is a Flue channel with one route, `POST /webhook`. It takes the [webhook bridge](../webhook/)'s signed POSTs (`x-yui-signature: sha256=<hex>`, the HMAC-SHA256 of `<x-yui-timestamp>.<raw body>`, five-minute window) and answers `{"reply": ...}` or `204`. It is there for Yui's hosted connector on Cloudflare, where nothing should hold a polling loop; today the webhook bridge can drive it (`yui-webhook run --webhook http://localhost:3000/channels/yui/webhook --secret S`). It refuses to exist without a secret.

## Tests

```
node --test tests/channel.test.ts   # the ingress route and the turn shape, no network
python3 tests/flue_e2e.py           # live: pair, a turn, a screen, a tap, memory, kill -9, clean stop (throwaway account)
```

The e2e builds `example/` with `vite build`, runs `node dist/server.mjs`, and needs Ollama with `qwen2.5:7b` and the maintainers' Supabase access token, like `supabase/tests`.
