#!/usr/bin/env python3
"""Copy the Yui Lines parser into the yui-mcp edge function.

Source of truth: yuigui/site/lib/yl/yl.mjs (pure, dependency free) and every
module it imports by relative path (tables.mjs, look.mjs, ...), walked from
the import lines so a new one comes along on its own. yui-mcp parses what an
MCP client sends to `yui_show`, so a bad line comes back to the model as an
error it can fix instead of a broken screen on the phone.

    sync_yl.py            # write supabase/functions/yui-mcp/yl.mjs + its imports
    sync_yl.py --check    # exit 1 if a copy is stale (mcp_test.py runs this)
"""
import argparse, os, re, sys
from pathlib import Path

SRC = Path(os.environ.get("YUI_YL_SOURCE", Path.home() / "dev/yuigui/site/lib/yl/yl.mjs"))
DST_DIR = Path(__file__).resolve().parents[1] / "functions/yui-mcp"
IMPORT = re.compile(r"""^\s*(?:import|export)\b[^'"]*?\bfrom\s*["'](\.{1,2}/[^"']+)["']|^\s*import\s*["'](\.{1,2}/[^"']+)["']""", re.M)


def header(rel: str) -> str:
    return f"// Copied from yuigui site/lib/yl/{rel} by supabase/scripts/sync_yl.py. Do not edit here.\n"


def modules(root: Path) -> list[Path]:
    """root plus every module it reaches by relative import, in walk order."""
    seen, todo = [], [root.resolve()]
    while todo:
        f = todo.pop(0)
        if f in seen:
            continue
        seen.append(f)
        for m in IMPORT.finditer(f.read_text()):
            dep = (f.parent / (m.group(1) or m.group(2))).resolve()
            if not dep.is_relative_to(root.resolve().parent):
                sys.exit(f"{f.name} imports {dep}, outside {root.parent}; the flat copy cannot hold it")
            todo.append(dep)
    return seen


def plan() -> list[tuple[Path, str]]:
    base = SRC.resolve().parent
    out = []
    for f in modules(SRC):
        rel = f.relative_to(base).as_posix()
        out.append((DST_DIR / rel, header(rel) + f.read_text()))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    stale = [(dst, want) for dst, want in plan() if not dst.exists() or dst.read_text() != want]
    if a.check:
        if stale:
            print(f"stale: {', '.join(str(d) for d, _ in stale)} differ from {SRC.parent}; run sync_yl.py", file=sys.stderr)
            return 1
        print("yl.mjs and its imports are current")
        return 0
    for dst, want in stale:
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_text(want)
        print(f"wrote {dst}")
    if not stale:
        print("already current")
    return 0


if __name__ == "__main__":
    sys.exit(main())
