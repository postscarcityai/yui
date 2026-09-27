#!/usr/bin/env bash
# Finish Yui's move to its own Supabase project, yuigui (Sep 27 2026). Run once, by Chris,
# from the repo root:
#   bash supabase/scripts/finish_yuigui.sh
# 1. Sets the function secrets only a person can supply. Keys are typed with input hidden
#    or read from their .p8 file; the JWT secret comes from the project itself.
# 2. Turns Supabase Auth sign-ups off (Yui accounts never enter it).
# 3. Points the site's Vercel env (production) at yuigui.
# 4. Applies the site's ledger table, then switches the native crew on.
# Nothing is printed or written to disk. Safe to run again.
set -euo pipefail
REF=txuibjxyfpalzvpneqgp
API="https://api.supabase.com/v1/projects/$REF"
YUIGUI="${YUIGUI:-$(cd "$(dirname "$0")/../.." && pwd)/../yuigui}"
command -v supabase >/dev/null || { echo "needs the supabase CLI"; exit 1; }

token() {
  if [ -n "${SUPABASE_ACCESS_TOKEN:-}" ]; then printf %s "$SUPABASE_ACCESS_TOKEN"; return; fi
  security find-generic-password -s "Supabase CLI" -w | sed 's/^go-keyring-base64://' | base64 -d
}
api() { curl -fsS -H "authorization: Bearer $(token)" -H "content-type: application/json" "$@"; }
sql() { api -X POST "$API/database/query" -d "$(python3 -c 'import json,sys; print(json.dumps({"query": sys.stdin.read()}))')" >/dev/null; }
hidden() { local v; read -r -s -p "$1 (input hidden): " v; echo >&2; printf %s "$v"; }
plain() { local v; read -r -p "$1: " v; printf %s "$v"; }
p8() {
  local p; read -r -p "$1: " p; p="${p/#\~/$HOME}"
  [ -f "$p" ] || { echo "no file at $p" >&2; exit 1; }
  cat "$p"
}

echo "1/4 Function secrets"
JWT=$(api "$API/postgrest" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("jwt_secret") or "", end="")')
[ -n "$JWT" ] || JWT=$(hidden "yuigui's legacy JWT secret (Dashboard > Settings > JWT Keys)")
TEAM=$(plain "Apple team id")
APNS_KEY_ID=$(plain "APNs key id")
APNS_P8=$(p8 "Path to the APNs .p8 (AuthKey_<id>.p8)")
read -r -p "Same key for Sign in with Apple? [Y/n]: " same
if [ "${same:-Y}" = "n" ] || [ "${same:-Y}" = "N" ]; then
  SIWA_KEY_ID=$(plain "Sign in with Apple key id")
  SIWA_P8=$(p8 "Path to the Sign in with Apple .p8")
else
  SIWA_KEY_ID=$APNS_KEY_ID; SIWA_P8=$APNS_P8
fi
OR_KEY=$(hidden "Yui's OpenRouter key (set a monthly spend ceiling on it first)")
supabase secrets set --project-ref "$REF" \
  "YUI_JWT_SECRET=$JWT" "YUI_APPLE_TEAM_ID=$TEAM" \
  "YUI_APNS_KEY_ID=$APNS_KEY_ID" "YUI_APNS_P8=$APNS_P8" \
  "YUI_SIWA_KEY_ID=$SIWA_KEY_ID" "YUI_SIWA_P8=$SIWA_P8" \
  "YUI_OPENROUTER_KEY=$OR_KEY" >/dev/null
unset JWT APNS_P8 SIWA_P8 OR_KEY
REVIEW_CODE=$(hidden "App Review demo code (Enter to skip)")
if [ -n "$REVIEW_CODE" ]; then
  REVIEW_USER=$(plain "App Review demo account's Yui user id")
  supabase secrets set --project-ref "$REF" "YUI_REVIEW_CODE=$REVIEW_CODE" "YUI_REVIEW_USER=$REVIEW_USER" >/dev/null
fi
unset REVIEW_CODE
echo "   secrets set"

echo "2/4 Supabase Auth sign-ups off"
api -X PATCH "$API/config/auth" -d '{"disable_signup": true, "external_apple_enabled": false}' >/dev/null
echo "   done"

echo "3/4 Site env on Vercel (production)"
if command -v vercel >/dev/null && [ -f "$YUIGUI/site/.vercel/project.json" ]; then
  SERVICE=$(api "$API/api-keys?reveal=true" | python3 -c 'import json,sys; print(next(k["api_key"] for k in json.load(sys.stdin) if k.get("name") == "service_role"), end="")')
  (
    cd "$YUIGUI/site"
    for pair in "YUI_SUPABASE_URL=https://$REF.supabase.co" "YUI_SUPABASE_SERVICE_ROLE_KEY=$SERVICE"; do
      name=${pair%%=*}
      vercel env rm "$name" production --yes >/dev/null 2>&1 || true
      printf %s "${pair#*=}" | vercel env add "$name" production >/dev/null
    done
  )
  unset SERVICE
  echo "   done; the next production deploy picks it up"
else
  echo "   skipped: needs the vercel CLI and $YUIGUI/site linked"
fi

echo "4/4 Ledger and native crew"
[ -f "$YUIGUI/ledger/yui_ledger.sql" ] && sql < "$YUIGUI/ledger/yui_ledger.sql" && echo "   ledger applied"
echo "update public.yui_limits set value = 1 where name = 'native_enabled';" | sql
echo "   native_enabled = 1: reopen the app and Yui and the crew are at the top of your list"
