-- YUI-8: push handoff. The app registers its APNs device token at sign-in
-- (yui-push action=register); any agent host can then ask yui-push to
-- notify the user when it writes into a thread (action=notify), and the
-- tap deep-links to that agent's thread (yui://agent/<id>/thread).
--
-- Registration goes through the edge function, not PostgREST, because one
-- phone can move between Yui accounts: the token must be taken over from the
-- old account, which RLS (rightly) never lets the new account touch.

alter table public.yui_devices
  add column if not exists environment text not null default 'production'
    check (environment in ('production', 'sandbox')),
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists last_push_at timestamptz,
  add column if not exists last_error text;

-- One row per phone. APNs tokens are hex, 64+ chars.
create unique index if not exists yui_devices_token_key on public.yui_devices(apns_token);
alter table public.yui_devices drop constraint if exists yui_devices_token_shape;
alter table public.yui_devices add constraint yui_devices_token_shape
  check (apns_token is null or apns_token ~ '^[0-9a-f]{64,200}$');
