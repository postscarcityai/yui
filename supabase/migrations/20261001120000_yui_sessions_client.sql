-- YUI-241: a session knows which client holds it. The web signs in with its
-- own Apple Services ID (a second audience); its sessions are marked web so
-- the two are told apart and sign out on the site ends only its own session.
-- Existing rows are the iPhone app.
alter table public.yui_sessions
  add column if not exists client text not null default 'app'
  check (client in ('app', 'web'));
