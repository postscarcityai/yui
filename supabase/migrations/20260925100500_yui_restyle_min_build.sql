-- YUI-96: restyle the whole app by asking (spec yuigui/spec/RESTYLE.md, sections 5 and 7).
--
-- A build that does not know `theme app` reads `theme app accent=...` as the
-- agent's own theme and restyles that agent. So the host passes the line on,
-- and the channel guide teaches it, only when the oldest of the person's phones
-- (yui-connect session: app_build) is at or above restyle_min_build. Hosts read
-- it from yui_limits with their session token (yui_connector may select it,
-- 20260924070000_yui_limits.sql). Same pattern as group_min_build: high until
-- the build with the preview card ships, then lowered to that build.

insert into public.yui_limits (name, value, note) values
  ('restyle_min_build', 10000, 'oldest app build a host sends `theme app` lines to (and teaches them); the app card sets it to the first build with the restyle preview')
on conflict (name) do nothing;
