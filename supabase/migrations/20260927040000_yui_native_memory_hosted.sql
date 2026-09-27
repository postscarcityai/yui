-- YUI-140: native memory is for native agents only. A note belongs to one of
-- the person's own hosted agents; connected (paired) agents never get a row,
-- and never read the about-you card (yui_connector has no grant on the table).

create or replace function public.yui_native_memory_hosted() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.agent_id is not null and not exists (
    select 1 from public.yui_agents a where a.id = new.agent_id and a.user_id = new.user_id and a.kind = 'hosted'
  ) then
    raise exception 'memory notes belong to one of this person''s native agents' using errcode = '23514';
  end if;
  return new;
end $$;
revoke all on function public.yui_native_memory_hosted() from public, anon, authenticated;

drop trigger if exists yui_native_memory_hosted on public.yui_native_memory;
create trigger yui_native_memory_hosted before insert or update of agent_id, user_id on public.yui_native_memory
  for each row execute function public.yui_native_memory_hosted();

-- Belt and braces: nothing but the person and the server reads memory.
revoke all on public.yui_native_memory from yui_connector;

notify pgrst, 'reload schema';
