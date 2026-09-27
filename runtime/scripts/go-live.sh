#!/usr/bin/env bash
# Native Yui, go live (NATIVE-1). Run once from the repo root, by a maintainer:
#   bash runtime/scripts/go-live.sh
# It sets the secrets the native runtime needs, without printing any of them:
#   1. a new random wake secret, as the function secret YUI_NATIVE_SECRET and
#      as the vault secret yui_native_secret (the database sends it to yui-native);
#   2. the vault secret yui_native_url (where the database wakes yui-native);
#   3. YUI_OPENROUTER_KEY, Yui's own OpenRouter key (you paste it; set a spend
#      ceiling on it at openrouter.ai first).
# It does not switch native Yui on. That is one line after it:
#   update yui_limits set value = 1 where name = 'native_enabled';
set -euo pipefail
REF=ewzzaoperdpxqxkshynx

command -v supabase >/dev/null || { echo "needs the supabase CLI"; exit 1; }
[ -f supabase/.temp/linked-project.json ] || supabase link --project-ref "$REF"

read -r -s -p "Yui's OpenRouter key (input hidden, Enter to keep the one already set): " OR_KEY; echo
WAKE=$(openssl rand -base64 48 | tr -d '\n/+=' | cut -c1-56)

if [ -n "$OR_KEY" ]; then
  supabase secrets set --project-ref "$REF" YUI_NATIVE_SECRET="$WAKE" YUI_OPENROUTER_KEY="$OR_KEY" >/dev/null
else
  supabase secrets set --project-ref "$REF" YUI_NATIVE_SECRET="$WAKE" >/dev/null
fi
echo "function secrets set"

SQL=$(mktemp)
trap 'rm -f "$SQL"' EXIT
cat > "$SQL" <<SQL
delete from vault.secrets where name in ('yui_native_url', 'yui_native_secret');
select vault.create_secret('https://$REF.supabase.co/functions/v1/yui-native', 'yui_native_url', 'NATIVE-1: where the database wakes yui-native');
select vault.create_secret('$WAKE', 'yui_native_secret', 'NATIVE-1: the x-yui-native header');
select count(*) as vault_secrets from vault.decrypted_secrets where name in ('yui_native_url', 'yui_native_secret');
SQL
supabase db query --linked -f "$SQL" | grep -E "vault_secrets|[0-9]" | tail -2
echo "vault secrets set. Tell Claude, or switch it on yourself:"
echo "  update yui_limits set value = 1 where name = 'native_enabled';"
