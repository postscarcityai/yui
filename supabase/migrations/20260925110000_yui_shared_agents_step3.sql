-- YUI-97, step 3 of YUI-57 (spec yuigui spec/AGENTS.md "Shared agents").
-- 1. The owner's settings sheet says "Safe to share" or "Not safe to share:
--    <rule>": the list carries the rules an owned agent breaks (share_why).
-- 2. Photos in a shared thread: the client uploads into their own folder for
--    an agent they hold a live grant for, and the host reads those and writes
--    the agent's pictures into that folder while the grant serves.
-- 3. 30 days after a revoke, the thread is deleted (yui_retention).

-- 1. The rules an agent breaks, from its host's last sandbox report. Only to
-- its owner (or the service role, which yui-agents reads the list with): a
-- client's row never carries its host's details.
create or replace function public.yui_share_why(agent uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(a.sandbox -> 'why', '["no sandbox report from its host yet"]'::jsonb)
    from public.yui_agents a
   where a.id = agent and (a.user_id = public.yui_uid() or public.yui_uid() is null)
$$;
revoke all on function public.yui_share_why(uuid) from public, anon, authenticated;
grant execute on function public.yui_share_why(uuid) to yui_user;

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
         case when a.client_safe then '[]'::jsonb else public.yui_share_why(a.id) end as share_why
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
         null::jsonb
    from public.yui_agent_grants g
    join public.yui_agents a on a.id = g.agent_id
    left join public.yui_connectors c on c.id = a.connector_id
   where g.revoked_at is null
     and g.user_id = coalesce(public.yui_uid(), g.user_id);  -- an owner's token never lists its clients' rows

-- 2. Media in a shared thread. The object's first segment is the thread's
-- person; for a client that is not the host's owner, so the host's read and
-- write need the live grant (while the agent is client-safe), exactly as its
-- messages do.
create or replace function public.yui_media_grant_serves(name text) returns boolean
language sql stable security definer set search_path = '' as $$
  select case when public.yui_media_agent($1) is null then false
              else public.yui_grant_serves(public.yui_media_agent($1), split_part($1, '/', 1)::uuid) is not null end
$$;
revoke all on function public.yui_media_grant_serves(text) from public, anon, authenticated;
grant execute on function public.yui_media_grant_serves(text) to yui_connector;

drop policy if exists yui_media_connector_read on storage.objects;
create policy yui_media_connector_read on storage.objects for select to yui_connector
  using (bucket_id = 'yui-media'
         and (split_part(name, '/', 1) = public.yui_uid()::text or public.yui_media_grant_serves(name))
         and public.yui_connector_serves(public.yui_media_agent(name)));
drop policy if exists yui_media_connector_write on storage.objects;
create policy yui_media_connector_write on storage.objects for insert to yui_connector
  with check (bucket_id = 'yui-media'
              and (split_part(name, '/', 1) = public.yui_uid()::text or public.yui_media_grant_serves(name))
              and split_part(name, '/', 3) = 'agent'
              and public.yui_connector_serves(public.yui_media_agent(name))
              and public.yui_media_quota_ok(name));

-- The client: their own folder, for an agent they own or hold a live grant for.
drop policy if exists yui_media_user_write on storage.objects;
create policy yui_media_user_write on storage.objects for insert to yui_user
  with check (bucket_id = 'yui-media' and split_part(name, '/', 1) = public.yui_uid()::text
              and split_part(name, '/', 3) = 'user'
              and (public.yui_owns_agent(public.yui_media_agent(name))
                   or public.yui_granted(public.yui_media_agent(name), public.yui_uid()))
              and exists (select 1 from public.yui_users u
                          where u.id = public.yui_uid() and u.suspended_at is null)
              and public.yui_media_quota_ok(name));

-- 3. Retention: a revoked thread is hidden at once and deleted 30 days later
-- (every row from before the revoke, then the grant itself). A later grant of
-- the same agent reads only rows from its own start, so nothing of it is lost.
create or replace function public.yui_retention(dry boolean default true)
returns table(what text, n_rows bigint)
language plpgsql security definer set search_path = '' as $$
declare
  cutoff timestamptz := now() - make_interval(days => public.yui_limit('message_retention_days')::int);
  revoked timestamptz := now() - interval '30 days';
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
      union all select 'revoked_grants'::text, count(*) from public.yui_agent_grants where revoked_at < revoked;
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
end $$;
revoke all on function public.yui_retention(boolean) from public, anon, authenticated;
