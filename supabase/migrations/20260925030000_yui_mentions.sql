-- YUI-44 step 1: @mention another of your agents. Spec: yuigui/spec/RELAY.md "Mentions".
--
-- The person is in agent A's thread and writes "@Coach can you check this".
-- The app writes ONE ordinary row in A's thread:
--
--   body  [yui] mention to=coach
--         can you check this
--   meta  {"mention": {"to": "<B agent id>", "handle": "coach", "name": "Coach"}}
--
-- and this migration does the rest, in the same transaction:
--   1. The row is marked delivered and handled on the way in, so A's host
--      never runs a turn on it (A was not asked). A's plugin reads it as
--      context on A's next turn.
--   2. A copy goes into B's thread as the person's row, with A's last few
--      lines quoted, meta.mentioned {from, from_name, msg, by, depth}. B's host
--      answers it like any message, in B's own thread.
--   3. Every agent row that answers a `mentioned` row (its meta.turn names it)
--      is copied back into A's thread as an agent row with
--      meta.mention_reply {agent, name, handle, msg, to}: the app draws it in
--      B's look, with a link to B's thread.
--   4. When B is asleep, offline, not connected yet or muted, A's thread gets
--      a one-line status in B's look right away, instead of silence.
--
-- Agents may @ each other only inside a turn the person started: an agent
-- reply may carry meta.mentions ["coach", ...] (the Hermes plugin fills it from
-- @handles in the reply's text), and it is honoured only when that reply's
-- meta.turn names a row the person wrote in this thread and no `mentioned`
-- row. So B, answering a mention, can never mention anyone: depth 1, no loops.
-- Mirrors and status lines carry no meta.turn and never trigger anything.

-- Presence as the agent list reports it (online, asleep, offline, pending).
create or replace function public.yui_agent_presence(agent uuid) returns text
language sql stable security definer
set search_path = ''
as $$
  select case
    when a.connector_id is null then 'pending'
    when c.revoked_at is not null or c.stopped_at is not null then 'offline'
    when c.last_seen_at > now() - interval '2 minutes' then 'online'
    else 'asleep'
  end
  from public.yui_agents a
  left join public.yui_connectors c on c.id = a.connector_id
  where a.id = agent
$$;

-- One message as a quoted line: the app's `[yui] ...` first line dropped,
-- screens shown as [screen], one line, at most `n` characters.
create or replace function public.yui_mention_plain(body text, n int) returns text
language sql immutable
set search_path = ''
as $$
  select left(btrim(regexp_replace(regexp_replace(
           regexp_replace(body, '^\[yui\] (mention|reply) [^\n]*\n?', ''),
           '```yui.*?(```|$)', '[screen]', 'g'),
         '\s+', ' ', 'g')), n)
$$;

-- The thread's last six chat lines before `at`, oldest first, quoted. Status lines
-- ("Coach is asleep") are the app talking, not the thread, and stay out.
create or replace function public.yui_mention_context(agent uuid, at timestamptz, skip uuid) returns text
language sql stable security definer
set search_path = ''
as $$
  select coalesce(string_agg('> ' || who || ': ' || line, E'\n' order by created_at), '')
  from (
    select m.created_at,
           case when m.sender = 'user' then 'Person'
                when m.meta ? 'mention_reply' then coalesce(m.meta #>> '{mention_reply,name}', 'Agent')
                else a.name end as who,
           public.yui_mention_plain(m.body, 200) as line
    from public.yui_messages m
    join public.yui_agents a on a.id = m.agent_id
    where m.agent_id = agent and m.kind = 'text' and m.created_at <= at and m.id <> skip
      and m.meta #> '{mention_reply,status}' is null
    order by m.created_at desc
    limit 6
  ) t
  where line <> ''
$$;

-- Hand a mention to agent `target`, and tell the source thread when it can't answer yet.
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

-- 1. The person's mention: A was not asked, so its host never sees it as a turn.
create or replace function public.yui_mention_accept() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  target text := new.meta #>> '{mention,to}';
begin
  if target is null or target !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    raise sqlstate '22023' using message = 'mention_needs_agent';
  end if;
  if target::uuid = new.agent_id or not exists (
    select 1 from public.yui_agents where id = target::uuid and user_id = new.user_id
  ) then
    raise sqlstate '22023' using message = 'mention_agent_not_found';
  end if;
  new.delivered_at := coalesce(new.delivered_at, now());
  new.handled_at := coalesce(new.handled_at, now());
  return new;
end $$;

-- 2. ...and its copy in the mentioned agent's thread.
create or replace function public.yui_mention_send() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  perform public.yui_mention_deliver(new, (new.meta #>> '{mention,to}')::uuid,
    regexp_replace(new.body, '^\[yui\] mention [^\n]*\n?', ''), 'person');
  return null;
end $$;

-- An agent's @ inside a turn the person started (depth 1).
create or replace function public.yui_mention_by_agent() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  h text;
  target uuid;
  sent uuid[] := '{}';
begin
  if jsonb_typeof(new.meta -> 'mentions') <> 'array' or jsonb_typeof(new.meta -> 'turn') <> 'array' then
    return null;
  end if;
  -- The turn must answer the person, and nothing in it may be a mention itself.
  if not exists (
    select 1 from public.yui_messages m
    where m.agent_id = new.agent_id and m.user_id = new.user_id and m.sender = 'user'
      and m.id::text in (select jsonb_array_elements_text(new.meta -> 'turn'))
  ) or exists (
    select 1 from public.yui_messages m
    where m.agent_id = new.agent_id and m.user_id = new.user_id and m.meta ? 'mentioned'
      and m.id::text in (select jsonb_array_elements_text(new.meta -> 'turn'))
  ) then
    return null;
  end if;
  for h in select lower(ltrim(x, '@')) from jsonb_array_elements_text(new.meta -> 'mentions') x limit 3 loop
    select id into target from public.yui_agents
     where user_id = new.user_id and id <> new.agent_id and (handle = h or lower(name) = h)
     order by handle = h desc limit 1;
    if target is not null and not target = any(sent) then
      perform public.yui_mention_deliver(new, target, public.yui_mention_plain(new.body, 2000), 'agent');
      sent := sent || target;
    end if;
  end loop;
  return null;
end $$;

-- 3. An answer to a mention goes back to the thread it came from.
create or replace function public.yui_mention_mirror() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  src public.yui_messages;
  b public.yui_agents;
  home uuid;
begin
  if jsonb_typeof(new.meta -> 'turn') <> 'array' then
    return null;
  end if;
  select * into src from public.yui_messages m
   where m.agent_id = new.agent_id and m.user_id = new.user_id and m.meta ? 'mentioned'
     and m.id::text in (select jsonb_array_elements_text(new.meta -> 'turn'))
   order by m.created_at desc limit 1;
  if src.id is null then
    return null;
  end if;
  select id into home from public.yui_agents
   where id::text = src.meta #>> '{mentioned,from}' and user_id = new.user_id and id <> new.agent_id;
  if home is null then
    return null;
  end if;
  select * into b from public.yui_agents where id = new.agent_id;
  insert into public.yui_messages(user_id, agent_id, sender, kind, body, meta)
  values (new.user_id, home, 'agent', 'text', new.body,
          jsonb_build_object('mention_reply', jsonb_build_object(
            'agent', b.id, 'name', b.name, 'handle', b.handle,
            'msg', new.id, 'to', src.meta #>> '{mentioned,msg}')));
  return null;
end $$;

revoke all on function public.yui_agent_presence(uuid) from public, anon, authenticated;
revoke all on function public.yui_mention_plain(text, int) from public, anon, authenticated;
revoke all on function public.yui_mention_context(uuid, timestamptz, uuid) from public, anon, authenticated;
revoke all on function public.yui_mention_deliver(public.yui_messages, uuid, text, text) from public, anon, authenticated;
revoke all on function public.yui_mention_accept() from public, anon, authenticated;
revoke all on function public.yui_mention_send() from public, anon, authenticated;
revoke all on function public.yui_mention_by_agent() from public, anon, authenticated;
revoke all on function public.yui_mention_mirror() from public, anon, authenticated;

drop trigger if exists yui_mention_accept on public.yui_messages;
create trigger yui_mention_accept before insert on public.yui_messages
  for each row when (new.sender = 'user' and new.meta ? 'mention')
  execute function public.yui_mention_accept();

drop trigger if exists yui_mention_send on public.yui_messages;
create trigger yui_mention_send after insert on public.yui_messages
  for each row when (new.sender = 'user' and new.meta ? 'mention')
  execute function public.yui_mention_send();

drop trigger if exists yui_mention_by_agent on public.yui_messages;
create trigger yui_mention_by_agent after insert on public.yui_messages
  for each row when (new.sender = 'agent' and new.meta ? 'mentions' and new.meta ? 'turn')
  execute function public.yui_mention_by_agent();

drop trigger if exists yui_mention_mirror on public.yui_messages;
create trigger yui_mention_mirror after insert on public.yui_messages
  for each row when (new.sender = 'agent' and new.meta ? 'turn' and not new.meta ? 'mention_reply')
  execute function public.yui_mention_mirror();

notify pgrst, 'reload schema';
