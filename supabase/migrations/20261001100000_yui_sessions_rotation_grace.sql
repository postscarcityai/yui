-- YUI-239: stay signed in. A refresh whose reply never lands leaves the phone
-- holding the token the server already rotated. yui-auth now gives a rotated
-- token a short grace window; to do that it needs to know when and into which
-- session a token rotated. Sign-out and mass revocation leave both null, so
-- they never get a grace.
alter table public.yui_sessions
  add column if not exists rotated_at timestamptz,
  add column if not exists rotated_to uuid references public.yui_sessions(id) on delete set null;
