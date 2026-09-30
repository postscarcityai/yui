-- YUI-216, pick your crew: what a new person chose in the first-run picker.
-- One row per person who was shown the picker. `picked_at` is null while the
-- picker is still waiting for them; `bases` is who they picked (Yui is always
-- on the crew); `own` is true when they chose to bring their own agent.
-- People who signed up before the picker have no row and never see it.
-- Service role only: yui-agents reads and writes it, the app never does.
create table if not exists public.yui_crew_choice (
  user_id uuid primary key references public.yui_users(id) on delete cascade,
  picked_at timestamptz,
  bases text[] not null default '{}',
  own boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.yui_crew_choice enable row level security;
revoke all on public.yui_crew_choice from public, anon, authenticated, yui_user, yui_connector;
grant select, insert, update, delete on public.yui_crew_choice to service_role;
