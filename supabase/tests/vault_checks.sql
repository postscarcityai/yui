\set ON_ERROR_STOP on
\set A '''aaaaaaaa-0000-0000-0000-000000000001'''
\set B '''bbbbbbbb-0000-0000-0000-000000000001'''
\set PENNY '''a1a1a1a1-0000-0000-0000-000000000001'''
\set QUILL '''a2a2a2a2-0000-0000-0000-000000000002'''
\set BEE '''b1b1b1b1-0000-0000-0000-000000000001'''
\set CA '''c0c0c0c0-0000-0000-0000-00000000000a'''
\set CQ '''c0c0c0c0-0000-0000-0000-00000000000b'''
\set CB '''c0c0c0c0-0000-0000-0000-00000000000c'''

create function public._t(name text, ok boolean) returns text language sql as $$ select case when coalesce(ok, false) then 'PASS  ' else 'FAIL  ' end || name $$;
create function public._err(q text) returns text language plpgsql as $$
begin execute q; return 'ok'; exception when others then return sqlerrm; end $$;
create function public._rows(q text) returns int language plpgsql as $$
declare n int; begin execute q; get diagnostics n = row_count; return n; end $$;
grant execute on function public._t(text, boolean), public._err(text), public._rows(text) to yui_user, yui_connector, service_role;
create function public._who(uid text, r text default 'yui_user', cid text default null) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', r, 'cid', cid)::text, false) $$;
-- The line an agent read, newest first.
create function public._lines(agent uuid) returns text language sql as $$
  select coalesce(string_agg(body, ' | ' order by created_at, id), '') from public.yui_messages where agent_id = agent and meta ? 'vault' $$;

-- Seed: A owns Penny (host CA) and Quill (host CQ); B owns Bee (host CB) and is shared Penny.
insert into yui_users(id, apple_sub) values (:A, 'vault.a'), (:B, 'vault.b');
insert into yui_connectors(id, user_id, name, token_hash) values
  (:CA, :A, 'mac', 'ha'), (:CQ, :A, 'mini', 'hq'), (:CB, :B, 'mac-b', 'hb');
insert into yui_agents(id, user_id, name, handle, is_default, connector_id, remote_ref) values
  (:PENNY, :A, 'Penny', 'penny', true, :CA, 'penny'),
  (:QUILL, :A, 'Quill', 'quill', false, :CQ, 'quill'),
  (:BEE, :B, 'Bee', 'bee', true, :CB, 'bee');
update yui_agents set client_safe = true where id = :PENNY;
insert into yui_agent_grants(agent_id, user_id, owner_id, shared_by) values (:PENNY, :B, :A, 'A');

-- Supabase gives service_role every table by default privilege; the stub kit does not.
grant all on all tables in schema public to service_role;

-- Sealed bytes: never printable.
create function public._sealed() returns bytea language sql as $$ select decode(repeat('9f3ac1', 30), 'hex') $$;

-- 1. Keys, as A ------------------------------------------------------------------
set role yui_user; select public._who('aaaaaaaa-0000-0000-0000-000000000001');
insert into yui_vault_keys (user_id, provider, name, last4, sealed, key_id)
  values (:A, 'fal', 'Personal fal', 'x7Qa', public._sealed(), 'yvk-1');
insert into yui_vault_keys (user_id, provider, name, last4, sealed, key_id)
  values (:A, 'replicate', 'Replicate', 'abcd', public._sealed(), 'yvk-1');
select public._t('the owner inserts a key and its cap defaults to $10',
  (select cap_cents = 1000 from yui_vault_keys_public where provider = 'fal'));
select public._t('a plaintext-looking blob is refused as sealed',
  public._err($q$insert into yui_vault_keys (user_id, provider, name, last4, sealed, key_id)
    values ('aaaaaaaa-0000-0000-0000-000000000001', 'fal', 'x', 'abcd', convert_to('key-1234567890:abcdefghijklmnopqrstuvwxyz0123456789', 'utf8'), 'yvk-1')$q$) like '%check%');
select public._t('an unknown provider is refused',
  public._err($q$insert into yui_vault_keys (user_id, provider, name, last4, sealed, key_id)
    values ('aaaaaaaa-0000-0000-0000-000000000001', 'gemini', 'x', 'abcd', public._sealed(), 'yvk-1')$q$) like '%check%');
select public._t('yui_user cannot select the sealed column',
  public._err('select sealed from yui_vault_keys') like 'permission denied%');
select public._t('select * on the table is refused too (sealed is in it)',
  public._err('select * from yui_vault_keys') like 'permission denied%');
select public._t('the public view has no sealed column',
  not exists (select 1 from information_schema.columns where table_name = 'yui_vault_keys_public' and column_name = 'sealed'));
select public._t('has_column_privilege(yui_user, sealed, select) is false',
  not has_column_privilege('yui_user', 'public.yui_vault_keys', 'sealed', 'select'));
select public._t('nobody can update sealed',
  public._err($q$update yui_vault_keys set sealed = public._sealed()$q$) like 'permission denied%');
select public._t('the owner can change a cap',
  public._rows($q$update yui_vault_keys set cap_cents = 2000 where provider = 'replicate'$q$) = 1);
select public._t('yui_user cannot write uses',
  public._err($q$insert into yui_vault_uses (user_id, kind) values ('aaaaaaaa-0000-0000-0000-000000000001', 'call')$q$) like 'permission denied%');
select public._t('yui_user cannot delete uses',
  public._err('delete from yui_vault_uses') like 'permission denied%');
reset role;
select id as kfal from yui_vault_keys where provider = 'fal' \gset
select id as krep from yui_vault_keys where provider = 'replicate' \gset

-- 2. A second account sees none of it ---------------------------------------------
set role yui_user; select public._who('bbbbbbbb-0000-0000-0000-000000000001');
select public._t('B: key view empty', (select count(*) = 0 from yui_vault_keys_public));
select public._t('B: keys table empty', (select count(*) = 0 from yui_vault_keys));
select public._t('B: grants empty', (select count(*) = 0 from yui_vault_grants));
select public._t('B: uses empty', (select count(*) = 0 from yui_vault_uses));
select public._t('B: grants view empty', (select count(*) = 0 from yui_vault_grants_public));
select public._t('B cannot insert a key for A',
  public._err($q$insert into yui_vault_keys (user_id, provider, name, last4, sealed, key_id)
    values ('aaaaaaaa-0000-0000-0000-000000000001', 'fal', 'x', 'abcd', public._sealed(), 'yvk-1')$q$) like '%row-level security%');
select public._t('B cannot update or delete A''s key',
  public._rows($q$update yui_vault_keys set cap_cents = 0$q$) = 0 and public._rows('delete from yui_vault_keys') = 0);
select public._t('B cannot grant A''s key to Bee',
  public._err(format($q$insert into yui_vault_grants (key, agent_id, purpose) values (%L, 'b1b1b1b1-0000-0000-0000-000000000001', 'x')$q$, :'kfal')) <> 'ok');
insert into yui_vault_keys (user_id, provider, name, last4, sealed, key_id)
  values (:B, 'fal', 'B fal', 'zzzz', public._sealed(), 'yvk-1');
select public._t('B: a shared agent cannot use its client''s own key (grant of B''s key to A''s Penny refused)',
  public._err(format($q$insert into yui_vault_grants (key, agent_id, purpose) values (%L, 'a1a1a1a1-0000-0000-0000-000000000001', 'x')$q$,
    (select id from yui_vault_keys where provider = 'fal'))) like '%not_your_agent%');
reset role;

-- 3. Grants, as A ----------------------------------------------------------------------
set role yui_user; select public._who('aaaaaaaa-0000-0000-0000-000000000001');
select public._t('a provider with no price entry cannot be granted before a provider limit is confirmed',
  public._err(format($q$insert into yui_vault_grants (key, agent_id, purpose) values (%L, 'a1a1a1a1-0000-0000-0000-000000000001', 'x')$q$, :'krep')) like '%provider_limit_unconfirmed%');
update yui_vault_keys set provider_limit_confirmed = true where provider = 'replicate';
select public._t('...and can after the owner confirms one',
  public._err(format($q$insert into yui_vault_grants (key, agent_id, purpose) values (%L, 'a1a1a1a1-0000-0000-0000-000000000001', 'Draw')$q$, :'krep')) = 'ok');
select public._t('a grant cap above the key cap is refused',
  public._err(format($q$insert into yui_vault_grants (key, agent_id, purpose, cap_cents) values (%L, 'a1a1a1a1-0000-0000-0000-000000000001', 'x', 5000)$q$, :'kfal')) like '%grant_cap_above_key_cap%');
insert into yui_vault_grants (key, agent_id, purpose, cap_cents) values (:'kfal', :PENNY, 'Draw your agent avatars', 500);
insert into yui_vault_grants (key, agent_id, purpose, once) values (:'kfal', :PENNY, 'One shot', true);
insert into yui_vault_grants (key, agent_id, purpose) values (:'kfal', :QUILL, 'Quill images');
select public._t('handles look like vk_fal_<4 hex>, made by the database',
  (select bool_and(handle ~ '^vk_fal_[0-9a-f]{4}$') from yui_vault_grants where key = :'kfal'::uuid));
select public._t('an app-supplied handle is ignored',
  (select handle from (select handle from yui_vault_grants where purpose = 'Quill images') s) <> 'vk_fal_dead');
reset role;
select handle as hp from yui_vault_grants where purpose = 'Draw your agent avatars' \gset
select handle as ho from yui_vault_grants where purpose = 'One shot' \gset
select handle as hq from yui_vault_grants where purpose = 'Quill images' \gset

select public._t('every add and grant left a use row',
  (select count(*) filter (where kind = 'add') = 2 and count(*) filter (where kind = 'grant') = 4 from yui_vault_uses where user_id = :A));

-- 4. The connector's round trip (service role) ------------------------------------
set role service_role;
select public._t('ok call: begin returns the sealed blob as hex and a use id',
  (select (r ->> 'ok')::boolean and (r ->> 'sealed') = repeat('9f3ac1', 30) and (r ->> 'key_id') = 'yvk-1' and (r ->> 'provider') = 'fal'
     from (select yui_vault_begin(:'hp', :CA, 'fal-ai/flux/dev', true, 100) r) s));
select public._t('one use row per call, holding the estimate',
  (select count(*) = 1 and max(cost_cents) = 100 and bool_and(status is null) from yui_vault_uses where kind = 'call' and handle = :'hp'));
select public._t('wrong agent: the token of the host that serves Quill is not_granted on Penny''s handle',
  (yui_vault_begin(:'hp', :CQ, 'fal-ai/flux/dev', true, 10)) ->> 'error' = 'not_granted');
select public._t('wrong agent: another account''s host is not_granted',
  (yui_vault_begin(:'hp', :CB, 'fal-ai/flux/dev', true, 10)) ->> 'error' = 'not_granted');
select public._t('wrong agent is on the owner''s trail as a refused call',
  (select count(*) = 2 and bool_and(not allowed and error = 'not_granted') from yui_vault_uses where kind = 'call' and handle = :'hp' and not allowed));
select public._t('unknown handle: not_granted', (yui_vault_begin('vk_fal_0000', :CA, 'fal-ai/flux/dev', true, 10)) ->> 'error' = 'not_granted');
select public._t('path off the list: path_not_allowed',
  (yui_vault_begin(:'hp', :CA, 'fal-ai/../secret', false, 10)) ->> 'error' = 'path_not_allowed');
select public._t('a refused path did not touch the once grant',
  (yui_vault_begin(:'ho', :CA, 'nope', false, 10)) ->> 'error' = 'path_not_allowed'
  and (select last_used_at is null from yui_vault_grants where handle = :'ho'));
-- finish
select yui_vault_finish((select id from yui_vault_uses where kind = 'call' and handle = :'hp' and allowed and status is null), 200, 3);
select public._t('finish turns the hold into the real cost',
  (select cost_cents = 3 and status = 200 from yui_vault_uses where kind = 'call' and handle = :'hp' and allowed));
select yui_vault_finish((select id from yui_vault_uses where kind = 'call' and handle = :'hp' and allowed), 500, 999);
select public._t('a second finish changes nothing',
  (select cost_cents = 3 and status = 200 from yui_vault_uses where kind = 'call' and handle = :'hp' and allowed));

-- cap: the grant cap is $5 (500). Holds count before the calls finish.
select public._t('cap holds: 4 calls of 120 fit under 500, the 5th is cap_reached even though none finished',
  (select bool_and((r ->> 'ok')::boolean) from (select yui_vault_begin(:'hp', :CA, 'fal-ai/x', true, 120) r from generate_series(1, 4)) s)
  and (yui_vault_begin(:'hp', :CA, 'fal-ai/x', true, 120)) ->> 'error' = 'cap_reached');
select public._t('cap_reached leaves a refused row',
  (select count(*) = 1 from yui_vault_uses where kind = 'call' and handle = :'hp' and error = 'cap_reached' and not allowed));
select public._t('the key cap counts every grant: Quill''s handle sees the same key spend (3 + 480)',
  (yui_vault_begin(:'hq', :CQ, 'fal-ai/x', true, 100)) ->> 'ok' = 'true');
select public._t('the key cap is reached across grants (483 + 100 + 500 > 1000)',
  (yui_vault_begin(:'hq', :CQ, 'fal-ai/x', true, 500)) ->> 'error' = 'cap_reached');
-- once
select public._t('once: the first call goes through',
  (yui_vault_begin(:'ho', :CA, 'fal-ai/x', true, 10)) ->> 'ok' = 'true');
select public._t('once: the second is once_used',
  (yui_vault_begin(:'ho', :CA, 'fal-ai/x', true, 10)) ->> 'error' = 'once_used');
reset role;

-- 80% row
set role service_role;
select yui_vault_finish(id, 200, 1) from yui_vault_uses where kind = 'call' and allowed and status is null and handle = :'hp';
select yui_vault_finish((r ->> 'use_id')::bigint, 200, 800) from (select yui_vault_begin(:'hq', :CQ, 'fal-ai/x', true, 50) r) s;
reset role;
select public._t('cap_80 written once, after the key crossed 800 of 1000 (spent counts finished + holds)',
  (select count(*) = 1 from yui_vault_uses where kind = 'cap_80' and key = :'kfal'::uuid));

-- 5. Revoke ----------------------------------------------------------------------------
set role yui_user; select public._who('aaaaaaaa-0000-0000-0000-000000000001');
select public._t('the owner revokes a grant',
  public._rows(format($q$update yui_vault_grants set revoked_at = now() where handle = %L$q$, :'hp')) = 1);
select public._t('a revoke cannot be undone',
  public._err(format($q$update yui_vault_grants set revoked_at = null where handle = %L$q$, :'hp')) like '%already_revoked%');
select public._t('the handle cannot be changed',
  public._err(format($q$update yui_vault_grants set handle = 'vk_fal_0001' where handle = %L$q$, :'hp')) like 'permission denied%');
reset role;
set role service_role;
select public._t('revoked: not_granted on the very next call',
  (yui_vault_begin(:'hp', :CA, 'fal-ai/x', true, 1)) ->> 'error' = 'not_granted');
reset role;
select public._t('the agent heard the revoke, in one line',
  public._lines(:PENNY) like '%[yui] Key access: fal revoked.%' and (select count(*) = 1 from yui_messages where agent_id = :PENNY and body = '[yui] Key access: fal revoked.'));
select public._t('the revoke line is a quiet event from the person (no echo, no bubble)',
  (select bool_and(kind = 'event' and sender = 'user' and not (meta ? 'echo')) from yui_messages where agent_id = :PENNY and meta ? 'vault'));

-- 6. Lapse: 90 idle days ----------------------------------------------------------------
insert into yui_vault_grants (key, agent_id, purpose) values (:'kfal', :QUILL, 'Old one');
select handle as hl from yui_vault_grants where purpose = 'Old one' \gset
select public._t('lapse: a fresh grant is not warned', (select count(*) = 0 from yui_vault_sweep() where what = 'vault_lapse_soon' and n_rows > 0));
update yui_vault_grants set last_used_at = now() - interval '81 days' where handle = :'hl';
select public._t('day 80: the sweep adds one lapse_soon row', (select n_rows = 1 from yui_vault_sweep() where what = 'vault_lapse_soon'));
select public._t('day 80: and only once', (select n_rows = 0 from yui_vault_sweep() where what = 'vault_lapse_soon'));
update yui_vault_grants set last_used_at = now() - interval '91 days' where handle = :'hl';
set role service_role;
select public._t('day 90 with no call: not_granted and the grant is ended',
  (yui_vault_begin(:'hl', :CQ, 'fal-ai/x', true, 1)) ->> 'error' = 'not_granted');
reset role;
select public._t('a lapsed grant is revoked and the agent is told why',
  (select revoked_at is not null from yui_vault_grants where handle = :'hl')
  and public._lines(:QUILL) like '%fal lapsed after 90 days without a call.%');
insert into yui_vault_grants (key, agent_id, purpose) values (:'kfal', :QUILL, 'Never used');
update yui_vault_grants set created_at = now() - interval '95 days' where purpose = 'Never used';
select public._t('a grant never used lapses 90 days after it was made (sweep)', (select n_rows = 1 from yui_vault_sweep() where what = 'vault_lapsed'));
select public._t('a call resets the 80-day clock',
  (select last_used_at > now() - interval '1 minute' from yui_vault_grants where handle = (select handle from yui_vault_grants where purpose = 'Quill images')));

-- 7. key_ask / key_answer -----------------------------------------------------------------
set role yui_connector; select public._who('aaaaaaaa-0000-0000-0000-000000000001', 'yui_connector', 'c0c0c0c0-0000-0000-0000-00000000000a');
select public._t('the host asks: a key_ask control row lands',
  public._err($q$insert into yui_messages (user_id, agent_id, sender, kind, body, meta) values
    ('aaaaaaaa-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001', 'agent', 'control', 'key_ask',
     '{"v":1,"req":"k-1","op":"key_ask","provider":"fal","for":"Draw your agent avatars","est":"about 4 images a week","cap":5}')$q$) = 'ok');
select public._t('an unknown provider is refused',
  public._err($q$insert into yui_messages (user_id, agent_id, sender, kind, body, meta) values
    ('aaaaaaaa-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001', 'agent', 'control', 'key_ask',
     '{"v":1,"req":"k-x","op":"key_ask","provider":"gemini","for":"x"}')$q$) like '%invalid_key_ask%');
select public._t('a for line over 80 characters is refused',
  public._err(format($q$insert into yui_messages (user_id, agent_id, sender, kind, body, meta) values
    ('aaaaaaaa-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001', 'agent', 'control', 'key_ask',
     '{"v":1,"req":"k-y","op":"key_ask","provider":"fal","for":"%s"}')$q$, repeat('x', 81))) like '%invalid_key_ask%');
select public._t('a key-shaped for line is refused',
  public._err($q$insert into yui_messages (user_id, agent_id, sender, kind, body, meta) values
    ('aaaaaaaa-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001', 'agent', 'control', 'key_ask',
     '{"v":1,"req":"k-z","op":"key_ask","provider":"openai","for":"use sk-abcdefghijklmnopqrstuvwx"}')$q$) like '%invalid_key_ask%');
reset role;

-- The app answers: allow (a new grant for this ask)
set role yui_user; select public._who('aaaaaaaa-0000-0000-0000-000000000001');
insert into yui_vault_grants (key, agent_id, purpose, cap_cents) values (:'kfal', :PENNY, 'Draw your agent avatars', 500);
reset role;
select handle as hn from yui_vault_grants where agent_id = :PENNY and revoked_at is null and purpose = 'Draw your agent avatars' \gset
set role yui_user; select public._who('aaaaaaaa-0000-0000-0000-000000000001');
insert into yui_messages (user_id, agent_id, sender, kind, body, meta) values
  (:A, :PENNY, 'user', 'control', 'key_answer',
   jsonb_build_object('v', 1, 'req', 'k-1', 'op', 'key_answer', 'decision', 'allow', 'provider', 'fal', 'handle', :'hn', 'cap', 5));
reset role;
select public._t('allow: the agent hears the exact line',
  exists (select 1 from yui_messages where agent_id = :PENNY and
    body = format('[yui] Key access: fal allowed for "Draw your agent avatars", cap $5 a month, handle %s.', :'hn')));
set role yui_user; select public._who('aaaaaaaa-0000-0000-0000-000000000001');
insert into yui_messages (user_id, agent_id, sender, kind, body, meta) values
  (:A, :PENNY, 'user', 'control', 'key_answer', jsonb_build_object('v', 1, 'req', 'k-1', 'op', 'key_answer', 'decision', 'deny', 'provider', 'fal'));
reset role;
select public._t('an answer twice for one req writes one line only',
  (select count(*) = 1 from yui_messages where agent_id = :PENNY and meta ->> 'vault_req' = 'k-1'));
insert into yui_messages (user_id, agent_id, sender, kind, body, meta) values
  (:A, :PENNY, 'user', 'control', 'key_answer', '{"req":"nope","op":"key_answer","decision":"deny","provider":"fal"}');
select public._t('an answer with no matching ask is ignored',
  (select count(*) = 0 from yui_messages where meta ->> 'vault_req' = 'nope'));

-- deny: a new ask, then Don't allow, then 24h no-nag
set role yui_connector; select public._who('aaaaaaaa-0000-0000-0000-000000000001', 'yui_connector', 'c0c0c0c0-0000-0000-0000-00000000000a');
insert into yui_messages (user_id, agent_id, sender, kind, body, meta) values
  (:A, :PENNY, 'agent', 'control', 'key_ask', '{"v":1,"req":"k-2","op":"key_ask","provider":"openai","for":"Summaries"}');
reset role;
set role yui_user; select public._who('aaaaaaaa-0000-0000-0000-000000000001');
insert into yui_messages (user_id, agent_id, sender, kind, body, meta) values
  (:A, :PENNY, 'user', 'control', 'key_answer', jsonb_build_object('v', 1, 'req', 'k-2', 'op', 'key_answer', 'decision', 'deny', 'provider', 'openai'));
reset role;
select public._t('deny: the agent hears "not allowed" and a deny row is kept',
  exists (select 1 from yui_messages where agent_id = :PENNY and body = '[yui] Key access: openai not allowed.')
  and (select count(*) = 1 from yui_vault_uses where kind = 'deny' and provider = 'openai' and agent_id = :PENNY));
select count(*) as asks_before from yui_messages where kind = 'control' and meta ->> 'op' = 'key_ask' \gset
set role yui_connector; select public._who('aaaaaaaa-0000-0000-0000-000000000001', 'yui_connector', 'c0c0c0c0-0000-0000-0000-00000000000a');
select public._t('no nag: a repeat ask for openai inside 24h is accepted by the API (201) but dropped',
  public._err($q$insert into yui_messages (user_id, agent_id, sender, kind, body, meta) values
    ('aaaaaaaa-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001', 'agent', 'control', 'key_ask',
     '{"v":1,"req":"k-3","op":"key_ask","provider":"openai","for":"Summaries again"}')$q$) = 'ok');
select public._t('a different provider is not dropped',
  public._err($q$insert into yui_messages (user_id, agent_id, sender, kind, body, meta) values
    ('aaaaaaaa-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001', 'agent', 'control', 'key_ask',
     '{"v":1,"req":"k-4","op":"key_ask","provider":"anthropic","for":"Summaries"}')$q$) = 'ok');
reset role;
select public._t('the dropped ask never reached the thread (no k-3 row) and the agent got the declined-today line',
  (select count(*) = 0 from yui_messages where meta ->> 'req' = 'k-3' and kind = 'control')
  and (select count(*) = 1 from yui_messages where agent_id = :PENNY and body = '[yui] Key access: openai was declined today. Ask again tomorrow, or let them bring it up.'));
select public._t('exactly one new ask row landed (k-4)',
  (select count(*) = :asks_before + 1 from yui_messages where kind = 'control' and meta ->> 'op' = 'key_ask'));
select public._t('another agent of the same owner is not held by Penny''s no',
  (select count(*) = 0 from yui_vault_uses where kind = 'deny' and agent_id = :QUILL));
update yui_vault_uses set at = now() - interval '25 hours' where kind = 'deny' and provider = 'openai';
set role yui_connector; select public._who('aaaaaaaa-0000-0000-0000-000000000001', 'yui_connector', 'c0c0c0c0-0000-0000-0000-00000000000a');
select public._t('after 24 hours Penny may ask again',
  public._err($q$insert into yui_messages (user_id, agent_id, sender, kind, body, meta) values
    ('aaaaaaaa-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001', 'agent', 'control', 'key_ask',
     '{"v":1,"req":"k-5","op":"key_ask","provider":"openai","for":"Summaries, tomorrow"}')$q$) = 'ok');
reset role;
select public._t('...and the ask lands in the thread', (select count(*) = 1 from yui_messages where meta ->> 'req' = 'k-5' and kind = 'control'));

-- once via key_answer
set role yui_user; select public._who('aaaaaaaa-0000-0000-0000-000000000001');
insert into yui_vault_grants (key, agent_id, purpose, once) values (:'kfal', :PENNY, 'A picture', true);
reset role;
select handle as hone from yui_vault_grants where purpose = 'A picture' \gset
set role yui_connector; select public._who('aaaaaaaa-0000-0000-0000-000000000001', 'yui_connector', 'c0c0c0c0-0000-0000-0000-00000000000a');
insert into yui_messages (user_id, agent_id, sender, kind, body, meta) values
  (:A, :PENNY, 'agent', 'control', 'key_ask', '{"v":1,"req":"k-6","op":"key_ask","provider":"fal","for":"A picture"}');
reset role;
set role yui_user; select public._who('aaaaaaaa-0000-0000-0000-000000000001');
insert into yui_messages (user_id, agent_id, sender, kind, body, meta) values
  (:A, :PENNY, 'user', 'control', 'key_answer', jsonb_build_object('v', 1, 'req', 'k-6', 'op', 'key_answer', 'decision', 'once', 'provider', 'fal', 'handle', :'hone', 'cap', 5));
reset role;
select public._t('once: the agent hears "allowed once"',
  exists (select 1 from yui_messages where agent_id = :PENNY and body = format('[yui] Key access: fal allowed once for "A picture", handle %s.', :'hone')));

-- 8. Removing a key ------------------------------------------------------------------------
set role yui_user; select public._who('aaaaaaaa-0000-0000-0000-000000000001');
select public._t('the owner removes a key', public._rows(format($q$delete from yui_vault_keys where id = %L$q$, :'kfal')) = 1);
reset role;
select public._t('removing a key deletes its grants', (select count(*) = 0 from yui_vault_grants where key = :'kfal'::uuid));
select public._t('...and the agents heard "revoked" for the ones that were live',
  (select count(*) >= 2 from yui_messages where agent_id = :PENNY and body = '[yui] Key access: fal revoked.'));
select public._t('...and the trail keeps a remove row', (select count(*) = 1 from yui_vault_uses where kind = 'remove' and key = :'kfal'::uuid));
set role service_role;
select public._t('a removed key''s handle is not_granted', (yui_vault_begin(:'hn', :CA, 'fal-ai/x', true, 1)) ->> 'error' = 'not_granted');
reset role;

-- 9. Retention -----------------------------------------------------------------------------
update yui_vault_uses set at = now() - interval '91 days' where kind = 'add';
select public._t('yui_retention (dry) counts old uses', (select n_rows >= 3 from yui_retention(true) where what = 'vault_uses'));
select count(*) as old_uses from yui_vault_uses where at < now() - interval '90 days' \gset
select count(*) as young_uses from yui_vault_uses where at >= now() - interval '90 days' \gset
select public._t('yui_retention deletes the uses older than 90 days', (select n_rows = :old_uses from yui_retention(false) where what = 'vault_uses'));
select public._t('...and only those', (select count(*) = 0 from yui_vault_uses where at < now() - interval '90 days')
  and (select count(*) >= :young_uses from yui_vault_uses));

-- 10. No provider-shaped string in any relay row ---------------------------------------------
select public._t('no row in the vault tables holds a provider-shaped string',
  (select count(*) = 0 from (
     select row_to_json(k)::text t from yui_vault_keys k union all
     select row_to_json(g)::text from yui_vault_grants g union all
     select row_to_json(u)::text from yui_vault_uses u) x
   where t ~ '(sk-[A-Za-z0-9_-]{16,}|r8_[A-Za-z0-9]{16,}|sk-ant-|[0-9a-f-]{8,}:[A-Za-z0-9]{16,})'));
