-- YUI-40 step 4: widget push rules on local Postgres 16, after every migration (see
-- supabase/tests/widgets_local.sh). Stubs net.http_post so each widget push request is logged.
\set ON_ERROR_STOP on

create table public.widget_calls (at timestamptz default now(), url text, body jsonb, headers jsonb);
create or replace function net.http_post(url text, body jsonb default '{}', params jsonb default '{}',
  headers jsonb default '{}', timeout_milliseconds int default 1000) returns bigint language sql as
  $$ insert into public.widget_calls (url, body, headers) values (url, body, headers) returning 1::bigint $$;
select vault.create_secret('https://example.test/functions/v1/yui-push', 'yui_widgets_url');
select vault.create_secret('s3cret', 'yui_widgets_secret');

insert into public.yui_users (id, apple_sub) values ('00000000-0000-0000-0000-00000000000a', 'apple.sam');
insert into public.yui_agents (id, user_id, name, handle, kind)
  values ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-00000000000a', 'Coach', 'coach', 'hermes'),
         ('00000000-0000-0000-0000-0000000000e2', '00000000-0000-0000-0000-00000000000a', 'Penny', 'penny', 'hermes');

-- Sam's phone pinned two of Coach's saved screens: "today" (a list and a timer) and "weight" (a stat).
insert into public.yui_widgets (id, user_id, agent_id, screen, ids, token_hash, push_token) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000e1',
   'today', '[{"id":"today","preset":"list"},{"id":"focus","preset":"timer"}]', repeat('a', 64), repeat('1', 64)),
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000e1',
   'weight', '[{"id":"weight","preset":"stat"}]', repeat('a', 64), repeat('1', 64));

create or replace function public.say(agent uuid, txt text, kind text default 'text', sender text default 'agent') returns void
language sql as $$
  insert into public.yui_messages (user_id, agent_id, sender, kind, body)
  values ('00000000-0000-0000-0000-00000000000a', agent, sender, kind, txt)
$$;

do $$
declare
  coach uuid := '00000000-0000-0000-0000-0000000000e1';
  penny uuid := '00000000-0000-0000-0000-0000000000e2';
  n int;
  w timestamptz;
begin
  -- 1. A patch to a pinned id sends one push, naming that row only.
  perform public.say(coach, E'```yui\n~weight 178.4 delta=-2.8\n```');
  select count(*) into n from public.widget_calls;
  if n <> 1 then raise exception 'patch to a pinned id: % calls', n; end if;
  if (select body->'ids' from public.widget_calls) <> '["00000000-0000-0000-0000-0000000000f2"]'::jsonb then
    raise exception 'wrong rows: %', (select body from public.widget_calls);
  end if;
  if (select headers->>'x-yui-widgets' from public.widget_calls) <> 's3cret' then raise exception 'no secret'; end if;
  if (select body->>'action' from public.widget_calls) <> 'widgets' then raise exception 'wrong action'; end if;

  -- 2. A second patch inside 15 minutes sends nothing now: it is pending.
  perform public.say(coach, E'```yui\n>2 ~weight 178.2\n```');
  select count(*) into n from public.widget_calls;
  if n <> 1 then raise exception 'coalesce: % calls', n; end if;
  if (select pending_at from public.yui_widgets where screen = 'weight') is null then raise exception 'not pending'; end if;

  -- 3. The tick inside the window does nothing; after the window it sends the pending one.
  if public.yui_widgets_tick() <> 0 then raise exception 'tick sent early'; end if;
  update public.yui_widgets set last_push_at = now() - interval '16 minutes' where screen = 'weight';
  if public.yui_widgets_tick() <> 1 then raise exception 'tick did not send'; end if;
  select count(*) into n from public.widget_calls;
  if n <> 2 then raise exception 'after tick: % calls', n; end if;
  if (select pending_at from public.yui_widgets where screen = 'weight') is not null then raise exception 'still pending'; end if;

  -- 4. A timer patch goes at once, inside the window.
  perform public.say(coach, E'```yui\n~today 1\n```');  -- first push for "today"
  select count(*) into n from public.widget_calls;
  if n <> 3 then raise exception 'today first push: % calls', n; end if;
  perform public.say(coach, E'```yui\n~focus started\n```');
  select count(*) into n from public.widget_calls;
  if n <> 4 then raise exception 'timer not at once: % calls', n; end if;
  -- ...but a list patch right after is coalesced.
  perform public.say(coach, E'```yui\n~today 2\n```');
  select count(*) into n from public.widget_calls;
  if n <> 4 then raise exception 'list not coalesced: % calls', n; end if;

  -- 5. Not a hit: another agent, the person's own row, a patch to an id that is not pinned, a prefix of a pinned id.
  perform public.say(penny, E'```yui\n~weight 1\n```');
  perform public.say(coach, E'~weight 1', 'text', 'user');
  perform public.say(coach, E'```yui\n~height 180\n```');
  perform public.say(coach, E'```yui\n~weightx 1\n```');
  perform public.say(coach, 'Nice work today.');
  select count(*) into n from public.widget_calls;
  if n <> 4 then raise exception 'false hits: % calls', n; end if;

  -- 6. Saving the same screen name again counts; saving another name does not.
  update public.yui_widgets set last_push_at = now() - interval '20 minutes', pending_at = null;
  perform public.say(coach, E'```yui\nadd stat@x value=1\nsave weight\n```');
  select count(*) into n from public.widget_calls;
  if n <> 5 then raise exception 'save of a pinned name: % calls', n; end if;
  perform public.say(coach, E'```yui\nadd stat@x value=1\nsave other\n```');
  select count(*) into n from public.widget_calls;
  if n <> 5 then raise exception 'save of another name: % calls', n; end if;

  -- 7. A phone with no push token is never pushed, and the app roles cannot read the table.
  update public.yui_widgets set push_token = null, last_push_at = null;
  perform public.say(coach, E'```yui\n~weight 9\n```');
  select count(*) into n from public.widget_calls;
  if n <> 5 then raise exception 'no token pushed: % calls', n; end if;
  begin
    set local role yui_user;
    perform count(*) from public.yui_widgets;
    raise exception 'yui_user read yui_widgets';
  exception when insufficient_privilege then null; end;
  reset role;

  -- 8. A missing secret never stops the message.
  delete from vault.secrets where name = 'yui_widgets_secret';
  update public.yui_widgets set push_token = repeat('1', 64);
  perform public.say(coach, E'```yui\n~weight 10\n```');
  select count(*) into n from public.yui_messages where body like '%~weight 10%';
  if n <> 1 then raise exception 'message lost'; end if;

  -- 9. Deleting the agent takes its widget rows with it.
  delete from public.yui_agents where id = coach;
  select count(*) into n from public.yui_widgets;
  if n <> 0 then raise exception 'rows left: %', n; end if;
end $$;

select 'widget checks ok' as result;
