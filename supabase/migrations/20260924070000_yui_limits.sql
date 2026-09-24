-- YUI-26: safe for strangers. Limits, a kill switch and a retention rule, so
-- outside users cannot hurt the backend, each other, or the rest of PROOF.
--
-- Limits. Every number lives in yui_limits (server only) and is documented in
-- the app README ("Limits"). Rates are token buckets: a bucket holds `burst`
-- tokens and refills at `per_min`. A client that was quiet for a while (a Mac
-- that slept, a phone that was offline) has a full bucket, so its outbox flush
-- goes through in one go; only a sustained flood is refused. A refused write
-- answers 429 and costs nothing, and both outboxes retry 429 with backoff, so
-- a refused message waits instead of being lost. A resend of a row that
-- already landed is never charged: it gets its usual 409.
--
-- Kill switch. yui_users.suspended_at stops one account; yui_connectors.
-- suspended_at stops one host. Either takes effect on the next request, even
-- for a token minted before it: RLS (yui_connector_serves) and the insert
-- guards read the flag live. Reversible: clearing it restores everything.
-- Operated with supabase/scripts/kill_switch.py (service role only).
--
-- Retention. yui_retention() deletes messages older than
-- message_retention_days and the housekeeping rows nobody needs (expired
-- pairing codes and sessions, old pairing attempts, idle rate buckets). The
-- daily sweep (supabase/scripts/media_sweep.py) runs it before the media
-- orphan sweep, which then removes pictures no remaining message uses.
--
-- Writes made with no request claims (the operator's SQL console, the
-- migration runner) are exempt from rates and caps. Everything that arrives
-- through PostgREST or an edge function is not.

-- Limits --------------------------------------------------------------------
create table if not exists public.yui_limits (
  name text primary key,
  value numeric not null check (value >= 0),
  note text not null
);
revoke all on public.yui_limits from public, anon, authenticated;
alter table public.yui_limits enable row level security;

insert into public.yui_limits (name, value, note) values
  ('msg_user_burst',         120, 'messages and taps one account can send at once'),
  ('msg_user_per_min',        30, 'sustained messages and taps per account per minute'),
  ('msg_connector_burst',    240, 'agent replies one host can write at once'),
  ('msg_connector_per_min',   60, 'sustained agent replies per host per minute'),
  ('connect_burst',           30, 'yui-connect calls one host can make at once'),
  ('connect_per_min',          6, 'sustained yui-connect calls per host per minute'),
  ('push_burst',              60, 'push notifications one host can ask for at once'),
  ('push_per_min',            10, 'sustained push notifications per host per minute'),
  ('agents_api_burst',        60, 'yui-agents calls one account can make at once'),
  ('agents_api_per_min',      30, 'sustained yui-agents calls per account per minute'),
  ('pair_code_burst',         20, 'pairing codes one account can mint at once'),
  ('pair_code_per_min',     0.34, 'sustained pairing codes per account per minute (about 20 an hour)'),
  ('agents_per_user',         50, 'agents per account'),
  ('connectors_per_user',     10, 'paired hosts per account (not counting removed ones)'),
  ('devices_per_user',        10, 'phones registered for push per account'),
  ('mgmt_tokens_per_user',    10, 'live agent-management tokens per account'),
  ('media_uploads_per_day',  200, 'pictures per account per day, each side (person, agents)'),
  ('message_retention_days',  90, 'messages older than this are deleted by the daily sweep')
on conflict (name) do update set value = excluded.value, note = excluded.note;

create or replace function public.yui_limit(n text) returns numeric
language sql stable security definer
set search_path = ''
as $$
  select value from public.yui_limits where name = n
$$;

-- The PostgREST caller's role, or null for a direct SQL session.
create or replace function public.yui_caller() returns text
language sql stable
set search_path = ''
as $$
  select nullif(nullif(current_setting('request.jwt.claims', true), ''), '{}')::json ->> 'role'
$$;

-- Rate buckets (server only) ---------------------------------------------------
create table if not exists public.yui_rate_buckets (
  key text primary key,
  tokens double precision not null,
  at timestamptz not null default now()
);
revoke all on public.yui_rate_buckets from public, anon, authenticated;
alter table public.yui_rate_buckets enable row level security;

-- Takes one token from bucket `k`, sized by the limits `<lim>_burst` and
-- `<lim>_per_min`. False (and nothing taken) when the bucket is empty.
create or replace function public.yui_take(k text, lim text) returns boolean
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  burst double precision := public.yui_limit(lim || '_burst');
  rate double precision := public.yui_limit(lim || '_per_min');
  t double precision;
  a timestamptz;
begin
  select tokens, at into t, a from public.yui_rate_buckets where key = k for update;
  if not found then
    insert into public.yui_rate_buckets (key, tokens, at) values (k, burst - 1, now())
      on conflict (key) do nothing;
    return true;
  end if;
  t := least(burst, t + greatest(extract(epoch from now() - a), 0) * rate / 60.0);
  if t < 1 then
    update public.yui_rate_buckets set tokens = t, at = now() where key = k;
    return false;
  end if;
  update public.yui_rate_buckets set tokens = t - 1, at = now() where key = k;
  return true;
end $$;

-- Kill switch ---------------------------------------------------------------
alter table public.yui_users
  add column if not exists suspended_at timestamptz,
  add column if not exists suspended_reason text;
alter table public.yui_connectors
  add column if not exists suspended_at timestamptz,
  add column if not exists suspended_reason text;
-- yui_user reads its own yui_users row (whole-table grant), so it can see why
-- it was stopped. yui_connectors grants are per column: the reason stays
-- server side there.

create or replace function public.yui_user_suspended(uid uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (select 1 from public.yui_users where id = uid and suspended_at is not null)
$$;

-- yui_connector_serves (YUI-7) now also refuses a suspended host or account.
create or replace function public.yui_connector_serves(agent uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.yui_agents a
    join public.yui_connectors c on c.id = a.connector_id
    join public.yui_users u on u.id = a.user_id
    where a.id = agent
      and a.user_id = public.yui_uid()
      and c.id = public.yui_cid()
      and c.user_id = public.yui_uid()
      and c.revoked_at is null
      and c.suspended_at is null
      and u.suspended_at is null
  )
$$;

-- Operator switch. kind = 'user' | 'connector'; on = true stops it.
create or replace function public.yui_suspend(kind text, target uuid, on_ boolean, reason text default null)
returns timestamptz
language plpgsql volatile security definer
set search_path = ''
as $$
declare at_ timestamptz := case when on_ then now() end;
begin
  if kind = 'user' then
    update public.yui_users set suspended_at = at_, suspended_reason = case when on_ then reason end
      where id = target;
  elsif kind = 'connector' then
    update public.yui_connectors set suspended_at = at_, suspended_reason = case when on_ then reason end
      where id = target;
  else
    raise exception 'kind must be user or connector';
  end if;
  if not found then raise exception 'no % %', kind, target; end if;
  return at_;
end $$;

-- Message guard ---------------------------------------------------------------
-- Size: body is already 1..32000 characters (YUI-7); meta gets a cap too.
alter table public.yui_messages drop constraint if exists yui_messages_meta_check;
alter table public.yui_messages add constraint yui_messages_meta_check
  check (jsonb_typeof(meta) = 'object' and pg_column_size(meta) <= 16384);

create or replace function public.yui_messages_guard() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  caller text := public.yui_caller();
  cid uuid;
begin
  if caller is null or caller not in ('yui_user', 'yui_connector', 'service_role') then
    return new;
  end if;
  -- A resend of a row that already landed: the primary key answers 409. Free.
  if exists (select 1 from public.yui_messages where id = new.id) then
    return new;
  end if;
  if public.yui_user_suspended(new.user_id) then
    raise sqlstate 'PT403' using message = 'account_suspended';
  end if;
  if new.sender = 'user' then
    if not public.yui_take('msg:u:' || new.user_id, 'msg_user') then
      raise sqlstate 'PT429' using message = 'rate_limited';
    end if;
  else
    cid := coalesce(public.yui_cid(),
                    (select connector_id from public.yui_agents where id = new.agent_id));
    if cid is not null and not public.yui_take('msg:c:' || cid, 'msg_connector') then
      raise sqlstate 'PT429' using message = 'rate_limited';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists yui_messages_guard on public.yui_messages;
create trigger yui_messages_guard before insert on public.yui_messages
  for each row execute function public.yui_messages_guard();

-- Account caps ----------------------------------------------------------------
-- One guard for every table an account can grow through the app or the edge
-- functions: a suspended account creates nothing, and each has a ceiling.
create or replace function public.yui_caps_guard() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  caller text := public.yui_caller();
  n bigint;
  cap numeric;
begin
  if caller is null or caller not in ('yui_user', 'yui_connector', 'service_role') then
    return new;
  end if;
  if public.yui_user_suspended(new.user_id) then
    raise sqlstate 'PT403' using message = 'account_suspended';
  end if;
  case tg_table_name
    when 'yui_agents' then
      select count(*) into n from public.yui_agents where user_id = new.user_id;
      cap := public.yui_limit('agents_per_user');
    when 'yui_connectors' then
      select count(*) into n from public.yui_connectors where user_id = new.user_id and revoked_at is null;
      cap := public.yui_limit('connectors_per_user');
    when 'yui_devices' then
      -- Re-registering a phone Yui already knows is an upsert, not a new device.
      if new.apns_token is not null
         and exists (select 1 from public.yui_devices where apns_token = new.apns_token) then
        return new;
      end if;
      select count(*) into n from public.yui_devices where user_id = new.user_id;
      cap := public.yui_limit('devices_per_user');
    when 'yui_mgmt_tokens' then
      select count(*) into n from public.yui_mgmt_tokens where user_id = new.user_id and revoked_at is null;
      cap := public.yui_limit('mgmt_tokens_per_user');
    when 'yui_pairings' then
      if not public.yui_take('pair:u:' || new.user_id, 'pair_code') then
        raise sqlstate 'PT429' using message = 'rate_limited';
      end if;
      return new;
  end case;
  if n >= cap then
    raise sqlstate 'PT403' using message = 'limit_reached', detail = tg_table_name;
  end if;
  return new;
end $$;

do $$
declare t text;
begin
  foreach t in array array['yui_agents', 'yui_connectors', 'yui_devices', 'yui_mgmt_tokens', 'yui_pairings'] loop
    execute format('drop trigger if exists yui_caps_guard on public.%I', t);
    execute format('create trigger yui_caps_guard before insert on public.%I
                    for each row execute function public.yui_caps_guard()', t);
  end loop;
end $$;

-- Media quota -----------------------------------------------------------------
-- Uploads per day, per side (`user` = the person's photos, `agent` = what
-- hosts re-host). Invoker rights, like every function yui_user may call: the
-- person counts their own uploads, a host counts what it can see (the threads
-- it serves). A suspended account uploads nothing: the person's policy reads
-- their own yui_users row, a host's goes through yui_connector_serves.
create or replace function public.yui_media_quota_ok(name text) returns boolean
language sql stable security invoker
set search_path = ''
as $$
  -- $1, not `name`: inside the subquery `name` would be storage.objects.name.
  select case
    when public.yui_media_agent($1) is null then false
    else (select count(*) from storage.objects o
          where o.bucket_id = 'yui-media'
            and o.name like split_part($1, '/', 1) || '/%/' || split_part($1, '/', 3) || '/%'
            and o.created_at > now() - interval '1 day')
         < (select l.value from public.yui_limits l where l.name = 'media_uploads_per_day')
  end
$$;

-- The limits are public (README "Limits"); the invoker quota needs to read one.
grant select on public.yui_limits to yui_user, yui_connector;
drop policy if exists yui_limits_read on public.yui_limits;
create policy yui_limits_read on public.yui_limits for select to yui_user, yui_connector using (true);

drop policy if exists yui_media_user_write on storage.objects;
create policy yui_media_user_write on storage.objects for insert to yui_user
  with check (bucket_id = 'yui-media' and split_part(name, '/', 1) = public.yui_uid()::text
              and split_part(name, '/', 3) = 'user'
              and public.yui_owns_agent(public.yui_media_agent(name))
              and exists (select 1 from public.yui_users u
                          where u.id = public.yui_uid() and u.suspended_at is null)
              and public.yui_media_quota_ok(name));
drop policy if exists yui_media_connector_write on storage.objects;
create policy yui_media_connector_write on storage.objects for insert to yui_connector
  with check (bucket_id = 'yui-media' and split_part(name, '/', 1) = public.yui_uid()::text
              and split_part(name, '/', 3) = 'agent'
              and public.yui_connector_serves(public.yui_media_agent(name))
              and public.yui_media_quota_ok(name));

-- Retention -------------------------------------------------------------------
-- Counts what is due (dry) or deletes it. Service role only.
create or replace function public.yui_retention(dry boolean default true)
returns table (what text, n_rows bigint)
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  cutoff timestamptz := now() - make_interval(days => public.yui_limit('message_retention_days')::int);
  n bigint;
begin
  if dry then
    return query
      select 'messages'::text, count(*) from public.yui_messages where created_at < cutoff
      union all select 'pairings'::text, count(*) from public.yui_pairings where expires_at < now() - interval '1 day'
      union all select 'pair_attempts'::text, count(*) from public.yui_pair_attempts where created_at < now() - interval '1 day'
      union all select 'sessions'::text, count(*) from public.yui_sessions where expires_at < now() - interval '1 day'
      union all select 'rate_buckets'::text, count(*) from public.yui_rate_buckets where at < now() - interval '1 day';
    return;
  end if;
  delete from public.yui_messages where created_at < cutoff;
  get diagnostics n = row_count; what := 'messages'; n_rows := n; return next;
  delete from public.yui_pairings where expires_at < now() - interval '1 day';
  get diagnostics n = row_count; what := 'pairings'; n_rows := n; return next;
  delete from public.yui_pair_attempts where created_at < now() - interval '1 day';
  get diagnostics n = row_count; what := 'pair_attempts'; n_rows := n; return next;
  -- Spent refresh tokens stay until they expire: the reuse check needs them.
  delete from public.yui_sessions where expires_at < now() - interval '1 day';
  get diagnostics n = row_count; what := 'sessions'; n_rows := n; return next;
  -- An idle bucket has refilled; no row reads the same as a full one.
  delete from public.yui_rate_buckets where at < now() - interval '1 day';
  get diagnostics n = row_count; what := 'rate_buckets'; n_rows := n; return next;
end $$;

-- Grants ----------------------------------------------------------------------
revoke all on function public.yui_limit(text) from public, anon, authenticated;
revoke all on function public.yui_caller() from public, anon, authenticated;
revoke all on function public.yui_take(text, text) from public, anon, authenticated;
revoke all on function public.yui_user_suspended(uuid) from public, anon, authenticated;
revoke all on function public.yui_suspend(text, uuid, boolean, text) from public, anon, authenticated;
revoke all on function public.yui_messages_guard() from public, anon, authenticated;
revoke all on function public.yui_caps_guard() from public, anon, authenticated;
revoke all on function public.yui_media_quota_ok(text) from public, anon, authenticated;
revoke all on function public.yui_retention(boolean) from public, anon, authenticated;
grant execute on function public.yui_take(text, text) to service_role;
grant execute on function public.yui_user_suspended(uuid) to service_role;
grant execute on function public.yui_suspend(text, uuid, boolean, text) to service_role;
grant execute on function public.yui_retention(boolean) to service_role;
-- Storage evaluates the upload policies as the caller.
grant execute on function public.yui_media_quota_ok(text) to yui_user, yui_connector, service_role;

notify pgrst, 'reload schema';
