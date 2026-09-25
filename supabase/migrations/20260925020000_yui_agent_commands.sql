-- YUI-61: slash commands in the composer. Spec: yuigui/spec/AGENTS.md "Commands".
--
-- yui_agents.commands: what the agent's host accepts as a /command, as its
-- plugin reports it through yui-connect (action=commands) on gateway start,
-- on pair and whenever the list changes:
--   [{"name": "new", "description": "Start a new session", "args": "[name]"}, ...]
-- null = the host reports no registry (MCP, OpenClaw, webhook, pending): the
-- app shows no suggestions. Only the service role writes it (yui-connect
-- cleans every entry); the app reads it through yui_agent_list.

alter table public.yui_agents
  add column if not exists commands jsonb,
  add column if not exists commands_at timestamptz;

alter table public.yui_agents drop constraint if exists yui_agents_commands_check;
alter table public.yui_agents add constraint yui_agents_commands_check
  check (commands is null or (jsonb_typeof(commands) = 'array' and pg_column_size(commands) <= 32768));

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
       end as presence,
       a.commands
from public.yui_agents a
left join public.yui_connectors c on c.id = a.connector_id;

notify pgrst, 'reload schema';
