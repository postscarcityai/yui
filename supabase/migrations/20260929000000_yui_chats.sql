-- YUI-169 step 2: several chats per agent. Spec: yuigui/spec/CHATS.md.
--
-- A chat is one conversation with one agent. It has an id, a title and its
-- own messages (yui_messages.chat_id). Screens, the shelf, the drawer rows and
-- memory stay the agent's. A group (yui_threads) is a different thing and its
-- rows keep chat_id null.
--
-- 1. yui_chats: one row per chat, same rules as every account table (user_id,
--    RLS for yui_user, no grant for yui_connector). The host never reads it:
--    the person's rows are stamped with meta.chat {id, first, new} by the
--    trigger below, and that is all a host needs to pick a session.
-- 2. yui_messages.chat_id, backfilled: every existing thread becomes its
--    agent's first chat, so an update loses nothing.
-- 3. One BEFORE INSERT trigger decides the chat of every row:
--      the person's row   the chat_id it names (must be theirs and for that
--                         agent), else the agent's newest chat (an old app);
--      an agent's reply   the chat of the row it answers (meta.turn), else the
--                         chat a host names in meta.chat, else the newest;
--      groups, and the agent's own control rows: no chat.
--    A host never has to know about chats to reply in the right one.
-- 4. One AFTER INSERT trigger moves last_at and titles a chat from its first
--    ask (32 characters, cut at a word). A first chat keeps "Hi <agent>".
-- 5. yui_chat_list: the drawer's rows (last line said, unread) in one call.
-- 6. Limits: chats_per_agent, and chats_min_build gates a second chat the way
--    group_min_build gates groups. High until the build that draws the list is
--    VALID on TestFlight, then lowered to it.

-- 1. ---------------------------------------------------------------------------
create table if not exists public.yui_chats (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.yui_users(id) on delete cascade,
  agent_id    uuid not null references public.yui_agents(id) on delete cascade,
  title       text check (title is null or length(btrim(title)) between 1 and 60),
  titled_by   text not null default 'auto' check (titled_by in ('auto', 'person')),
  is_first    boolean not null default false,
  last_at     timestamptz not null default now(),
  seen_at     timestamptz not null default now(),
  created_at  timestamptz not null default now(),
  unique (id, user_id)
);
create index if not exists yui_chats_list_idx on public.yui_chats(user_id, agent_id, last_at desc);
-- One first chat per person and agent: its session key is the agent's, so a
-- turn in progress before chats existed carries on.
create unique index if not exists yui_chats_first_idx on public.yui_chats(user_id, agent_id) where is_first;

revoke all on public.yui_chats from public, anon, authenticated;
grant select, delete on public.yui_chats to yui_user;
grant insert (id, user_id, agent_id) on public.yui_chats to yui_user;
grant update (title, seen_at) on public.yui_chats to yui_user;
alter table public.yui_chats enable row level security;

drop policy if exists yui_chats_user_read on public.yui_chats;
drop policy if exists yui_chats_user_write on public.yui_chats;
drop policy if exists yui_chats_user_update on public.yui_chats;
drop policy if exists yui_chats_user_delete on public.yui_chats;
create policy yui_chats_user_read on public.yui_chats for select to yui_user
  using (user_id = public.yui_uid());
create policy yui_chats_user_write on public.yui_chats for insert to yui_user
  with check (user_id = public.yui_uid()
              and (public.yui_owns_agent(agent_id) or public.yui_granted(agent_id, public.yui_uid())));
create policy yui_chats_user_update on public.yui_chats for update to yui_user
  using (user_id = public.yui_uid()) with check (user_id = public.yui_uid());
create policy yui_chats_user_delete on public.yui_chats for delete to yui_user
  using (user_id = public.yui_uid());

-- 2. ---------------------------------------------------------------------------
alter table public.yui_messages add column if not exists chat_id uuid;
alter table public.yui_messages drop constraint if exists yui_messages_chat_fk;
alter table public.yui_messages add constraint yui_messages_chat_fk
  foreign key (chat_id, user_id) references public.yui_chats(id, user_id) on delete cascade not valid;
create index if not exists yui_messages_chat_idx on public.yui_messages(chat_id, created_at)
  where chat_id is not null;

-- Every person and agent that has a thread, or an owner and their agent, gets a first chat.
insert into public.yui_chats (user_id, agent_id, is_first, last_at, seen_at, created_at)
select p.user_id, p.agent_id, true,
       coalesce((select max(m.created_at) from public.yui_messages m
                  where m.user_id = p.user_id and m.agent_id = p.agent_id), now()),
       now(),
       coalesce((select min(m.created_at) from public.yui_messages m
                  where m.user_id = p.user_id and m.agent_id = p.agent_id), now())
  from (select user_id, id as agent_id from public.yui_agents
        union
        select m.user_id, m.agent_id from public.yui_messages m
          join public.yui_agents a on a.id = m.agent_id
         where m.agent_id is not null) p
on conflict do nothing;

update public.yui_messages m
   set chat_id = c.id
  from public.yui_chats c
 where c.user_id = m.user_id and c.agent_id = m.agent_id and c.is_first
   and m.chat_id is null and m.thread_id is null
   and (m.kind <> 'control' or (m.sender = 'user' and m.body = 'stop'));

alter table public.yui_messages validate constraint yui_messages_chat_fk;

-- Helpers ---------------------------------------------------------------------
-- The chat a row lands in when nothing names one: the newest, made if the
-- person has none with this agent yet (a grant, a new agent).
create or replace function public.yui_chat_newest(uid uuid, agent uuid) returns uuid
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  c uuid;
begin
  select id into c from public.yui_chats
   where user_id = uid and agent_id = agent order by last_at desc, created_at desc limit 1;
  if c is null then
    insert into public.yui_chats (user_id, agent_id) values (uid, agent) on conflict do nothing;
    select id into c from public.yui_chats
     where user_id = uid and agent_id = agent order by last_at desc, created_at desc limit 1;
  end if;
  return c;
end $$;

-- A title from words: one line, 32 characters, cut at a word. Null when there are none.
create or replace function public.yui_chat_title(t text) returns text
language plpgsql immutable
set search_path = ''
as $$
declare
  s text := btrim(regexp_replace(coalesce(t, ''), '\s+', ' ', 'g'));
  cut text;
begin
  if s = '' then
    return null;
  end if;
  if length(s) <= 32 then
    return s;
  end if;
  s := left(s, 32);
  cut := regexp_replace(s, '\s+\S*$', '');
  if length(cut) >= 8 then
    s := cut;
  end if;
  return btrim(s);
end $$;

-- 3. ---------------------------------------------------------------------------
create or replace function public.yui_chat_assign() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  c public.yui_chats;
  named uuid;
  turn_chat uuid;
begin
  -- Groups have their own place, and the agent's Controls traffic is the agent's.
  if new.thread_id is not null or new.agent_id is null
     or (new.kind = 'control' and not (new.sender = 'user' and new.body = 'stop')) then
    new.chat_id := null;
    new.meta := new.meta - 'chat';
    return new;
  end if;

  if new.sender = 'user' then
    if new.chat_id is not null then
      select * into c from public.yui_chats
       where id = new.chat_id and user_id = new.user_id and agent_id = new.agent_id;
      if c.id is null then
        raise sqlstate '22023' using message = 'chat_not_found';
      end if;
    else
      -- Two statements: the second sees a chat the first just made.
      named := public.yui_chat_newest(new.user_id, new.agent_id);
      select * into c from public.yui_chats where id = named;
    end if;
    -- What the host reads: which session, whether it is the first chat, and
    -- whether this is the first row in it. Only this trigger writes it.
    new.chat_id := c.id;
    new.meta := (new.meta - 'chat') || jsonb_build_object('chat', jsonb_build_object(
      'id', c.id, 'first', c.is_first,
      'new', not exists (select 1 from public.yui_messages m where m.chat_id = c.id)));
    return new;
  end if;

  -- An agent's row: the chat of the row it answers.
  new.chat_id := null;
  if jsonb_typeof(new.meta -> 'turn') = 'array' then
    select m.chat_id into turn_chat from public.yui_messages m
     where m.agent_id = new.agent_id and m.user_id = new.user_id and m.sender = 'user'
       and m.chat_id is not null
       and m.id::text in (select jsonb_array_elements_text(new.meta -> 'turn'))
     order by m.created_at desc limit 1;
    new.chat_id := turn_chat;
  end if;
  if new.chat_id is null and jsonb_typeof(new.meta -> 'chat') = 'string'
     and (new.meta ->> 'chat') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    named := (new.meta ->> 'chat')::uuid;
    select id into new.chat_id from public.yui_chats
     where id = named and user_id = new.user_id and agent_id = new.agent_id;
  end if;
  if new.chat_id is null then
    new.chat_id := public.yui_chat_newest(new.user_id, new.agent_id);
  end if;
  new.meta := new.meta - 'chat';
  return new;
end $$;
-- Named to fire after the group, mention and shared-agent triggers, which may
-- set thread_id or refuse the row first.
drop trigger if exists yui_zchat_assign on public.yui_messages;
create trigger yui_zchat_assign before insert on public.yui_messages
  for each row execute function public.yui_chat_assign();

-- 4. ---------------------------------------------------------------------------
create or replace function public.yui_chat_touch() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  c public.yui_chats;
  new_title text;
  said text;
begin
  if new.chat_id is null then
    return new;
  end if;
  select * into c from public.yui_chats where id = new.chat_id for update;
  if c.id is null then
    return new;
  end if;
  update public.yui_chats set last_at = greatest(c.last_at, new.created_at) where id = c.id;
  if c.title is not null or c.titled_by <> 'auto' or c.is_first or new.kind <> 'text' then
    return new;
  end if;
  if new.sender = 'user' then
    -- The person's first words. A tap or a photo (`[yui] ...`) has none.
    if new.body !~ '^\s*\[yui\]' then
      new_title := public.yui_chat_title(new.body);
    end if;
  elsif not exists (select 1 from public.yui_messages m
                     where m.chat_id = c.id and m.sender = 'user' and m.kind = 'text' and m.body !~ '^\s*\[yui\]') then
    -- The person opened it with a tap or a photo: the agent's first line names it.
    said := regexp_replace(new.body, '```.*?```', '', 'gs');
    said := (regexp_split_to_array(btrim(said, E' \n\r\t'), E'\n'))[1];
    new_title := public.yui_chat_title(said);
  end if;
  if new_title is not null then
    update public.yui_chats set title = new_title where id = c.id and titled_by = 'auto' and title is null;
  end if;
  return new;
end $$;
drop trigger if exists yui_chat_touch on public.yui_messages;
create trigger yui_chat_touch after insert on public.yui_messages
  for each row when (new.chat_id is not null) execute function public.yui_chat_touch();

-- Chats: min build, cap, first, rename, the last chat stays ------------------
create or replace function public.yui_chats_guard() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  caller text := public.yui_caller();
  build int;
  n bigint;
begin
  if tg_op = 'INSERT' then
    select count(*) into n from public.yui_chats where user_id = new.user_id and agent_id = new.agent_id;
    new.is_first := (n = 0);
    new.titled_by := 'auto';
    if caller = 'yui_user' and n > 0 then
      select max(app_build) into build from public.yui_devices where user_id = new.user_id;
      if coalesce(build, 0) < public.yui_limit('chats_min_build') then
        raise sqlstate 'PT403' using message = 'update_needed';
      end if;
    end if;
    if caller in ('yui_user', 'service_role') then
      if public.yui_user_suspended(new.user_id) then
        raise sqlstate 'PT403' using message = 'account_suspended';
      end if;
      if n >= public.yui_limit('chats_per_agent') then
        raise sqlstate 'PT403' using message = 'limit_reached', detail = 'yui_chats';
      end if;
    end if;
    return new;
  end if;

  if tg_op = 'UPDATE' then
    if new.title is distinct from old.title then
      new.title := nullif(btrim(new.title), '');
      new.titled_by := case when new.title is null then 'auto' else 'person' end;
    end if;
    return new;
  end if;

  -- DELETE. An agent's last chat stays (the app clears it instead); an agent or
  -- account going away takes its chats with it.
  if exists (select 1 from public.yui_agents a where a.id = old.agent_id)
     and exists (select 1 from public.yui_users u where u.id = old.user_id)
     and not exists (select 1 from public.yui_chats c
                      where c.user_id = old.user_id and c.agent_id = old.agent_id and c.id <> old.id) then
    raise sqlstate '23514' using message = 'last_chat';
  end if;
  return old;
end $$;
drop trigger if exists yui_chats_guard on public.yui_chats;
create trigger yui_chats_guard before insert or update or delete on public.yui_chats
  for each row execute function public.yui_chats_guard();

-- A new agent has its first chat before anyone says a word.
create or replace function public.yui_agent_first_chat() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  insert into public.yui_chats (user_id, agent_id) values (new.user_id, new.id) on conflict do nothing;
  return new;
end $$;
drop trigger if exists yui_agents_first_chat on public.yui_agents;
create trigger yui_agents_first_chat after insert on public.yui_agents
  for each row execute function public.yui_agent_first_chat();

revoke all on function public.yui_chat_newest(uuid, uuid), public.yui_chat_title(text),
  public.yui_chat_assign(), public.yui_chat_touch(), public.yui_chats_guard(), public.yui_agent_first_chat()
  from public, anon, authenticated, yui_user, yui_connector;

-- 5. ---------------------------------------------------------------------------
-- The drawer's list in one call: each chat with the last line said and whether
-- the agent's newest text is newer than the last time the person looked. Read
-- as the caller, so a shared agent's rows stay behind the grant.
create or replace view public.yui_chat_list with (security_invoker = true) as
select c.id, c.user_id, c.agent_id, c.title, c.titled_by, c.is_first, c.last_at, c.seen_at, c.created_at,
       lm.sender as last_sender, left(lm.body, 200) as last_body, lm.created_at as last_message_at,
       coalesce(lm.sender = 'agent' and lm.created_at > c.seen_at, false) as unread
  from public.yui_chats c
  left join lateral (
    select m.sender, m.body, m.created_at from public.yui_messages m
     where m.chat_id = c.id and m.kind = 'text' order by m.created_at desc limit 1) lm on true;
revoke all on public.yui_chat_list from public, anon, authenticated;
grant select on public.yui_chat_list to yui_user;

-- 6. ---------------------------------------------------------------------------
insert into public.yui_limits (name, value, note) values
  ('chats_per_agent', 500, 'chats one person may hold with one agent (YUI-169); past it New chat says the list is full'),
  ('chats_min_build', 10000, 'oldest app build that may start a second chat; the app card sets it to the first build with the drawer chat list')
on conflict (name) do nothing;

-- Realtime: a rename or a delete reaches the person's other phones.
do $$ begin
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'yui_chats') then
    alter publication supabase_realtime add table public.yui_chats;
  end if;
end $$;

notify pgrst, 'reload schema';
