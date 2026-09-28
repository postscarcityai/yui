-- YUI-170: every native agent keeps its own little database. The words are
-- yuigui spec/TABLES.md (`table create`, `put`, `query`); for a native agent
-- the store is here instead of on the phone, because the agent itself runs
-- here (runtime/src/tables.ts). One set of tables per agent:
--   yui_native_tables      a table's name and columns ([{name, type, unit?}])
--   yui_native_table_rows  its rows, one jsonb object of cells per row key
-- Server only: the runtime reads and writes them with the service role. No
-- grant to anon, authenticated, yui_connector or yui_user; the person reads
-- and deletes them through their agent and its Controls (section "tables").
-- A starter agent's tables (runtime/profiles/<name>/tables.yui) are written by
-- yui_native_add_agent when the agent is added, and never kept in its profile.

create table if not exists public.yui_native_tables (
  agent_id uuid not null references public.yui_agents(id) on delete cascade,
  user_id uuid not null references public.yui_users(id) on delete cascade,
  name text not null check (name ~ '^[A-Za-z][A-Za-z0-9_-]{0,31}$'),
  cols jsonb not null check (jsonb_typeof(cols) = 'array' and jsonb_array_length(cols) between 1 and 12
                             and pg_column_size(cols) <= 4096),
  next integer not null default 1 check (next >= 1),
  created_at timestamptz not null default clock_timestamp(), -- tables list in the order they were made, seeds too
  updated_at timestamptz not null default now(),
  primary key (agent_id, name)
);
create index if not exists yui_native_tables_user_idx on public.yui_native_tables(user_id);

create table if not exists public.yui_native_table_rows (
  agent_id uuid not null,
  user_id uuid not null references public.yui_users(id) on delete cascade,
  tname text not null,
  key text not null check (length(key) between 1 and 64),
  vals jsonb not null default '{}'::jsonb check (jsonb_typeof(vals) = 'object' and pg_column_size(vals) <= 16384),
  pos bigint not null default (extract(epoch from clock_timestamp()) * 1000000)::bigint,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (agent_id, tname, key),
  foreign key (agent_id, tname) references public.yui_native_tables(agent_id, name) on delete cascade on update cascade
);
create index if not exists yui_native_table_rows_order_idx on public.yui_native_table_rows(agent_id, tname, pos);
create index if not exists yui_native_table_rows_user_idx on public.yui_native_table_rows(user_id);

alter table public.yui_native_tables enable row level security;
alter table public.yui_native_table_rows enable row level security;
revoke all on public.yui_native_tables from public, anon, authenticated, yui_user, yui_connector;
revoke all on public.yui_native_table_rows from public, anon, authenticated, yui_user, yui_connector;
grant select, insert, update, delete on public.yui_native_tables, public.yui_native_table_rows to service_role;

-- A table belongs to one of the person's own native (hosted) agents, and a row
-- to that same person; 20 tables an agent at most (the runtime refuses first).
create or replace function public.yui_native_tables_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_table_name = 'yui_native_tables' then
    if not exists (select 1 from public.yui_agents a where a.id = new.agent_id and a.user_id = new.user_id and a.kind = 'hosted') then
      raise exception 'tables belong to one of this person''s native agents' using errcode = '23514';
    end if;
    if tg_op = 'INSERT' and (select count(*) from public.yui_native_tables t where t.agent_id = new.agent_id) >= 20 then
      raise exception '20 tables per agent at most' using errcode = '23514';
    end if;
  elsif not exists (select 1 from public.yui_native_tables t where t.agent_id = new.agent_id and t.name = new.tname and t.user_id = new.user_id) then
    raise exception 'a row belongs to its table''s person' using errcode = '23514';
  end if;
  return new;
end $$;
revoke all on function public.yui_native_tables_guard() from public, anon, authenticated;

drop trigger if exists yui_native_tables_guard on public.yui_native_tables;
create trigger yui_native_tables_guard before insert or update of agent_id, user_id on public.yui_native_tables
  for each row execute function public.yui_native_tables_guard();
drop trigger if exists yui_native_table_rows_guard on public.yui_native_table_rows;
create trigger yui_native_table_rows_guard before insert or update of agent_id, user_id, tname on public.yui_native_table_rows
  for each row execute function public.yui_native_tables_guard();

-- Controls: native agents list their tables with row counts, and delete one (asks first).
create or replace function public.yui_native_controls() returns jsonb
language sql immutable set search_path = '' as $$
  select '{"v": 1, "sections": {"soul": "rw", "memory": "rwd", "schedules": "rwd", "tables": "rd", "model": "r"}}'::jsonb
$$;
revoke all on function public.yui_native_controls() from public, anon, authenticated;

update public.yui_agents set controls = public.yui_native_controls(), controls_at = now()
 where kind = 'hosted' and controls is distinct from public.yui_native_controls();

-- yui_native_add_agent, as 20260927010000, plus the starter tables: `prof.tables`
-- is [{name, cols, next, rows: [{key, values}]}] (runtime/src/tables.ts TableSeed),
-- written for the new agent and left out of its saved profile, which says
-- `seeded: true` instead (an agent added before this migration is seeded by
-- the runtime on its next turn, runtime/src/turn.ts).
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
  seeds jsonb := case when jsonb_typeof(prof -> 'tables') = 'array' then prof -> 'tables' else '[]'::jsonb end;
  t jsonb;
  r record;
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
    values (aid, uid, (prof - 'tables') || jsonb_build_object('handle', h, 'name', nm)
                      || case when jsonb_array_length(seeds) > 0 then '{"seeded": true}'::jsonb else '{}'::jsonb end);
  for t in select * from jsonb_array_elements(seeds) limit 20 loop
    insert into public.yui_native_tables (agent_id, user_id, name, cols, next)
      values (aid, uid, t ->> 'name', t -> 'cols', greatest(coalesce((t ->> 'next')::integer, 1), 1));
    for r in select e.value as v, e.ordinality as n
               from jsonb_array_elements(coalesce(t -> 'rows', '[]'::jsonb)) with ordinality e limit 5000 loop
      insert into public.yui_native_table_rows (agent_id, user_id, tname, key, vals, pos)
        values (aid, uid, t ->> 'name', r.v ->> 'key', coalesce(r.v -> 'values', '{}'::jsonb), r.n);
    end loop;
  end loop;
  if coalesce(prof ->> 'first', '') <> '' then
    insert into public.yui_messages (user_id, agent_id, sender, kind, body, meta)
      values (uid, aid, 'agent', 'text', left(prof ->> 'first', 32000), '{"native": "first"}'::jsonb);
  end if;
  return query select aid;
end $$;
revoke all on function public.yui_native_add_agent(uuid, jsonb, integer) from public, anon, authenticated;
grant execute on function public.yui_native_add_agent(uuid, jsonb, integer) to service_role;

notify pgrst, 'reload schema';
