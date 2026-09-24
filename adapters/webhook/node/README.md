# Yui webhook bridge, Node

No dependencies, Node 20+. One file: copy `yui-webhook.mjs` anywhere.

```
node yui-webhook.mjs pair 123456 --ref my-agent        # code from the app's Add agent
node example-agent.mjs &                               # or your own agent on any URL
node yui-webhook.mjs run --webhook http://127.0.0.1:8787 [--secret S]
```

| Command | Does |
| --- | --- |
| `pair <code> [--ref NAME] [--host-name NAME]` | binds the agent the app just made to this bridge |
| `run --webhook URL [--secret S] [--interval 2] [--timeout 300]` | the bridge; `$YUI_WEBHOOK_URL` / `$YUI_WEBHOOK_SECRET` work too |
| `send "text" [--agent ID\|HANDLE\|REF]` | a message on its own (a handoff), with a push |
| `guide` | prints the channel guide for your agent's prompt |
| `status` | the connector and its agents |

`--state FILE` (or `$YUI_WEBHOOK_STATE`) picks the state file, default `~/.yui/webhook.json`. It is the same format as the Python bridge's, so either can take over from the other.

`example-agent.mjs` is the whole agent in ten lines: it answers any message with a `choose` screen and any tap with the choice. What the webhook receives and may answer: [../README.md](../README.md).
