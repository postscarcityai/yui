-- YUI-7: Yui as a Hermes messaging platform. Spec: yuigui/spec/RELAY.md.
--
-- The agent host (a Mac running Hermes with the `yui` platform plugin) dials
-- out to PROOF. It never holds the service key. `yui-connect` trades the
-- host's connector token for a short-lived JWT with role = yui_connector:
--   sub = the paired user's yui_users.id
--   cid = the connector id
-- That role reads the user's messages and writes agent replies, and only in
-- threads of agents bound to its own, unrevoked connector.

-- Role --------------------------------------------------------------------
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'yui_connector') then
    create role yui_connector nologin noinherit;
  end if;
end $$;
grant yui_connector to authenticator;
grant usage on schema public to yui_connector;
grant execute on function public.yui_uid() to yui_connector;

create or replace function public.yui_cid() returns uuid
language sql stable
set search_path = ''
as $$
  select nullif(current_setting('request.jwt.claims', true)::json ->> 'cid', '')::uuid
$$;
revoke all on function public.yui_cid() from public, anon, authenticated;
grant execute on function public.yui_cid() to yui_connector, service_role;

-- True when the agent belongs to the caller's user and is bound to the
-- caller's connector, and that connector is not revoked. Security definer so
-- the policy can see yui_connectors.revoked_at without granting the table.
create or replace function public.yui_connector_serves(agent uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.yui_agents a
    join public.yui_connectors c on c.id = a.connector_id
    where a.id = agent
      and a.user_id = public.yui_uid()
      and c.id = public.yui_cid()
      and c.user_id = public.yui_uid()
      and c.revoked_at is null
  )
$$;
revoke all on function public.yui_connector_serves(uuid) from public, anon, authenticated;
grant execute on function public.yui_connector_serves(uuid) to yui_connector, service_role;

-- Messages: events and metadata -------------------------------------------
-- kind 'text': a chat message. For the agent, `body` may hold ```yui fenced
-- Yui Lines; the app renders those as presets.
-- kind 'event': a tap or submit from a preset. `body` is the line the agent
-- reads (`[yui] n1 ask answer=Yes`), `meta` the structured event
-- ({id, preset, value, echo}).
alter table public.yui_messages
  add column if not exists kind text not null default 'text',
  add column if not exists meta jsonb not null default '{}'::jsonb;
alter table public.yui_messages drop constraint if exists yui_messages_kind_check;
alter table public.yui_messages add constraint yui_messages_kind_check
  check (kind in ('text', 'event'));
alter table public.yui_messages drop constraint if exists yui_messages_body_check;
alter table public.yui_messages add constraint yui_messages_body_check
  check (length(body) between 1 and 32000);
create index if not exists yui_messages_thread_idx
  on public.yui_messages(agent_id, created_at);

-- The app writes only its own side of the thread.
drop policy if exists yui_messages_owner on public.yui_messages;
drop policy if exists yui_messages_user_read on public.yui_messages;
drop policy if exists yui_messages_user_write on public.yui_messages;
drop policy if exists yui_messages_user_delete on public.yui_messages;
create policy yui_messages_user_read on public.yui_messages for select to yui_user
  using (user_id = public.yui_uid());
create policy yui_messages_user_write on public.yui_messages for insert to yui_user
  with check (user_id = public.yui_uid() and sender = 'user' and agent_id is not null);
create policy yui_messages_user_delete on public.yui_messages for delete to yui_user
  using (user_id = public.yui_uid());
revoke update on public.yui_messages from yui_user;

-- The connector reads and writes only threads of agents it serves.
grant select on public.yui_messages to yui_connector;
grant insert (user_id, agent_id, sender, body, kind, meta) on public.yui_messages to yui_connector;
drop policy if exists yui_messages_connector_read on public.yui_messages;
drop policy if exists yui_messages_connector_write on public.yui_messages;
create policy yui_messages_connector_read on public.yui_messages for select to yui_connector
  using (user_id = public.yui_uid() and public.yui_connector_serves(agent_id));
create policy yui_messages_connector_write on public.yui_messages for insert to yui_connector
  with check (user_id = public.yui_uid() and sender = 'agent' and kind = 'text'
              and public.yui_connector_serves(agent_id));

-- The connector may see which of the user's agents it serves (not the rest).
grant select (id, user_id, name, handle, remote_ref, connector_id) on public.yui_agents to yui_connector;
drop policy if exists yui_agents_connector_read on public.yui_agents;
create policy yui_agents_connector_read on public.yui_agents for select to yui_connector
  using (user_id = public.yui_uid() and public.yui_connector_serves(id));

-- Channel guide -----------------------------------------------------------
-- The text every agent gets on the Yui channel (yuigui/spec/CHANNEL.md, from
-- "## You are talking to someone in Yui" to the end). Hermes bundles a copy
-- in the plugin; any other agent gets it from `yui-connect` at connect time.
-- Public product copy, but served through the function, not granted.
create table if not exists public.yui_channel_guides (
  version text primary key,
  body text not null,
  created_at timestamptz not null default now()
);
revoke all on public.yui_channel_guides from public, anon, authenticated;
alter table public.yui_channel_guides enable row level security;

-- Realtime ----------------------------------------------------------------
do $$ begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public'
                   and tablename = 'yui_messages') then
    alter publication supabase_realtime add table public.yui_messages;
  end if;
end $$;

notify pgrst, 'reload schema';
