-- NATIVE-1: the drawer's Controls tab for native agents (spec yuigui spec/CONTROLS.md).
-- yui-native answers control rows the way the Hermes plugin does: Personality,
-- Memory, Schedules (check-ins, which can now be paused) and Model (read only).
-- Every native agent reports those sections, so the app shows the tab.

alter table public.yui_native_schedules add column if not exists paused boolean not null default false;

-- What yui-native serves (runtime/src/controls.ts REPORT).
create or replace function public.yui_native_controls() returns jsonb
language sql immutable set search_path = '' as $$
  select '{"v": 1, "sections": {"soul": "rw", "memory": "rwd", "schedules": "rwd", "model": "r"}}'::jsonb
$$;

create or replace function public.yui_native_add_agent(uid uuid, prof jsonb, at_sort integer default null)
returns table (agent_id uuid)
language plpgsql security definer set search_path = '' as $$
declare
  cid uuid;
  base text := coalesce(nullif(prof ->> 'handle', ''), 'agent');
  h text := base;
  i integer := 2;
  aid uuid;
  nm text := left(coalesce(nullif(btrim(prof ->> 'name'), ''), 'Agent'), 40);
  col text := coalesce(nullif(prof ->> 'color', ''), 'lavender');
begin
  select id into cid from public.yui_connectors where user_id = uid and kind = 'hosted' and revoked_at is null;
  if cid is null then
    raise exception 'no hosted connector for this person';
  end if;
  if col not in ('lavender', 'mint', 'butter', 'brand') then col := 'lavender'; end if;
  while exists (select 1 from public.yui_agents a where a.user_id = uid and a.handle = h)
     or exists (select 1 from public.yui_agents a where a.connector_id = cid and a.remote_ref = h) loop
    h := left(base, 28) || '-' || i;
    i := i + 1;
  end loop;
  insert into public.yui_agents (user_id, name, handle, color, kind, connector_id, remote_ref, sort, is_default, controls, controls_at)
    values (uid, nm, h, col, 'hosted', cid, h,
            coalesce(at_sort, (select max(sort) + 1 from public.yui_agents where user_id = uid), 0),
            coalesce((prof ->> 'maker')::boolean, false) or not exists (select 1 from public.yui_agents where user_id = uid),
            public.yui_native_controls(), now())
    returning id into aid;
  insert into public.yui_native_profiles (agent_id, user_id, profile)
    values (aid, uid, prof || jsonb_build_object('handle', h, 'name', nm));
  if coalesce(prof ->> 'first', '') <> '' then
    insert into public.yui_messages (user_id, agent_id, sender, kind, body, meta)
      values (uid, aid, 'agent', 'text', left(prof ->> 'first', 32000), '{"native": "first"}'::jsonb);
  end if;
  return query select aid;
end $$;
revoke all on function public.yui_native_add_agent(uuid, jsonb, integer) from public, anon, authenticated;
grant execute on function public.yui_native_add_agent(uuid, jsonb, integer) to service_role;
revoke all on function public.yui_native_controls() from public, anon, authenticated;

update public.yui_agents set controls = public.yui_native_controls(), controls_at = now()
 where kind = 'hosted' and controls is distinct from public.yui_native_controls();

-- A control request wakes yui-native too; it answers in a second, never as a turn.
drop trigger if exists yui_native_wake on public.yui_messages;
create trigger yui_native_wake after insert on public.yui_messages
  for each row when (new.sender = 'user' and new.kind in ('text', 'event', 'control'))
  execute function public.yui_native_wake();

-- Paused check-ins never fire.
create or replace function public.yui_native_tick()
returns integer
language plpgsql security definer set search_path = '' as $$
declare
  u text;
  s text;
  r record;
  n integer := 0;
begin
  if coalesce(public.yui_limit('native_enabled'), 0) < 1 then return 0; end if;
  select decrypted_secret into u from vault.decrypted_secrets where name = 'yui_native_url';
  select decrypted_secret into s from vault.decrypted_secrets where name = 'yui_native_secret';
  if u is null or s is null then return 0; end if;
  for r in
    update public.yui_native_schedules set next_at = null, fired_at = now()
     where id in (select id from public.yui_native_schedules
                   where not paused
                     and (next_at <= now()
                          or (next_at is null and fired_at < now() - interval '10 minutes' and rule ? 'every'))
                   order by next_at nulls first limit 200 for update skip locked)
    returning id
  loop
    perform net.http_post(url := u, body := jsonb_build_object('schedule_id', r.id),
      headers := jsonb_build_object('content-type', 'application/json', 'x-yui-native', s), timeout_milliseconds := 5000);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.yui_native_tick() from public, anon, authenticated;

notify pgrst, 'reload schema';
