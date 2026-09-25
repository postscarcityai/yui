#!/usr/bin/env node
// Yui Lines -> Telegram, from the command line (INT-4). No bot, no token:
// it prints the Bot API calls a bot would make, so you can see what a reply
// becomes before wiring it into one.
//
//   node yui-telegram.ts render reply.md        a whole agent reply (chat text + ```yui fences)
//   echo 'choose "Today?" Push|Pull' | node yui-telegram.ts render --yl
//   node yui-telegram.ts link 'timer 40/20x8'   the Mini App link for some lines
//   node yui-telegram.ts tap 'y:<token>:0'      after render in the same run: see render --tap
//
// Flags: --mini-app URL (default https://www.yuigui.com/tg), --bridge URL,
// --agent NAME, --tap INDEX,... (render, then press those buttons in order and
// print the event lines they send).
import { readFileSync } from "node:fs";
import { MemoryStore, appLink, render } from "./src/render.ts";
import { tap } from "./src/taps.ts";

const argv = process.argv.slice(2);
const flag = (name: string) => { const i = argv.indexOf(name); if (i < 0) return undefined; const v = argv[i + 1]; argv.splice(i, 2); return v; };
const bool = (name: string) => { const i = argv.indexOf(name); if (i < 0) return false; argv.splice(i, 1); return true; };
const opts = { miniApp: flag("--mini-app"), bridge: flag("--bridge"), agent: flag("--agent") };
const taps = flag("--tap");
const bare = bool("--yl");
const [cmd, arg] = argv;

const input = () => (arg && arg !== "-" ? (cmd === "link" ? arg : readFileSync(arg, "utf8")) : readFileSync(0, "utf8"));

if (cmd === "render") {
  const store = new MemoryStore();
  const text = input();
  const r = await render(bare ? "```yui\n" + text + "\n```" : text, { store, ...opts });
  for (const m of r.messages) console.log(JSON.stringify({ method: "sendMessage", params: m }));
  for (const e of r.errors) console.error(`error: ${e}`);
  if (taps) {
    const buttons = r.messages.flatMap((m) => m.reply_markup?.inline_keyboard.flat() ?? []).filter((b) => b.callback_data);
    for (const i of taps.split(",")) {
      const b = buttons[Number(i)];
      const t = b ? await tap(b.callback_data!, store) : null;
      console.log(`tap ${i} "${b?.text}": ${t?.line ?? t?.toast ?? "nothing"}`);
    }
  }
} else if (cmd === "link") {
  console.log(await appLink(input(), opts));
} else {
  console.log("usage: node yui-telegram.ts render [file|-] [--yl] [--tap 0,1] [--mini-app URL] [--bridge URL] [--agent NAME]\n       node yui-telegram.ts link '<yui lines>'");
  process.exit(cmd ? 1 : 0);
}
