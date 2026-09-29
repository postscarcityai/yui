"""Shared Supabase management API helpers for the yuigui project (YUI-211).

Needs a Supabase access token (SUPABASE_ACCESS_TOKEN or the CLI's keychain entry).
"""
import base64, json, os, subprocess, sys, urllib.error, urllib.parse, urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

REF = "txuibjxyfpalzvpneqgp"
MIGRATIONS = Path(__file__).resolve().parents[1] / "migrations"


def access_token() -> str:
    t = os.environ.get("SUPABASE_ACCESS_TOKEN")
    if t:
        return t
    raw = subprocess.check_output(["security", "find-generic-password", "-s", "Supabase CLI", "-w"]).decode().strip()
    return base64.b64decode(raw.removeprefix("go-keyring-base64:")).decode()


def _call(req: urllib.request.Request):
    req.add_header("authorization", f"Bearer {access_token()}")
    req.add_header("user-agent", "yui-supabase-scripts")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        sys.exit(f"supabase api failed: {e.code} {e.read().decode()[:300]}")


def sql(q: str):
    return _call(urllib.request.Request(f"https://api.supabase.com/v1/projects/{REF}/database/query",
                                        data=json.dumps({"query": q}).encode(), method="POST",
                                        headers={"content-type": "application/json"}))


def logs(q: str, minutes: int = 60):
    """ClickHouse SQL over the one `logs` table. The old logs.all endpoint returns 410.
    Example: SELECT timestamp, event_message FROM logs WHERE event_message LIKE '%yui-native%' ORDER BY timestamp DESC LIMIT 40
    Avoid SELECT * and source_name: both return "Backend error"."""
    end = datetime.now(timezone.utc)
    start = end - timedelta(minutes=minutes)
    qs = urllib.parse.urlencode({"sql": q, "iso_timestamp_start": start.strftime("%Y-%m-%dT%H:%M:%SZ"),
                                 "iso_timestamp_end": end.strftime("%Y-%m-%dT%H:%M:%SZ")})
    return _call(urllib.request.Request(f"https://api.supabase.com/v1/projects/{REF}/analytics/endpoints/logs?{qs}"))


def repo_migrations() -> list[tuple[str, str]]:
    """(version, filename) for every migration file, oldest first."""
    return sorted((f.name.split("_", 1)[0], f.name) for f in MIGRATIONS.glob("*.sql"))


def applied_versions() -> set[str]:
    return {r["version"] for r in sql("select version from supabase_migrations.schema_migrations")}


def unapplied() -> list[tuple[str, str]]:
    have = applied_versions()
    return [(v, n) for v, n in repo_migrations() if v not in have]
