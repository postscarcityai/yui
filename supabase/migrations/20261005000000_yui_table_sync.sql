-- YUI-36 step 1: optional end to end encrypted sync of agent tables (spec yuigui/spec/SYNC.md).
--
-- The relay holds sealed boxes and nothing else it could read. A row's table name, row key and cells are inside
-- `box` (AES-GCM, key only on the person's devices); `id` is an opaque HMAC of agent / table / key. The server
-- sees the agent (so removing an agent removes its copy), the clock, a key fingerprint, whether the unit is a
-- delete, the device, and the size. Same rules as every account table: user_id, RLS for yui_user, no grant at
-- all for yui_connector (a host never reads a table).
--
-- yui_sync_rows     one sealed unit (a row, a table's columns, or a delete of either), last write wins by `clock`
-- yui_sync_pairings a sync key sealed under a one-time pairing code, for the second device. Lives 2 minutes.

create table if not exists public.yui_sync_rows (
  user_id    uuid not null references public.yui_users(id) on delete cascade,
  agent_id   uuid not null references public.yui_agents(id) on delete cascade,
  id         text not null check (length(id) between 16 and 64),
  box        text not null check (length(box) between 1 and 65536),
  clock      bigint not null check (clock > 0),
  gone       boolean not null default false,
  kid        text not null check (length(kid) between 8 and 32),
  device     text check (device is null or length(device) <= 40),
  rev        bigint not null default 0,
  updated_at timestamptz not null default now(),
  primary key (user_id, agent_id, id)
);

create sequence if not exists public.yui_sync_rev;
create index if not exists yui_sync_rows_rev on public.yui_sync_rows (user_id, rev);

revoke all on public.yui_sync_rows from public, anon, authenticated;
grant select, delete on public.yui_sync_rows to yui_user;
grant insert (user_id, agent_id, id, box, clock, gone, kid, device) on public.yui_sync_rows to yui_user;
grant update (user_id, agent_id, id, box, clock, gone, kid, device) on public.yui_sync_rows to yui_user;
alter table public.yui_sync_rows enable row level security;

drop policy if exists yui_sync_rows_read on public.yui_sync_rows;
drop policy if exists yui_sync_rows_insert on public.yui_sync_rows;
drop policy if exists yui_sync_rows_update on public.yui_sync_rows;
drop policy if exists yui_sync_rows_delete on public.yui_sync_rows;
create policy yui_sync_rows_read on public.yui_sync_rows for select to yui_user
  using (user_id = public.yui_uid());
create policy yui_sync_rows_insert on public.yui_sync_rows for insert to yui_user
  with check (user_id = public.yui_uid()
              and (public.yui_owns_agent(agent_id) or public.yui_granted(agent_id, public.yui_uid())));
create policy yui_sync_rows_update on public.yui_sync_rows for update to yui_user
  using (user_id = public.yui_uid())
  with check (user_id = public.yui_uid()
              and (public.yui_owns_agent(agent_id) or public.yui_granted(agent_id, public.yui_uid())));
create policy yui_sync_rows_delete on public.yui_sync_rows for delete to yui_user
  using (user_id = public.yui_uid());

-- Stamps the server order (rev, so a device reads "everything after the last rev it saw"), keeps an older clock
-- from overwriting a newer one (last write wins, whichever device's request lands last), and holds the account
-- to 50 MB of boxes.
create or replace function public.yui_sync_rows_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare used bigint;
begin
  if tg_op = 'UPDATE' and new.clock < old.clock then
    return null;
  end if;
  select coalesce(sum(octet_length(box)), 0) into used from public.yui_sync_rows where user_id = new.user_id;
  if tg_op = 'UPDATE' then used := used - octet_length(old.box); end if;
  if used + octet_length(new.box) > 52428800 then
    raise exception 'sync_full' using errcode = '53400';
  end if;
  new.rev := nextval('public.yui_sync_rev');
  new.updated_at := now();
  return new;
end $$;
revoke all on function public.yui_sync_rows_guard() from public, anon, authenticated;
drop trigger if exists yui_sync_rows_guard on public.yui_sync_rows;
create trigger yui_sync_rows_guard before insert or update on public.yui_sync_rows
  for each row execute function public.yui_sync_rows_guard();

create table if not exists public.yui_sync_pairings (
  user_id    uuid not null references public.yui_users(id) on delete cascade,
  id         text not null check (length(id) between 16 and 64),
  sealed     text not null check (length(sealed) between 1 and 2048),
  kid        text not null check (length(kid) between 8 and 32),
  expires_at timestamptz not null default now() + interval '2 minutes',
  primary key (user_id, id)
);
revoke all on public.yui_sync_pairings from public, anon, authenticated;
grant select, delete on public.yui_sync_pairings to yui_user;
grant insert (user_id, id, sealed, kid) on public.yui_sync_pairings to yui_user;
alter table public.yui_sync_pairings enable row level security;
drop policy if exists yui_sync_pairings_read on public.yui_sync_pairings;
drop policy if exists yui_sync_pairings_insert on public.yui_sync_pairings;
drop policy if exists yui_sync_pairings_delete on public.yui_sync_pairings;
create policy yui_sync_pairings_read on public.yui_sync_pairings for select to yui_user
  using (user_id = public.yui_uid() and expires_at > now());
create policy yui_sync_pairings_insert on public.yui_sync_pairings for insert to yui_user
  with check (user_id = public.yui_uid());
create policy yui_sync_pairings_delete on public.yui_sync_pairings for delete to yui_user
  using (user_id = public.yui_uid());

-- Delete markers go after 30 days (an offline device has had that long to hear), expired pairings at once.
create or replace function public.yui_sync_prune() returns jsonb
language plpgsql security definer set search_path = public as $$
declare a int; b int;
begin
  delete from public.yui_sync_rows where gone and updated_at < now() - interval '30 days';
  get diagnostics a = row_count;
  delete from public.yui_sync_pairings where expires_at < now();
  get diagnostics b = row_count;
  return jsonb_build_object('markers', a, 'pairings', b);
end $$;
revoke all on function public.yui_sync_prune() from public, anon, authenticated;

do $$ begin
  perform cron.schedule('yui-sync-prune', '17 * * * *', 'select public.yui_sync_prune()');
exception when others then null;
end $$;

notify pgrst, 'reload schema';
