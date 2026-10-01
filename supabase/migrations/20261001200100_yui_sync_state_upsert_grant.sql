-- YUI-249 follow-up: an upsert names every column in DO UPDATE SET, so the key columns need the update grant, and the
-- update policy checks the agent as the insert policy does. (Folded into 20261001200000 for a fresh database.)
grant update (user_id, agent_id, key, value, device, updated_at) on public.yui_sync_state to yui_user;
drop policy if exists yui_sync_state_update on public.yui_sync_state;
create policy yui_sync_state_update on public.yui_sync_state for update to yui_user
  using (user_id = public.yui_uid())
  with check (user_id = public.yui_uid()
              and (public.yui_owns_agent(agent_id) or public.yui_granted(agent_id, public.yui_uid())));
notify pgrst, 'reload schema';
