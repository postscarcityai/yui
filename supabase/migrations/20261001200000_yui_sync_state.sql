-- YUI-249: one Yui across phone and web. The few things that were per device and should follow the person:
-- the words half typed in a thread (`draft`) and the saved screens taken off the shelf by hand (`shelf-removed`,
-- a JSON map of name -> ms). Everything else already shares through yui_messages and yui_chats (thread,
-- chats, screens, the shelf's saves, read state in yui_chats.seen_at).
--
-- One row per person, agent and key. The server clock stamps updated_at, so two devices never compare their
-- own clocks. An empty value is a cleared draft (the row stays, so the clear reaches the other device).
-- Same rules as every account table: user_id, RLS for yui_user, no grant for yui_connector (a host never
-- reads a draft). Drafts never hold a pasted key: both clients refuse to send one.

create table if not exists public.yui_sync_state (
  user_id    uuid not null references public.yui_users(id) on delete cascade,
  agent_id   uuid not null references public.yui_agents(id) on delete cascade,
  key        text not null check (key in ('draft', 'shelf-removed')),
  value      text not null default '' check (length(value) <= 20000),
  device     text check (device is null or length(device) <= 40),
  updated_at timestamptz not null default now(),
  primary key (user_id, agent_id, key)
);

revoke all on public.yui_sync_state from public, anon, authenticated;
grant select, delete on public.yui_sync_state to yui_user;
grant insert (user_id, agent_id, key, value, device) on public.yui_sync_state to yui_user;
-- An upsert (PostgREST merge-duplicates) names every column it writes in DO UPDATE SET, key columns included,
-- so those need the grant too; the update policy below keeps the row the person's own and the agent theirs.
grant update (user_id, agent_id, key, value, device, updated_at) on public.yui_sync_state to yui_user;
alter table public.yui_sync_state enable row level security;

drop policy if exists yui_sync_state_read on public.yui_sync_state;
drop policy if exists yui_sync_state_insert on public.yui_sync_state;
drop policy if exists yui_sync_state_update on public.yui_sync_state;
drop policy if exists yui_sync_state_delete on public.yui_sync_state;
create policy yui_sync_state_read on public.yui_sync_state for select to yui_user
  using (user_id = public.yui_uid());
create policy yui_sync_state_insert on public.yui_sync_state for insert to yui_user
  with check (user_id = public.yui_uid()
              and (public.yui_owns_agent(agent_id) or public.yui_granted(agent_id, public.yui_uid())));
create policy yui_sync_state_update on public.yui_sync_state for update to yui_user
  using (user_id = public.yui_uid())
  with check (user_id = public.yui_uid()
              and (public.yui_owns_agent(agent_id) or public.yui_granted(agent_id, public.yui_uid())));
create policy yui_sync_state_delete on public.yui_sync_state for delete to yui_user
  using (user_id = public.yui_uid());

create or replace function public.yui_sync_state_stamp() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists yui_sync_state_stamp on public.yui_sync_state;
create trigger yui_sync_state_stamp before insert or update on public.yui_sync_state
  for each row execute function public.yui_sync_state_stamp();

notify pgrst, 'reload schema';
