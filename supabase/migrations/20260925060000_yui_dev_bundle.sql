-- YUI-91: test builds by link install as "Yui Dev" (bundle com.yuigui.app.dev)
-- next to the TestFlight app. Two things follow the bundle id:
--
-- yui_devices.topic: the APNs topic this phone's token belongs to. Null means
-- the main app (YUI_APNS_TOPIC). yui-push sets it on register (the `bundle`
-- field, or a dev build's "Yui/<n>.<m> CFNetwork" user agent) and fixes it
-- when Apple answers DeviceTokenNotForTopic.
--
-- yui_apple_tokens.client_id: Sign in with Apple's audience for the stored
-- refresh token. A Yui Dev sign-in's token belongs to the .dev client id, and
-- Apple only revokes it (account deletion) under that same id. Null = main app.

alter table public.yui_devices
  add column if not exists topic text check (topic is null or topic ~ '^[A-Za-z0-9.-]{3,100}$');

alter table public.yui_apple_tokens
  add column if not exists client_id text check (client_id is null or client_id ~ '^[A-Za-z0-9.-]{3,100}$');

notify pgrst, 'reload schema';
