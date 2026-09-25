-- YUI-93 (YUI-77 step 2): group threads, two or more of the person's agents in
-- one conversation. Spec: yuigui/spec/GROUPS.md. Builds on the mention triggers
-- (20260925030000_yui_mentions.sql) and keeps their shape.
--
-- Rows stay per agent. Every group row still has an agent_id (the agent it is
-- to or from), so the host's poll, delivered_at/handled_at and meta.turn work
-- exactly as today. A group row also has thread_id and meta.group:
--
--   the person's message   agent_id = first addressee (or the lead)
--                          {thread, root: <own id>, hop: 0, to: [ids], words}
--   a copy for addressee   agent_id = that agent
--   2 and 3                {thread, root, hop: 0, copy_of}
--   an agent's reply       {thread, root, hop}, stamped here from meta.turn
--   a handoff ask          agent_id = the agent asked, sender = 'user'
--                          {thread, root, hop, from, from_name, msg}
--   a guard row            agent_id = the agent that asked, sender = 'agent'
--                          {thread, root, hop, guard {to, to_name, from, msg, hop,
--                           reason: hops|turns, state: held|continued|stopped}}
--   a status line          {thread, root, status: asleep|offline|pending|muted
--                           |stopped, about}
--   Let it / Stop          sender = 'user', agent_id = the lead, handled on the
--                          way in: {thread, control: continue|stop, guard}
--
-- Every row an agent is asked on (the person's message, its copies, handoff
-- asks) starts `[yui] group "<title>" ...` with the thread's last six lines
-- quoted, so a host that knows nothing of groups still answers well.
--
-- Budgets: a person's message is root and hop 0. An agent answering hop n may
-- @ up to three members: hop n+1, while n+1 <= max_hops and the root has asked
-- fewer than max_turns agents. Past either, the ask is held as a guard row the
-- person answers with Let it (sends it on a fresh budget) or Stop. Stop also
-- cancels every handoff not picked up yet, and replies to anything rooted
-- before it hand off nothing.
--
-- Security: yui_user owns threads and members (no delete: archive).
-- yui_connector gets NO grant on either table and cannot set thread_id; its
-- only view of the rest of a group is the quote in its own rows and
-- yui_group_notes(), one plain line per row, for groups its agent is in.

-- Tables ----------------------------------------------------------------------
create table if not exists public.yui_threads (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.yui_users(id) on delete cascade,
  title       text not null check (length(btrim(title)) between 1 and 60),
  lead        uuid not null,
  max_hops    int  not null default 3 check (max_hops between 1 and 5),
  max_turns   int  not null default 8 check (max_turns between 1 and 12),
  stopped_at  timestamptz,
  created_at  timestamptz not null default now(),
  archived_at timestamptz,
  unique (id, user_id),
  foreign key (lead, user_id) references public.yui_agents(id, user_id) on delete cascade
);
create index if not exists yui_threads_user_idx on public.yui_threads(user_id, created_at);

create table if not exists public.yui_thread_members (
  thread_id  uuid not null,
  agent_id   uuid not null,
  user_id    uuid not null,
  joined_at  timestamptz not null default now(),
  left_at    timestamptz,
  primary key (thread_id, agent_id),
  foreign key (thread_id, user_id) references public.yui_threads(id, user_id) on delete cascade,
  foreign key (agent_id, user_id) references public.yui_agents(id, user_id) on delete cascade
);
create index if not exists yui_thread_members_agent_idx on public.yui_thread_members(agent_id);

alter table public.yui_messages add column if not exists thread_id uuid;
alter table public.yui_messages drop constraint if exists yui_messages_thread_fk;
alter table public.yui_messages add constraint yui_messages_thread_fk
  foreign key (thread_id, user_id) references public.yui_threads(id, user_id) on delete cascade;
create index if not exists yui_messages_group_idx on public.yui_messages(thread_id, created_at)
  where thread_id is not null;
create index if not exists yui_messages_group_root_idx on public.yui_messages(thread_id, (meta #>> '{group,root}'))
  where thread_id is not null;

insert into public.yui_limits (name, value, note) values
  ('threads_per_user', 50, 'group threads per account, archived included'),
  ('group_min_build', 10000, 'oldest app build that may create a group; the app card sets it to the first build with the New group sheet')
on conflict (name) do nothing;

-- Grants and RLS --------------------------------------------------------------
revoke all on public.yui_threads, public.yui_thread_members from public, anon, authenticated, yui_connector;
grant select on public.yui_threads, public.yui_thread_members to yui_user;
grant insert (id, user_id, title, lead, max_hops, max_turns) on public.yui_threads to yui_user;
grant update (title, lead, max_hops, max_turns, archived_at) on public.yui_threads to yui_user;
grant insert (thread_id, agent_id, user_id) on public.yui_thread_members to yui_user;
grant update (left_at) on public.yui_thread_members to yui_user;
alter table public.yui_threads enable row level security;
alter table public.yui_thread_members enable row level security;

drop policy if exists yui_threads_owner on public.yui_threads;
create policy yui_threads_owner on public.yui_threads for all to yui_user
  using (user_id = public.yui_uid()) with check (user_id = public.yui_uid());
drop policy if exists yui_thread_members_owner on public.yui_thread_members;
create policy yui_thread_members_owner on public.yui_thread_members for all to yui_user
  using (user_id = public.yui_uid()) with check (user_id = public.yui_uid());

-- A person's row in a group must name a thread they own and an agent in it.
-- (The trigger below picks the agent, then this checks the result.)
drop policy if exists yui_messages_user_write on public.yui_messages;
create policy yui_messages_user_write on public.yui_messages for insert to yui_user
  with check (user_id = public.yui_uid() and sender = 'user' and agent_id is not null
              and (thread_id is null or exists (
                select 1 from public.yui_thread_members tm
                where tm.thread_id = yui_messages.thread_id and tm.agent_id = yui_messages.agent_id
                  and tm.user_id = public.yui_uid())));
-- yui_connector's column grant on yui_messages never included thread_id, so a
-- host cannot put a row in a group. The trigger does.

-- Threads: min build, cap, lead is a member ------------------------------------
create or replace function public.yui_threads_guard() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  caller text := public.yui_caller();
  build int;
begin
  if tg_op = 'INSERT' then
    if caller = 'yui_user' then
      select max(app_build) into build from public.yui_devices where user_id = new.user_id;
      if coalesce(build, 0) < public.yui_limit('group_min_build') then
        raise sqlstate 'PT403' using message = 'update_needed';
      end if;
    end if;
    if caller in ('yui_user', 'service_role') then
      if public.yui_user_suspended(new.user_id) then
        raise sqlstate 'PT403' using message = 'account_suspended';
      end if;
      if (select count(*) from public.yui_threads where user_id = new.user_id)
         >= public.yui_limit('threads_per_user') then
        raise sqlstate 'PT403' using message = 'limit_reached', detail = 'yui_threads';
      end if;
    end if;
    new.title := btrim(new.title);
    return new;
  end if;
  new.title := btrim(new.title);
  if new.lead <> old.lead and not exists (
    select 1 from public.yui_thread_members
    where thread_id = new.id and agent_id = new.lead and left_at is null
  ) then
    raise sqlstate '22023' using message = 'group_lead_not_member';
  end if;
  return new;
end $$;

create or replace function public.yui_threads_seat_lead() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  insert into public.yui_thread_members(thread_id, agent_id, user_id)
  values (new.id, new.lead, new.user_id) on conflict do nothing;
  return null;
end $$;

create or replace function public.yui_thread_members_guard() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if (select count(*) from public.yui_thread_members where thread_id = new.thread_id) >= 12 then
      raise sqlstate 'PT403' using message = 'limit_reached', detail = 'yui_thread_members';
    end if;
    return new;
  end if;
  if new.left_at is not null and old.left_at is null
     and exists (select 1 from public.yui_threads where id = new.thread_id and lead = new.agent_id) then
    raise sqlstate '22023' using message = 'group_lead_cannot_leave';
  end if;
  return new;
end $$;

drop trigger if exists yui_threads_guard on public.yui_threads;
create trigger yui_threads_guard before insert or update on public.yui_threads
  for each row execute function public.yui_threads_guard();
drop trigger if exists yui_threads_seat_lead on public.yui_threads;
create trigger yui_threads_seat_lead after insert on public.yui_threads
  for each row execute function public.yui_threads_seat_lead();
drop trigger if exists yui_thread_members_guard on public.yui_thread_members;
create trigger yui_thread_members_guard before insert or update on public.yui_thread_members
  for each row execute function public.yui_thread_members_guard();

-- Helpers -----------------------------------------------------------------------
create or replace function public.yui_group_member(thread uuid, agent uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (select 1 from public.yui_thread_members
                 where thread_id = thread and agent_id = agent and left_at is null)
$$;

-- The group's last six chat lines before `at`, oldest first, quoted: the
-- person's words and the agents' answers. Copies, asks, guards, status lines
-- and Let it / Stop are the app talking, not the thread.
create or replace function public.yui_group_context(thread uuid, at timestamptz, skip uuid) returns text
language sql stable security definer
set search_path = ''
as $$
  select coalesce(string_agg('> ' || who || ': ' || line, E'\n' order by created_at), '')
  from (
    select m.created_at,
           case when m.sender = 'user' then 'Person' else a.name end as who,
           public.yui_mention_plain(case when m.sender = 'user' then m.meta #>> '{group,words}' else m.body end, 200) as line
    from public.yui_messages m
    join public.yui_agents a on a.id = m.agent_id
    where m.thread_id = thread and m.kind = 'text' and m.created_at <= at and m.id <> skip
      and ((m.sender = 'user' and m.meta -> 'group' ? 'to')
           or (m.sender = 'agent' and not m.meta -> 'group' ?| array['guard', 'status']))
    order by m.created_at desc
    limit 6
  ) t
  where line <> ''
$$;

-- What an addressed agent reads: header, the thread just before, the words.
create or replace function public.yui_group_body(t public.yui_threads, hop int, from_ text, msg uuid,
                                                 words text, at timestamptz, skip uuid) returns text
language plpgsql stable security definer
set search_path = ''
as $$
declare
  members text;
  lead_handle text;
  ctx text := public.yui_group_context(t.id, at, skip);
begin
  select string_agg(a.handle, ',' order by tm.joined_at, a.handle) into members
    from public.yui_thread_members tm join public.yui_agents a on a.id = tm.agent_id
   where tm.thread_id = t.id and tm.left_at is null;
  select handle into lead_handle from public.yui_agents where id = t.lead;
  return left(format('[yui] group "%s" thread=%s with=%s lead=%s hop=%s from=%s msg=%s',
                     replace(t.title, '"', ''''), t.id, members, lead_handle, hop, from_, msg)
              || case when ctx <> '' then E'\n' || t.title || E', just before:\n' || ctx else '' end
              || E'\n' || words, 32000);
end $$;

-- One line in `agent`'s look when it can't answer yet (as for mentions).
create or replace function public.yui_group_status(t public.yui_threads, agent uuid, root uuid, at timestamptz)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  b public.yui_agents;
  presence text := public.yui_agent_presence(agent);
  status text;
begin
  select * into b from public.yui_agents where id = agent;
  status := case presence
    when 'asleep' then b.name || ' is asleep. It gets this when its computer wakes.'
    when 'offline' then b.name || ' is offline. It gets this when it''s back.'
    when 'pending' then b.name || ' isn''t connected yet. It gets this once it is.'
    else case when b.push_muted then b.name || ' is muted. It still gets this, and its answer lands here quietly.' end
  end;
  if status is null then
    return;
  end if;
  insert into public.yui_messages(user_id, agent_id, thread_id, sender, kind, body, meta, created_at)
  values (t.user_id, agent, t.id, 'agent', 'text', status,
          jsonb_build_object('group', jsonb_build_object(
            'thread', t.id, 'root', root, 'about', agent,
            'status', case when presence = 'online' then 'muted' else presence end)),
          at + interval '1 microsecond');
end $$;

-- How many agents one root has asked so far (the person's addressees included).
create or replace function public.yui_group_turns(thread uuid, root uuid) returns int
language sql stable security definer
set search_path = ''
as $$
  select count(*)::int from public.yui_messages
  where thread_id = thread and meta #>> '{group,root}' = root::text
    and sender = 'user' and not meta -> 'group' ? 'control'
$$;

-- Ask `target` in the group: a row in its thread it answers like any message.
create or replace function public.yui_group_ask(t public.yui_threads, target uuid, root uuid, hop int,
                                                from_agent uuid, msg uuid, words text, at timestamptz)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  a public.yui_agents;
  id_ uuid := gen_random_uuid();
begin
  select * into a from public.yui_agents where id = from_agent;
  insert into public.yui_messages(id, user_id, agent_id, thread_id, sender, kind, body, meta, created_at)
  values (id_, t.user_id, target, t.id, 'user', 'text',
          public.yui_group_body(t, hop, a.handle, msg, words, at, msg),
          jsonb_build_object('group', jsonb_build_object(
            'thread', t.id, 'root', root, 'hop', hop,
            'from', a.id, 'from_name', a.name, 'msg', msg)),
          at);
  perform public.yui_group_status(t, target, root, at);
  return id_;
end $$;

-- BEFORE insert: route the person's row, stamp agent replies -----------------------
create or replace function public.yui_group_accept() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  t public.yui_threads;
  src public.yui_messages;
  ctl text;
  g public.yui_messages;
  x text;
  to_ uuid[] := '{}';
  words text;
begin
  if pg_trigger_depth() > 1 then
    return new;  -- a row these triggers wrote themselves
  end if;

  if new.sender = 'agent' then
    -- A host never sets meta.group; a reply to a group row gets it here.
    new.meta := new.meta - 'group';
    if jsonb_typeof(new.meta -> 'turn') <> 'array' then
      return new;
    end if;
    select * into src from public.yui_messages m
     where m.agent_id = new.agent_id and m.user_id = new.user_id and m.sender = 'user'
       and m.thread_id is not null
       and m.id::text in (select jsonb_array_elements_text(new.meta -> 'turn'))
     order by m.created_at desc limit 1;
    if src.id is null then
      return new;
    end if;
    new.thread_id := src.thread_id;
    -- In a group @s route by the hop budget (below), never as a depth-1 mention.
    new.meta := (new.meta - 'mentions') || jsonb_build_object('group', jsonb_strip_nulls(jsonb_build_object(
      'thread', src.thread_id, 'root', src.meta #>> '{group,root}',
      'hop', coalesce((src.meta #>> '{group,hop}')::int, 0),
      'mentions', case when jsonb_typeof(new.meta -> 'mentions') = 'array' then new.meta -> 'mentions' end)));
    return new;
  end if;

  -- The person's row.
  if new.thread_id is null then
    new.meta := new.meta - 'group';
    return new;
  end if;
  select * into t from public.yui_threads where id = new.thread_id and user_id = new.user_id;
  if t.id is null then
    raise sqlstate '22023' using message = 'group_not_found';
  end if;
  if t.archived_at is not null then
    raise sqlstate '22023' using message = 'group_archived';
  end if;
  if new.meta ? 'mention' then
    raise sqlstate '22023' using message = 'group_uses_to';
  end if;

  ctl := new.meta #>> '{group,control}';
  if ctl is not null then
    if ctl not in ('continue', 'stop') then
      raise sqlstate '22023' using message = 'group_bad_control';
    end if;
    if ctl = 'continue' then
      x := new.meta #>> '{group,guard}';
      if x is null or x !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        raise sqlstate '22023' using message = 'group_guard_gone';
      end if;
      select * into g from public.yui_messages
       where id = x::uuid and thread_id = t.id and meta #>> '{group,guard,state}' = 'held';
      if g.id is null then
        raise sqlstate '22023' using message = 'group_guard_gone';
      end if;
    end if;
    new.agent_id := t.lead;
    new.delivered_at := coalesce(new.delivered_at, now());
    new.handled_at := coalesce(new.handled_at, now());
    new.meta := (new.meta - 'group') || jsonb_build_object('group', jsonb_strip_nulls(jsonb_build_object(
      'thread', t.id, 'control', ctl, 'guard', g.id)));
    return new;
  end if;

  -- Who answers: the members it names, in order, three at most; else the lead.
  if jsonb_typeof(new.meta #> '{group,to}') = 'array' then
    for x in select jsonb_array_elements_text(new.meta #> '{group,to}') loop
      if x !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
         or not public.yui_group_member(t.id, x::uuid) then
        raise sqlstate '22023' using message = 'group_agent_not_member';
      end if;
      if not x::uuid = any(to_) then
        to_ := to_ || x::uuid;
      end if;
    end loop;
    if array_length(to_, 1) > 3 then
      raise sqlstate '22023' using message = 'group_too_many';
    end if;
  end if;
  if coalesce(array_length(to_, 1), 0) = 0 then
    to_ := array[t.lead];
  end if;
  words := new.body;
  new.agent_id := to_[1];
  new.body := public.yui_group_body(t, 0, 'person', new.id, words, new.created_at, new.id);
  new.meta := (new.meta - 'group') || jsonb_build_object('group', jsonb_build_object(
    'thread', t.id, 'root', new.id, 'hop', 0, 'to', to_jsonb(to_), 'words', left(words, 2000)));
  return new;
end $$;

-- AFTER insert: copies, handoffs, the guard, Let it and Stop ------------------------
create or replace function public.yui_group_route() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  t public.yui_threads;
  g public.yui_messages;
  reply public.yui_messages;
  root_at timestamptz;
  a public.yui_agents;
  b public.yui_agents;
  h text;
  target uuid;
  sent uuid[] := '{}';
  hop int;
  n int := 0;
  at_ timestamptz;
  words text;
  lines text[] := '{}';
  cancelled uuid[] := '{}';
  r record;
begin
  if pg_trigger_depth() > 1 then
    return null;
  end if;
  select * into t from public.yui_threads where id = new.thread_id;

  if new.sender = 'user' then
    if new.meta #>> '{group,control}' = 'stop' then
      update public.yui_threads set stopped_at = now() where id = t.id;
      for r in
        update public.yui_messages m set delivered_at = now(), handled_at = now(),
               meta = jsonb_set(m.meta, '{group,cancelled}', 'true')
         where m.thread_id = t.id and m.sender = 'user' and m.meta -> 'group' ? 'from'
           and m.delivered_at is null and m.handled_at is null
        returning m.id, m.agent_id, m.meta #>> '{group,from_name}' as from_name
      loop
        cancelled := cancelled || r.id;
        select * into b from public.yui_agents where id = r.agent_id;
        lines := lines || format('%s won''t pick up %s''s ask.', b.name, r.from_name);
      end loop;
      update public.yui_messages m
         set meta = jsonb_set(m.meta, '{group,guard,state}', '"stopped"')
       where m.thread_id = t.id and m.meta #>> '{group,guard,state}' = 'held';
      insert into public.yui_messages(user_id, agent_id, thread_id, sender, kind, body, meta, created_at)
      values (t.user_id, t.lead, t.id, 'agent', 'text',
              btrim('Stopped. ' || array_to_string(lines, ' ')),
              jsonb_build_object('group', jsonb_build_object(
                'thread', t.id, 'status', 'stopped', 'about', t.lead, 'cancelled', to_jsonb(cancelled))),
              new.created_at + interval '1 microsecond');
      return null;
    end if;

    if new.meta #>> '{group,control}' = 'continue' then
      -- Let it: the held ask goes out on a fresh budget, rooted at this tap.
      select * into g from public.yui_messages where id = (new.meta #>> '{group,guard}')::uuid;
      target := (g.meta #>> '{group,guard,to}')::uuid;
      select * into reply from public.yui_messages where id = (g.meta #>> '{group,guard,msg}')::uuid;
      if public.yui_group_member(t.id, target) and reply.id is not null then
        perform public.yui_group_ask(t, target, new.id, 1, reply.agent_id, reply.id,
                                     public.yui_mention_plain(reply.body, 2000), new.created_at + interval '1 millisecond');
        update public.yui_messages set meta = jsonb_set(jsonb_set(meta, '{group,guard,state}', '"continued"'),
                                                        '{group,guard,by}', to_jsonb(new.id))
         where id = g.id;
      else
        update public.yui_messages set meta = jsonb_set(meta, '{group,guard,state}', '"gone"') where id = g.id;
      end if;
      return null;
    end if;

    -- The person's message: say so if the first addressee can't answer yet,
    -- and copy it to the second and third.
    perform public.yui_group_status(t, new.agent_id, new.id, new.created_at);
    for target in select (jsonb_array_elements_text(new.meta #> '{group,to}'))::uuid offset 1 loop
      n := n + 1;
      at_ := new.created_at + n * interval '1 millisecond';
      insert into public.yui_messages(user_id, agent_id, thread_id, sender, kind, body, meta, created_at)
      values (new.user_id, target, t.id, 'user', 'text',
              public.yui_group_body(t, 0, 'person', new.id, new.meta #>> '{group,words}', new.created_at, new.id),
              jsonb_build_object('group', jsonb_build_object(
                'thread', t.id, 'root', new.id, 'hop', 0, 'copy_of', new.id)),
              at_);
      perform public.yui_group_status(t, target, new.id, at_);
    end loop;
    return null;
  end if;

  -- An agent's reply: its @s become handoffs while the budget holds.
  if jsonb_typeof(new.meta #> '{group,mentions}') <> 'array' then
    return null;
  end if;
  select created_at into root_at from public.yui_messages where id = (new.meta #>> '{group,root}')::uuid;
  if t.stopped_at is not null and (root_at is null or root_at <= t.stopped_at) then
    return null;  -- Stop came after this chain started: its @s go nowhere
  end if;
  select * into a from public.yui_agents where id = new.agent_id;
  hop := coalesce((new.meta #>> '{group,hop}')::int, 0) + 1;
  words := public.yui_mention_plain(new.body, 2000);
  for h in select lower(ltrim(x, '@')) from jsonb_array_elements_text(new.meta #> '{group,mentions}') x limit 3 loop
    select ag.id into target from public.yui_agents ag
      join public.yui_thread_members tm on tm.agent_id = ag.id and tm.thread_id = t.id and tm.left_at is null
     where ag.user_id = new.user_id and ag.id <> new.agent_id and (ag.handle = h or lower(ag.name) = h)
     order by ag.handle = h desc limit 1;
    if target is null or target = any(sent) then
      continue;
    end if;
    sent := sent || target;
    n := n + 1;
    at_ := new.created_at + n * interval '1 millisecond';
    if hop > t.max_hops or public.yui_group_turns(t.id, (new.meta #>> '{group,root}')::uuid) >= t.max_turns then
      select * into b from public.yui_agents where id = target;
      insert into public.yui_messages(user_id, agent_id, thread_id, sender, kind, body, meta, created_at)
      values (new.user_id, a.id, t.id, 'agent', 'text',
              format(E'%s wants to ask %s: "%s"\n%s', a.name, b.name, public.yui_mention_plain(new.body, 200),
                     case when hop > t.max_hops
                          then format('That''s %s handoff%s since you last said something.', hop - 1,
                                      case when hop - 1 = 1 then '' else 's' end)
                          else format('That''s %s turns since you last said something.', t.max_turns) end),
              jsonb_build_object('group', jsonb_build_object(
                'thread', t.id, 'root', new.meta #>> '{group,root}', 'hop', hop - 1,
                'guard', jsonb_build_object('to', b.id, 'to_name', b.name, 'from', a.id, 'msg', new.id,
                                            'hop', hop, 'reason', case when hop > t.max_hops then 'hops' else 'turns' end,
                                            'state', 'held'))),
              at_);
    else
      perform public.yui_group_ask(t, target, (new.meta #>> '{group,root}')::uuid, hop, a.id, new.id, words, at_);
    end if;
  end loop;
  return null;
end $$;

-- Notes for a host (yui_connector): what else happened in a group its agent is
-- in, since `since`, one plain line per row. The only way a host reads another
-- agent's part of a group; rows addressed to this agent are its own turns.
create or replace function public.yui_group_notes(agent uuid, thread uuid, since timestamptz, upto timestamptz)
returns table (id uuid, created_at timestamptz, kind text, name text, to_names text, title text, words text)
language sql stable security definer
set search_path = ''
as $$
  select m.id, m.created_at,
         case when m.sender = 'user' then 'asked'
              when m.meta #>> '{group,status}' = 'stopped' then 'stopped'
              else 'answered' end,
         case when m.sender = 'user' then 'Person' else a.name end,
         case when m.sender = 'user' then (
           select string_agg(x.name, ', ' order by x.o) from (
             select ag.name, j.o from jsonb_array_elements_text(m.meta #> '{group,to}') with ordinality j(v, o)
             join public.yui_agents ag on ag.id::text = j.v) x) end,
         t.title,
         public.yui_mention_plain(case when m.sender = 'user' then m.meta #>> '{group,words}' else m.body end, 600)
  from public.yui_messages m
  join public.yui_threads t on t.id = m.thread_id
  join public.yui_agents a on a.id = m.agent_id
  where public.yui_caller() = 'yui_connector'
    and public.yui_connector_serves(agent)
    and m.thread_id = thread
    and t.user_id = public.yui_uid()
    and public.yui_group_member(thread, agent)
    and m.created_at > since and m.created_at <= coalesce(upto, now())
    and m.kind = 'text'
    and ((m.sender = 'user' and m.meta -> 'group' ? 'to' and not (m.meta #> '{group,to}') ? agent::text)
         or (m.sender = 'agent' and m.agent_id <> agent and not m.meta -> 'group' ?| array['guard', 'status'])
         or m.meta #>> '{group,status}' = 'stopped')
  order by m.created_at, m.id
  limit 20
$$;

revoke all on function public.yui_threads_guard() from public, anon, authenticated;
revoke all on function public.yui_threads_seat_lead() from public, anon, authenticated;
revoke all on function public.yui_thread_members_guard() from public, anon, authenticated;
revoke all on function public.yui_group_member(uuid, uuid) from public, anon, authenticated;
revoke all on function public.yui_group_context(uuid, timestamptz, uuid) from public, anon, authenticated;
revoke all on function public.yui_group_body(public.yui_threads, int, text, uuid, text, timestamptz, uuid) from public, anon, authenticated;
revoke all on function public.yui_group_status(public.yui_threads, uuid, uuid, timestamptz) from public, anon, authenticated;
revoke all on function public.yui_group_turns(uuid, uuid) from public, anon, authenticated;
revoke all on function public.yui_group_ask(public.yui_threads, uuid, uuid, int, uuid, uuid, text, timestamptz) from public, anon, authenticated;
revoke all on function public.yui_group_accept() from public, anon, authenticated;
revoke all on function public.yui_group_route() from public, anon, authenticated;
revoke all on function public.yui_group_notes(uuid, uuid, timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function public.yui_group_notes(uuid, uuid, timestamptz, timestamptz) to yui_connector;

-- yui_group_accept sorts before yui_mention_accept and yui_messages_guard.
drop trigger if exists yui_group_accept on public.yui_messages;
create trigger yui_group_accept before insert on public.yui_messages
  for each row when (new.thread_id is not null or new.meta ? 'group' or (new.sender = 'agent' and new.meta ? 'turn'))
  execute function public.yui_group_accept();

drop trigger if exists yui_group_route on public.yui_messages;
create trigger yui_group_route after insert on public.yui_messages
  for each row when (new.thread_id is not null)
  execute function public.yui_group_route();

notify pgrst, 'reload schema';
