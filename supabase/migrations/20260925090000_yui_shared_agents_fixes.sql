-- YUI-95 follow-up. Rows with no agent (agent_id null, allowed since the
-- accounts migration) pass the owner-or-grant trigger and stay readable and
-- deletable by their user, as before 20260925080000. The two trigger
-- functions are not callable by the app or a host.

create or replace function public.yui_messages_owner() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.agent_id is null
     or exists (select 1 from public.yui_agents a where a.id = new.agent_id and a.user_id = new.user_id) then
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

drop policy yui_messages_user_read on public.yui_messages;
drop policy yui_messages_user_delete on public.yui_messages;
create policy yui_messages_user_read on public.yui_messages for select to yui_user
  using (user_id = public.yui_uid()
         and (agent_id is null or public.yui_owns_agent(agent_id)
              or created_at >= public.yui_grant_since(agent_id, public.yui_uid())));
create policy yui_messages_user_delete on public.yui_messages for delete to yui_user
  using (user_id = public.yui_uid()
         and (agent_id is null or public.yui_owns_agent(agent_id)
              or created_at >= public.yui_grant_since(agent_id, public.yui_uid())));

revoke all on function public.yui_messages_owner(), public.yui_client_safe_guard() from public, anon, authenticated, yui_user, yui_connector;
