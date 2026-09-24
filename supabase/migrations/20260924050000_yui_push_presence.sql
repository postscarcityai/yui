-- YUI-24: reply pushes only when they help.
--
-- Presence: the open app tells yui-push which thread is on screen
-- (action=presence) and repeats it every minute. notify skips a phone while it
-- is looking at that agent's thread, so an answer never rings twice (once in
-- the thread, once as a banner). A phone that went quiet for 90 seconds counts
-- as closed: a killed app always gets its push.
--
-- Mute: yui_agents.push_muted stops one agent's pushes on every phone. Set in
-- the agent's settings in the app (yui-agents update) or over PostgREST.

alter table public.yui_devices
  add column if not exists active_at timestamptz,
  add column if not exists active_agent_id uuid references public.yui_agents(id) on delete set null;

alter table public.yui_agents
  add column if not exists push_muted boolean not null default false;

grant update (push_muted) on public.yui_agents to yui_user;

-- New column goes last: create or replace view can only append.
create or replace view public.yui_agent_list with (security_invoker = true) as
select a.id, a.user_id, a.name, a.handle, a.color, a.avatar, a.theme, a.kind,
       a.connector_id, a.remote_ref, a.is_default, a.sort, a.created_at, a.updated_at,
       c.name as connector_name, c.last_seen_at,
       case
         when a.connector_id is null then 'pending'
         when c.revoked_at is null and c.last_seen_at > now() - interval '2 minutes' then 'connected'
         else 'offline'
       end as status,
       a.push_muted
from public.yui_agents a
left join public.yui_connectors c on c.id = a.connector_id;

notify pgrst, 'reload schema';
