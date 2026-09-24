-- YUI-15: agents are user-managed. Spec: yuigui/spec/AGENTS.md.
--
-- A connector is one agent host (a Mac running Hermes), paired once per
-- machine. An agent is one remote agent on that host (a Hermes profile).
-- Pairing codes, connector tokens and management tokens are stored as
-- SHA-256 hashes only, and every write that creates or binds an agent goes
-- through the `yui-agents` / `yui-connect` edge functions (service role).
-- The app's yui_user token may read its own registry and edit an agent's
-- cosmetic fields; it may not mint codes, bind connectors or see a hash.
-- Every table cascades from yui_users, so account deletion leaves zero rows.

-- Connectors ----------------------------------------------------------------
create table if not exists public.yui_connectors (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.yui_users(id) on delete cascade,
  name text not null,
  kind text not null default 'hermes' check (kind in ('hermes', 'http', 'mcp', 'hosted')),
  token_hash text not null unique,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz,
  revoked_at timestamptz,
  unique (id, user_id)
);
create index if not exists yui_connectors_user_idx on public.yui_connectors(user_id);

-- Agents: extend the YUI-6 table -------------------------------------------
alter table public.yui_agents
  add column if not exists handle text,
  add column if not exists color text not null default 'lavender',
  add column if not exists avatar text,
  add column if not exists theme jsonb not null default '{}'::jsonb,
  add column if not exists kind text not null default 'hermes',
  add column if not exists connector_id uuid,
  add column if not exists remote_ref text,
  add column if not exists is_default boolean not null default false,
  add column if not exists sort integer not null default 0,
  add column if not exists updated_at timestamptz not null default now();

update public.yui_agents
  set handle = coalesce(nullif(regexp_replace(lower(name), '[^a-z0-9]+', '-', 'g'), ''), 'agent')
               || case when row_number > 1 then '-' || row_number else '' end
  from (select id aid, row_number() over (partition by user_id, lower(name) order by created_at) row_number
        from public.yui_agents) r
  where r.aid = yui_agents.id and handle is null;
alter table public.yui_agents alter column handle set not null;

alter table public.yui_agents drop constraint if exists yui_agents_kind_check;
alter table public.yui_agents add constraint yui_agents_kind_check
  check (kind in ('hermes', 'http', 'mcp', 'hosted'));
alter table public.yui_agents drop constraint if exists yui_agents_handle_check;
alter table public.yui_agents add constraint yui_agents_handle_check
  check (handle ~ '^[a-z0-9][a-z0-9-]{0,31}$');
alter table public.yui_agents drop constraint if exists yui_agents_name_check;
alter table public.yui_agents add constraint yui_agents_name_check
  check (length(btrim(name)) between 1 and 40);
alter table public.yui_agents drop constraint if exists yui_agents_color_check;
alter table public.yui_agents add constraint yui_agents_color_check
  check (color in ('lavender', 'mint', 'butter', 'brand'));
alter table public.yui_agents drop constraint if exists yui_agents_remote_ref_check;
alter table public.yui_agents add constraint yui_agents_remote_ref_check
  check (remote_ref is null or remote_ref ~ '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$');

-- The connector must belong to the same user. Revoking/deleting a connector
-- leaves its agents in place, unbound (status goes back to pending).
alter table public.yui_agents drop constraint if exists yui_agents_connector_owner_fk;
alter table public.yui_agents add constraint yui_agents_connector_owner_fk
  foreign key (connector_id, user_id) references public.yui_connectors(id, user_id)
  on delete set null (connector_id);

create unique index if not exists yui_agents_handle_uq on public.yui_agents(user_id, handle);
create unique index if not exists yui_agents_one_default_uq on public.yui_agents(user_id) where is_default;
create unique index if not exists yui_agents_remote_uq on public.yui_agents(connector_id, remote_ref)
  where connector_id is not null;

create or replace function public.yui_touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end $$;
revoke all on function public.yui_touch_updated_at() from public, anon, authenticated;
drop trigger if exists yui_agents_touch on public.yui_agents;
create trigger yui_agents_touch before update on public.yui_agents
  for each row execute function public.yui_touch_updated_at();

-- Setting a default clears the old one, so "make default" is one write.
-- Runs as the caller: RLS keeps it inside the caller's own rows.
create or replace function public.yui_agents_single_default() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.is_default then
    update public.yui_agents set is_default = false
      where user_id = new.user_id and id <> new.id and is_default;
  end if;
  return new;
end $$;
revoke all on function public.yui_agents_single_default() from public, anon, authenticated;
drop trigger if exists yui_agents_single_default on public.yui_agents;
create trigger yui_agents_single_default before insert or update of is_default on public.yui_agents
  for each row when (new.is_default) execute function public.yui_agents_single_default();

-- Removing the default hands it to the first remaining agent. Skipped while
-- the whole account is being deleted.
create or replace function public.yui_agents_promote_default() returns trigger
language plpgsql set search_path = '' as $$
begin
  if old.is_default and exists (select 1 from public.yui_users where id = old.user_id) then
    update public.yui_agents set is_default = true
      where id = (select id from public.yui_agents where user_id = old.user_id
                  order by sort, created_at limit 1);
  end if;
  return null;
end $$;
revoke all on function public.yui_agents_promote_default() from public, anon, authenticated;
drop trigger if exists yui_agents_promote_default on public.yui_agents;
create trigger yui_agents_promote_default after delete on public.yui_agents
  for each row execute function public.yui_agents_promote_default();

-- Pairing codes: extend the YUI-6 table ------------------------------------
-- One row per 6-digit code. 10 minutes, single use. Only its hash is kept.
alter table public.yui_pairings
  add column if not exists used_at timestamptz,
  add column if not exists connector_id uuid;
update public.yui_pairings set expires_at = created_at + interval '10 minutes' where expires_at is null;
alter table public.yui_pairings alter column expires_at set default now() + interval '10 minutes';
alter table public.yui_pairings alter column expires_at set not null;
alter table public.yui_pairings drop constraint if exists yui_pairings_connector_owner_fk;
alter table public.yui_pairings add constraint yui_pairings_connector_owner_fk
  foreign key (connector_id, user_id) references public.yui_connectors(id, user_id)
  on delete set null (connector_id);
-- An unused code is unique across all users: the host looks it up without
-- knowing whose it is.
create unique index if not exists yui_pairings_open_code_uq on public.yui_pairings(code_hash)
  where used_at is null;

-- Failed code claims, per client address. Throttles guessing (server-only).
create table if not exists public.yui_pair_attempts (
  id bigint generated always as identity primary key,
  ip text not null,
  created_at timestamptz not null default now()
);
create index if not exists yui_pair_attempts_ip_idx on public.yui_pair_attempts(ip, created_at);

-- Management tokens (Settings > Agent access). Scope: manage agents only.
create table if not exists public.yui_mgmt_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.yui_users(id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 40),
  token_hash text not null unique,
  scope text not null default 'agents:manage' check (scope = 'agents:manage'),
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  revoked_at timestamptz
);
create index if not exists yui_mgmt_tokens_user_idx on public.yui_mgmt_tokens(user_id);

-- Agent list with derived status ------------------------------------------
-- pending: not bound to a host yet. connected: host heartbeat in the last
-- 2 minutes. offline: bound, but the host is silent or revoked.
create or replace view public.yui_agent_list with (security_invoker = true) as
select a.id, a.user_id, a.name, a.handle, a.color, a.avatar, a.theme, a.kind,
       a.connector_id, a.remote_ref, a.is_default, a.sort, a.created_at, a.updated_at,
       c.name as connector_name, c.last_seen_at,
       case
         when a.connector_id is null then 'pending'
         when c.revoked_at is null and c.last_seen_at > now() - interval '2 minutes' then 'connected'
         else 'offline'
       end as status
from public.yui_agents a
left join public.yui_connectors c on c.id = a.connector_id;

-- Grants --------------------------------------------------------------------
revoke all on public.yui_connectors, public.yui_pair_attempts, public.yui_mgmt_tokens,
  public.yui_agent_list from public, anon, authenticated;

-- Agents: read everything; edit cosmetic fields; delete. Creating and
-- binding go through the edge functions.
revoke insert, update on public.yui_agents from yui_user;
grant select, delete on public.yui_agents to yui_user;
grant update (name, color, avatar, theme, sort, is_default) on public.yui_agents to yui_user;

-- Pairings: read status only. Codes are minted and claimed server-side.
revoke all on public.yui_pairings from yui_user;
grant select (id, user_id, agent_id, connector_id, created_at, expires_at, used_at)
  on public.yui_pairings to yui_user;

-- Connectors: read without the hash; rename; revoke is an edge function call.
grant select (id, user_id, name, kind, created_at, last_seen_at, revoked_at)
  on public.yui_connectors to yui_user;
grant update (name) on public.yui_connectors to yui_user;

grant select on public.yui_agent_list to yui_user;
-- yui_mgmt_tokens and yui_pair_attempts: RLS on, no grants. Server only.

-- RLS -----------------------------------------------------------------------
alter table public.yui_connectors enable row level security;
alter table public.yui_pair_attempts enable row level security;
alter table public.yui_mgmt_tokens enable row level security;

drop policy if exists yui_connectors_owner on public.yui_connectors;
create policy yui_connectors_owner on public.yui_connectors for all to yui_user
  using (user_id = public.yui_uid()) with check (user_id = public.yui_uid());

notify pgrst, 'reload schema';
