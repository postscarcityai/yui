-- Beta feedback ANJPrtB7CHynwGR5mqNVPSM (build 96): an agent sent a `sketch` the
-- phone's build could not draw, and it showed as raw lines under "unknown preset".
--
-- Each phone now says which app build it runs: yui-push reads it from register
-- and presence (the `build` field, or the "Yui/<build> CFNetwork" user agent
-- every build already sends). yui-connect's session hands hosts the oldest
-- build among the user's phones seen in the last 14 days (`app_build`), so a
-- host can turn a preset that build cannot draw into plain words before it sends.

alter table public.yui_devices
  add column if not exists app_build integer check (app_build is null or app_build > 0),
  add column if not exists app_build_at timestamptz;

notify pgrst, 'reload schema';
