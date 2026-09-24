# Yui webhook bridge, Python

Stdlib only, Python 3.10+. One file: copy `yui_webhook.py` anywhere.

```
python3 yui_webhook.py pair 123456 --ref my-agent      # code from the app's Add agent
python3 example_agent.py &                             # or your own agent on any URL
python3 yui_webhook.py run --webhook http://127.0.0.1:8787 [--secret S]
```

| Command | Does |
| --- | --- |
| `pair <code> [--ref NAME] [--host-name NAME]` | binds the agent the app just made to this bridge |
| `run --webhook URL [--secret S] [--interval 2] [--timeout 300]` | the bridge; `$YUI_WEBHOOK_URL` / `$YUI_WEBHOOK_SECRET` work too |
| `send "text" [--agent ID\|HANDLE\|REF]` | a message on its own (a handoff), with a push |
| `guide` | prints the channel guide for your agent's prompt |
| `status` | the connector and its agents |

`--state FILE` (or `$YUI_WEBHOOK_STATE`) before the command picks the state file, default `~/.yui/webhook.json`.

`example_agent.py` is the whole agent in ten lines: it answers any message with a `choose` screen and any tap with the choice. What the webhook receives and may answer: [../README.md](../README.md).
