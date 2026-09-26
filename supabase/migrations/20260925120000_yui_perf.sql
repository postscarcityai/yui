-- YUI-102: speed numbers from the phone (spec yuigui/spec/PERF.md, section 5;
-- bucket edges in section 4).
--
-- yui_perf holds numbers only: signpost intervals as fixed-edge histograms,
-- memory samples, MetricKit metrics and MetricKit diagnostics (a call stack as
-- frames). Nothing a person wrote or an agent sent fits in a row:
--   kind         one of four words
--   name         a snake_case identifier (keystroke_render, hang, ...)
--   app_version  ^[0-9][0-9.]{0,15}$            e.g. 1.4 or 1.4.2
--   os           ^[0-9][0-9.]{0,15}$            e.g. 26.0.1
--   device       ^[A-Za-z]{1,16}[0-9]{0,4},[0-9]{1,4}$ (iPhone16,2, iPad14,3)
--                or arm64 / x86_64 (the Simulator reports its CPU)
--   buckets      18 non-negative counts: one per edge 2, 4, 8, 12, 16, 24, 33,
--                50, 75, 100, 150, 250, 400, 600, 1000, 2000, 5000 ms, plus
--                one above
--   stack        diagnostics only: a JSON array of frames, each exactly
--                {"image": binary name, "uuid": image UUID, "offset": integer},
--                at most 100 frames and 16 KB (about 100 bytes a frame; the
--                app sends the top 100 frames). yui_perf_stack_ok() refuses
--                any other key, a string frame, a nested object or a long
--                name, so no free text fits.
-- Every other column is a number, a boolean or a timestamp.
--
-- Who sees what:
--   yui_user      inserts its own rows (column list, no id or created_at) and
--                 reads its own rows. No update, no delete.
--   yui_connector reads its owner's rows (sub = the owner), and only while
--                 that connector is live: not revoked, not suspended, owner
--                 not suspended (yui_connector_live(), read live on every
--                 request, like yui_connector_serves). A shared agent's host
--                 carries its owner's sub, so it never sees a client's rows.
--   anon, authenticated, public: nothing. PROOF Auth has no path.
--
-- Flood guard: a before-insert trigger drops (returns null, silently) rows
-- past perf_rows_per_day per account in the last 24 hours, for PostgREST
-- callers. A stuck loop cannot fill the table; the app sees a normal 201 and
-- moves on. Direct SQL (the operator, the migration runner) is exempt, like
-- the other limits (20260924070000_yui_limits.sql).
--
-- Retention: yui_perf_retention() deletes rows older than perf_retention_days.
-- The daily sweep (supabase/scripts/media_sweep.py) runs it after
-- yui_retention(). Deleting the account deletes its rows (on delete cascade).

-- Limits ----------------------------------------------------------------------
insert into public.yui_limits (name, value, note) values
  ('perf_rows_per_day',    500, 'speed rows (yui_perf) one account can write per rolling day; more are dropped'),
  ('perf_retention_days',   90, 'speed rows older than this are deleted by the daily sweep')
on conflict (name) do update set value = excluded.value, note = excluded.note;

-- Stack shape -----------------------------------------------------------------
-- Invoker rights and immutable: the column check calls it for every insert,
-- so yui_user needs execute. It reads no table.
create or replace function public.yui_perf_stack_ok(s jsonb) returns boolean
language sql immutable
set search_path = ''
as $$
  select s is null or case when jsonb_typeof(s) <> 'array' then false else (
    jsonb_array_length(s) between 1 and 100
    and not exists (
      select 1 from jsonb_array_elements(s) f
      -- case first: key functions raise on a scalar. coalesce: a missing
      -- key reads null, and null must count as bad.
      where case when jsonb_typeof(f) <> 'object' then true else coalesce(
            (select array_agg(k order by k) from jsonb_object_keys(f) k) <> array['image', 'offset', 'uuid']
         or jsonb_typeof(f -> 'image') <> 'string'
         or (f ->> 'image') !~ '^[A-Za-z0-9_.+-]{1,64}$'
         or jsonb_typeof(f -> 'uuid') <> 'string'
         or (f ->> 'uuid') !~ '^[0-9A-Fa-f-]{32,36}$'
         or jsonb_typeof(f -> 'offset') <> 'number'
         or (f ->> 'offset') !~ '^[0-9]{1,20}$', true) end
    )
  ) end
$$;

-- Table -----------------------------------------------------------------------
create table if not exists public.yui_perf (
  id           bigint generated always as identity primary key,
  user_id      uuid not null references public.yui_users(id) on delete cascade,
  kind         text not null check (kind in ('interval', 'memory', 'metrics', 'diagnostic')),
  name         text not null check (name ~ '^[a-z][a-z0-9_]{1,40}$'),
  app_build    int  not null check (app_build >= 0),
  app_version  text not null check (app_version ~ '^[0-9][0-9.]{0,15}$'),
  os           text not null check (os ~ '^[0-9][0-9.]{0,15}$'),
  device       text not null check (device ~ '^([A-Za-z]{1,16}[0-9]{0,4},[0-9]{1,4}|arm64|x86_64)$'),
  promotion    boolean not null default false,
  low_power    boolean not null default false,
  thermal      smallint not null default 0 check (thermal between 0 and 3),  -- ProcessInfo.ThermalState raw value
  period_start timestamptz not null,
  period_end   timestamptz not null,
  n            int not null default 0 check (n >= 0),   -- samples in the period
  buckets      int[] check (buckets is null or (
                 cardinality(buckets) = 18 and array_ndims(buckets) = 1
                 and array_position(buckets, null) is null and 0 <= all(buckets))),
  p50          real,
  p95          real,
  max          real,
  value        real,                    -- a single number: memory MB, hang s/h, hitch ms/s
  stack        jsonb check (stack is null or (kind = 'diagnostic' and pg_column_size(stack) <= 16384
                                              and public.yui_perf_stack_ok(stack))),
  created_at   timestamptz not null default now(),
  check (period_end >= period_start)
);
create index if not exists yui_perf_user_idx on public.yui_perf(user_id, app_build, name);
-- The flood guard counts an account's last day; retention scans by age.
create index if not exists yui_perf_user_created_idx on public.yui_perf(user_id, created_at);
create index if not exists yui_perf_created_idx on public.yui_perf(created_at);

alter table public.yui_perf enable row level security;

-- The caller's connector is live and belongs to the caller's user.
-- Security definer so the policy can read yui_connectors without a grant.
create or replace function public.yui_connector_live() returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.yui_connectors c
    join public.yui_users u on u.id = c.user_id
    where c.id = public.yui_cid()
      and c.user_id = public.yui_uid()
      and c.revoked_at is null
      and c.suspended_at is null
      and u.suspended_at is null
  )
$$;

-- Grants and policies ---------------------------------------------------------
revoke all on public.yui_perf from public, anon, authenticated, yui_user, yui_connector;
revoke all on sequence public.yui_perf_id_seq from public, anon, authenticated, yui_user, yui_connector;

-- The phone writes its own rows and reads nothing else.
grant insert (user_id, kind, name, app_build, app_version, os, device, promotion, low_power,
              thermal, period_start, period_end, n, buckets, p50, p95, max, value, stack)
  on public.yui_perf to yui_user;
grant select on public.yui_perf to yui_user;
drop policy if exists yui_perf_owner on public.yui_perf;
drop policy if exists yui_perf_owner_insert on public.yui_perf;
drop policy if exists yui_perf_owner_read on public.yui_perf;
create policy yui_perf_owner_insert on public.yui_perf for insert to yui_user
  with check (user_id = public.yui_uid());
create policy yui_perf_owner_read on public.yui_perf for select to yui_user
  using (user_id = public.yui_uid());

-- The owner's own agents (their live connector) read the numbers; nobody else's.
grant select on public.yui_perf to yui_connector;
drop policy if exists yui_perf_connector_read on public.yui_perf;
create policy yui_perf_connector_read on public.yui_perf for select to yui_connector
  using (user_id = public.yui_uid() and public.yui_connector_live());

-- Flood guard -----------------------------------------------------------------
create or replace function public.yui_perf_guard() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  caller text := public.yui_caller();
  n bigint;
begin
  if caller is null or caller not in ('yui_user', 'yui_connector', 'service_role') then
    return new;
  end if;
  if public.yui_user_suspended(new.user_id) then
    raise sqlstate 'PT403' using message = 'account_suspended';
  end if;
  -- One writer per account at a time, so two batches cannot both slip under.
  perform pg_advisory_xact_lock(hashtextextended('yui_perf:' || new.user_id::text, 0));
  -- Rows earlier in the same statement (a batch) are visible here.
  select count(*) into n from public.yui_perf
    where user_id = new.user_id and created_at > now() - interval '1 day';
  if n >= public.yui_limit('perf_rows_per_day') then
    return null;
  end if;
  return new;
end $$;
drop trigger if exists yui_perf_guard on public.yui_perf;
create trigger yui_perf_guard before insert on public.yui_perf
  for each row execute function public.yui_perf_guard();

-- Retention -------------------------------------------------------------------
-- Counts what is due (dry) or deletes it. Service role only.
create or replace function public.yui_perf_retention(dry boolean default true)
returns table (what text, n_rows bigint)
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  cutoff timestamptz := now() - make_interval(days => public.yui_limit('perf_retention_days')::int);
  n bigint;
begin
  if dry then
    return query select 'perf'::text, count(*) from public.yui_perf where created_at < cutoff;
    return;
  end if;
  delete from public.yui_perf where created_at < cutoff;
  get diagnostics n = row_count; what := 'perf'; n_rows := n; return next;
end $$;

-- Function grants ---------------------------------------------------------------
revoke all on function public.yui_perf_stack_ok(jsonb) from public, anon, authenticated;
revoke all on function public.yui_connector_live() from public, anon, authenticated;
revoke all on function public.yui_perf_guard() from public, anon, authenticated;
revoke all on function public.yui_perf_retention(boolean) from public, anon, authenticated;
-- The column check runs as the caller.
grant execute on function public.yui_perf_stack_ok(jsonb) to yui_user, yui_connector, service_role;
-- The connector read policy runs as the caller.
grant execute on function public.yui_connector_live() to yui_connector, service_role;
grant execute on function public.yui_perf_retention(boolean) to service_role;

notify pgrst, 'reload schema';
