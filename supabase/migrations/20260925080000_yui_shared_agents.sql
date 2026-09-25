-- YUI-95: shared agents, step 2 of YUI-57 (spec yuigui spec/AGENTS.md, "Shared agents").
-- An owner lets someone else talk to one of their agents: a grant. The client
-- gets their own thread with it, keyed (agent_id, user_id) like any other,
-- in the look the owner picked, with a first message waiting. Only an agent
-- whose host reports it client-safe can be granted (yui-connect sets
-- client_safe from the heartbeat's sandbox report); the database refuses
-- anything else, so neither yui-auth nor a hand-written query can skip it.

-- 1. The client-safe mark, written only by the service role (yui-connect).
alter table public.yui_agents
  add column client_safe boolean not null default false,
  add column sandbox jsonb check (sandbox is null or (jsonb_typeof(sandbox) = 'object' and pg_column_size(sandbox) <= 4096)),
  add column client_safe_at timestamptz;
grant select (client_safe, client_safe_at) on public.yui_agents to yui_user;

-- Whose template an invite names (the name alone is unique per owner only).
alter table public.yui_invites
  add column template_owner uuid references public.yui_users(id) on delete set null;

-- 2. Templates: named sets of the owner's agents to hand out together.
create table public.yui_agent_templates (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.yui_users(id) on delete cascade,
  name text not null check (name ~ '^[a-z0-9][a-z0-9-]{0,39}$'),
  title text not null check (char_length(title) between 1 and 60),
  shared_by text check (char_length(btrim(shared_by)) between 1 and 40),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (owner_id, name)
);
create table public.yui_agent_template_items (
  template_id uuid not null references public.yui_agent_templates(id) on delete cascade,
  agent_id uuid not null,
  owner_id uuid not null,
  theme jsonb not null default '{}' check (jsonb_typeof(theme) = 'object' and pg_column_size(theme) <= 2048),
  first_message text check (char_length(first_message) between 1 and 2000),
  sort int not null default 0,
  primary key (template_id, agent_id),
  foreign key (agent_id, owner_id) references public.yui_agents(id, user_id) on delete cascade
);

-- 3. Grants: one person may talk to one of the owner's agents.
create table public.yui_agent_grants (
  id uuid primary key default gen_random_uuid(),
  agent_id uuid not null,
  owner_id uuid not null,
  user_id uuid not null references public.yui_users(id) on delete cascade,
  role text not null default 'user' check (role in ('user')),
  theme jsonb not null default '{}' check (jsonb_typeof(theme) = 'object' and pg_column_size(theme) <= 2048),
  first_message text check (char_length(first_message) between 1 and 2000),
  shared_by text check (char_length(btrim(shared_by)) between 1 and 40),
  template text check (template ~ '^[a-z0-9][a-z0-9-]{0,39}$'),
  invite_id uuid references public.yui_invites(id) on delete set null,
  push_muted boolean not null default false,
  sort int not null default 0,
  granted_at timestamptz not null default now(),
  revoked_at timestamptz,
  foreign key (agent_id, owner_id) references public.yui_agents(id, user_id) on delete cascade,
  check (user_id <> owner_id)
);
create unique index yui_agent_grants_live on public.yui_agent_grants (agent_id, user_id)
  where revoked_at is null;
create index yui_agent_grants_user on public.yui_agent_grants (user_id) where revoked_at is null;
create index yui_agent_grants_owner on public.yui_agent_grants (owner_id);

revoke all on public.yui_agent_templates, public.yui_agent_template_items, public.yui_agent_grants
  from public, anon, authenticated;
alter table public.yui_agent_templates enable row level security;
alter table public.yui_agent_template_items enable row level security;
alter table public.yui_agent_grants enable row level security;

create trigger yui_agent_templates_touch before update on public.yui_agent_templates
  for each row execute function public.yui_touch_updated_at();

-- A template item or a grant names only a client-safe agent. There is no way around it.
create function public.yui_client_safe_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_table_name = 'yui_agent_grants' and tg_op = 'UPDATE' and new.agent_id = old.agent_id then
    return new;  -- mute, order, revoke: not a new grant
  end if;
  if not exists (select 1 from public.yui_agents a where a.id = new.agent_id and a.client_safe) then
    raise sqlstate '42501' using message = 'agent_not_client_safe',
      hint = 'Only an agent its host reports client-safe can be shared (spec/AGENTS.md, Client-safe).';
  end if;
  return new;
end $$;
create trigger yui_client_safe_guard before insert or update of agent_id on public.yui_agent_template_items
  for each row execute function public.yui_client_safe_guard();
create trigger yui_client_safe_guard before insert or update of agent_id on public.yui_agent_grants
  for each row execute function public.yui_client_safe_guard();

-- True while the user holds a live grant for the agent.
create function public.yui_granted(agent uuid, uid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.yui_agent_grants g
                  where g.agent_id = agent and g.user_id = uid and g.revoked_at is null)
$$;
-- When the live grant began (null: none). A thread shows only rows from then
-- on, so granting an agent again after a revoke starts a new, empty thread.
create function public.yui_grant_since(agent uuid, uid uuid) returns timestamptz
language sql stable security definer set search_path = '' as $$
  select g.granted_at from public.yui_agent_grants g
   where g.agent_id = agent and g.user_id = uid and g.revoked_at is null
$$;
-- The host may serve a granted thread only while the grant is live AND the
-- agent is client-safe right now. An agent that stops passing pauses every grant.
create function public.yui_grant_serves(agent uuid, uid uuid) returns timestamptz
language sql stable security definer set search_path = '' as $$
  select g.granted_at from public.yui_agent_grants g
    join public.yui_agents a on a.id = g.agent_id
   where g.agent_id = agent and g.user_id = uid and g.revoked_at is null and a.client_safe
$$;
revoke all on function public.yui_granted(uuid, uuid), public.yui_grant_since(uuid, uuid), public.yui_grant_serves(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.yui_granted(uuid, uuid), public.yui_grant_since(uuid, uuid), public.yui_grant_serves(uuid, uuid)
  to yui_user, yui_connector;

-- The app: a person reads their own live grants and may change only mute and order.
grant select on public.yui_agent_grants to yui_user;
grant update (push_muted, sort) on public.yui_agent_grants to yui_user;
create policy yui_grants_holder on public.yui_agent_grants for select to yui_user
  using (user_id = public.yui_uid() and revoked_at is null);
create policy yui_grants_holder_edit on public.yui_agent_grants for update to yui_user
  using (user_id = public.yui_uid() and revoked_at is null)
  with check (user_id = public.yui_uid() and revoked_at is null);
-- The owner reads the grants they gave (who has which agent), never the threads.
create policy yui_grants_owner on public.yui_agent_grants for select to yui_user
  using (owner_id = public.yui_uid());
-- Templates are read and written only by the service role (grant.py, yui-auth).

-- 4. Messages: a row's (agent_id, user_id) was the agent's owner by a composite
-- foreign key. Now: the owner, or someone holding a live grant, by a trigger.
alter table public.yui_messages drop constraint yui_messages_agent_owner_fk;
alter table public.yui_messages add constraint yui_messages_agent_fk
  foreign key (agent_id) references public.yui_agents(id) on delete cascade;
create index if not exists yui_messages_agent_user on public.yui_messages (agent_id, user_id, created_at);

create function public.yui_messages_owner() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.yui_agents a where a.id = new.agent_id and a.user_id = new.user_id) then
    return new;
  end if;
  if not public.yui_granted(new.agent_id, new.user_id) then
    raise sqlstate '23503' using message = 'agent_not_yours';
  end if;
  -- A shared thread stands alone: no groups, no mentions in or out. The
  -- owner's other agents are not the client's, and the client's are not the owner's.
  if new.thread_id is not null or new.meta ? 'mention' or new.meta ? 'mentioned' then
    raise sqlstate '22023' using message = 'not_in_a_shared_thread';
  end if;
  new.meta := new.meta - 'mentions' - 'mention_reply';
  return new;
end $$;
create trigger yui_messages_owner before insert or update of agent_id, user_id on public.yui_messages
  for each row execute function public.yui_messages_owner();

-- The person: their own rows, in threads of agents they own or hold a live grant
-- for (from the moment it was granted).
drop policy yui_messages_user_read on public.yui_messages;
drop policy yui_messages_user_write on public.yui_messages;
drop policy yui_messages_user_delete on public.yui_messages;
create policy yui_messages_user_read on public.yui_messages for select to yui_user
  using (user_id = public.yui_uid()
         and (public.yui_owns_agent(agent_id) or created_at >= public.yui_grant_since(agent_id, public.yui_uid())));
create policy yui_messages_user_write on public.yui_messages for insert to yui_user
  with check (user_id = public.yui_uid() and sender = 'user' and agent_id is not null
              and (public.yui_owns_agent(agent_id) or created_at >= public.yui_grant_since(agent_id, public.yui_uid()))
              and (thread_id is null or exists (
                select 1 from public.yui_thread_members tm
                 where tm.thread_id = yui_messages.thread_id and tm.agent_id = yui_messages.agent_id
                   and tm.user_id = public.yui_uid())));
create policy yui_messages_user_delete on public.yui_messages for delete to yui_user
  using (user_id = public.yui_uid()
         and (public.yui_owns_agent(agent_id) or created_at >= public.yui_grant_since(agent_id, public.yui_uid())));

-- The host: threads of agents it serves, the owner's own or a live grant's
-- while the agent is client-safe. A revoked client's rows stop reaching it at once.
drop policy yui_messages_connector_read on public.yui_messages;
drop policy yui_messages_connector_write on public.yui_messages;
drop policy yui_messages_connector_ack on public.yui_messages;
create policy yui_messages_connector_read on public.yui_messages for select to yui_connector
  using (public.yui_connector_serves(agent_id)
         and (user_id = public.yui_uid() or created_at >= public.yui_grant_serves(agent_id, user_id)));
create policy yui_messages_connector_write on public.yui_messages for insert to yui_connector
  with check (sender = 'agent' and kind = 'text' and public.yui_connector_serves(agent_id)
              and (user_id = public.yui_uid() or created_at >= public.yui_grant_serves(agent_id, user_id)));
create policy yui_messages_connector_ack on public.yui_messages for update to yui_connector
  using (sender = 'user' and public.yui_connector_serves(agent_id)
         and (user_id = public.yui_uid() or created_at >= public.yui_grant_serves(agent_id, user_id)))
  with check (sender = 'user' and public.yui_connector_serves(agent_id)
              and (user_id = public.yui_uid() or created_at >= public.yui_grant_serves(agent_id, user_id)));

-- 5. The list: the person's own agents, then their live grants, each grant as
-- the owner's agent with the grant's look merged over the agent's own, the
-- grant's mute and order, shared = true and who shared it. user_id is the
-- person reading (the grantee), so `user_id = me` lists both. The host's
-- details (remote_ref, connector name, commands) stay the owner's.
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
         a.client_safe
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
         a.client_safe
    from public.yui_agent_grants g
    join public.yui_agents a on a.id = g.agent_id
    left join public.yui_connectors c on c.id = a.connector_id
   where g.revoked_at is null
     and g.user_id = coalesce(public.yui_uid(), g.user_id);  -- an owner's token never lists its clients' rows

-- 6. Claiming an invite applies its template in the same transaction: one grant
-- per client-safe item (an item whose agent stopped passing is skipped, never
-- a failed sign-in), then each item's first message at the top of the thread.
create or replace function public.yui_claim_invite(uid uuid, code_sha text, verified_email text)
returns table(id uuid, first_name text, agent_template text)
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  inv record;
  tpl public.yui_agent_templates;
  g record;
begin
  if exists (select 1 from public.yui_invites i where i.claimed_user_id = uid) then
    return;
  end if;
  update public.yui_invites i
     set status = 'claimed', claimed_user_id = uid, claimed_at = now()
   where i.id = (
     select j.id from public.yui_invites j
      where j.status in ('approved', 'invited') and j.claimed_user_id is null
        and (case when code_sha is not null then j.code_hash = code_sha
                  else verified_email is not null and lower(j.email) = lower(verified_email) end)
      limit 1 for update)
  returning i.id, i.first_name, i.agent_template, i.template_owner into inv;
  if inv.id is null then
    return;
  end if;
  if inv.agent_template is not null then
    select t.* into tpl from public.yui_agent_templates t
     where t.name = inv.agent_template
       and (t.owner_id = inv.template_owner
            or (inv.template_owner is null
                and (select count(*) from public.yui_agent_templates u where u.name = inv.agent_template) = 1));
    if tpl.id is not null then
      for g in
        insert into public.yui_agent_grants (agent_id, owner_id, user_id, theme, first_message, shared_by,
                                             template, invite_id, sort)
        select it.agent_id, it.owner_id, uid, it.theme, it.first_message, tpl.shared_by, tpl.name, inv.id, it.sort
          from public.yui_agent_template_items it
          join public.yui_agents a on a.id = it.agent_id and a.client_safe
         where it.template_id = tpl.id and it.owner_id <> uid
        on conflict do nothing
        returning agent_id, first_message
      loop
        if g.first_message is not null then
          insert into public.yui_messages (user_id, agent_id, sender, kind, body, meta)
          values (uid, g.agent_id, 'agent', 'text', g.first_message, '{"first": true}');
        end if;
      end loop;
    end if;
  end if;
  id := inv.id; first_name := inv.first_name; agent_template := inv.agent_template;
  return next;
end $$;
revoke all on function public.yui_claim_invite(uuid, text, text) from public, anon, authenticated, yui_user, yui_connector;
