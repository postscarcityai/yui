// A ten-line agent for Yui: every turn gets a screen back. Start it, then: node yui-webhook.mjs run --webhook http://127.0.0.1:8787
import { createServer } from "node:http";
createServer(async (req, res) => {
  let raw = "";
  for await (const chunk of req) raw += chunk;
  const turn = JSON.parse(raw);
  const taps = turn.messages.filter((m) => m.event?.echo).map((m) => m.event.echo); // taps on our screen
  const reply = taps.length ? `${taps.at(-1)} it is. Enjoy!` : 'Hi! What sounds good?\n```yui\nchoose "Pick one" Coffee|Walk|Nap\n```';
  res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ reply }));
}).listen(process.env.PORT ?? 8787, "127.0.0.1");
