// Copies the Yui Lines parser and the event formatter from yuigui, so the
// Telegram renderer reads lines exactly like the app, the site and yui-mcp.
// Source of truth: yuigui site/lib/yl/yl.mjs and mcp-app/src/events.mjs, plus
// every module they import by relative path (tables.mjs, look.mjs, ...),
// walked from the import lines so a new one comes along on its own.
//
//   node scripts/sync-vendor.mjs           write src/vendor/*
//   node scripts/sync-vendor.mjs --check   exit 1 when a copy is stale
//
// YUIGUI=/path/to/yuigui overrides the default ~/dev/yuigui.
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const hub = process.env.YUIGUI || join(homedir(), "dev/yuigui");
// The roots. Each lands in src/vendor under its own name; its imports keep
// their path relative to it, so the copies import each other unchanged.
export const ROOTS = ["site/lib/yl/yl.mjs", "mcp-app/src/events.mjs"];
const header = (src) => `// Copied from yuigui ${src} by adapters/telegram/scripts/sync-vendor.mjs. Do not edit here.\n`;
const IMPORT = /^\s*(?:import|export)\b[^'"]*?\bfrom\s*["'](\.{1,2}\/[^"']+)["']|^\s*import\s*["'](\.{1,2}\/[^"']+)["']/gm;

// [yuigui path, src/vendor path] for a root and everything it reaches.
export function files() {
  const out = new Map();
  for (const root of ROOTS) {
    const base = dirname(join(hub, root));
    const todo = [join(hub, root)];
    while (todo.length) {
      const f = resolve(todo.shift());
      const dst = relative(base, f);
      if (dst.startsWith("..")) throw new Error(`${root} reaches ${f}, outside ${base}; the vendor copy cannot hold it`);
      if (out.has(dst)) { if (out.get(dst) !== relative(hub, f)) throw new Error(`two sources for src/vendor/${dst}`); continue; }
      out.set(dst, relative(hub, f));
      for (const m of readFileSync(f, "utf8").matchAll(IMPORT)) todo.push(join(dirname(f), m[1] || m[2]));
    }
  }
  return [...out].map(([dst, src]) => [src, dst]);
}

export function stale() {
  const out = [];
  for (const [src, dst] of files()) {
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
