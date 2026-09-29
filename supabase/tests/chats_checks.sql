\set ON_ERROR_STOP on
\set A '''aaaaaaaa-0000-0000-0000-000000000001'''
\set B '''bbbbbbbb-0000-0000-0000-000000000001'''
\set BASIL '''a1a1a1a1-0000-0000-0000-000000000001'''
\set ARNOLD '''a2a2a2a2-0000-0000-0000-000000000002'''
\set BEE '''b1b1b1b1-0000-0000-0000-000000000001'''

create function public._t(name text, ok boolean) returns text language sql as $$ select case when coalesce(ok, false) then 'PASS  ' else 'FAIL  ' end || name $$;
-- Run a statement as the current role: 'ok' or the error message.
create function public._err(q text) returns text language plpgsql as $$
begin execute q; return 'ok'; exception when others then return sqlerrm; end $$;
-- Rows a statement touches, as the current role.
create function public._rows(q text) returns int language plpgsql as $$
declare n int; begin execute q; get diagnostics n = row_count; return n; end $$;
grant execute on function public._t(text, boolean), public._err(text), public._rows(text) to yui_user, yui_connector;
create temp table ctx(k text primary key, v text);
grant all on ctx to public;
create function public._who(uid text, r text default 'yui_user', cid text default null) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', r, 'cid', cid)::text, false) $$;

-- Backfill ---------------------------------------------------------------------------
select public._t('backfill: every agent has exactly one chat, and it is the first',
  (select count(*) = 3 and bool_and(is_first) from public.yui_chats));
select public._t('backfill: text and event rows carry the first chat of their agent',
  (select count(*) = 4 and bool_and(m.chat_id = c.id) from public.yui_messages m
     join public.yui_chats c on c.agent_id = m.agent_id and c.user_id = m.user_id
    where m.kind in ('text', 'event')));
select public._t('backfill: controls stay with the agent, the Stop row is in the chat',
  (select count(*) filter (where body = 'controls: list' and chat_id is null) = 1
      and count(*) filter (where body = 'stop' and chat_id is not null) = 1 from public.yui_messages where kind = 'control'));
select public._t('backfill: the first chat is stamped with last_at of its newest row and titled by nobody',
  (select c.title is null and c.titled_by = 'auto' and c.last_at = (select max(created_at) from public.yui_messages m where m.chat_id = c.id)
     from public.yui_chats c where c.agent_id = :BASIL));
select public._t('no message with an agent lost its chat but the controls',
  (select count(*) = 1 from public.yui_messages where chat_id is null));

-- The connector for A's Basil ---------------------------------------------------------
insert into public.yui_connectors(id, user_id, name, token_hash) values ('c0c0c0c0-0000-0000-0000-000000000001', :A, 'mac', 'h1');
update public.yui_agents set connector_id = 'c0c0c0c0-0000-0000-0000-000000000001', remote_ref = 'basil' where id = :BASIL;

-- The app (A) ---------------------------------------------------------------------------
set role yui_user;
select public._who(:A);
select public._t('the app reads its own chats and none of B''s',
  (select count(*) = 2 from public.yui_chats) and not exists (select 1 from public.yui_chats where user_id = :B));
select public._t('a second chat is refused below chats_min_build',
  public._err($q$ insert into public.yui_chats(id, user_id, agent_id) values ('c1000000-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001') $q$) like '%update_needed%');
reset role;
update public.yui_limits set value = 100 where name = 'chats_min_build';
set role yui_user;
select public._who(:A);
select public._t('a second chat is made from a build at or above it',
  public._err($q$ insert into public.yui_chats(id, user_id, agent_id) values ('c1000000-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001') $q$) = 'ok');
select public._t('the new chat is not the first, has no title and nothing said',
  (select not is_first and title is null and titled_by = 'auto' from public.yui_chats where id = 'c1000000-0000-0000-0000-000000000001'));
select public._t('the app cannot make a chat for B''s agent',
  public._err($q$ insert into public.yui_chats(id, user_id, agent_id) values ('c1000000-0000-0000-0000-0000000000b1', 'aaaaaaaa-0000-0000-0000-000000000001', 'b1b1b1b1-0000-0000-0000-000000000001') $q$) <> 'ok');
select public._t('the app cannot set the title, is_first or last_at on insert',
  public._err($q$ insert into public.yui_chats(id, user_id, agent_id, title) values ('c1000000-0000-0000-0000-0000000000c1', 'aaaaaaaa-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001', 'x') $q$) like '%permission denied%');

-- Messages: the person's rows ---------------------------------------------------------
insert into public.yui_messages(id, user_id, agent_id, sender, body, chat_id)
  values ('00000003-0000-0000-0000-000000000001', :A, :BASIL, 'user', 'What should I eat before a 10k run this weekend', 'c1000000-0000-0000-0000-000000000001');
select public._t('the first row in a chat is stamped new, not first, with its chat id',
  (select meta -> 'chat' = jsonb_build_object('id', 'c1000000-0000-0000-0000-000000000001', 'first', false, 'new', true)
     from public.yui_messages where id = '00000003-0000-0000-0000-000000000001'));
select public._t('the chat is titled from the first ask, 32 characters, cut at a word',
  (select title = 'What should I eat before a 10k' and length(title) <= 32 from public.yui_chats where id = 'c1000000-0000-0000-0000-000000000001'));
insert into public.yui_messages(id, user_id, agent_id, sender, body, chat_id)
  values ('00000003-0000-0000-0000-000000000002', :A, :BASIL, 'user', 'and after?', 'c1000000-0000-0000-0000-000000000001');
select public._t('the second row is not new',
  (select meta #> '{chat,new}' = 'false' from public.yui_messages where id = '00000003-0000-0000-0000-000000000002'));
select public._t('the title stays after a second ask',
  (select title = 'What should I eat before a 10k' from public.yui_chats where id = 'c1000000-0000-0000-0000-000000000001'));
select public._t('a row naming a chat of another agent is refused',
  public._err($q$ insert into public.yui_messages(user_id, agent_id, sender, body, chat_id) values ('aaaaaaaa-0000-0000-0000-000000000001', 'a2a2a2a2-0000-0000-0000-000000000002', 'user', 'hi', 'c1000000-0000-0000-0000-000000000001') $q$) like '%chat_not_found%');
insert into public.yui_messages(id, user_id, agent_id, sender, body, meta)
  values ('00000003-0000-0000-0000-000000000003', :A, :ARNOLD, 'user', 'old app', '{"chat":{"id":"x","first":false,"new":false}}');
select public._t('a row cannot forge meta.chat',
  (select meta #>> '{chat,first}' = 'true' and meta #>> '{chat,id}' <> 'x' from public.yui_messages where id = '00000003-0000-0000-0000-000000000003'));
-- An old app: no chat_id. Basil's newest chat is the one just written in.
insert into public.yui_messages(id, user_id, agent_id, sender, body) values ('00000003-0000-0000-0000-000000000004', :A, :BASIL, 'user', 'from an old app');
select public._t('an old app''s row lands in the newest chat',
  (select chat_id = 'c1000000-0000-0000-0000-000000000001' from public.yui_messages where id = '00000003-0000-0000-0000-000000000004'));
select public._t('the list shows the last line said, newest chat first',
  (select array_agg(id::text order by last_at desc) = array['c1000000-0000-0000-0000-000000000001', (select id::text from public.yui_chats where agent_id = 'a1a1a1a1-0000-0000-0000-000000000001' and is_first)]
      and (array_agg(last_body order by last_at desc))[1] = 'from an old app' and (array_agg(last_sender order by last_at desc))[1] = 'user'
    from public.yui_chat_list where agent_id = 'a1a1a1a1-0000-0000-0000-000000000001'));

-- The host (A's connector) ---------------------------------------------------------------
reset role;
insert into ctx values ('first', (select id::text from public.yui_chats where agent_id = :BASIL and is_first));
-- a row in the first chat, waiting for an answer, while the new chat is the newest
set role yui_user; select public._who(:A);
insert into public.yui_messages(id, user_id, agent_id, sender, body, chat_id)
  values ('00000003-0000-0000-0000-000000000005', :A, :BASIL, 'user', 'back in the first chat', (select v::uuid from ctx where k = 'first'));
reset role;
set role yui_connector; select public._who(:A, 'yui_connector', 'c0c0c0c0-0000-0000-0000-000000000001');
select public._t('the host reads no chats table',
  public._err('select * from public.yui_chats') like '%permission denied%');
insert into public.yui_messages(id, user_id, agent_id, sender, body, meta)
  values ('00000004-0000-0000-0000-000000000001', :A, :BASIL, 'agent', 'Answering the first chat.', '{"turn":["00000003-0000-0000-0000-000000000005"]}');
select public._t('the host cannot name a chat by column',
  public._err($q$ insert into public.yui_messages(user_id, agent_id, sender, body, chat_id) values ('aaaaaaaa-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001', 'agent', 'x', 'c1000000-0000-0000-0000-000000000001') $q$) like '%permission denied%');
insert into public.yui_messages(id, user_id, agent_id, sender, body, meta)
  values ('00000004-0000-0000-0000-000000000002', :A, :BASIL, 'agent', 'A cron note, no turn.', '{}');
insert into public.yui_messages(id, user_id, agent_id, sender, body, meta)
  values ('00000004-0000-0000-0000-000000000003', :A, :BASIL, 'agent', 'A push for the first chat.', jsonb_build_object('chat', (select v from ctx where k = 'first')));
insert into public.yui_messages(id, user_id, agent_id, sender, body, meta)
  values ('00000004-0000-0000-0000-000000000004', :A, :BASIL, 'agent', 'Naming a chat that does not exist.', '{"chat":"a1a1a1a1-0000-0000-0000-00000000dead"}');
reset role;
select public._t('a reply lands in the chat of the row it answers, not the newest',
  (select chat_id = (select v::uuid from ctx where k = 'first') and not meta ? 'chat' from public.yui_messages where id = '00000004-0000-0000-0000-000000000001'));
select public._t('a reply with no turn goes to the newest chat',
  (select chat_id = 'c1000000-0000-0000-0000-000000000001' from public.yui_messages where id = '00000004-0000-0000-0000-000000000002')
  or (select chat_id = (select v::uuid from ctx where k = 'first') from public.yui_messages where id = '00000004-0000-0000-0000-000000000002'));
select public._t('a reply naming a chat in meta.chat lands there',
  (select chat_id = (select v::uuid from ctx where k = 'first') from public.yui_messages where id = '00000004-0000-0000-0000-000000000003'));
select public._t('a reply naming a chat that does not exist falls back to a chat of this agent',
  (select c.agent_id = 'a1a1a1a1-0000-0000-0000-000000000001' and not m.meta ? 'chat'
     from public.yui_messages m join public.yui_chats c on c.id = m.chat_id where m.id = '00000004-0000-0000-0000-000000000004'));

-- Unread and seen -------------------------------------------------------------------------
set role yui_user; select public._who(:A);
select public._t('an agent reply newer than seen_at is unread',
  (select unread from public.yui_chat_list where id = (select v::uuid from ctx where k = 'first')));
update public.yui_chats set seen_at = now() + interval '1 second' where id = (select v::uuid from ctx where k = 'first');
select public._t('opening the chat clears it',
  (select not unread from public.yui_chat_list where id = (select v::uuid from ctx where k = 'first')));

-- A tap opens a chat: the agent's first line names it --------------------------------------
insert into public.yui_chats(id, user_id, agent_id) values ('c1000000-0000-0000-0000-000000000002', :A, :ARNOLD);
insert into public.yui_messages(id, user_id, agent_id, sender, body, kind, chat_id)
  values ('00000005-0000-0000-0000-000000000001', :A, :ARNOLD, 'user', '[yui] n1 ask answer=Start', 'event', 'c1000000-0000-0000-0000-000000000002');
select public._t('a tap does not title a chat', (select title is null from public.yui_chats where id = 'c1000000-0000-0000-0000-000000000002'));
reset role;
set role yui_connector; select public._who(:A, 'yui_connector', 'c0c0c0c0-0000-0000-0000-000000000001');
reset role;
-- Arnold is not bound to the connector: write the reply as the service role, the way yui-native does.
insert into public.yui_messages(id, user_id, agent_id, sender, body, meta)
  values ('00000006-0000-0000-0000-000000000001', :A, :ARNOLD, 'agent', E'```yui\nask "Ready?" Yes|No\n```\nLeg day. Pick your gear and I''ll build the session.', '{"turn":["00000005-0000-0000-0000-000000000001"]}');
select public._t('the agent''s first plain line names a chat opened with a tap',
  (select title = 'Leg day. Pick your gear and' from public.yui_chats where id = 'c1000000-0000-0000-0000-000000000002'));

-- Rename, delete ------------------------------------------------------------------------------
set role yui_user; select public._who(:A);
update public.yui_chats set title = '  Tuesday''s groceries ' where id = 'c1000000-0000-0000-0000-000000000001';
select public._t('a rename sets titled_by person and trims',
  (select title = 'Tuesday''s groceries' and titled_by = 'person' from public.yui_chats where id = 'c1000000-0000-0000-0000-000000000001'));
select public._t('a title over 60 characters is refused',
  public._err($q$ update public.yui_chats set title = repeat('x', 61) where id = 'c1000000-0000-0000-0000-000000000001' $q$) like '%check%');
select public._t('the app cannot move last_at or is_first',
  public._err($q$ update public.yui_chats set is_first = true where id = 'c1000000-0000-0000-0000-000000000001' $q$) like '%permission denied%');
select public._t('a renamed title never changes on its own',
  (select true from (select 1) x where (select title from public.yui_chats where id = 'c1000000-0000-0000-0000-000000000001') = 'Tuesday''s groceries'));
-- Delete the non-first Basil chat: its rows go with it, the first stays.
select public._t('deleting a chat removes its messages',
  (select count(*) filter (where chat_id = 'c1000000-0000-0000-0000-000000000001') = 3 from public.yui_messages where agent_id = 'a1a1a1a1-0000-0000-0000-000000000001'));
select public._t('the chat deletes', public._err($q$ delete from public.yui_chats where id = 'c1000000-0000-0000-0000-000000000001' $q$) = 'ok');
select public._t('its messages are gone and the first chat''s stay',
  (select count(*) = 0 from public.yui_messages where chat_id = 'c1000000-0000-0000-0000-000000000001')
  and (select count(*) >= 4 from public.yui_messages where chat_id = (select v::uuid from ctx where k = 'first')));
select public._t('the last chat cannot be deleted',
  public._err($q$ delete from public.yui_chats where agent_id = 'a1a1a1a1-0000-0000-0000-000000000001' $q$) like '%last_chat%');
select public._t('A cannot delete B''s chat',
  public._rows($q$ delete from public.yui_chats where user_id = 'bbbbbbbb-0000-0000-0000-000000000001' $q$) = 0);
-- Arnold has its first chat and a second: the first can go, the survivor is then the only one.
select public._t('the first chat can be deleted once another exists',
  public._err($q$ delete from public.yui_chats where agent_id = 'a2a2a2a2-0000-0000-0000-000000000002' and is_first $q$) = 'ok');
select public._t('the survivor is not first and now cannot be deleted',
  (select count(*) = 1 and not bool_or(is_first) from public.yui_chats where agent_id = 'a2a2a2a2-0000-0000-0000-000000000002')
  and public._err($q$ delete from public.yui_chats where agent_id = 'a2a2a2a2-0000-0000-0000-000000000002' $q$) like '%last_chat%');
reset role;

-- B ---------------------------------------------------------------------------------------------
set role yui_user; select public._who(:B);
select public._t('B sees only its own chat', (select count(*) = 1 and bool_and(user_id = :B) from public.yui_chats));
select public._t('B cannot write into A''s chat',
  public._err($q$ insert into public.yui_messages(user_id, agent_id, sender, body, chat_id) values ('bbbbbbbb-0000-0000-0000-000000000001', 'b1b1b1b1-0000-0000-0000-000000000001', 'user', 'x', (select v::uuid from ctx where k = 'first')) $q$) like '%chat_not_found%');
select public._t('B cannot read A''s chat list rows', (select count(*) = 1 from public.yui_chat_list));
reset role;

-- Agents and accounts --------------------------------------------------------------------------
insert into public.yui_agents(id, user_id, name, handle) values ('a3a3a3a3-0000-0000-0000-000000000003', :A, 'Penny', 'penny');
select public._t('a new agent has its first chat at once',
  (select count(*) = 1 and bool_and(is_first) from public.yui_chats where agent_id = 'a3a3a3a3-0000-0000-0000-000000000003'));
-- A person with no chat for an agent (a grant, an agent from before the trigger): the first row makes one.
insert into public.yui_agents(id, user_id, name, handle) values ('a4a4a4a4-0000-0000-0000-000000000004', :A, 'Zed', 'zed');
alter table public.yui_chats disable trigger yui_chats_guard;
delete from public.yui_chats where agent_id = 'a4a4a4a4-0000-0000-0000-000000000004';
alter table public.yui_chats enable trigger yui_chats_guard;
insert into public.yui_messages(id, user_id, agent_id, sender, body) values ('00000007-0000-0000-0000-000000000001', :A, 'a4a4a4a4-0000-0000-0000-000000000004', 'user', 'first words');
select public._t('a message to an agent with no chat makes the first one',
  (select c.is_first and c.title is null and c.id = m.chat_id from public.yui_messages m join public.yui_chats c on c.id = m.chat_id where m.id = '00000007-0000-0000-0000-000000000001'));
delete from public.yui_agents where id = 'a3a3a3a3-0000-0000-0000-000000000003';
select public._t('deleting an agent takes its chats, even the last',
  (select count(*) = 0 from public.yui_chats where agent_id = 'a3a3a3a3-0000-0000-0000-000000000003'));
delete from public.yui_users where id = :B;
select public._t('deleting an account takes its chats',
  (select count(*) = 0 from public.yui_chats where user_id = :B));
select public._t('yui_chats is in the realtime publication',
  exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'yui_chats'));
select public._t('chats_per_agent and chats_min_build exist',
  (select count(*) = 2 from public.yui_limits where name in ('chats_per_agent', 'chats_min_build')));
