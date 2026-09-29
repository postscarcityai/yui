#!/bin/bash
# YUI-169: the chats migration on a throwaway Postgres 16, with data that
# already exists when it lands (the backfill), then the RLS and trigger checks.
#
#   chats_local.sh <kit dir>     the kit: stubs.sql, fake_ext.sh (see
#                                artifacts/t_4be27be2 on the Mac mini)
#
# Prints PASS/FAIL per check and exits 1 on any FAIL.
set -u
KIT=${1:?kit dir}
HERE=$(cd "$(dirname "$0")" && pwd)
MIG=$HERE/../migrations
PRE=$(mktemp -d)
for f in "$MIG"/*.sql; do case "$f" in *_yui_chats.sql) ;; *) cp "$f" "$PRE/";; esac; done
C=yui169-pg
docker rm -f $C >/dev/null 2>&1
docker run -d --name $C -e POSTGRES_HOST_AUTH_METHOD=trust postgres:16-alpine -c wal_level=logical >/dev/null
until docker exec $C pg_isready -q -U postgres 2>/dev/null; do sleep 1; done; sleep 2
docker exec -i $C sh < "$KIT/fake_ext.sh"
psqlc() { docker exec -i $C psql -q -U postgres -v ON_ERROR_STOP=1 "$@"; }
psqlc < "$KIT/stubs.sql" || exit 1
for f in "$PRE"/*.sql; do psqlc < "$f" >/dev/null 2>&1 || { echo "FAIL pre-migration $(basename "$f")"; exit 1; }; done
psqlc < "$HERE/chats_seed.sql" || exit 1
psqlc < "$MIG"/*_yui_chats.sql >/dev/null || { echo "FAIL chats migration"; exit 1; }
out=$(psqlc -t -A < "$HERE/chats_checks.sql" 2>&1)
echo "$out" | grep -E '^(PASS|FAIL)|ERROR' 
rm -rf "$PRE"
echo "$out" | grep -qE '^FAIL|ERROR' && exit 1
exit 0
