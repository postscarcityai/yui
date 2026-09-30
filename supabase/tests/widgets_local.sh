#!/bin/bash
# YUI-40 step 4: the widget push rules on a throwaway local Postgres 16 (kit: pg16 stubs, see
# reference yui_migrations_local_pg16). Usage: widgets_local.sh <kit dir with reset.sh>
set -e
KIT=${1:?kit dir with reset.sh, stubs.sql, fake_ext.sh, apply.sh}
HERE="$(cd "$(dirname "$0")" && pwd)"
"$KIT/reset.sh" "$HERE/../migrations"
docker exec -i yui4048-pg psql -q -U postgres -v ON_ERROR_STOP=1 < "$HERE/widgets_checks.sql" | tail -3
