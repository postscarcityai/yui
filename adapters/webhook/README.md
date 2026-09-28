# Yui webhook bridge (INT-2)

Any agent that can answer an HTTP POST can talk in Yui. No Hermes, no SDK, no open ports.

The bridge is one small process you run next to your agent. It dials out to Yui, reads what the person sends, POSTs it to your webhook, and writes your answer back into their thread. Every message arrives once, in order, even across crashes and restarts.

```
 Yui app  <-->  Yui (rows in yui_messages)  <--dials out--  bridge  --POST-->  your agent (localhost)
```

Two reference clients, same behaviour, same state file:

| | Needs | Client | Ten-line agent |
| --- | --- | --- | --- |
| [Python](python/) | Python 3.10+, stdlib only | `python/yui_webhook.py` | `python/example_agent.py` |
| [Node](node/) | Node 20+, no dependencies | `node/yui-webhook.mjs` | `node/example-agent.mjs` |

## Five minutes

1. In the Yui app: **Agents > Add agent**. It shows a 6-digit code.
2. Pair this machine with it:
   ```
   python3 python/yui_webhook.py pair 123456 --ref my-agent
   ```
3. Start your agent (or the example), then the bridge:
   ```
   python3 python/example_agent.py &
   python3 python/yui_webhook.py run --webhook http://127.0.0.1:8787
   ```
4. Say hi in the app. The example answers with three buttons; tap one.

Swap `python3 python/yui_webhook.py` for `node node/yui-webhook.mjs` to use Node.

## What your webhook gets

One POST per turn, `content-type: application/json`:

```json
{
  "agent": {"id": "…", "name": "My agent", "handle": "my-agent", "ref": "my-agent"},
  "turn": ["<row id>", "<row id>"],
  "text": "hi\n[yui] n1 choose choice=Walk",
  "messages": [
    {"id": "…", "kind": "text", "body": "hi", "event": null, "created_at": "…"},
    {"id": "…", "kind": "event", "body": "[yui] n1 choose choice=Walk",
     "event": {"id": "n1", "preset": "choose", "value": {"choice": "Walk"}, "echo": "Walk"}, "created_at": "…"}
  ],
  "guide": {"version": "v10+53ddb59c", "body": "## You are talking to someone in Yui …"}
}
```

- **A turn can hold several messages.** While your agent works on one, anything the person sends waits and goes in together as the next turn, oldest first, one line each in `text`.
- **Taps are events.** When the person answers a screen you sent, the message is `kind: "event"`. `body` is the one-line form (`[yui] <id> <preset> key=value`), `event` the same thing as JSON, and `event.echo` is what the person sees as their reply. Spec: [RELAY.md](https://github.com/postscarcityai/yuigui/blob/main/spec/RELAY.md).
- **`tables` is what your table lines did,** present only after a turn that sent them (see Tables).
- **`guide` is the channel guide.** Put it in your agent's system prompt. Without it your agent writes plain text and never a screen. It changes rarely; `guide.version` tells you when. `yui_webhook.py guide` prints it.

Headers: `x-yui-turn` is a stable key for this turn (use it to skip a turn you already answered). With `--secret S`, every POST also carries `x-yui-timestamp` and `x-yui-signature: sha256=<hex>`, the HMAC-SHA256 of `<timestamp>.<raw body>` with `S`.

## What you answer

| Your response | What happens |
| --- | --- |
| `200` `{"reply": "text"}` | one message in the thread |
| `200` `{"replies": ["a", "b"]}` | several, in order |
| `200` `{"reply": "Logged.", "tables": "put meals Food=Oats"}` | the reply, and the table lines run on Yui (see Tables) |
| `200` `{"tables": "query meals"}` | a read: the rows come back to you at once (see Tables) |
| `200` `text/plain` body | the body is the message |
| `200` or `204` with no body | no reply; the turn is done |
| anything else, or no answer within `--timeout` (300 s) | nothing is written; the turn is tried again, backing off up to a minute |

To show a screen, put [Yui Lines](https://www.yuigui.com/yl) in a ```` ```yui ```` fence. Text outside the fence is a chat bubble:

````
Hi! What sounds good?
```yui
choose "Pick one" Coffee|Walk|Nap
```
````

## Tables

Your agent can keep tables in Yui: a meal log, a to-do list, a small CRM. The words are `table create`, `put` and `query`, the same for every agent ([TABLES.md](https://github.com/postscarcityai/yuigui/blob/main/spec/TABLES.md), section 8). The rows live on Yui's server, held by your agent, and outlive every reply.

Two ways in:

- **In the reply.** Write the lines in your reply, in a ```` ```yui ```` or ```` ```tables ```` fence. Before the reply is saved the bridge hands it to Yui, which writes the rows, draws each `query` as a screen and takes the table lines out; the person sees the result. A reply with no table words skips this. A reply of only `query` lines is a read: nothing is saved and the rows come back to you at once (below).
- **As a field.** Answer `{"reply": "Logged.", "tables": "put meals Food=Oats Cal=300"}`. The lines run, the reply is saved, and what the lines did arrives with your next POST as `tables`. Answer `tables` with no `reply` to read: `{"tables": "query meals where=Day=today"}`.

After a read the bridge POSTs you again right away, in the same turn: the same `turn` ids, `"round": 1` (its own `x-yui-turn`), `text` with the rows in words added at the end, and the rows in `tables`:

```json
"tables": {
  "results": [{"table": "meals", "cols": ["Food", "Cal"], "keys": ["r1"], "rows": [["Oats", 300]], "count": 1}],
  "failed": [{"line": "put meals Cal=lots", "error": "Cal is a number"}],
  "held": null,
  "tables": [{"name": "meals", "rows": 1}],
  "note": "[yui] Your tables:\n..."
}
```

Keys Yui did not send are left out. `failed` holds each refused line and why; `held` is a delete waiting on the person's Delete or Keep tap; `tables` is what your agent holds now; `note` is all of it in words, ready for a prompt. A turn gets at most two read rounds; after that the rows wait for your next POST. A result waiting for your next POST is kept in the state file, so a restart does not lose it.

**Tables handed to you.** When the person gives your agent tables from another agent, your next turn's `text` opens with one line saying what you now hold: `[yui] tables foods(3 rows: Food, Cal)`.

If the tables call fails (network, Yui refuses it), the bridge logs it and saves your reply as written.

## Exactly once

The bridge keeps the relay's delivery rules (RELAY.md, Delivery):

- It reads the person's rows that are not finished (`handled_at` is empty), marks them `delivered_at` when it hands them to you and `handled_at` once your answer is written.
- Your answer gets its id on this machine and goes to an outbox on disk before the first try. A network drop keeps it there; it goes out later, oldest first, never twice.
- Every reply names the rows it answers (`meta.turn`). After a crash, a row whose answer is already written is only marked done, not sent to you again.
- A crash while your agent is thinking replays that turn after the restart. That is the one case your webhook sees a turn twice, with the same `x-yui-turn`.
- A clean stop (Ctrl-C, SIGTERM) tells Yui, so the app shows the agent offline at once. A machine that just goes quiet shows asleep.

## More

- `send "text" [--agent ref]` puts a message in a thread on its own, e.g. from a cron job. The phone gets a push.
- `status` shows the connector and its agents. Pair more agents onto the same bridge with more codes; the payload's `agent` says which one a turn is for.
- State lives in `~/.yui/webhook.json` (mode 600): the connector token, a start point per agent, the outbox and any tables result waiting for an agent's next POST. `--state` or `$YUI_WEBHOOK_STATE` moves it. Treat it like a password; removing the agent's computer in the app revokes it.
- Limits are the relay's: 32,000 characters per message, and the rate limits in the app repo README.

## Tests

Offline, no account needed (a fake Yui and a stub agent on localhost):

```
python3 adapters/webhook/tests/test_tables_offline.py
node --test adapters/webhook/tests/tables-offline.test.mjs
```

Live:

`python3 adapters/webhook/tests/webhook_e2e.py [--client python|node|both]` runs both clients against a fake webhook on a fresh throwaway account in the live backend: pairing, a screen round trip, a tap, a kill -9 mid-turn, a crash between the answer and the ack, a clean stop, a backlog, a handoff. It needs the maintainers' Supabase access token, like `supabase/tests`.
