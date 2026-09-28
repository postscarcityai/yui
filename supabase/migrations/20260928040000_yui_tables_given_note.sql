-- YUI-171 step 3: after a hand over, the new agent learns what it holds (yuigui
-- spec/TABLES.md section 8, "The agent learns what it has"). yui_tables_give
-- stamps given_at; the person's next message to the agent that got the table
-- carries one line in meta.tables:
--
--   [yui] tables foods(44 rows: Food, Cal, Protein) meals(12 rows: Day, Food, Cal)
--
-- Every adapter (the Hermes plugin, the A2A bridge, the webhook bridge) puts
-- that line at the top of the turn, so the agent needs no memory of the old
-- agent to carry on. Once, then given_at clears. Only the owner's own thread:
-- a shared client's message never names the owner's tables.

alter table public.yui_native_tables add column if not exists given_at timestamptz;

create or replace function public.yui_tables_give(from_agent uuid, to_agent uuid, tname text, as_name text default null)
returns text
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := public.yui_uid();
  owner uuid;
  dest text := coalesce(nullif(btrim(as_name), ''), tname);
  old_handle text;
begin
  select a.user_id, a.handle into owner, old_handle from public.yui_agents a where a.id = from_agent;
  if owner is null or (uid is not null and owner <> uid) or (uid is null and coalesce(public.yui_caller(), 'service_role') <> 'service_role') then
    raise exception 'no_such_agent' using errcode = '42501';
  end if;
  if not exists (select 1 from public.yui_agents a where a.id = to_agent and a.user_id = owner) then
    raise exception 'no_such_agent' using errcode = '42501';
  end if;
  if from_agent = to_agent then
    raise exception 'same_agent' using errcode = '22023';
  end if;
  if dest !~ '^[A-Za-z][A-Za-z0-9_-]{0,31}$' then
    raise exception 'bad_name' using errcode = '22023';
  end if;
  if not exists (select 1 from public.yui_native_tables t where t.agent_id = from_agent and t.name = tname) then
    raise exception 'no_such_table' using errcode = 'P0002';
  end if;
  if exists (select 1 from public.yui_native_tables t where t.agent_id = to_agent and t.name = dest) then
    raise exception 'name_taken: try %', left(tname || '-' || old_handle, 32) using errcode = '23505';
  end if;
  update public.yui_native_tables set agent_id = to_agent, name = dest, read_at = null, given_at = now(), updated_at = now()
   where agent_id = from_agent and name = tname;
  -- A delete the old agent asked for is not the new agent's to settle.
  update public.yui_table_holds set done_at = now(), choice = 'expired'
   where agent_id = from_agent and done_at is null;
  return dest;
end $$;
revoke all on function public.yui_tables_give(uuid, uuid, text, text) from public, anon, authenticated;
grant execute on function public.yui_tables_give(uuid, uuid, text, text) to yui_user, service_role;

-- What an agent holds, as the line its turn opens with (runtime holdingLine).
create or replace function public.yui_tables_line(agent uuid) returns text
language sql stable security definer set search_path = '' as $$
  select coalesce('[yui] tables ' || string_agg(
           t.name || '(' || n.c || ' row' || case when n.c = 1 then '' else 's' end || ': '
             || (select string_agg(x.c->>'name', ', ' order by x.o) from jsonb_array_elements(t.cols) with ordinality as x(c, o))
             || ')', ' ' order by t.created_at), '[yui] tables (none yet)')
    from public.yui_native_tables t
    cross join lateral (select count(*) as c from public.yui_native_table_rows r where r.agent_id = t.agent_id and r.tname = t.name) n
   where t.agent_id = agent
$$;
revoke all on function public.yui_tables_line(uuid) from public, anon, authenticated;

create or replace function public.yui_tables_given_note() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.yui_native_tables t
              where t.agent_id = new.agent_id and t.user_id = new.user_id and t.given_at is not null) then
    new.meta := coalesce(new.meta, '{}'::jsonb) || jsonb_build_object('tables', public.yui_tables_line(new.agent_id));
    update public.yui_native_tables set given_at = null where agent_id = new.agent_id and given_at is not null;
  end if;
  return new;
end $$;
revoke all on function public.yui_tables_given_note() from public, anon, authenticated;

-- Runs after yui_messages_guard (names sort), so a refused message clears nothing.
drop trigger if exists yui_tables_given_note on public.yui_messages;
create trigger yui_tables_given_note before insert on public.yui_messages
  for each row when (new.sender = 'user') execute function public.yui_tables_given_note();

notify pgrst, 'reload schema';
