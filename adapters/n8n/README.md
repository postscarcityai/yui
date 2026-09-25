# Yui for n8n (INT-17)

Put a screen on someone's phone from an n8n workflow and get their tap back. Three ways, pick the one that fits:

| | What it is | Needs an LLM |
| --- | --- | --- |
| **The Yui node** (this package) | Drag in "Yui", pick Ask and Wait, write the screen. The next node gets the tap. | No |
| **MCP Client Tool** | n8n's AI Agent calls Yui's MCP server as a tool, like Claude does. | Yes |
| **Webhook trigger** | The [webhook bridge](../webhook) POSTs every message to an n8n Webhook; the workflow answers. Yui becomes a chat front end for a workflow. | No |

All three talk to the same live Yui. Importable workflows for each are in [`workflows/`](workflows).

```
 n8n workflow --Yui node / MCP Client Tool-->  yui-mcp  -->  the thread  -->  Yui app
              <--the tap------------------------        <--             <--  a tap
```

## 1. Get a connection token

Once, for the Yui node and the MCP Client Tool (the webhook path pairs its own bridge instead):

1. In the Yui app: **Agents > Add agent**, name it "n8n". It shows a 6-digit code.
2. Trade the code for a token (it works once, for ten minutes):
   ```
   curl -s https://ewzzaoperdpxqxkshynx.supabase.co/functions/v1/yui-connect \
     -H 'content-type: application/json' \
     -d '{"action":"pair","code":"123456","remote_ref":"n8n","kind":"mcp","host_name":"n8n"}'
   ```
3. Keep the `connector_token` (`yui_ct_...`). It is shown once. Treat it like a password: it goes into an n8n credential, never into a workflow. Removing its computer ("n8n") in the app revokes it.

## 2a. The Yui node

Not on npm yet. Install it from this folder into your n8n's custom nodes:

```
cd adapters/n8n && npm install && npm run build && npm pack
mkdir -p ~/.n8n/nodes && cd ~/.n8n/nodes && npm install --omit=peer /path/to/n8n-nodes-yui-0.1.0.tgz
```

Restart n8n. Add a **Yui API** credential with the token, then a **Yui** node:

| Operation | What it does | Output |
| --- | --- | --- |
| Ask and Wait | Shows the screen, waits for the tap (Timeout, default 300 s; On Timeout: fail or an empty item) | `choice`, `echo`, `value`, `line`, `id`, `preset`, `screen_id` |
| Send Screen | Shows the screen and goes on | `screen_id`, `ids` (the tap ids) |
| Wait for Answer | Waits for the tap on a screen sent earlier (`{{ $json.screen_id }}`) | as Ask and Wait |
| Send Message | A plain chat message | `message_id` |

**Screen** is [Yui Lines](https://www.yuigui.com/yl), one component per line: `choose "Lunch?" Salad|Soup|Tacos`, `ask "Ship it?" Yes|No`, `timer 5m Focus`, a `form`, a `card`. Expressions work: `=choose "{{ $json.question }}" Yes|No`. Lines Yui can't read fail the node with the parser's message and nothing is sent.

By default a wait ends only on a tap; text the person types meanwhile rides along in `also_wrote`. Turn off **Taps Only** to let typed text end the wait too. The node is usable as an AI Agent tool as well.

Example: [`workflows/yui-node-ask.json`](workflows/yui-node-ask.json) (Webhook, Ask and Wait, Send Message "Tacos it is", respond with the tap).

## 2b. MCP Client Tool (AI Agent)

1. Add an **AI Agent** node and a chat model.
2. Add the **MCP Client Tool** as its tool:
   - Endpoint: `https://ewzzaoperdpxqxkshynx.supabase.co/functions/v1/yui-mcp`
   - Server Transport: **HTTP Streamable**
   - Authentication: **Bearer Auth**, a credential holding the `yui_ct_...` token. (MCP OAuth2 works too; see spec/MCP.md "OAuth".)
   - Tools to Include: `yui_show`, `yui_answers`, `yui_say`. Leave `yui_tap` out, it is for the in-chat screen.
   - Options > Timeout: 40000 ms or more, since `yui_answers` holds a call up to 25 s.
3. Tell the agent how to use them in its system message. The tool descriptions carry a short guide; small models need the steps spelled out. The one in [`workflows/yui-mcp-agent.json`](workflows/yui-mcp-agent.json) got `qwen2.5:7b` on Ollama through it.

## 2c. Webhook trigger (no token here)

1. A **Webhook** node, POST, Respond: Using 'Respond to Webhook' Node. Then your logic, then **Respond to Webhook** with `{"reply": "..."}`.
2. Pair and run the bridge next to n8n ([webhook README](../webhook)):
   ```
   python3 ../webhook/python/yui_webhook.py pair 123456 --ref n8n
   python3 ../webhook/python/yui_webhook.py run --webhook http://127.0.0.1:5678/webhook/yui-turn
   ```
3. Each message arrives as one POST: `body.text`, `body.messages[]` (a tap is `kind: "event"` with its `event` JSON), and `body.guide`. Put a screen in the reply inside a ```` ```yui ```` fence.

Example: [`workflows/yui-webhook-turn.json`](workflows/yui-webhook-turn.json) (answers "hi" with a lunch screen and a tap with "Soup it is").

## Tests

- `npm test`: builds, then 10 unit tests against a fake yui-mcp (Ask and Wait through an empty answer, Send Screen then Wait by id, Send Message, bad lines, timeouts, typed text, several items, the wait never past the timeout, the package manifest).
- `python3 tests/n8n_e2e.py [--run mcp|node|webhook|all]`: a real n8n (npm `n8n`, Node 24) with an empty user folder, this package installed from `npm pack`, the three workflows imported and published, on a throwaway account in live Yui. Each screen parses with the YL parser, the tap reaches the workflow, the account and n8n's folder are deleted after. Needs the maintainers' Supabase access token, and Ollama with `qwen2.5:7b` for `mcp`. 22 of 22 on Sep 25 2026.

Not published to npm or the n8n community list yet.
