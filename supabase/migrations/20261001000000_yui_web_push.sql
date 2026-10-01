-- YUI-248: Web Push. A browser subscription (endpoint + p256dh + auth) lives in
-- yui_devices next to APNs tokens: a row has an apns_token or a web_endpoint, never
-- both. yui-push register_web / unregister_web write it; notify fans out to both kinds.
-- Rows with no apns_token are skipped by every APNs path (they already filter on it).

alter table public.yui_devices
  add column if not exists web_endpoint text,
  add column if not exists web_p256dh text,
  add column if not exists web_auth text;

create unique index if not exists yui_devices_web_endpoint_key on public.yui_devices(web_endpoint);
alter table public.yui_devices drop constraint if exists yui_devices_one_kind;
alter table public.yui_devices add constraint yui_devices_one_kind check (
  (web_endpoint is null and web_p256dh is null and web_auth is null)
  or (apns_token is null and web_endpoint is not null and web_p256dh is not null and web_auth is not null)
);
