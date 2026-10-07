#!/usr/bin/env python3
"""YUI-211: is the Yui crew answering? Prints nothing when healthy, one line per problem.

Three cheap checks against the yuigui project, meant for a 5 minute cron:
  1. migration drift: a file in supabase/migrations not in schema_migrations
  2. wake failures: pg_net calls to yui-native answered 5xx or timed out in the last window
  3. yui-native / yui-agents errors in the edge function logs (ClickHouse, not logs.all)

Exit 0 always when it could ask; a problem is a printed line, not a failure, so the
cron delivers it to Yui. If the probe itself cannot reach the API it exits 1 (the cron
guard turns that into a card). Usage: health_probe.py [--minutes 15]
"""
import argparse, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mgmt


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--minutes", type=int, default=15)
    m = ap.parse_args().minutes
    out = []

    miss = mgmt.unapplied()
    if miss:
        out.append("Migrations not applied: " + ", ".join(n for _, n in miss))

    bad = mgmt.sql(f"""select status_code, left(coalesce(content, error_msg, ''), 160) as body, count(*) n
                       from net._http_response
                       where created > now() - interval '{m} minutes' and (status_code >= 500 or timed_out)
                       group by 1, 2 order by n desc limit 3""")
    for r in bad:
        out.append(f"Crew wake failed {r['n']}x in {m} min: {r['status_code']} {r['body']}")

    rows = mgmt.logs("SELECT timestamp, event_message FROM logs WHERE (event_message LIKE '%yui-native%' OR event_message LIKE '%yui-agents%') "
                     "AND (event_message LIKE '%does not exist%' OR event_message LIKE '%error%') ORDER BY timestamp DESC LIMIT 5", m)
    hits = rows.get("result") if isinstance(rows, dict) else rows
    if not isinstance(hits, list):
        print(f"health_probe: unexpected logs response: {str(rows)[:200]}", file=sys.stderr)
        return 1
    if hits:
        out.append(f"{len(hits)} function error log lines in {m} min, latest: {str(hits[0].get('event_message', ''))[:160]}")

    if out:
        print("Yui crew health: " + " | ".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
