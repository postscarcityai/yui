-- YUI-49: react to a message. Spec: yuigui/spec/REACTIONS.md.
--
-- The person long-presses an agent's message and reacts with one of six
-- emoji. One write does both jobs: the app inserts an ordinary event row
-- (kind 'event', sender 'user') that the host hands to the agent as a turn:
--
--   body  [yui] react msg=<agent row id> emoji=👍 meaning="build it"
--         > first ~200 characters of the reacted message
--   meta  {"react": {"msg": "<agent row id>", "emoji": "👍"}}   emoji null = taken back
--
-- and this trigger copies the emoji onto the reacted agent row, so a
-- reopened thread shows the badge. One reaction per message: the newest
-- row wins. The row must be the agent's, in the same user's same thread;
-- anything else is refused (400), so a reaction can never touch someone
-- else's message. Retention needs nothing new: the reaction lives on the
-- message and the event is a message, both go with the 90-day sweep.

alter table public.yui_messages
  add column if not exists reaction text,
  add column if not exists reacted_at timestamptz;
alter table public.yui_messages drop constraint if exists yui_messages_reaction_check;
alter table public.yui_messages add constraint yui_messages_reaction_check
  check (reaction is null or (sender = 'agent' and reaction in ('👍', '👎', '🤔', '❤️', '⏳', '🔥')));

-- The app never updates rows (update was revoked from yui_user in YUI-7);
-- the reaction only moves through this trigger.
create or replace function public.yui_messages_react() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  target text := new.meta #>> '{react,msg}';
  emoji text := nullif(new.meta #>> '{react,emoji}', '');
begin
  if target is null or target !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    raise sqlstate '22023' using message = 'react_needs_msg';
  end if;
  if emoji is not null and emoji not in ('👍', '👎', '🤔', '❤️', '⏳', '🔥') then
    raise sqlstate '22023' using message = 'unknown_reaction';
  end if;
  update public.yui_messages
     set reaction = emoji, reacted_at = new.created_at
   where id = target::uuid
     and user_id = new.user_id
     and agent_id = new.agent_id
     and sender = 'agent'
     and (reacted_at is null or reacted_at <= new.created_at);
  if not found and not exists (
    select 1 from public.yui_messages
     where id = target::uuid and user_id = new.user_id and agent_id = new.agent_id and sender = 'agent'
  ) then
    raise sqlstate '22023' using message = 'react_msg_not_found';
  end if;
  return new;
end $$;
revoke all on function public.yui_messages_react() from public, anon, authenticated;

drop trigger if exists yui_messages_react on public.yui_messages;
create trigger yui_messages_react after insert on public.yui_messages
  for each row when (new.sender = 'user' and new.kind = 'event' and new.meta ? 'react')
  execute function public.yui_messages_react();

notify pgrst, 'reload schema';
