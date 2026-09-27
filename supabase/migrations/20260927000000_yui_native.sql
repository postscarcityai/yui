-- NATIVE-1 (YUI-130 to YUI-140): every person gets their own Yui.
-- Spec: yuigui spec/NATIVE.md. Runtime: runtime/ (edge copy in functions/_native).
--
-- A person's native Yui is one `hosted` connector and a `hosted` agent row per
-- native agent, as Hermes profiles share one install. What makes an agent
-- native lives next to it:
--   yui_native_profiles  the agent's profile (soul, favorites, model, version)
--   yui_native_memory    its notes, and the person's "about you" card (agent_id null)
--   yui_native_usage     free turns taken per person per month
--   yui_native_models    which model serves which kind of turn
--   yui_native_locks     one turn at a time per agent
--   yui_native_keys      a person's own model key (in Vault), used instead of Yui's
--   yui_native_schedules check-ins agents set; pg_cron wakes them each minute
--   yui_native_daily     web searches per person per day
-- A new person row in a hosted agent's thread wakes the yui-native function
-- through pg_net. It all ships dark: nothing happens until native_enabled is 1.
--
-- Before switching it on, by hand in the SQL console (never in a file):
--   select vault.create_secret('https://<ref>.supabase.co/functions/v1/yui-native', 'yui_native_url');
--   select vault.create_secret('<a long random string>', 'yui_native_secret');
-- and set the same string as the function secret YUI_NATIVE_SECRET, plus
-- YUI_OPENROUTER_KEY. Needs pg_net and pg_cron (both created here). Then: update yui_limits set value = 1 where name = 'native_enabled';

create extension if not exists pg_net;

-- Limits ------------------------------------------------------------------------
insert into public.yui_limits (name, value, note) values
  ('native_enabled',    0, '1: every person gets Yui and the starter crew, and native agents answer (NATIVE-1)'),
  ('native_free_turns', 100, 'native turns a month on Yui''s own model key, per person')
on conflict (name) do nothing;

-- Profiles ----------------------------------------------------------------------
create table if not exists public.yui_native_profiles (
  agent_id uuid primary key references public.yui_agents(id) on delete cascade,
  user_id uuid not null references public.yui_users(id) on delete cascade,
  profile jsonb not null check (jsonb_typeof(profile) = 'object' and pg_column_size(profile) <= 16384),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists yui_native_profiles_user_idx on public.yui_native_profiles(user_id);
alter table public.yui_native_profiles enable row level security;
revoke all on public.yui_native_profiles from public, anon, authenticated;
grant select on public.yui_native_profiles to yui_user;
drop policy if exists yui_native_profiles_owner on public.yui_native_profiles;
create policy yui_native_profiles_owner on public.yui_native_profiles for select to yui_user
  using (user_id = public.yui_uid());

-- Memory ------------------------------------------------------------------------
create table if not exists public.yui_native_memory (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.yui_users(id) on delete cascade,
  agent_id uuid references public.yui_agents(id) on delete cascade, -- null: the about-you card
  kind text not null check (kind in ('note', 'about')),
  key text check (key is null or length(key) between 1 and 40),
  body text not null check (length(body) between 1 and 400),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((kind = 'about' and agent_id is null and key is not null) or (kind = 'note' and agent_id is not null))
);
create index if not exists yui_native_memory_user_idx on public.yui_native_memory(user_id, agent_id);
create unique index if not exists yui_native_memory_about_uq on public.yui_native_memory(user_id, key) where kind = 'about';
alter table public.yui_native_memory enable row level security;
revoke all on public.yui_native_memory from public, anon, authenticated;
-- The person sees, fixes and forgets what their agents remember (Controls).
grant select, delete on public.yui_native_memory to yui_user;
grant update (body, updated_at) on public.yui_native_memory to yui_user;
drop policy if exists yui_native_memory_owner on public.yui_native_memory;
create policy yui_native_memory_owner on public.yui_native_memory for all to yui_user
  using (user_id = public.yui_uid()) with check (user_id = public.yui_uid());

-- Usage, models, locks (server only) ---------------------------------------------
create table if not exists public.yui_native_usage (
  user_id uuid not null references public.yui_users(id) on delete cascade,
  month date not null,
  turns integer not null default 0,
  primary key (user_id, month)
);
alter table public.yui_native_usage enable row level security;
revoke all on public.yui_native_usage from public, anon, authenticated;

create table if not exists public.yui_native_models (
  kind text primary key check (kind in ('text', 'vision')),
  model text not null,
  note text not null default ''
);
alter table public.yui_native_models enable row level security;
revoke all on public.yui_native_models from public, anon, authenticated;
insert into public.yui_native_models (kind, model, note) values
  ('text',   'z-ai/glm-5.2',      'every turn without a picture'),
  ('vision', 'z-ai/glm-5v-turbo', 'turns with a photo or video (GLM 5.2 reads text only)')
on conflict (kind) do nothing;

create table if not exists public.yui_native_locks (
  agent_id uuid primary key references public.yui_agents(id) on delete cascade,
  until timestamptz not null
);
alter table public.yui_native_locks enable row level security;
revoke all on public.yui_native_locks from public, anon, authenticated;

-- One hosted connector per person.
create unique index if not exists yui_connectors_one_hosted_uq on public.yui_connectors(user_id)
  where kind = 'hosted' and revoked_at is null;

-- Functions (service role only) ----------------------------------------------------

-- Takes one free turn this month. ok=false when they are used up.
create or replace function public.yui_native_take_turn(uid uuid)
returns table (ok boolean, left_turns integer, lim integer)
language plpgsql security definer set search_path = '' as $$
declare
  cap integer := coalesce(public.yui_limit('native_free_turns'), 100)::integer;
  m date := date_trunc('month', now())::date;
  used integer;
begin
  insert into public.yui_native_usage as u (user_id, month, turns) values (uid, m, 1)
    on conflict (user_id, month) do update set turns = u.turns + 1 where u.turns < cap
    returning turns into used;
  if used is null then
    return query select false, 0, cap;
  else
    return query select true, greatest(cap - used, 0), cap;
  end if;
end $$;

-- One turn at a time per agent: true when this caller holds the lock.
create or replace function public.yui_native_lock(agent uuid, secs integer)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare got uuid;
begin
  insert into public.yui_native_locks as l (agent_id, until) values (agent, now() + make_interval(secs => secs))
    on conflict (agent_id) do update set until = excluded.until where l.until < now()
    returning agent_id into got;
  return got is not null;
end $$;

-- A native agent on the person's hosted connector, with its profile and its
-- first answer in its thread. The handle is made unique ("gouda", "gouda-2").
-- Yui (the maker) becomes the person's default agent, even next to agents they
-- connected before (Chris, Sep 27). `at_sort` places it; null goes last.
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
  insert into public.yui_agents (user_id, name, handle, color, kind, connector_id, remote_ref, sort, is_default)
    values (uid, nm, h, col, 'hosted', cid, h,
            coalesce(at_sort, (select max(sort) + 1 from public.yui_agents where user_id = uid), 0),
            coalesce((prof ->> 'maker')::boolean, false) or not exists (select 1 from public.yui_agents where user_id = uid))
    returning id into aid;
  insert into public.yui_native_profiles (agent_id, user_id, profile)
    values (aid, uid, prof || jsonb_build_object('handle', h, 'name', nm));
  if coalesce(prof ->> 'first', '') <> '' then
    insert into public.yui_messages (user_id, agent_id, sender, kind, body, meta)
      values (uid, aid, 'agent', 'text', left(prof ->> 'first', 32000), '{"native": "first"}'::jsonb);
  end if;
  return query select aid;
end $$;

-- Gives a person their Yui and the starter crew, once, at the top of their
-- list. `profs` is the list of starter profiles from runtime/profiles (Yui
-- first). Returns agents made.
create or replace function public.yui_native_provision(uid uuid, profs jsonb)
returns integer
language plpgsql security definer set search_path = '' as $$
declare
  p jsonb;
  n integer := 0;
  top integer;
begin
  if coalesce(public.yui_limit('native_enabled'), 0) < 1 then return 0; end if;
  perform pg_advisory_xact_lock(hashtext('yui_native_provision:' || uid::text));
  if exists (select 1 from public.yui_connectors where user_id = uid and kind = 'hosted') then return 0; end if;
  insert into public.yui_connectors (user_id, name, kind, token_hash)
    values (uid, 'Yui', 'hosted', 'hosted:' || gen_random_uuid()::text); -- no token: nobody dials in
  top := coalesce((select min(sort) from public.yui_agents where user_id = uid), 0) - jsonb_array_length(profs) - 1;
  for p in select * from jsonb_array_elements(profs) loop
    perform public.yui_native_add_agent(uid, p, top + n);
    n := n + 1;
  end loop;
  return n;
end $$;

revoke all on function public.yui_native_take_turn(uuid) from public, anon, authenticated;
revoke all on function public.yui_native_lock(uuid, integer) from public, anon, authenticated;
revoke all on function public.yui_native_add_agent(uuid, jsonb, integer) from public, anon, authenticated;
revoke all on function public.yui_native_provision(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.yui_native_take_turn(uuid) to service_role;
grant execute on function public.yui_native_lock(uuid, integer) to service_role;
grant execute on function public.yui_native_add_agent(uuid, jsonb, integer) to service_role;
grant execute on function public.yui_native_provision(uuid, jsonb) to service_role;

-- Presence: a hosted agent is always there (no computer to fall asleep).
create or replace function public.yui_connector_hosted(connector uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.yui_connectors where id = connector and kind = 'hosted' and revoked_at is null)
$$;
revoke all on function public.yui_connector_hosted(uuid) from public, anon, authenticated;
grant execute on function public.yui_connector_hosted(uuid) to yui_user, yui_connector, service_role;

create or replace function public.yui_presence(connector uuid, revoked_at timestamptz,
  stopped_at timestamptz, last_seen_at timestamptz, serving_at timestamptz,
  bound_at timestamptz, served_at timestamptz) returns text
language sql stable
set search_path = ''
as $$
  select case
    when connector is null then 'pending'
    when revoked_at is not null then 'offline'
    when public.yui_connector_hosted(connector) then 'online'
    when serving_at is not null and bound_at is not null and served_at is null then 'not_listening'
    when stopped_at is not null then 'offline'
    when last_seen_at is null or last_seen_at <= now() - interval '2 minutes' then 'asleep'
    when serving_at > now() - interval '2 minutes' and served_at is not null
         and served_at <= now() - interval '2 minutes' then 'offline'
    else 'online'
  end
$$;

-- Wake ----------------------------------------------------------------------------
-- A person's message to a hosted agent calls yui-native. A failure here never
-- stops the message from landing: the next message wakes it again.
create or replace function public.yui_native_wake() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  u text;
  s text;
begin
  if coalesce(public.yui_limit('native_enabled'), 0) < 1 then return null; end if;
  if not exists (select 1 from public.yui_agents where id = new.agent_id and kind = 'hosted') then return null; end if;
  select decrypted_secret into u from vault.decrypted_secrets where name = 'yui_native_url';
  select decrypted_secret into s from vault.decrypted_secrets where name = 'yui_native_secret';
  if u is null or s is null then return null; end if;
  perform net.http_post(
    url := u,
    body := jsonb_build_object('agent_id', new.agent_id, 'message_id', new.id),
    headers := jsonb_build_object('content-type', 'application/json', 'x-yui-native', s),
    timeout_milliseconds := 5000
  );
  return null;
exception when others then
  raise warning 'yui_native_wake: %', sqlerrm;
  return null;
end $$;
revoke all on function public.yui_native_wake() from public, anon, authenticated;
drop trigger if exists yui_native_wake on public.yui_messages;
create trigger yui_native_wake after insert on public.yui_messages
  for each row when (new.sender = 'user' and new.kind in ('text', 'event'))
  execute function public.yui_native_wake();

-- The person's own model key (YUI-139) ------------------------------------------------
-- One key per person, kept in Vault; the table holds the vault id and what the
-- app shows (provider, last four). A person with a key uses it for every native
-- turn and has no monthly cap. Only the service role reads the key itself.
create table if not exists public.yui_native_keys (
  user_id uuid primary key references public.yui_users(id) on delete cascade,
  provider text not null check (provider in ('openrouter', 'trustedrouter', 'groq', 'custom')),
  base_url text not null check (base_url ~ '^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._/-]*)?$'),
  model text check (model is null or length(model) between 1 and 120),
  secret_id uuid not null,
  hint text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.yui_native_keys enable row level security;
revoke all on public.yui_native_keys from public, anon, authenticated;
grant select (user_id, provider, base_url, model, hint, created_at, updated_at) on public.yui_native_keys to yui_user;
drop policy if exists yui_native_keys_owner on public.yui_native_keys;
create policy yui_native_keys_owner on public.yui_native_keys for select to yui_user using (user_id = public.yui_uid());

create or replace function public.yui_native_key_set(uid uuid, prov text, url text, mdl text, secret text)
returns void
language plpgsql security definer set search_path = '' as $$
declare sid uuid;
begin
  select secret_id into sid from public.yui_native_keys where user_id = uid;
  if sid is null then
    sid := vault.create_secret(secret, 'yui_native_key:' || uid::text, 'a person''s own model key (NATIVE-1)');
  else
    perform vault.update_secret(sid, secret);
  end if;
  insert into public.yui_native_keys (user_id, provider, base_url, model, secret_id, hint)
    values (uid, prov, url, nullif(mdl, ''), sid, right(secret, 4))
    on conflict (user_id) do update set provider = excluded.provider, base_url = excluded.base_url, model = excluded.model,
      secret_id = excluded.secret_id, hint = excluded.hint, updated_at = now();
end $$;

create or replace function public.yui_native_key_get(uid uuid)
returns table (provider text, base_url text, model text, secret text)
language sql stable security definer set search_path = '' as $$
  select k.provider, k.base_url, k.model, s.decrypted_secret
    from public.yui_native_keys k join vault.decrypted_secrets s on s.id = k.secret_id
   where k.user_id = uid
$$;

create or replace function public.yui_native_key_remove(uid uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare sid uuid;
begin
  delete from public.yui_native_keys where user_id = uid returning secret_id into sid;
  if sid is not null then delete from vault.secrets where id = sid; end if;
end $$;

-- A person's keys go with them.
create or replace function public.yui_native_keys_gone() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  delete from vault.secrets where id = old.secret_id;
  return null;
end $$;
drop trigger if exists yui_native_keys_gone on public.yui_native_keys;
create trigger yui_native_keys_gone after delete on public.yui_native_keys
  for each row execute function public.yui_native_keys_gone();

-- Time, schedules and search (YUI-142, YUI-143) ------------------------------------------
-- The phone says which time zone the person is in; agents plan in it.
alter table public.yui_users add column if not exists timezone text
  check (timezone is null or timezone ~ '^[A-Za-z_]+(/[A-Za-z0-9_+-]+){0,2}$');

insert into public.yui_limits (name, value, note) values
  ('native_searches_per_day', 20, 'web searches a native agent makes for one person per day'),
  ('native_schedules_per_user', 30, 'check-ins and reminders one person''s native agents can hold')
on conflict (name) do nothing;

create table if not exists public.yui_native_schedules (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.yui_users(id) on delete cascade,
  agent_id uuid not null references public.yui_agents(id) on delete cascade,
  note text not null check (length(note) between 1 and 300),
  rule jsonb not null check (jsonb_typeof(rule) = 'object'), -- {every: "day"|"mon,wed", at: "07:00"} or {once: "<iso>"}
  tz text not null default 'UTC',
  next_at timestamptz, -- null: running now, or done
  fired_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists yui_native_schedules_due_idx on public.yui_native_schedules(next_at) where next_at is not null;
create index if not exists yui_native_schedules_agent_idx on public.yui_native_schedules(agent_id);
alter table public.yui_native_schedules enable row level security;
revoke all on public.yui_native_schedules from public, anon, authenticated;
grant select, delete on public.yui_native_schedules to yui_user;
drop policy if exists yui_native_schedules_owner on public.yui_native_schedules;
create policy yui_native_schedules_owner on public.yui_native_schedules for all to yui_user
  using (user_id = public.yui_uid());

create table if not exists public.yui_native_daily (
  user_id uuid not null references public.yui_users(id) on delete cascade,
  day date not null,
  searches integer not null default 0,
  primary key (user_id, day)
);
alter table public.yui_native_daily enable row level security;
revoke all on public.yui_native_daily from public, anon, authenticated;

create or replace function public.yui_native_take_search(uid uuid)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  cap integer := coalesce(public.yui_limit('native_searches_per_day'), 20)::integer;
  used integer;
begin
  insert into public.yui_native_daily as d (user_id, day, searches) values (uid, current_date, 1)
    on conflict (user_id, day) do update set searches = d.searches + 1 where d.searches < cap
    returning searches into used;
  return used is not null;
end $$;

-- Every minute: claim what is due and wake yui-native for each. A claimed row
-- has next_at null until the runtime sets the next one; a run that died leaves
-- it null, and it is picked up again after ten minutes.
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
                   where next_at <= now()
                      or (next_at is null and fired_at < now() - interval '10 minutes' and rule ? 'every')
                   order by next_at nulls first limit 200 for update skip locked)
    returning id
  loop
    perform net.http_post(url := u, body := jsonb_build_object('schedule_id', r.id),
      headers := jsonb_build_object('content-type', 'application/json', 'x-yui-native', s), timeout_milliseconds := 5000);
    n := n + 1;
  end loop;
  return n;
end $$;

revoke all on function public.yui_native_key_set(uuid, text, text, text, text) from public, anon, authenticated;
revoke all on function public.yui_native_key_get(uuid) from public, anon, authenticated;
revoke all on function public.yui_native_key_remove(uuid) from public, anon, authenticated;
revoke all on function public.yui_native_keys_gone() from public, anon, authenticated;
revoke all on function public.yui_native_take_search(uuid) from public, anon, authenticated;
revoke all on function public.yui_native_tick() from public, anon, authenticated;
grant execute on function public.yui_native_key_set(uuid, text, text, text, text) to service_role;
grant execute on function public.yui_native_key_get(uuid) to service_role;
grant execute on function public.yui_native_key_remove(uuid) to service_role;
grant execute on function public.yui_native_take_search(uuid) to service_role;

create extension if not exists pg_cron;
do $$ begin
  perform cron.unschedule('yui-native-tick') where exists (select 1 from cron.job where jobname = 'yui-native-tick');
  perform cron.schedule('yui-native-tick', '* * * * *', 'select public.yui_native_tick()');
end $$;

notify pgrst, 'reload schema';
