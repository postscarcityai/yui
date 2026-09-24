-- YUI-6: Yui accounts in PROOF, isolated from the PSAI portal.
--
-- PROOF's portal tables grant ALL to `authenticated` and are protected only by
-- disabled signups. Yui users therefore never touch Supabase Auth: the
-- `yui-auth` edge function verifies Sign in with Apple and mints a short-lived
-- JWT with role = yui_user. That role can reach yui_* tables only, and RLS
-- keys every row to the token's `sub` (= yui_users.id).

-- Role --------------------------------------------------------------------
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'yui_user') then
    create role yui_user nologin noinherit;
  end if;
end $$;
grant yui_user to authenticator;
grant usage on schema public to yui_user;

-- Caller id from the PostgREST JWT claims. Not auth.uid(): yui_user has no
-- access to the auth schema, and Yui ids are not auth.users ids.
create or replace function public.yui_uid() returns uuid
language sql stable
set search_path = ''
as $$
  select nullif(current_setting('request.jwt.claims', true)::json ->> 'sub', '')::uuid
$$;
revoke all on function public.yui_uid() from public, anon, authenticated;
grant execute on function public.yui_uid() to yui_user, service_role;

-- Tables ------------------------------------------------------------------
create table if not exists public.yui_users (
  id uuid primary key default gen_random_uuid(),
  apple_sub text not null unique,
  email text,
  email_is_private_relay boolean not null default false,
  created_at timestamptz not null default now(),
  last_sign_in_at timestamptz not null default now()
);

-- Server-only: Apple refresh token (for revocation on delete) and our own
-- refresh sessions. yui_user gets no grant on either.
create table if not exists public.yui_apple_tokens (
  user_id uuid primary key references public.yui_users(id) on delete cascade,
  refresh_token text not null,
  updated_at timestamptz not null default now()
);

create table if not exists public.yui_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.yui_users(id) on delete cascade,
  refresh_hash text not null unique,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked_at timestamptz
);
create index if not exists yui_sessions_user_idx on public.yui_sessions(user_id);

-- Relay tables. YUI-7 extends these; the account layer only needs every one
-- of them to hang off yui_users with ON DELETE CASCADE.
create table if not exists public.yui_devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.yui_users(id) on delete cascade,
  name text,
  apns_token text,
  created_at timestamptz not null default now()
);
create index if not exists yui_devices_user_idx on public.yui_devices(user_id);

create table if not exists public.yui_agents (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.yui_users(id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now(),
  unique (id, user_id)
);
create index if not exists yui_agents_user_idx on public.yui_agents(user_id);

create table if not exists public.yui_pairings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.yui_users(id) on delete cascade,
  agent_id uuid,
  code_hash text,
  created_at timestamptz not null default now(),
  expires_at timestamptz
);
-- (agent_id, user_id) so a row can only point at its owner's agent.
alter table public.yui_pairings drop constraint if exists yui_pairings_agent_owner_fk;
alter table public.yui_pairings add constraint yui_pairings_agent_owner_fk
  foreign key (agent_id, user_id) references public.yui_agents(id, user_id) on delete cascade;
create index if not exists yui_pairings_user_idx on public.yui_pairings(user_id);

create table if not exists public.yui_messages (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.yui_users(id) on delete cascade,
  agent_id uuid,
  sender text not null check (sender in ('user', 'agent')),
  body text not null,
  created_at timestamptz not null default now()
);
alter table public.yui_messages drop constraint if exists yui_messages_agent_owner_fk;
alter table public.yui_messages add constraint yui_messages_agent_owner_fk
  foreign key (agent_id, user_id) references public.yui_agents(id, user_id) on delete cascade;
create index if not exists yui_messages_user_idx on public.yui_messages(user_id, created_at);

-- Grants ------------------------------------------------------------------
-- Supabase's default privileges hand every new public table to anon and
-- authenticated. Take that back on every account table.
revoke all on public.yui_users, public.yui_apple_tokens, public.yui_sessions,
  public.yui_devices, public.yui_agents, public.yui_pairings, public.yui_messages
  from public, anon, authenticated;

grant select on public.yui_users to yui_user;
grant select, insert, update, delete on public.yui_devices, public.yui_agents,
  public.yui_pairings, public.yui_messages to yui_user;

-- RLS ---------------------------------------------------------------------
alter table public.yui_users enable row level security;
alter table public.yui_apple_tokens enable row level security;
alter table public.yui_sessions enable row level security;
alter table public.yui_devices enable row level security;
alter table public.yui_agents enable row level security;
alter table public.yui_pairings enable row level security;
alter table public.yui_messages enable row level security;

drop policy if exists yui_users_self on public.yui_users;
create policy yui_users_self on public.yui_users for select to yui_user
  using (id = public.yui_uid());

drop policy if exists yui_devices_owner on public.yui_devices;
create policy yui_devices_owner on public.yui_devices for all to yui_user
  using (user_id = public.yui_uid()) with check (user_id = public.yui_uid());

drop policy if exists yui_agents_owner on public.yui_agents;
create policy yui_agents_owner on public.yui_agents for all to yui_user
  using (user_id = public.yui_uid()) with check (user_id = public.yui_uid());

drop policy if exists yui_pairings_owner on public.yui_pairings;
create policy yui_pairings_owner on public.yui_pairings for all to yui_user
  using (user_id = public.yui_uid()) with check (user_id = public.yui_uid());

drop policy if exists yui_messages_owner on public.yui_messages;
create policy yui_messages_owner on public.yui_messages for all to yui_user
  using (user_id = public.yui_uid()) with check (user_id = public.yui_uid());
-- yui_apple_tokens and yui_sessions: RLS on, no policies, no grants. Only
-- service_role (edge functions) reads them.

notify pgrst, 'reload schema';
