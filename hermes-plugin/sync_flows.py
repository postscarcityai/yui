#!/usr/bin/env python3
"""Copy the saved flows and the Python Yui Lines parser into the plugin (YUI-155).

A phone older than compat.FLOW_BUILD cannot run `flow`, so compat.downgrade
turns one into the plan it walks by default (Chris's feedback AMLn-Gg3: the
intake came back as a headline and nothing to tap). For that it needs the
saved flows by name and a parser that reads Mermaid the way every hub parser
does. Both come from yuigui, never edited here:

    yuigui/site/lib/yl/starter-flows.mjs  ->  yui/starter_flows.json
    yuigui/parsers/python/yuilines.py     ->  yui/yuilines.py

    sync_flows.py            # write both (needs node)
    sync_flows.py --check    # exit 1 if either copy is stale

$YUIGUI points at the yuigui checkout (default ~/dev/yuigui). Run it from a
worktree off origin/main there, like sync_yl.py.
"""
import argparse, json, os, subprocess, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
YUIGUI = Path(os.environ.get("YUIGUI", Path.home() / "dev/yuigui")).resolve()
FLOWS = HERE / "yui" / "starter_flows.json"
PARSER = HERE / "yui" / "yuilines.py"
STARTERS = YUIGUI / "site/lib/yl/starter-flows.mjs"
SOURCE = YUIGUI / "parsers/python/yuilines.py"
NOTE = "# Copied by hermes-plugin/sync_flows.py from yuigui/parsers/python/yuilines.py. Do not edit.\n"

JS = """
import(process.argv[1]).then((m) => {
  const pick = (f, keys) => Object.fromEntries(keys.map((k) => [k, f[k]]));
  process.stdout.write(JSON.stringify({
    flows: m.STARTER_FLOWS.map((f) => pick(f, ["name", "id", "title", "submit", "source"])),
    variants: m.FLOW_VARIANTS.map((v) => pick(v, ["name", "base", "id", "lines"])),
  }, null, 2) + "\\n");
});
"""


def build() -> dict:
    out = subprocess.run(["node", "-e", JS, STARTERS.as_uri()], capture_output=True, text=True, check=True).stdout
    return {FLOWS: out, PARSER: NOTE + SOURCE.read_text()}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--check", action="store_true", help="exit 1 if a copy is stale")
    a = ap.parse_args()
    stale = []
    for path, text in build().items():
        if (path.read_text() if path.exists() else "") == text:
            continue
        stale.append(path.name)
        if not a.check:
            path.write_text(text)
    if a.check:
        print(f"stale: {', '.join(stale)}" if stale else "flows and parser up to date")
        return 1 if stale else 0
    print(f"wrote {', '.join(stale)}" if stale else "already up to date")
    return 0


if __name__ == "__main__":
    sys.exit(main())
