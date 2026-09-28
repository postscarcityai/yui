-- YUI-171: tables for any agent (yuigui spec/TABLES.md section 8). The store
-- YUI-170 gave native agents (yui_native_tables, yui_native_table_rows) now
-- holds the tables of every agent a person has: a Hermes agent, a Claude or
-- ChatGPT agent over MCP, a native one. They all reach it through one server
-- call (yui-connect /tables, the yui-mcp tool yui_tables), never the database.
--
-- The person owns a table, one agent holds it. user_id is the person, agent_id
-- the agent that holds it; only that agent reads or writes it. The person
-- hands a table to another of their agents with yui_tables_give.
--
--   read_at          when the holding agent last read it (Controls: "Basil, 2 min ago")
--   yui_table_holds  deletes an agent asked for, waiting for the person's
--                    Delete or Keep tap; the next tables call settles them.
--   limits           100 tables per person across all agents (and 20 an agent,
--                    as before); 60 tables calls a minute per agent.

alter table public.yui_native_tables add column if not exists read_at timestamptz;

-- A table belongs to one of the person's own agents, of any kind now; 20 an
-- agent and 100 a person at most (the server call refuses first).
create or replace function public.yui_native_tables_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_table_name = 'yui_native_tables' then
    if not exists (select 1 from public.yui_agents a where a.id = new.agent_id and a.user_id = new.user_id) then
      raise exception 'tables belong to one of this person''s agents' using errcode = '23514';
    end if;
    if (tg_op = 'INSERT' or new.agent_id is distinct from old.agent_id)
       and (select count(*) from public.yui_native_tables t where t.agent_id = new.agent_id) >= 20 then
      raise exception '20 tables per agent at most' using errcode = '23514';
    end if;
    if tg_op = 'INSERT' and (select count(*) from public.yui_native_tables t where t.user_id = new.user_id) >= 100 then
      raise exception '100 tables per person at most' using errcode = '23514';
    end if;
  elsif not exists (select 1 from public.yui_native_tables t where t.agent_id = new.agent_id and t.name = new.tname and t.user_id = new.user_id) then
    raise exception 'a row belongs to its table''s person' using errcode = '23514';
  end if;
  return new;
end $$;
revoke all on function public.yui_native_tables_guard() from public, anon, authenticated;

-- Deletes waiting for a tap. Server only, like the tables themselves.
create table if not exists public.yui_table_holds (
  id text not null check (id ~ '^del-[A-Za-z0-9]{1,16}$'),
  agent_id uuid not null references public.yui_agents(id) on delete cascade,
  user_id uuid not null references public.yui_users(id) on delete cascade,
  lines jsonb not null check (jsonb_typeof(lines) = 'array' and jsonb_array_length(lines) between 1 and 50),
  ask text not null check (length(ask) <= 300),
  message_id uuid,
  created_at timestamptz not null default now(),
  done_at timestamptz,
  choice text check (choice in ('Delete', 'Keep', 'expired')),
  primary key (agent_id, id)
);
create index if not exists yui_table_holds_open_idx on public.yui_table_holds(agent_id, created_at) where done_at is null;
alter table public.yui_table_holds enable row level security;
revoke all on public.yui_table_holds from public, anon, authenticated, yui_user, yui_connector;
grant select, insert, update, delete on public.yui_table_holds to service_role;

insert into public.yui_limits (name, value, note) values
  ('tables_burst',   60, 'tables calls one agent can make at once (yui-connect /tables, yui_tables)'),
  ('tables_per_min', 60, 'sustained tables calls per agent per minute')
on conflict (name) do update set value = excluded.value, note = excluded.note;

-- Give a table to another of the person's agents (spec section 8, "Hand them
-- over"). Nothing is copied: the table keeps its columns and rows and answers
-- to the new agent; the old one loses it. The app calls it as the person
-- (yui_user); the server (service_role) and the operator's SQL may give any
-- person's table between that person's own agents.
-- as_name renames it on the way, for when the new agent already has one by
-- that name (refused with name_taken, suggesting <name>-<old handle>).
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
  update public.yui_native_tables set agent_id = to_agent, name = dest, read_at = null, updated_at = now()
   where agent_id = from_agent and name = tname;
  -- A delete the old agent asked for is not the new agent's to settle.
  update public.yui_table_holds set done_at = now(), choice = 'expired'
   where agent_id = from_agent and done_at is null;
  return dest;
end $$;
revoke all on function public.yui_tables_give(uuid, uuid, text, text) from public, anon, authenticated;
grant execute on function public.yui_tables_give(uuid, uuid, text, text) to yui_user, service_role;

notify pgrst, 'reload schema';
