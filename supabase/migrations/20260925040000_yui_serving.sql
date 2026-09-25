-- YUI-64: presence per agent. Spec: yuigui/spec/RELAY.md "Presence".
--
-- One connector token is one computer, and one computer runs a gateway per
-- Hermes profile. The heartbeat used to be per computer, so an agent whose
-- profile was paired but whose gateway never started read "online" while
-- nothing read its thread (TestFlight AMiI7ezKx6x1KcexlzOKYJc).
--
-- Now a gateway says which profiles it serves: yui-connect heartbeat, session
-- and bye carry `serving: ["<remote_ref>", ...]`, and `yui pair|add` send
-- `serving: []` (a CLI serves nothing). Any call with `serving` marks the
-- computer as one that reports it (yui_connectors.serving_at); every agent of
-- a profile named in it gets yui_agents.served_at = now().
--
-- yui_agents.bound_at: when the agent was last bound to its computer and
-- profile (the trigger below sets it and clears served_at). An agent with no
-- report since then has no gateway reading its thread yet: presence
-- `not_listening`, and the app names the one step left (restart that
-- profile's gateway).
--
-- Hosts that never report (older plugins, MCP, OpenClaw, webhooks) keep the
-- per-computer rules, unchanged.

alter table public.yui_agents
  add column if not exists served_at timestamptz,
  add column if not exists bound_at timestamptz;
alter table public.yui_connectors
  add column if not exists serving_at timestamptz;

-- The agent list is security_invoker: the app reads the columns it derives from.
grant select (serving_at) on public.yui_connectors to yui_user;

create or replace function public.yui_agent_bound() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.connector_id is not null and (tg_op = 'INSERT'
      or new.connector_id is distinct from old.connector_id
      or new.remote_ref is distinct from old.remote_ref) then
    new.bound_at := now();
    new.served_at := null;
  end if;
  return new;
end $$;

drop trigger if exists yui_agent_bound on public.yui_agents;
create trigger yui_agent_bound before insert or update of connector_id, remote_ref
  on public.yui_agents for each row execute function public.yui_agent_bound();

-- One rule for the app's list, mentions and anything else that asks:
--   pending        no computer yet
--   offline        host removed
--   not_listening  its computer reports serving, and no gateway has served it
--                  since it was paired
--   offline        the computer said goodbye
--   asleep         the computer went quiet without a goodbye
--   offline        its computer is up, but its own gateway stopped reporting
--   online         otherwise
-- Scalars, not rows: a whole-row connector would need select on token_hash.
create or replace function public.yui_presence(connector uuid, revoked_at timestamptz,
  stopped_at timestamptz, last_seen_at timestamptz, serving_at timestamptz,
  bound_at timestamptz, served_at timestamptz) returns text
language sql stable
set search_path = ''
as $$
  select case
    when connector is null then 'pending'
    when revoked_at is not null then 'offline'
    when serving_at is not null and bound_at is not null and served_at is null then 'not_listening'
    when stopped_at is not null then 'offline'
    when last_seen_at is null or last_seen_at <= now() - interval '2 minutes' then 'asleep'
    when serving_at > now() - interval '2 minutes' and served_at is not null
         and served_at <= now() - interval '2 minutes' then 'offline'
    else 'online'
  end
$$;

create or replace function public.yui_agent_presence(agent uuid) returns text
language sql stable security definer
set search_path = ''
as $$
  select public.yui_presence(a.connector_id, c.revoked_at, c.stopped_at, c.last_seen_at,
                             c.serving_at, a.bound_at, a.served_at)
  from public.yui_agents a
  left join public.yui_connectors c on c.id = a.connector_id
  where a.id = agent
$$;

-- Same columns, presence from the one rule. Old apps that don't know
-- not_listening fall back to `status`, which stays per computer.
create or replace view public.yui_agent_list with (security_invoker = true) as
select a.id, a.user_id, a.name, a.handle, a.color, a.avatar, a.theme, a.kind,
       a.connector_id, a.remote_ref, a.is_default, a.sort, a.created_at, a.updated_at,
       c.name as connector_name, c.last_seen_at,
       case
         when a.connector_id is null then 'pending'
         when c.revoked_at is null and c.stopped_at is null
              and c.last_seen_at > now() - interval '2 minutes' then 'connected'
         else 'offline'
       end as status,
       a.push_muted,
       public.yui_presence(a.connector_id, c.revoked_at, c.stopped_at, c.last_seen_at,
                           c.serving_at, a.bound_at, a.served_at) as presence,
       a.commands
from public.yui_agents a
left join public.yui_connectors c on c.id = a.connector_id;

-- A mention to an agent that isn't listening yet says so, like asleep does.
-- (YUI-44's function, one line added.)
create or replace function public.yui_mention_deliver(src public.yui_messages, target uuid, words text, by text)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  a public.yui_agents;
  b public.yui_agents;
  ctx text;
  presence text;
  status text;
begin
  select * into a from public.yui_agents where id = src.agent_id;
  select * into b from public.yui_agents where id = target and user_id = src.user_id;
  if b.id is null or b.id = a.id then
    return;
  end if;
  ctx := public.yui_mention_context(a.id, src.created_at, src.id);
  insert into public.yui_messages(user_id, agent_id, sender, kind, body, meta)
  values (src.user_id, b.id, 'user', 'text',
          left(format('[yui] mention from=%s by=%s msg=%s', a.handle, by, src.id)
               || case when ctx <> '' then E'\n' || a.name || E'''s thread, just before:\n' || ctx else '' end
               || E'\n' || coalesce(nullif(btrim(words), ''), '@' || b.handle), 32000),
          jsonb_build_object('mentioned', jsonb_build_object(
            'from', a.id, 'from_name', a.name, 'from_handle', a.handle,
            'msg', src.id, 'by', by, 'depth', 1)));
  presence := public.yui_agent_presence(b.id);
  status := case presence
    when 'asleep' then b.name || ' is asleep. It gets this when its computer wakes.'
    when 'offline' then b.name || ' is offline. It gets this when it''s back.'
    when 'pending' then b.name || ' isn''t connected yet. It gets this once it is.'
    when 'not_listening' then b.name || ' isn''t listening yet. It gets this once its gateway starts.'
    else case when b.push_muted then b.name || ' is muted. It still gets this, and its answer lands here quietly.' end
  end;
  if status is not null then
    -- A millisecond after the mention: same transaction, same now(), and the
    -- line must sort under the message it answers.
    insert into public.yui_messages(user_id, agent_id, sender, kind, body, meta, created_at)
    values (src.user_id, a.id, 'agent', 'text', status,
            jsonb_build_object('mention_reply', jsonb_build_object(
              'agent', b.id, 'name', b.name, 'handle', b.handle,
              'status', case when presence = 'online' then 'muted' else presence end, 'to', src.id)),
            src.created_at + interval '1 millisecond');
  end if;
end $$;

-- A gateway's report: the computer reports serving, and the profiles named
-- are served now. Called by yui-connect with the service role only.
create or replace function public.yui_serving(connector uuid, refs text[]) returns int
language plpgsql security definer
set search_path = ''
as $$
declare
  n int;
begin
  update public.yui_connectors set serving_at = now() where id = connector;
  update public.yui_agents set served_at = now()
   where connector_id = connector and remote_ref = any(coalesce(refs, '{}'));
  get diagnostics n = row_count;
  return n;
end $$;

-- A gateway's clean stop: its profiles read offline at once, and the whole
-- computer reads offline only when no other gateway on it still reports.
create or replace function public.yui_serving_bye(connector uuid, refs text[]) returns boolean
language plpgsql security definer
set search_path = ''
as $$
declare
  others boolean;
begin
  update public.yui_agents set served_at = now() - interval '2 minutes'
   where connector_id = connector and remote_ref = any(coalesce(refs, '{}')) and served_at is not null;
  select exists(select 1 from public.yui_agents
                 where connector_id = connector and served_at > now() - interval '2 minutes')
    into others;
  update public.yui_connectors set serving_at = now(), last_seen_at = now(),
         stopped_at = case when others then null else now() end
   where id = connector;
  return not others;
end $$;

revoke all on function public.yui_agent_bound() from public, anon, authenticated;
revoke all on function public.yui_presence(uuid, timestamptz, timestamptz, timestamptz, timestamptz, timestamptz, timestamptz) from public, anon, authenticated;
revoke all on function public.yui_agent_presence(uuid) from public, anon, authenticated;
revoke all on function public.yui_mention_deliver(public.yui_messages, uuid, text, text) from public, anon, authenticated;
revoke all on function public.yui_serving(uuid, text[]) from public, anon, authenticated, yui_user, yui_connector;
revoke all on function public.yui_serving_bye(uuid, text[]) from public, anon, authenticated, yui_user, yui_connector;
-- The list view calls yui_presence as the app's own role.
grant execute on function public.yui_presence(uuid, timestamptz, timestamptz, timestamptz, timestamptz, timestamptz, timestamptz) to yui_user;

notify pgrst, 'reload schema';
