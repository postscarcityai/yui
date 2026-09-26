-- YUI-70 step 2: agent controls in the drawer. Spec: yuigui spec/CONTROLS.md
-- (section 5, "Relay changes").
--
-- A control is one yui_messages row with kind = 'control': the app asks
-- (sender user: list, get, put, act or delete on one section of the agent's
-- settings) and the host answers (sender agent, same meta.req). They never
-- enter the thread, never start an agent turn and never push.
--
-- 1. The kind, and room in meta for a 32 KB SOUL.md or SKILL.md.
-- 2. Only the agent's owner inserts one: a person an agent is shared with
--    reads and writes its thread, never its controls. The host answers only
--    the owner (the connector's user) too.
-- 3. yui_agents.controls: the host's capability report, written only by the
--    service role through yui-connect (action=controls), read by the app with
--    the agent list. Null: the host shares no settings (every non-Hermes host
--    today), so the tab shows About and one line.
-- 4. Retention: control rows are deleted after 7 days (yui_retention).
--    Push: yui-push refuses a control row (function code, same release).

-- 1.
alter table public.yui_messages drop constraint if exists yui_messages_kind_check;
alter table public.yui_messages add constraint yui_messages_kind_check
  check (kind in ('text', 'event', 'control'));

alter table public.yui_messages drop constraint if exists yui_messages_meta_check;
alter table public.yui_messages add constraint yui_messages_meta_check
  check (jsonb_typeof(meta) = 'object'
         and pg_column_size(meta) <= case when kind = 'control' then 65536 else 16384 end);

-- 2. Restrictive: it narrows the existing insert policies, it does not widen them.
drop policy if exists yui_messages_control_owner on public.yui_messages;
create policy yui_messages_control_owner on public.yui_messages as restrictive
  for insert to yui_user
  with check (kind <> 'control' or (thread_id is null and public.yui_owns_agent(agent_id)));

drop policy if exists yui_messages_connector_write on public.yui_messages;
create policy yui_messages_connector_write on public.yui_messages for insert to yui_connector
  with check (sender = 'agent' and public.yui_connector_serves(agent_id)
              and ((kind = 'text'
                    and (user_id = public.yui_uid() or created_at >= public.yui_grant_serves(agent_id, user_id)))
                   or (kind = 'control' and user_id = public.yui_uid())));

-- 3.
alter table public.yui_agents
  add column if not exists controls jsonb,
  add column if not exists controls_at timestamptz;
alter table public.yui_agents drop constraint if exists yui_agents_controls_check;
alter table public.yui_agents add constraint yui_agents_controls_check
  check (controls is null or (jsonb_typeof(controls) = 'object' and pg_column_size(controls) <= 4096));

-- New columns go last: create or replace view can only append.
create or replace view public.yui_agent_list with (security_invoker = true) as
  select a.id, a.user_id, a.name, a.handle, a.color, a.avatar, a.theme, a.kind, a.connector_id,
         a.remote_ref, a.is_default, a.sort, a.created_at, a.updated_at,
         c.name as connector_name, c.last_seen_at,
         case when a.connector_id is null then 'pending'
              when c.revoked_at is null and c.stopped_at is null
                   and c.last_seen_at > now() - interval '2 minutes' then 'connected'
              else 'offline' end as status,
         a.push_muted,
         public.yui_presence(a.connector_id, c.revoked_at, c.stopped_at, c.last_seen_at, c.serving_at,
                             a.bound_at, a.served_at) as presence,
         a.commands,
         false as shared,
         null::text as shared_by,
         null::text as first_message,
         a.client_safe,
         case when a.client_safe then '[]'::jsonb else public.yui_share_why(a.id) end as share_why,
         a.controls
    from public.yui_agents a
    left join public.yui_connectors c on c.id = a.connector_id
  union all
  select a.id, g.user_id, a.name, a.handle, a.color, a.avatar, a.theme || g.theme, a.kind, a.connector_id,
         null::text, false, g.sort, g.granted_at, a.updated_at,
         null::text, c.last_seen_at,
         case when a.connector_id is null then 'pending'
              when c.revoked_at is null and c.stopped_at is null
                   and c.last_seen_at > now() - interval '2 minutes' then 'connected'
              else 'offline' end,
         g.push_muted,
         case when not a.client_safe then 'paused'
              else public.yui_presence(a.connector_id, c.revoked_at, c.stopped_at, c.last_seen_at, c.serving_at,
                                       a.bound_at, a.served_at) end,
         null::jsonb,
         true,
         g.shared_by,
         g.first_message,
         a.client_safe,
         null::jsonb,
         null::jsonb  -- a person an agent is shared with never gets its Controls
    from public.yui_agent_grants g
    join public.yui_agents a on a.id = g.agent_id
    left join public.yui_connectors c on c.id = a.connector_id
   where g.revoked_at is null
     and g.user_id = coalesce(public.yui_uid(), g.user_id);

-- 4.
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
      union all select 'control_rows'::text, count(*) from public.yui_messages where kind = 'control' and created_at < controls;
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
end $$;
revoke all on function public.yui_retention(boolean) from public, anon, authenticated;

notify pgrst, 'reload schema';
