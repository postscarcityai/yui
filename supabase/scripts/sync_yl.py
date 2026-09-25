#!/usr/bin/env python3
"""Copy the Yui Lines parser into the yui-mcp edge function.

Source of truth: yuigui/site/lib/yl/yl.mjs (pure, dependency free). yui-mcp
parses what an MCP client sends to `yui_show`, so a bad line comes back to the
model as an error it can fix instead of a broken screen on the phone.

    sync_yl.py            # write supabase/functions/yui-mcp/yl.mjs
    sync_yl.py --check    # exit 1 if the copy is stale (mcp_test.py runs this)
"""
import argparse, os, sys
from pathlib import Path

SRC = Path(os.environ.get("YUI_YL_SOURCE", Path.home() / "dev/yuigui/site/lib/yl/yl.mjs"))
DST = Path(__file__).resolve().parents[1] / "functions/yui-mcp/yl.mjs"
HEADER = "// Copied from yuigui site/lib/yl/yl.mjs by supabase/scripts/sync_yl.py. Do not edit here.\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    want = HEADER + SRC.read_text()
    have = DST.read_text() if DST.exists() else ""
    if a.check:
        if have != want:
            print(f"stale: {DST} differs from {SRC}; run sync_yl.py", file=sys.stderr)
            return 1
        print("yl.mjs copy is current")
        return 0
    if have != want:
        DST.write_text(want)
        print(f"wrote {DST}")
    else:
        print("already current")
    return 0


if __name__ == "__main__":
    sys.exit(main())
