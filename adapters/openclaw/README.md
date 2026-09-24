# Yui channel for OpenClaw

Your [OpenClaw](https://openclaw.ai) agent, on your iPhone, with real screens: buttons, pickers, forms, timers. Same relay as the Hermes plugin, so every message reaches the agent once and every answer lands once.

It is an OpenClaw channel plugin (`api.registerChannel` through `defineChannelPluginEntry`, plus a `channel-outbound` message adapter). It dials out to Yui, so your machine opens no ports. TypeScript, no dependencies; OpenClaw loads it from source.

Needs OpenClaw 2026.6.11 or later and the Yui app.

## Five minutes

1. Get the plugin and install it:
   ```
   git clone https://github.com/postscarcityai/yui
   openclaw plugins install ./yui/adapters/openclaw
   ```
2. In the Yui app: **Agents > Add agent**. It shows a 6-digit code.
3. Pair. `--agent` is the OpenClaw agent that answers (default `main`):
   ```
   openclaw yui pair 123456 --agent main
   ```
4. Turn the channel on and restart the gateway:
   ```
   openclaw config set channels.yui.enabled true
   openclaw gateway restart
   ```
5. Say hi in the app. Your agent reads online and answers there.

To add a second OpenClaw agent, add another agent in the app and pair again with its `--agent`. One pairing per install; each Yui agent maps to one OpenClaw agent.

## What your agent is told

Every turn, the plugin puts the Yui channel guide (`spec/CHANNEL.md`, served fresh by Yui) in the agent's trusted system prompt, with one line on top: **on Yui, use Yui Lines, not A2UI**. OpenClaw's own app draws A2UI with the canvas tool; the Yui phone draws Yui Lines in a ` ```yui ` fence. Taps come back as lines that start with `[yui]`.

## Commands

| | |
| --- | --- |
| `openclaw yui pair <code> [--agent ID] [--host-name NAME]` | claim a code from the app |
| `openclaw yui status` | the connector, the guide version, each Yui agent and its OpenClaw agent |
| `openclaw yui guide` | print the channel guide |
| `openclaw yui send "text" [--to AGENT]` | put a message in a thread, with a push |

Cron jobs and the `message` tool can deliver to Yui too: channel `yui`, target `yui:<agent handle or id>`.

## Config

`channels.yui` in `openclaw.json`, all optional:

| key | default | |
| --- | --- | --- |
| `enabled` | `true` | |
| `agent` | | OpenClaw agent for a Yui agent whose ref names none |
| `stateFile` | `<state dir>/yui/connector.json` | where the connector token lives (mode 600, never in `openclaw.json`) |
| `interval` | `2` | seconds between checks for new messages |

## How delivery works

The relay contract from `spec/RELAY.md`: the plugin reads the person's rows that are not handled yet, marks them `delivered_at`, runs one turn per Yui agent (whatever arrives meanwhile folds into the next turn), writes the reply to an outbox on disk before sending it, tags it with `meta.turn`, then marks the rows `handled_at`. A gateway killed mid-turn replays the turn after a restart; a row that was already answered is never sent to the agent again. A clean stop says goodbye, so the app shows the agent offline at once.

## Test

`tests/openclaw_e2e.py` runs a real `openclaw gateway` in a throwaway home against live Yui, on a throwaway account, with a fake model that records what the agent was told: pairing, a screen round trip, a tap, kill -9 mid-turn, a crash between answer and ack, a clean stop, a backlog, a handoff.

```
python3 adapters/openclaw/tests/openclaw_e2e.py
```
