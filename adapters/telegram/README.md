# Yui in Telegram (INT-4)

Yui Lines drawn in Telegram, for when the Yui app is not around. Questions become buttons whose taps come back as the exact line the phone sends (`[yui] n1 choose choice=Legs`). Text presets become formatted messages. Everything else (a timer, a chart, a deck, a form) goes behind one **Open in Yui** button that opens the whole screen in the Telegram Mini App at [yuigui.com/tg](https://www.yuigui.com/tg).

Spec: [yuigui spec/TELEGRAM.md](https://www.yuigui.com/developers/telegram). Step 1: the renderer, the tap handler and the Mini App. No bot runs it yet.

Needs Node 22.18 or newer (it runs the TypeScript as is). No dependencies. Runtime neutral: no Node APIs in `src/`, so a Worker or Deno bot runs the same code.

## Try it without a bot

```
echo 'choose "What today?" Push|Pull|Legs
timer 40/20x8 Tabata' | node yui-telegram.ts render --yl --tap 2,1
```

It prints the `sendMessage` calls a bot would make, then presses buttons 2 and 1 and prints what each sends:

```
tap 2 "Legs": [yui] n1 choose choice=Legs
tap 1 "Pull": [yui] n1 choose changed choice=Pull
```

`node yui-telegram.ts link 'timer 40/20x8'` prints a Mini App link.

## In a bot

| file | what |
| --- | --- |
| `src/render.ts` | `render(reply, {store, agent?, bridge?, miniApp?})`: a whole agent reply (chat text and ```` ```yui ```` fences) to `sendMessage` bodies. `HOW` says what each preset becomes. |
| `src/taps.ts` | `tap(callback_data, store)`: a button press to `{event, line, echo, toast, keyboard}`. `replies(cb, tap)`: the answerCallbackQuery and editMessageReplyMarkup calls. |
| `src/webapp.ts` | Mini App taps: `readWebAppData(message)` for `sendData`, `readBridgePost(body, botToken)` for the bridge, `verifyInitData` (Telegram's HMAC check). |
| `src/share.ts` | the share-code format the Mini App link uses. |
| `src/vendor/` | yuigui's `yl.mjs` parser (with every module it imports, like `tables.mjs` and `look.mjs`) and the MCP App's event formatter, copied by `node scripts/sync-vendor.mjs`. Never edit here. |

`callback_data` holds 64 bytes, so a button carries `y:<token>:<index>` and the component waits in the `Store` you pass. `MemoryStore` is fine for one process; a bot that restarts or scales needs one on its KV or database.

Keep the bot token in the bot's environment. It never goes in a link, a chat or this repo.

## Tests

```
npm test                                    # render, taps, webapp, vendor: 73 checks
node tests/miniapp_e2e.mjs --base https://www.yuigui.com --shots /tmp/tg
```

The e2e runs every playground sample in the Mini App in Telegram's dark and light themes (Playwright, a stand-in `Telegram.WebApp`, a made-up token), and checks taps through `sendData` and the bridge.
