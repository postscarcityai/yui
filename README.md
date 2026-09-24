# Yui | iOS app

Native SwiftUI app for yuigui.com. Hub, roadmap and Yui Lines spec live in `postscarcityai/yuigui`.

- Project is generated: `xcodegen generate` (source of truth is `project.yml`, the `.xcodeproj` is not committed).
- iOS 26, iPhone only, no Watch target yet.
- TestFlight: `scripts/testflight.sh` archives and uploads with the App Store Connect API key. Never commit keys.

## Accounts (Sign in with Apple)

- Backend lives in PROOF (Supabase ref `ewzzaoperdpxqxkshynx`), shared with the PSAI portal. Yui users never enter Supabase Auth: `supabase/functions/yui-auth` verifies Apple's identity token and mints a 15-minute JWT with role `yui_user`, which can reach only `yui_*` tables, each row keyed to the token's `sub`. `yui-delete` revokes the Apple token and deletes the account; every `yui_*` table cascades from `yui_users`.
- Schema: `supabase/migrations/`. Apply by hand, never `supabase db push` or `config push` against PROOF.
- Deploy functions: `supabase functions deploy yui-auth --project-ref ewzzaoperdpxqxkshynx --use-api --no-verify-jwt` (same for `yui-delete`). Secrets (`YUI_JWT_SECRET`, `YUI_SIWA_*`, `YUI_APPLE_TEAM_ID`) are edge function secrets only.
- Tests: `python3 supabase/tests/accounts_test.py` runs live against PROOF (negative RLS, cross-user isolation, create-then-delete lifecycle). Run it after any change to the migration or functions.
- Screenshot launch args (DEBUG only): `-yuiSignedOut`, `-yuiDemoAccount`, `-yuiSettingsLarge`, `-yuiConfirmDelete`.

## Agents (YUI-15)

- Agents are user-managed, never hardcoded. Spec: `postscarcityai/yuigui` `spec/AGENTS.md`.
- Schema: `supabase/migrations/20260924000000_yui_agent_registry.sql` (connectors, agents, pairing codes, management tokens, `yui_agent_list` view with derived status).
- Functions: `yui-agents` (app token or `yui_mt_` management token) and `yui-connect` (host side: pair, add, heartbeat). Deploy both like `yui-auth`.
- Host client until the YUI-7 plugin lands: `hermes-plugin/yui_connect.py pair <code> --profile <p>`, `add --profile <p>`, `heartbeat`. Credential: `~/.hermes/yui/connector.json`.
- Tests: `python3 supabase/tests/agents_test.py` (registry) and `accounts_test.py` (now covers the new tables in deletion).
- Screenshot launch args (DEBUG, with `-yuiDemoAccount`): `-yuiAgents`, `-yuiNoAgents`, `-yuiAddAgent`, `-yuiAddAgentCode`.
