-- YUI-34 step 2, backend lane: the key vault. Spec: yuigui spec/VAULT.md
-- (sections 3, 4, 6, 7, 10).
--
-- A person's tool keys live in the phone's Keychain. When they let an agent use
-- one, the app seals it (HPKE, X25519 + ChaCha20-Poly1305) to the hosted
-- connector's public key and stores the sealed blob here. Only the yui-vault
-- Edge Function, holding the private key, can open it, for one call at a time.
--
-- 1. yui_vault_keys       sealed keys, owner-only. `sealed` is never selectable
--                         by yui_user; the app reads yui_vault_keys_public.
-- 2. yui_vault_grants     (agent, key, purpose, cap, once). The handle
--                         vk_<provider>_<hex> is made here, never by the app.
-- 3. yui_vault_uses       the audit trail: one row per call, plus grant, revoke,
--                         cap, add, remove, deny. Owner reads; only the
--                         connector (service role) writes calls.
-- 4. yui_vault_begin/finish: the connector's one round trip per call. Token
--    owner, grant, lapse, path, once and cap checks happen in ONE statement
--    that locks the key row, so ten parallel calls cannot all slip under the
--    cap: each takes a hold (its estimated cost) as its use row.
-- 5. key_ask / key_answer: control rows (kind = 'control'). A repeat key_ask
--    for a provider declined in the last 24 hours is dropped, and the agent is
--    told; an answer becomes the one "[yui] Key access: ..." line the agent
--    reads on its next turn (a kind 'event' row from the person, no bubble).
-- 6. Grants lapse after 90 days with no call (day 80: a lapse_soon row for the
--    app to tell the person). yui_retention deletes uses after 90 days.

-- Limits --------------------------------------------------------------------
insert into public.yui_limits (name, value, note) values
  ('vault_burst',        30, 'vault calls one host can make at once'),
  ('vault_per_min',      60, 'sustained vault calls per host per minute'),
  ('vault_keys_per_user', 20, 'sealed keys per account')
on conflict (name) do update set value = excluded.value, note = excluded.note;

-- Providers -------------------------------------------------------------------
-- The migration allows all six (OpenRouter stays YUI-139's server-side model
-- key; forward compat only). "Priced" providers have a price table in the
-- connector (functions/yui-vault/pricing.ts); the others cannot be granted
-- until the owner confirms a provider-side limit (provider_limit_confirmed).
-- Keep this list in step with pricing.ts (a test compares them).
create or replace function public.yui_vault_priced(prov text) returns boolean
language sql immutable set search_path = '' as $$ select prov in ('fal', 'anthropic', 'openai') $$;

-- 1. Keys ---------------------------------------------------------------------
create table if not exists public.yui_vault_keys (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.yui_users(id) on delete cascade,
  provider text not null check (provider in ('fal', 'replicate', 'elevenlabs', 'openrouter', 'anthropic', 'openai')),
  name text not null check (length(name) between 1 and 60),
  last4 text not null check (length(last4) between 1 and 4),
  -- enc (32 bytes) || ciphertext || tag (16 bytes) of a key at least 1 byte long,
  -- and never printable text: a plaintext key pasted here by mistake is refused.
  sealed bytea not null check (length(sealed) between 49 and 4096
                               and encode(sealed, 'hex') !~ '^([2-7][0-9a-f])+$'),
  key_id text not null check (length(key_id) between 1 and 40),
  cap_cents int not null default 1000 check (cap_cents between 0 and 100000000),
  provider_limit_confirmed boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists yui_vault_keys_user_idx on public.yui_vault_keys (user_id);

-- 2. Grants -------------------------------------------------------------------
create table if not exists public.yui_vault_grants (
  id uuid primary key default gen_random_uuid(),
  key uuid not null references public.yui_vault_keys(id) on delete cascade,
  agent_id uuid not null references public.yui_agents(id) on delete cascade,
  handle text unique not null check (handle ~ '^vk_[a-z]+_[0-9a-f]{4,8}$'),
  purpose text not null check (length(purpose) between 1 and 80),
  cap_cents int check (cap_cents between 0 and 100000000),
  once boolean not null default false,
  created_at timestamptz not null default now(),
  revoked_at timestamptz,
  -- Last call that got through (a once grant: the call that used it). Grants
  -- lapse 90 days after this, or after created_at when never used.
  last_used_at timestamptz,
  lapse_warned_at timestamptz
);
create index if not exists yui_vault_grants_key_idx on public.yui_vault_grants (key);
create index if not exists yui_vault_grants_agent_idx on public.yui_vault_grants (agent_id);

-- 3. Uses ---------------------------------------------------------------------
create table if not exists public.yui_vault_uses (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.yui_users(id) on delete cascade,
  key uuid,                  -- no foreign key: the trail outlives a removed key
  agent_id uuid,
  kind text not null check (kind in ('call', 'grant', 'revoke', 'cap', 'add', 'remove', 'deny', 'cap_80', 'lapse_soon')),
  path text,
  status int,
  cost_cents int,
  at timestamptz not null default now(),
  -- Added to the spec's shape so Activity can read without a join that a
  -- removed key would break: who, which key, what was refused and why.
  provider text,
  key_name text,
  handle text,
  allowed boolean not null default true,
  error text
);
create index if not exists yui_vault_uses_key_month_idx on public.yui_vault_uses (key, at) where kind = 'call';
create index if not exists yui_vault_uses_user_idx on public.yui_vault_uses (user_id, at desc);
create index if not exists yui_vault_uses_deny_idx on public.yui_vault_uses (user_id, agent_id, provider, at) where kind = 'deny';

-- Access ------------------------------------------------------------------------
alter table public.yui_vault_keys enable row level security;
alter table public.yui_vault_grants enable row level security;
alter table public.yui_vault_uses enable row level security;
revoke all on public.yui_vault_keys, public.yui_vault_grants, public.yui_vault_uses from public, anon, authenticated, yui_connector;
revoke all on public.yui_vault_keys, public.yui_vault_grants, public.yui_vault_uses from yui_user;

-- The owner inserts and deletes keys and reads everything but `sealed`. Nobody
-- updates `sealed` (re-sealing is delete and insert); the app may rename a key,
-- change its cap and confirm a provider-side limit.
grant select (id, user_id, provider, name, last4, key_id, cap_cents, provider_limit_confirmed, created_at)
  on public.yui_vault_keys to yui_user;
grant insert (user_id, provider, name, last4, sealed, key_id, cap_cents, provider_limit_confirmed)
  on public.yui_vault_keys to yui_user;
grant update (name, cap_cents, provider_limit_confirmed) on public.yui_vault_keys to yui_user;
grant delete on public.yui_vault_keys to yui_user;
drop policy if exists yui_vault_keys_owner_read on public.yui_vault_keys;
drop policy if exists yui_vault_keys_owner_insert on public.yui_vault_keys;
drop policy if exists yui_vault_keys_owner_update on public.yui_vault_keys;
drop policy if exists yui_vault_keys_owner_delete on public.yui_vault_keys;
create policy yui_vault_keys_owner_read on public.yui_vault_keys for select to yui_user using (user_id = public.yui_uid());
create policy yui_vault_keys_owner_insert on public.yui_vault_keys for insert to yui_user with check (user_id = public.yui_uid());
create policy yui_vault_keys_owner_update on public.yui_vault_keys for update to yui_user
  using (user_id = public.yui_uid()) with check (user_id = public.yui_uid());
create policy yui_vault_keys_owner_delete on public.yui_vault_keys for delete to yui_user using (user_id = public.yui_uid());

-- Grants are inserted by the app after Face ID. Revoking sets revoked_at.
grant select on public.yui_vault_grants to yui_user;
grant insert (key, agent_id, purpose, cap_cents, once) on public.yui_vault_grants to yui_user;
grant update (revoked_at, cap_cents) on public.yui_vault_grants to yui_user;
drop policy if exists yui_vault_grants_owner_read on public.yui_vault_grants;
drop policy if exists yui_vault_grants_owner_insert on public.yui_vault_grants;
drop policy if exists yui_vault_grants_owner_update on public.yui_vault_grants;
create policy yui_vault_grants_owner_read on public.yui_vault_grants for select to yui_user
  using (exists (select 1 from public.yui_vault_keys k where k.id = key and k.user_id = public.yui_uid()));
create policy yui_vault_grants_owner_insert on public.yui_vault_grants for insert to yui_user
  with check (exists (select 1 from public.yui_vault_keys k where k.id = key and k.user_id = public.yui_uid()));
create policy yui_vault_grants_owner_update on public.yui_vault_grants for update to yui_user
  using (exists (select 1 from public.yui_vault_keys k where k.id = key and k.user_id = public.yui_uid()))
  with check (exists (select 1 from public.yui_vault_keys k where k.id = key and k.user_id = public.yui_uid()));

-- Uses: the owner reads. No write policy exists for anyone: rows come from the
-- definer functions below (the connector's service role calls them).
grant select on public.yui_vault_uses to yui_user;
drop policy if exists yui_vault_uses_owner_read on public.yui_vault_uses;
create policy yui_vault_uses_owner_read on public.yui_vault_uses for select to yui_user using (user_id = public.yui_uid());

-- What the app reads: keys without `sealed`, with this month's spend and the
-- last call; grants with the same. security_invoker keeps RLS in force.
create or replace function public.yui_vault_month() returns timestamptz
language sql stable set search_path = '' as $$
  select date_trunc('month', now() at time zone 'utc') at time zone 'utc'
$$;

create or replace view public.yui_vault_keys_public with (security_invoker = true) as
  select k.id, k.user_id, k.provider, k.name, k.last4, k.key_id, k.cap_cents, k.provider_limit_confirmed, k.created_at,
         coalesce((select sum(u.cost_cents) from public.yui_vault_uses u
                    where u.key = k.id and u.kind = 'call' and u.allowed and u.at >= public.yui_vault_month()), 0)::int as spent_cents,
         (select max(u.at) from public.yui_vault_uses u where u.key = k.id and u.kind = 'call' and u.allowed) as last_used_at
    from public.yui_vault_keys k;
grant select on public.yui_vault_keys_public to yui_user;

create or replace view public.yui_vault_grants_public with (security_invoker = true) as
  select g.id, g.key, g.agent_id, g.handle, g.purpose, g.cap_cents, g.once, g.created_at, g.revoked_at, g.last_used_at,
         k.provider, k.name as key_name,
         coalesce((select sum(u.cost_cents) from public.yui_vault_uses u
                    where u.handle = g.handle and u.kind = 'call' and u.allowed and u.at >= public.yui_vault_month()), 0)::int as spent_cents
    from public.yui_vault_grants g join public.yui_vault_keys k on k.id = g.key;
grant select on public.yui_vault_grants_public to yui_user;

-- The line an agent reads -------------------------------------------------------
-- A quiet event from the person (no meta.echo, so no bubble): the host hands it
-- to the agent on its next turn. Written with no request claims so the account's
-- message rate never turns a revoke into an error; the caller's claims come back.
create or replace function public.yui_vault_tell(uid uuid, agent uuid, line text, extra jsonb default '{}'::jsonb)
returns void
language plpgsql security definer set search_path = '' as $$
declare claims text := current_setting('request.jwt.claims', true);
begin
  perform set_config('request.jwt.claims', '', true);
  insert into public.yui_messages (user_id, agent_id, sender, kind, body, meta)
    values (uid, agent, 'user', 'event', left(line, 400), coalesce(extra, '{}'::jsonb) || '{"vault": true}'::jsonb);
  perform set_config('request.jwt.claims', coalesce(claims, ''), true);
end $$;
revoke all on function public.yui_vault_tell(uuid, uuid, text, jsonb) from public, anon, authenticated, yui_user, yui_connector;

create or replace function public.yui_vault_dollars(cents numeric) returns text
language sql immutable set search_path = '' as $$
  select case when cents % 100 = 0 then (cents / 100)::bigint::text else to_char(cents / 100, 'FM999999990.00') end
$$;

-- Keys: checks, audit ---------------------------------------------------------
create or replace function public.yui_vault_key_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if (select count(*) from public.yui_vault_keys where user_id = new.user_id) >= public.yui_limit('vault_keys_per_user') then
    raise sqlstate 'PT429' using message = 'too_many_keys';
  end if;
  if public.yui_user_suspended(new.user_id) then
    raise sqlstate 'PT403' using message = 'account_suspended';
  end if;
  return new;
end $$;
drop trigger if exists yui_vault_key_guard on public.yui_vault_keys;
create trigger yui_vault_key_guard before insert on public.yui_vault_keys
  for each row execute function public.yui_vault_key_guard();

create or replace function public.yui_vault_key_audit() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    insert into public.yui_vault_uses (user_id, key, kind, provider, key_name) values (new.user_id, new.id, 'add', new.provider, new.name);
    return new;
  elsif tg_op = 'UPDATE' then
    if new.cap_cents is distinct from old.cap_cents then
      insert into public.yui_vault_uses (user_id, key, kind, provider, key_name, path, cost_cents)
        values (new.user_id, new.id, 'cap', new.provider, new.name, old.cap_cents || '>' || new.cap_cents, new.cap_cents);
    end if;
    return new;
  end if;
  return old;
end $$;
drop trigger if exists yui_vault_key_audit on public.yui_vault_keys;
create trigger yui_vault_key_audit after insert or update on public.yui_vault_keys
  for each row execute function public.yui_vault_key_audit();

-- Removing a key ends every grant that used it (and tells those agents), then
-- leaves one 'remove' row. The cascade deletes the grants afterwards.
create or replace function public.yui_vault_key_remove() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform set_config('yui.vault_reason', 'removed', true);
  update public.yui_vault_grants set revoked_at = now() where key = old.id and revoked_at is null;
  perform set_config('yui.vault_reason', '', true);
  insert into public.yui_vault_uses (user_id, key, kind, provider, key_name) values (old.user_id, old.id, 'remove', old.provider, old.name);
  return old;
end $$;
drop trigger if exists yui_vault_key_remove on public.yui_vault_keys;
create trigger yui_vault_key_remove before delete on public.yui_vault_keys
  for each row execute function public.yui_vault_key_remove();

-- Grants: checks, handle, audit -----------------------------------------------
create or replace function public.yui_vault_grant_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
declare k public.yui_vault_keys; h text;
begin
  if tg_op = 'INSERT' then
    select * into k from public.yui_vault_keys where id = new.key;
    if not found then raise sqlstate 'PT404' using message = 'key_not_found'; end if;
    -- Only the agent's owner grants, and only their own keys: a person an agent
    -- is shared with cannot grant their keys to it, nor use the owner's.
    if not exists (select 1 from public.yui_agents a where a.id = new.agent_id and a.user_id = k.user_id) then
      raise sqlstate 'PT403' using message = 'not_your_agent';
    end if;
    if public.yui_user_suspended(k.user_id) then raise sqlstate 'PT403' using message = 'account_suspended'; end if;
    if not public.yui_vault_priced(k.provider) and not k.provider_limit_confirmed then
      raise sqlstate 'PT409' using message = 'provider_limit_unconfirmed';
    end if;
    if new.cap_cents is not null and new.cap_cents > k.cap_cents then
      raise sqlstate 'PT422' using message = 'grant_cap_above_key_cap';
    end if;
    new.revoked_at := null; new.last_used_at := null; new.lapse_warned_at := null;
    -- vk_<provider>_<4 hex>; a longer tail when the short ones run thin.
    for i in 1..40 loop
      h := 'vk_' || k.provider || '_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, case when i <= 12 then 4 else 6 end);
      exit when not exists (select 1 from public.yui_vault_grants where handle = h);
    end loop;
    new.handle := h;
    return new;
  end if;
  -- update: a revoke is final, the handle, key and agent never change.
  if old.revoked_at is not null and new.revoked_at is distinct from old.revoked_at then
    raise sqlstate 'PT409' using message = 'already_revoked';
  end if;
  if new.key <> old.key or new.agent_id <> old.agent_id or new.handle <> old.handle then
    raise sqlstate 'PT403' using message = 'grant_is_fixed';
  end if;
  if new.cap_cents is distinct from old.cap_cents and new.cap_cents is not null
     and new.cap_cents > (select cap_cents from public.yui_vault_keys where id = new.key) then
    raise sqlstate 'PT422' using message = 'grant_cap_above_key_cap';
  end if;
  return new;
end $$;
drop trigger if exists yui_vault_grant_guard on public.yui_vault_grants;
create trigger yui_vault_grant_guard before insert or update on public.yui_vault_grants
  for each row execute function public.yui_vault_grant_guard();

create or replace function public.yui_vault_grant_audit() returns trigger
language plpgsql security definer set search_path = '' as $$
declare k public.yui_vault_keys; why text := coalesce(nullif(current_setting('yui.vault_reason', true), ''), 'revoked');
begin
  select * into k from public.yui_vault_keys where id = new.key;
  if not found then return new; end if;
  if tg_op = 'INSERT' then
    insert into public.yui_vault_uses (user_id, key, agent_id, kind, provider, key_name, handle, path)
      values (k.user_id, k.id, new.agent_id, 'grant', k.provider, k.name, new.handle, new.purpose);
  elsif old.revoked_at is null and new.revoked_at is not null then
    insert into public.yui_vault_uses (user_id, key, agent_id, kind, provider, key_name, handle, error)
      values (k.user_id, k.id, new.agent_id, 'revoke', k.provider, k.name, new.handle, why);
    perform public.yui_vault_tell(k.user_id, new.agent_id,
      case why when 'lapsed' then format('[yui] Key access: %s lapsed after 90 days without a call.', k.provider)
               else format('[yui] Key access: %s revoked.', k.provider) end,
      jsonb_build_object('vault_op', 'revoke', 'provider', k.provider, 'handle', new.handle));
  elsif new.cap_cents is distinct from old.cap_cents then
    insert into public.yui_vault_uses (user_id, key, agent_id, kind, provider, key_name, handle, path, cost_cents)
      values (k.user_id, k.id, new.agent_id, 'cap', k.provider, k.name, new.handle, old.cap_cents || '>' || new.cap_cents, new.cap_cents);
  end if;
  return new;
end $$;
drop trigger if exists yui_vault_grant_audit on public.yui_vault_grants;
create trigger yui_vault_grant_audit after insert or update on public.yui_vault_grants
  for each row execute function public.yui_vault_grant_audit();

-- 4. The connector's round trip -------------------------------------------------
-- begin: every check, and the hold, in one locked statement sequence.
-- Returns {ok:true, use_id, provider, sealed (hex), key_id, user_id, agent_id}
-- or {ok:false, error}. Every refusal past "no such handle" leaves one use row
-- with allowed = false (the owner sees who tried what).
create or replace function public.yui_vault_begin(p_handle text, p_connector uuid, p_path text, p_path_ok boolean, p_est int)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  r record;
  est int := greatest(coalesce(p_est, 1), 1);
  month timestamptz := public.yui_vault_month();
  spent_key bigint; spent_grant bigint; uid bigint;
  err text;
begin
  select g.id as gid, g.agent_id, g.handle, g.cap_cents as gcap, g.once, g.created_at, g.revoked_at, g.last_used_at,
         k.id as kid, k.user_id, k.provider, k.name, k.sealed, k.key_id, k.cap_cents as kcap
    into r
    from public.yui_vault_grants g join public.yui_vault_keys k on k.id = g.key
   where g.handle = p_handle
   for update of k, g;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_granted'); end if;

  -- Lapse: 90 days with no call ends the grant.
  if r.revoked_at is null and coalesce(r.last_used_at, r.created_at) < now() - interval '90 days' then
    perform set_config('yui.vault_reason', 'lapsed', true);
    update public.yui_vault_grants set revoked_at = now() where id = r.gid;
    perform set_config('yui.vault_reason', '', true);
    r.revoked_at := now();
  end if;

  if r.revoked_at is not null then err := 'not_granted';
  elsif public.yui_user_suspended(r.user_id) then err := 'not_granted';
  -- The token must be of the connector that serves the agent the grant names,
  -- and that agent must be the key owner's own (never a shared one).
  elsif not exists (select 1 from public.yui_agents a
                     where a.id = r.agent_id and a.connector_id = p_connector and a.user_id = r.user_id) then err := 'not_granted';
  elsif not coalesce(p_path_ok, false) then err := 'path_not_allowed';
  elsif r.once and r.last_used_at is not null then err := 'once_used';
  else
    select coalesce(sum(cost_cents), 0) into spent_key from public.yui_vault_uses
     where key = r.kid and kind = 'call' and allowed and at >= month;
    select coalesce(sum(cost_cents), 0) into spent_grant from public.yui_vault_uses
     where handle = r.handle and kind = 'call' and allowed and at >= month;
    if spent_key + est > r.kcap or (r.gcap is not null and spent_grant + est > r.gcap) then err := 'cap_reached'; end if;
  end if;

  if err is not null then
    insert into public.yui_vault_uses (user_id, key, agent_id, kind, path, status, cost_cents, provider, key_name, handle, allowed, error)
      values (r.user_id, r.kid, r.agent_id, 'call', left(p_path, 200), null, 0, r.provider, r.name, r.handle, false, err);
    return jsonb_build_object('ok', false, 'error', err);
  end if;

  update public.yui_vault_grants set last_used_at = now(), lapse_warned_at = null where id = r.gid;
  insert into public.yui_vault_uses (user_id, key, agent_id, kind, path, status, cost_cents, provider, key_name, handle)
    values (r.user_id, r.kid, r.agent_id, 'call', left(p_path, 200), null, est, r.provider, r.name, r.handle)
    returning id into uid;
  return jsonb_build_object('ok', true, 'use_id', uid, 'provider', r.provider,
    'sealed', encode(r.sealed, 'hex'), 'key_id', r.key_id, 'user_id', r.user_id, 'agent_id', r.agent_id);
end $$;

-- finish: the hold becomes the real cost. Once only (a finished row stays put).
-- At 80% of the key's cap, one cap_80 row a month for the app to push.
create or replace function public.yui_vault_finish(p_use bigint, p_status int, p_cost int, p_error text default null)
returns void
language plpgsql security definer set search_path = '' as $$
declare u public.yui_vault_uses; total bigint; kcap int;
begin
  update public.yui_vault_uses set status = p_status, cost_cents = greatest(coalesce(p_cost, 0), 0), error = left(p_error, 60)
   where id = p_use and kind = 'call' and status is null and allowed
   returning * into u;
  if not found or u.key is null then return; end if;
  select cap_cents into kcap from public.yui_vault_keys where id = u.key;
  if kcap is null or kcap = 0 then return; end if;
  select coalesce(sum(cost_cents), 0) into total from public.yui_vault_uses
   where key = u.key and kind = 'call' and allowed and at >= public.yui_vault_month();
  if total * 100 >= kcap * 80 and not exists (
       select 1 from public.yui_vault_uses where key = u.key and kind = 'cap_80' and at >= public.yui_vault_month()) then
    insert into public.yui_vault_uses (user_id, key, kind, provider, key_name, path, cost_cents)
      values (u.user_id, u.key, 'cap_80', u.provider, u.key_name, total || '/' || kcap, total);
  end if;
end $$;

revoke all on function public.yui_vault_begin(text, uuid, text, boolean, int) from public, anon, authenticated, yui_user, yui_connector;
revoke all on function public.yui_vault_finish(bigint, int, int, text) from public, anon, authenticated, yui_user, yui_connector;
grant execute on function public.yui_vault_begin(text, uuid, text, boolean, int) to service_role;
grant execute on function public.yui_vault_finish(bigint, int, int, text) to service_role;
revoke all on function public.yui_vault_key_guard(), public.yui_vault_key_audit(), public.yui_vault_key_remove(),
  public.yui_vault_grant_guard(), public.yui_vault_grant_audit(), public.yui_vault_dollars(numeric),
  public.yui_vault_priced(text), public.yui_vault_month() from public, anon, authenticated;
grant execute on function public.yui_vault_month() to yui_user, service_role;

-- 5. key_ask and key_answer (control rows) ------------------------------------
-- key_ask, host to app: {v, req, op: 'key_ask', provider, for, est?, cap?}.
create or replace function public.yui_vault_ask_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
declare prov text := new.meta ->> 'provider'; why text := new.meta ->> 'for';
begin
  if prov is null or prov not in ('fal', 'replicate', 'elevenlabs', 'openrouter', 'anthropic', 'openai') then
    raise sqlstate 'PT400' using message = 'invalid_key_ask';
  end if;
  if why is null or length(why) not between 1 and 80
     or why ~ '(sk-[A-Za-z0-9_-]{16,}|r8_[A-Za-z0-9]{16,}|[0-9a-fA-F-]{8,}:[A-Za-z0-9]{16,})' then
    raise sqlstate 'PT400' using message = 'invalid_key_ask';
  end if;
  if new.meta ? 'cap' and jsonb_typeof(new.meta -> 'cap') <> 'number' then
    raise sqlstate 'PT400' using message = 'invalid_key_ask';
  end if;
  -- No nagging: a Don't allow holds for 24 hours. The ask never reaches the
  -- app; the agent is told once.
  if exists (select 1 from public.yui_vault_uses
              where user_id = new.user_id and agent_id = new.agent_id and kind = 'deny'
                and provider = prov and at > now() - interval '24 hours') then
    perform public.yui_vault_tell(new.user_id, new.agent_id,
      format('[yui] Key access: %s was declined today. Ask again tomorrow, or let them bring it up.', prov),
      jsonb_build_object('vault_op', 'key_declined_today', 'provider', prov, 'req', new.meta ->> 'req'));
    return null;
  end if;
  return new;
end $$;
drop trigger if exists yui_vault_ask_guard on public.yui_messages;
create trigger yui_vault_ask_guard before insert on public.yui_messages
  for each row when (new.kind = 'control' and new.sender = 'agent' and new.meta ->> 'op' = 'key_ask')
  execute function public.yui_vault_ask_guard();

-- key_answer, app to host: {v, req, op: 'key_answer', decision: allow|once|deny,
-- provider, handle?, cap}. It must answer a key_ask of this agent; the agent
-- hears one line per req, never the key.
create or replace function public.yui_vault_answer() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  m jsonb := new.meta;
  req text := m ->> 'req';
  decision text := m ->> 'decision';
  ask jsonb;
  prov text;
  why text;
  g record;
  cap numeric;
begin
  if req is null or decision not in ('allow', 'once', 'deny') then return new; end if;
  select a.meta into ask from public.yui_messages a
   where a.agent_id = new.agent_id and a.user_id = new.user_id and a.kind = 'control' and a.sender = 'agent'
     and a.meta ->> 'op' = 'key_ask' and a.meta ->> 'req' = req
   order by a.created_at desc limit 1;
  if ask is null then return new; end if;
  if exists (select 1 from public.yui_messages e
              where e.agent_id = new.agent_id and e.user_id = new.user_id and e.kind = 'event'
                and e.meta ->> 'vault_req' = req) then
    return new;
  end if;
  prov := ask ->> 'provider';
  why := replace(replace(coalesce(ask ->> 'for', ''), '"', ''''), E'\n', ' ');

  if decision = 'deny' then
    insert into public.yui_vault_uses (user_id, agent_id, kind, provider, path, allowed)
      values (new.user_id, new.agent_id, 'deny', prov, prov, false);
    perform public.yui_vault_tell(new.user_id, new.agent_id, format('[yui] Key access: %s not allowed.', prov),
      jsonb_build_object('vault_op', 'key_answer', 'vault_req', req, 'provider', prov));
    return new;
  end if;

  select gr.handle, gr.cap_cents, gr.once into g
    from public.yui_vault_grants gr join public.yui_vault_keys k on k.id = gr.key
   where gr.handle = m ->> 'handle' and gr.agent_id = new.agent_id and k.user_id = new.user_id
     and k.provider = prov and gr.revoked_at is null;
  if not found or g.once is distinct from (decision = 'once') then
    perform public.yui_vault_tell(new.user_id, new.agent_id, format('[yui] Key access: %s not allowed.', prov),
      jsonb_build_object('vault_op', 'key_answer', 'vault_req', req, 'provider', prov));
    return new;
  end if;
  cap := case when g.cap_cents is not null then g.cap_cents
              when jsonb_typeof(m -> 'cap') = 'number' then (m ->> 'cap')::numeric * 100 end;
  perform public.yui_vault_tell(new.user_id, new.agent_id,
    case when decision = 'once'
         then format('[yui] Key access: %s allowed once for "%s", handle %s.', prov, why, g.handle)
         when cap is null then format('[yui] Key access: %s allowed for "%s", handle %s.', prov, why, g.handle)
         else format('[yui] Key access: %s allowed for "%s", cap $%s a month, handle %s.', prov, why,
                     public.yui_vault_dollars(cap), g.handle) end,
    jsonb_build_object('vault_op', 'key_answer', 'vault_req', req, 'provider', prov, 'handle', g.handle));
  return new;
end $$;
drop trigger if exists yui_vault_answer on public.yui_messages;
create trigger yui_vault_answer after insert on public.yui_messages
  for each row when (new.kind = 'control' and new.sender = 'user' and new.meta ->> 'op' = 'key_answer')
  execute function public.yui_vault_answer();
revoke all on function public.yui_vault_ask_guard(), public.yui_vault_answer() from public, anon, authenticated;

-- 6. Lapse, heads-up, retention -------------------------------------------------
create or replace function public.yui_vault_sweep()
returns table(what text, n_rows bigint)
language plpgsql security definer set search_path = '' as $$
declare n bigint;
begin
  perform set_config('yui.vault_reason', 'lapsed', true);
  update public.yui_vault_grants set revoked_at = now()
   where revoked_at is null and coalesce(last_used_at, created_at) < now() - interval '90 days';
  get diagnostics n = row_count; what := 'vault_lapsed'; n_rows := n; return next;
  perform set_config('yui.vault_reason', '', true);
  -- Day 80: one lapse_soon row a grant, for the app to tell the person.
  with soon as (
    update public.yui_vault_grants g set lapse_warned_at = now()
      from public.yui_vault_keys k
     where k.id = g.key and g.revoked_at is null and g.lapse_warned_at is null
       and coalesce(g.last_used_at, g.created_at) < now() - interval '80 days'
     returning g.agent_id, g.handle, k.id as kid, k.user_id, k.provider, k.name)
  insert into public.yui_vault_uses (user_id, key, agent_id, kind, provider, key_name, handle)
    select user_id, kid, agent_id, 'lapse_soon', provider, name, handle from soon;
  get diagnostics n = row_count; what := 'vault_lapse_soon'; n_rows := n; return next;
  delete from public.yui_vault_grants where revoked_at < now() - interval '90 days';
  get diagnostics n = row_count; what := 'vault_old_grants'; n_rows := n; return next;
  delete from public.yui_vault_uses where at < now() - interval '90 days';
  get diagnostics n = row_count; what := 'vault_uses'; n_rows := n; return next;
end $$;
revoke all on function public.yui_vault_sweep() from public, anon, authenticated, yui_user, yui_connector;

create or replace function public.yui_retention(dry boolean default true)
returns table(what text, n_rows bigint)
language plpgsql security definer set search_path = '' as $$
declare
  cutoff timestamptz := now() - make_interval(days => public.yui_limit('message_retention_days')::int);
  revoked timestamptz := now() - interval '30 days';
  controls timestamptz := now() - interval '7 days';
  n bigint;
begin
  if dry then
    return query
      select 'messages'::text, count(*) from public.yui_messages where created_at < cutoff
      union all select 'pairings'::text, count(*) from public.yui_pairings where expires_at < now() - interval '1 day'
      union all select 'pair_attempts'::text, count(*) from public.yui_pair_attempts where created_at < now() - interval '1 day'
      union all select 'sessions'::text, count(*) from public.yui_sessions where expires_at < now() - interval '1 day'
      union all select 'rate_buckets'::text, count(*) from public.yui_rate_buckets where at < now() - interval '1 day'
      union all select 'oauth_requests'::text, count(*) from public.yui_oauth_requests where created_at < now() - interval '1 day'
      union all select 'oauth_tokens'::text, count(*) from public.yui_oauth_tokens where expires_at < now() - interval '1 day'
      union all select 'oauth_clients'::text, count(*) from public.yui_oauth_clients where last_used_at is null and created_at < now() - interval '1 day'
      union all select 'revoked_threads'::text, count(*) from public.yui_messages m
                 join public.yui_agent_grants g on g.agent_id = m.agent_id and g.user_id = m.user_id
                where g.revoked_at < revoked and m.created_at < g.revoked_at
      union all select 'revoked_grants'::text, count(*) from public.yui_agent_grants where revoked_at < revoked
      union all select 'control_rows'::text, count(*) from public.yui_messages where kind = 'control' and created_at < controls
      union all select 'vault_uses'::text, count(*) from public.yui_vault_uses where at < now() - interval '90 days'
      union all select 'vault_lapsed'::text, count(*) from public.yui_vault_grants
                 where revoked_at is null and coalesce(last_used_at, created_at) < now() - interval '90 days';
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
  delete from public.yui_oauth_requests where created_at < now() - interval '1 day';
  get diagnostics n = row_count; what := 'oauth_requests'; n_rows := n; return next;
  delete from public.yui_oauth_tokens where expires_at < now() - interval '1 day';
  get diagnostics n = row_count; what := 'oauth_tokens'; n_rows := n; return next;
  delete from public.yui_oauth_clients where last_used_at is null and created_at < now() - interval '1 day';
  get diagnostics n = row_count; what := 'oauth_clients'; n_rows := n; return next;
  -- The photos in it go with the next media sweep: nothing refers to them any more.
  delete from public.yui_messages m using public.yui_agent_grants g
   where g.agent_id = m.agent_id and g.user_id = m.user_id
     and g.revoked_at < revoked and m.created_at < g.revoked_at;
  get diagnostics n = row_count; what := 'revoked_threads'; n_rows := n; return next;
  delete from public.yui_agent_grants where revoked_at < revoked;
  get diagnostics n = row_count; what := 'revoked_grants'; n_rows := n; return next;
  -- Controls (YUI-70) are requests and answers, not history: a week is plenty.
  delete from public.yui_messages where kind = 'control' and created_at < controls;
  get diagnostics n = row_count; what := 'control_rows'; n_rows := n; return next;
  -- The key vault (YUI-34): lapsed grants end, day-80 heads-ups, uses after 90 days.
  return query select * from public.yui_vault_sweep();
end $$;
revoke all on function public.yui_retention(boolean) from public, anon, authenticated;

notify pgrst, 'reload schema';
