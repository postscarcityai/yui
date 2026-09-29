#!/bin/bash
# YUI-34: the vault migration and its relay rules on a throwaway Postgres 16.
#
#   vault_local.sh <kit dir>     the kit: stubs.sql, fake_ext.sh (see
#                                artifacts/t_4be27be2 on the Mac mini)
#
# Applies every migration, then vault_checks.sql. Prints PASS/FAIL per check
# and exits 1 on any FAIL.
set -u
KIT=${1:?kit dir}
HERE=$(cd "$(dirname "$0")" && pwd)
C=${VAULT_PG:-yui34-pg}
docker rm -f $C >/dev/null 2>&1
docker run -d --name $C -e POSTGRES_HOST_AUTH_METHOD=trust postgres:16-alpine -c wal_level=logical >/dev/null
until docker exec $C pg_isready -q -U postgres 2>/dev/null; do sleep 1; done; sleep 2
docker exec -i $C sh < "$KIT/fake_ext.sh"
psqlc() { docker exec -i $C psql -q -U postgres -v ON_ERROR_STOP=1 "$@"; }
psqlc < "$KIT/stubs.sql" || exit 1
for f in "$HERE"/../migrations/*.sql; do
  psqlc < "$f" >/dev/null 2>&1 || { echo "FAIL migration $(basename "$f")"; exit 1; }
done
out=$(psqlc -t -A < "$HERE/vault_checks.sql" 2>&1)
echo "$out" | grep -E '^(PASS|FAIL)|ERROR'
echo "$out" | grep -qE '^FAIL|ERROR' && exit 1
exit 0
