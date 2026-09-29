#!/usr/bin/env python3
"""YUI-211: the one way to deploy Yui edge functions. A function never runs ahead of its migrations.

    deploy_functions.py yui-native yui-agents        check, then deploy these
    deploy_functions.py --all                        every function in supabase/functions
    deploy_functions.py --check                      only the migration check
    deploy_functions.py --apply-migrations yui-native   apply unapplied files in order, then deploy

Before anything deploys, supabase/migrations is diffed against
supabase_migrations.schema_migrations on the yuigui project. Any file not yet
applied stops the deploy (exit 1) and is listed. --apply-migrations runs them in
filename order and records each in schema_migrations, then deploys. Never
`supabase db push`: the project is shared, so migrations are applied by hand.

Outage 2026-09-29: yui-native v58 and yui-agents v31 shipped carrying
yui_messages.chat_id while 20260929000000_yui_chats was never applied, and every
crew message failed for 2.5 hours.
"""
import argparse, subprocess, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mgmt

FUNCTIONS = mgmt.MIGRATIONS.parent / "functions"


def lit(s: str) -> str:
    return "'" + s.replace("'", "''") + "'"


def apply(missing) -> None:
    for version, fname in missing:
        body = (mgmt.MIGRATIONS / fname).read_text()
        name = fname[len(version) + 1:].removesuffix(".sql")
        # one request: the file and its ledger row commit together or not at all
        mgmt.sql(f"begin;\n{body}\n;insert into supabase_migrations.schema_migrations (version, name) "
                 f"values ({lit(version)}, {lit(name)});\ncommit;")
        print(f"applied {fname}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("functions", nargs="*")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--apply-migrations", action="store_true")
    a = ap.parse_args()

    names = sorted(p.name for p in FUNCTIONS.iterdir() if (p / "index.ts").exists() and not p.name.startswith("_")) if a.all else a.functions
    if not names and not a.check:
        ap.error("name a function, or pass --all or --check")
    bad = [n for n in names if not (FUNCTIONS / n / "index.ts").exists()]
    if bad:
        sys.exit(f"no such function: {', '.join(bad)}")

    missing = mgmt.unapplied()
    if missing and a.apply_migrations:
        apply(missing)
    elif missing:
        print("REFUSING to deploy: migrations not applied on the project:", file=sys.stderr)
        for _, n in missing:
            print(f"  {n}", file=sys.stderr)
        print("apply them first, or pass --apply-migrations", file=sys.stderr)
        return 1
    print(f"migrations: {len(mgmt.repo_migrations())} files, none unapplied")
    if a.check:
        return 0
    for n in names:
        r = subprocess.run(["supabase", "functions", "deploy", n, "--project-ref", mgmt.REF, "--use-api", "--no-verify-jwt"],
                           cwd=mgmt.MIGRATIONS.parent.parent)
        if r.returncode:
            return r.returncode
    return 0


if __name__ == "__main__":
    sys.exit(main())
