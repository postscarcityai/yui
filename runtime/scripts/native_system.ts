// What the native runtime adds after the channel guide on a turn, for one starter (default yui), as plain text.
// The channel eval (yuigui spec/channel-eval/run.mjs --extra) appends it so a case is scored on the whole prompt the
// model sees, not the guide alone:  node runtime/scripts/native_system.ts [handle] > /tmp/native.txt
import { starters } from "../src/profiles.ts";
import { systemPrompt } from "../src/prompt.ts";

const handle = process.argv[2] ?? "yui";
const p = starters().find((s) => s.handle === handle);
if (!p) throw new Error(`no starter ${handle}`);
process.stdout.write(systemPrompt(p, [], "eval") + "\n");
