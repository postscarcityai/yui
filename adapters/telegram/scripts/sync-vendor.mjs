// Copies the Yui Lines parser and the event formatter from yuigui, so the
// Telegram renderer reads lines exactly like the app, the site and yui-mcp.
// Source of truth: yuigui site/lib/yl/yl.mjs and mcp-app/src/events.mjs.
//
//   node scripts/sync-vendor.mjs           write src/vendor/*
//   node scripts/sync-vendor.mjs --check   exit 1 when a copy is stale
//
// YUIGUI=/path/to/yuigui overrides the default ~/dev/yuigui.
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const hub = process.env.YUIGUI || join(homedir(), "dev/yuigui");
export const FILES = [
  ["site/lib/yl/yl.mjs", "yl.mjs"],
  ["mcp-app/src/events.mjs", "events.mjs"],
];
const header = (src) => `// Copied from yuigui ${src} by adapters/telegram/scripts/sync-vendor.mjs. Do not edit here.\n`;

export function stale() {
  const out = [];
  for (const [src, dst] of FILES) {
    const want = header(src) + readFileSync(join(hub, src), "utf8");
    const path = join(here, "../src/vendor", dst);
    if (!existsSync(path) || readFileSync(path, "utf8") !== want) out.push({ path, want });
  }
  return out;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const s = stale();
  if (process.argv.includes("--check")) {
    if (s.length) { console.error(`stale: ${s.map((x) => x.path).join(", ")}; run node scripts/sync-vendor.mjs`); process.exit(1); }
    console.log("vendor copies are current");
  } else {
    for (const { path, want } of s) { writeFileSync(path, want); console.log(`wrote ${path}`); }
    if (!s.length) console.log("already current");
  }
}
