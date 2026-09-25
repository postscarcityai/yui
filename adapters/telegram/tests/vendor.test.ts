// The parser and event formatter are yuigui's, copied, never forked.
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { stale } from "../scripts/sync-vendor.mjs";

const hub = process.env.YUIGUI || join(homedir(), "dev/yuigui");

test("src/vendor matches yuigui", { skip: !existsSync(join(hub, "site/lib/yl/yl.mjs")) && "no yuigui checkout" }, () => {
  assert.deepEqual(stale().map((s) => s.path), [], "run node scripts/sync-vendor.mjs");
});
