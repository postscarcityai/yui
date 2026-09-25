---
{
  "kind": "channel",
  "version": 1,
  "website": "https://www.yuigui.com/developers"
}
---

# Add a Yui Channel to Flue

You are an AI coding agent connecting a Flue project to Yui, a phone app where
agents answer with screens (buttons, pickers, forms, timers, cards) instead of
paragraphs. The person talks to the agent in the Yui app; the agent's replies
can carry Yui Lines, a one-line-per-component screen format, and taps on those
screens come back as the next message.

Yui dials out, so there is no public webhook to register. The `yui-flue`
connector runs inside the Flue app on the Node target: it reads the person's
messages from Yui, hands each turn to your code, and writes the reply back
exactly once. For pushed delivery (Yui's hosted connector, or the Yui webhook
bridge) the same module also gives verified HTTP ingress in the usual Flue
channel shape.

## Inspect the project

Read local instructions, detect the package manager and target, and select the
first existing source root: `<root>/.flue/`, then `<root>/src/`, then
`<root>/`. Inspect existing agents, `app.ts` (the application's route map),
environment types, and secret conventions. Ask which agent should answer in
Yui when the project has more than one and the choice is not obvious.

The dial-out connector needs the Node target (a long-lived process). On the
Cloudflare target, use only the ingress route below and let Yui push turns to
it; see "Cloudflare" at the end.

Install `yui-flue` (Node 22.18+, no runtime dependencies) and `valibot` if the
project does not already use it. Until `yui-flue` is on npm, add it from the
Yui repository: `"yui-flue": "file:<path to yui>/adapters/flue"`.

## Create the channel

Create `<source-dir>/channels/yui.ts`. Adapt the imported agent:

```ts
// flue-blueprint: channel/yui@1
import { AgentRunError, init } from '@flue/runtime';
import { createYuiChannel, createYuiConnector, type YuiTurn } from 'yui-flue';
import { Assistant } from '../agents/assistant.ts';

// One Flue conversation per Yui thread. The instance id is the Yui agent's
// id, which only this connector's Yui account can reach.
async function answer(turn: YuiTurn): Promise<string | null> {
  const agent = init(Assistant, { id: `yui:${turn.agent.id}` });
  const receipt = await agent.dispatch({
    // A Yui thread is one person and their agent, so a user message. A tap
    // arrives as its `[yui] <id> <preset> key=value` line in the text.
    message: { kind: 'user', body: turn.text },
    // Stable for these rows: a turn replayed after a restart converges on
    // the first submission instead of running twice.
    idempotencyKey: turn.key,
    initialData: { yuiAgentId: turn.agent.id, name: turn.agent.name },
  });
  try {
    return (await agent.read(receipt)).text;
  } catch (e) {
    // A settled failure would fail the same way on a retry: tell the person once.
    if (e instanceof AgentRunError) return `${turn.agent.name} couldn't finish that (${e.outcome}).`;
    throw e; // anything else: the connector tries the same turn again later
  }
}

// Dial out to Yui (Node). Paired with `yui-flue pair <code>`.
export const client = createYuiConnector({ answer });

// Verified ingress for pushed turns: the webhook bridge's signed POSTs
// (`yui-webhook run --webhook <app>/channels/yui/webhook --secret ...`), and
// later Yui's hosted connector. Only when a secret is set: unsigned, anyone
// could talk as the person.
export const channel = process.env.YUI_WEBHOOK_SECRET
  ? createYuiChannel({ secret: process.env.YUI_WEBHOOK_SECRET, answer })
  : null;
```

`answer()` is application policy. Route by `turn.agent.ref` when one Yui
connector serves several Flue agents (`yui-flue add --ref <name>` adds one).
Return `null` or `''` for no reply. Throw to have the connector try the same
turn later with the same `key`.

`YuiTurn` fields: `agent` (`id`, `name`, `handle`, `ref`), `turn` (the row ids
it answers), `key` (stable idempotency key), `text` (the person's messages,
one per line), `messages` (each row, with `event` set for a tap: `{ id,
preset, value, echo }`), and `guide` (the Yui channel guide, `{ version, body }`).

## Mount and start it

```ts
// app.ts
import { createChannelRouter } from '@flue/runtime';
import { Hono } from 'hono';
import { channel as yui, client as yuiClient } from './channels/yui.ts';

const app = new Hono();
// POST /channels/yui/webhook, when YUI_WEBHOOK_SECRET is set
if (yui) app.route('/channels/yui', createChannelRouter(yui.routes));

// Node target: dial out to Yui once this machine is paired.
if (yuiClient.paired) {
  yuiClient.start().catch((e) => console.error(`yui-flue: ${e?.message ?? e}`));
  yuiClient.stopOnSignals(); // Yui hears goodbye before the server exits
}

export default app;
```

Merge into the existing `app.ts`; keep its routes and middleware.
`stopOnSignals()` tells Yui on SIGINT and SIGTERM, so the app shows the agent
offline at once instead of asleep. Flue's Node server exits as soon as it has
drained; the connector holds that exit until Yui has heard goodbye, at most
five seconds.

## Teach the agent Yui

The channel guide tells the model how to put a screen on the phone. The
connector fetches it with every Yui session; `withYuiGuide()` appends the
newest one to the agent's instructions:

```ts
'use agent';
import { useModel } from '@flue/runtime';
import * as v from 'valibot';
import { withYuiGuide } from 'yui-flue';

export function Assistant() {
  useModel('anthropic/claude-haiku-4-5');
  return withYuiGuide('You are a friendly helper. Keep answers short.');
}

Assistant.initialData = v.object({ yuiAgentId: v.string(), name: v.string() });
```

Keep the agent's own instructions; only wrap the returned string. Without the
guide the agent still works in Yui, as plain chat.

A reply shows a screen when it has a fenced `yui` block; text outside it is a
chat bubble:

````
Hi! What sounds good?
```yui
choose "Pick one" Coffee|Walk|Nap
```
````

The tap comes back as the next turn's text: `[yui] <id> choose choice=Walk`.
The agent answers it like any message.

## Pair it

1. In the Yui app: Agents, Add agent. It shows a 6-digit code.
2. From the project folder: `npx yui-flue pair <code> --ref assistant`.
   The connector token lands in `~/.yui/flue.json` (mode 600), or
   `$YUI_FLUE_STATE`. Treat it like a password; never commit it, never put it
   in model context. Removing the computer in the app revokes it.
3. Start the app (`vite dev`, or `vite build && node dist/server.mjs`) and say
   hi in Yui.

## Delivery rules

The connector keeps Yui's relay rules: a person's rows are marked delivered
when a turn starts and handled once the reply is written; every reply names
its rows (`meta.turn`); replies wait in an outbox on disk until Yui has them.
One turn at a time per Yui agent; messages sent meanwhile go in together as the
next turn. After a crash the turn in flight is sent again with the same `key`.
With a durable `db.ts` the dispatch converges on the first submission; with the
default in-memory store it runs again, and the reply still lands once.

## Verify

1. Type-check the project and `vite build` for the configured target.
2. Without Yui: POST a signed turn to `/channels/yui/webhook` with
   `YUI_WEBHOOK_SECRET` set. The signature is `x-yui-signature: sha256=<hex>`,
   the HMAC-SHA256 of `<x-yui-timestamp>.<raw body>`. Check a good signature
   answers `200 {"reply": ...}`, a bad or stale one `401`, and an empty
   answer `204`.
3. With Yui, only when the user asks: pair on a test account, send a message,
   ask for a choice as buttons, tap one.

## Cloudflare

On the Cloudflare target an agent is a Durable Object and nothing should hold
a polling loop. Use only the ingress route, imported from `yui-flue/channel`
(Fetch and Web Crypto, no Node modules), and let Yui push: Yui's hosted
connector (planned) posts each turn to `/channels/yui/webhook`, signed, and
reads the reply from the response, so keep the model call inside the request's
lifetime. A reply sent after the request ends is not supported yet.

When updating an existing integration, inspect and compare it against this complete current blueprint, apply every relevant change while preserving customizations, and then add or update the marker in the primary marked file. This comparison is required when the marker is missing.

## Upgrade Guide

### Version 1 — 2026-09-25

Initial version.
