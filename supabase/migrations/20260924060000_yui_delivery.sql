-- YUI-28: reliable connection. Messages survive a sleeping Mac, a dropped
-- network or a killed app, delivered in order, exactly once, both ways.
--
-- Inbound acks. The host marks each of the person's rows twice:
--   delivered_at  the host picked it up and handed it to the agent
--   handled_at    the agent's turn on it finished
-- A host that dies mid-turn leaves handled_at null, so the row is read again
-- on restart. The host may set only these two columns, only on the person's
-- rows, only in threads it serves.
--
-- Client ids. The host may choose the id of its own reply, so a resend after
-- a timeout hits the primary key (409) instead of writing the reply twice.
-- The app already chooses its own ids.
--
-- Honest presence. A host that stops cleanly says goodbye (yui-connect
-- action=bye, sets stopped_at); a heartbeat or session clears it. The agent
-- list gains `presence`: online (heartbeat in the last 2 minutes), asleep
-- (went quiet without a goodbye: the computer slept or lost its network),
-- offline (stopped or removed), pending (never paired). `status` stays for
-- older app builds, and no longer reads connected after a goodbye.

alter table public.yui_messages
  add column if not exists delivered_at timestamptz,
  add column if not exists handled_at timestamptz;

-- The host's work queue: the person's rows it has not finished.
create index if not exists yui_messages_unhandled_idx
  on public.yui_messages(agent_id, created_at)
  where sender = 'user' and handled_at is null;

grant insert (id) on public.yui_messages to yui_connector;
grant update (delivered_at, handled_at) on public.yui_messages to yui_connector;
drop policy if exists yui_messages_connector_ack on public.yui_messages;
create policy yui_messages_connector_ack on public.yui_messages for update to yui_connector
  using (user_id = public.yui_uid() and sender = 'user' and public.yui_connector_serves(agent_id))
  with check (user_id = public.yui_uid() and sender = 'user' and public.yui_connector_serves(agent_id));

alter table public.yui_connectors
  add column if not exists stopped_at timestamptz;
-- The agent list is security_invoker: the app reads the column it derives from.
grant select (stopped_at) on public.yui_connectors to yui_user;

-- New columns go last: create or replace view can only append.
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
       case
         when a.connector_id is null then 'pending'
         when c.revoked_at is not null or c.stopped_at is not null then 'offline'
         when c.last_seen_at > now() - interval '2 minutes' then 'online'
         else 'asleep'
       end as presence
from public.yui_agents a
left join public.yui_connectors c on c.id = a.connector_id;

notify pgrst, 'reload schema';
