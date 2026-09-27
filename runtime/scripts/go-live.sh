#!/usr/bin/env bash
# Native Yui, go live (NATIVE-1). Run from the repo root, by a maintainer:
#   bash runtime/scripts/go-live.sh              set Yui's OpenRouter key
#   bash runtime/scripts/go-live.sh --wake       also make a new wake secret (function + vault)
# Nothing is printed or written to disk; the key is typed with input hidden.
# Set a monthly spend ceiling on the key at openrouter.ai first.
# It does not switch native Yui on. That is one line after it:
#   update yui_limits set value = 1 where name = 'native_enabled';
set -euo pipefail
REF=txuibjxyfpalzvpneqgp
command -v supabase >/dev/null || { echo "needs the supabase CLI"; exit 1; }

read -r -s -p "Yui's OpenRouter key (input hidden): " OR_KEY; echo
[ -n "$OR_KEY" ] || { echo "no key given"; exit 1; }
supabase secrets set --project-ref "$REF" YUI_OPENROUTER_KEY="$OR_KEY" >/dev/null
unset OR_KEY
echo "YUI_OPENROUTER_KEY set"

if [ "${1:-}" = "--wake" ]; then
  [ -f supabase/.temp/project-ref ] || supabase link --project-ref "$REF" >/dev/null
  WAKE=$(openssl rand -base64 48 | tr -d '\n/+=' | cut -c1-56)
  SQL=$(mktemp)
  trap 'rm -f "$SQL"' EXIT
  cat > "$SQL" <<SQL
delete from vault.secrets where name in ('yui_native_url', 'yui_native_secret');
select vault.create_secret('https://$REF.supabase.co/functions/v1/yui-native', 'yui_native_url', 'NATIVE-1: where the database wakes yui-native');
select vault.create_secret('$WAKE', 'yui_native_secret', 'NATIVE-1: the x-yui-native header');
SQL
  supabase db query --linked -f "$SQL" -o json >/dev/null
  supabase secrets set --project-ref "$REF" YUI_NATIVE_SECRET="$WAKE" >/dev/null
  unset WAKE
  echo "wake secret set (function and vault)"
fi
