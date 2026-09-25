#!/usr/bin/env python3
"""Copy the Yui MCP App into the yui-mcp edge function (INT-7).

Source of truth: yuigui/mcp-app (built with `npm run build` there):
  dist/yui-screen.html  the web renderer in one file, served as ui://yui/screen
  src/events.mjs        the event line and echo rules the view uses, so yui_tap
                        writes exactly what the view showed

    sync_mcp_app.py            # write functions/yui-mcp/screen_html.mjs + app_events.mjs
    sync_mcp_app.py --check    # exit 1 if either copy is stale (mcp_test.py runs this)
"""
import argparse, json, os, sys
from pathlib import Path

SRC = Path(os.environ.get("YUI_MCP_APP_SOURCE", Path.home() / "dev/yuigui/mcp-app"))
FN = Path(__file__).resolve().parents[1] / "functions/yui-mcp"
HEADER = "// Copied from yuigui mcp-app by supabase/scripts/sync_mcp_app.py. Do not edit here.\n"


def wanted() -> dict:
    html = (SRC / "dist/yui-screen.html").read_text()
    return {
        FN / "screen_html.mjs": HEADER + "export default " + json.dumps(html) + ";\n",
        FN / "app_events.mjs": HEADER + (SRC / "src/events.mjs").read_text(),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    stale = []
    for dst, want in wanted().items():
        have = dst.read_text() if dst.exists() else ""
        if have == want:
            continue
        if a.check:
            stale.append(dst.name)
        else:
            dst.write_text(want)
            print(f"wrote {dst}")
    if stale:
        print(f"stale: {', '.join(stale)} differ from {SRC}; run sync_mcp_app.py", file=sys.stderr)
        return 1
    print("MCP App copies are current" if a.check else "done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
