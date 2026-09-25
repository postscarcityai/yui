-- INT-19: OAuth 2.1 for the Yui MCP server (functions/yui-oauth, spec
-- yuigui/spec/MCP.md "OAuth"). Clients that only speak OAuth (the Claude and
-- ChatGPT apps' custom connectors) register themselves (RFC 7591), send the
-- person through /authorize with PKCE, and trade the code for tokens.
--
-- A grant IS a connector: approving mints a kind-mcp yui_connectors row whose
-- own token_hash is a throwaway (nobody holds it), and every OAuth token points
-- at that row. So the connector's limits, its kill switch and "remove this
-- computer" in the app keep working unchanged: a revoked or suspended
-- connector makes every token on it dead at the next request.
--
-- All three tables are server-only: no grants to anon, authenticated,
-- yui_user or yui_connector. Only token hashes are stored.

-- Registered clients (dynamic client registration). Public clients (PKCE,
-- token_endpoint_auth_method none) have no secret; a client that asks for
-- client_secret_post/basic gets one, stored hashed.
create table if not exists public.yui_oauth_clients (
  id text primary key check (id ~ '^yui_oc_[A-Za-z0-9_-]{16,64}$'),
  name text not null check (length(btrim(name)) between 1 and 60),
  redirect_uris text[] not null check (cardinality(redirect_uris) between 1 and 10),
  client_uri text,
  logo_uri text,
  auth_method text not null default 'none'
    check (auth_method in ('none', 'client_secret_post', 'client_secret_basic')),
  secret_hash text,
  created_at timestamptz not null default now(),
  last_used_at timestamptz
);

-- One trip through /authorize. Pending until the person approves in the app
-- (hand-off) or types a pairing code on the web page; then it carries a
-- one-time code for /token, bound to the PKCE challenge.
create table if not exists public.yui_oauth_requests (
  id uuid primary key default gen_random_uuid(),
  client_id text not null references public.yui_oauth_clients(id) on delete cascade,
  redirect_uri text not null,
  state text,
  code_challenge text not null check (code_challenge ~ '^[A-Za-z0-9_-]{43}$'),
  scope text not null default 'yui',
  resource text,
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'denied', 'used')),
  user_id uuid references public.yui_users(id) on delete cascade,
  connector_id uuid,
  agent_id uuid,
  via text check (via in ('app', 'code')),
  code_hash text unique,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '15 minutes',
  decided_at timestamptz,
  code_expires_at timestamptz
);
create index if not exists yui_oauth_requests_created_idx on public.yui_oauth_requests(created_at);

-- Access and refresh tokens. A refresh token is single use: /token rotates it
-- and marks the old one used. Presenting a used one again revokes the whole
-- grant (the connector), as OAuth 2.1 asks for public clients.
create table if not exists public.yui_oauth_tokens (
  id uuid primary key default gen_random_uuid(),
  token_hash text not null unique,
  kind text not null check (kind in ('access', 'refresh')),
  client_id text not null references public.yui_oauth_clients(id) on delete cascade,
  user_id uuid not null references public.yui_users(id) on delete cascade,
  connector_id uuid not null references public.yui_connectors(id) on delete cascade,
  request_id uuid references public.yui_oauth_requests(id) on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz,
  revoked_at timestamptz
);
create index if not exists yui_oauth_tokens_connector_idx on public.yui_oauth_tokens(connector_id);
create index if not exists yui_oauth_tokens_request_idx on public.yui_oauth_tokens(request_id);

alter table public.yui_oauth_clients enable row level security;
alter table public.yui_oauth_requests enable row level security;
alter table public.yui_oauth_tokens enable row level security;
revoke all on public.yui_oauth_clients, public.yui_oauth_requests, public.yui_oauth_tokens
  from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'yui_user') then
    revoke all on public.yui_oauth_clients, public.yui_oauth_requests, public.yui_oauth_tokens from yui_user;
  end if;
  if exists (select 1 from pg_roles where rolname = 'yui_connector') then
    revoke all on public.yui_oauth_clients, public.yui_oauth_requests, public.yui_oauth_tokens from yui_connector;
  end if;
end $$;
grant all on public.yui_oauth_clients, public.yui_oauth_requests, public.yui_oauth_tokens to service_role;

-- Registration and the token endpoint are open to the internet: their own
-- bucket per client address.
insert into public.yui_limits (name, value, note) values
  ('oauth_burst',   30, 'OAuth register/authorize/token calls one address can make at once'),
  ('oauth_per_min', 10, 'sustained OAuth calls per address per minute')
on conflict (name) do update set value = excluded.value, note = excluded.note;

-- Retention (runs daily inside cron yui-media-sweep): connect requests after a
-- day, tokens a day after they expire (spent refresh tokens stay until then:
-- the reuse check needs them), and registrations that never got a token.
create or replace function public.yui_retention(dry boolean default true)
returns table(what text, n_rows bigint)
language plpgsql security definer set search_path = '' as $$
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
      union all select 'rate_buckets'::text, count(*) from public.yui_rate_buckets where at < now() - interval '1 day'
      union all select 'oauth_requests'::text, count(*) from public.yui_oauth_requests where created_at < now() - interval '1 day'
      union all select 'oauth_tokens'::text, count(*) from public.yui_oauth_tokens where expires_at < now() - interval '1 day'
      union all select 'oauth_clients'::text, count(*) from public.yui_oauth_clients where last_used_at is null and created_at < now() - interval '1 day';
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
end $$;
revoke all on function public.yui_retention(boolean) from public, anon, authenticated;
