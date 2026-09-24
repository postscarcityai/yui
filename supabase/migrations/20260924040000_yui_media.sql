-- YUI-21: media. Pictures and videos agents send, and photos people take.
--
-- One private Storage bucket, `yui-media`. Every object lives at
--   <user_id>/<agent_id>/<from>/<uuid>.<ext>      from = agent | user
-- and is read through signed URLs, never a public one. The same two roles as
-- the rest of Yui, never `authenticated` (it owns PROOF's portal tables):
--   yui_user       reads and deletes its own media, uploads under from=user
--                  into threads of its own agents.
--   yui_connector  reads media in threads it serves, uploads under from=agent.
-- Nobody updates or overwrites an object: a new picture is a new path.
-- Account deletion removes the user's objects (yui-delete, via
-- yui_media_names). The sweep (supabase/scripts/media_sweep.py) removes
-- orphans: owner or agent gone, or never referenced by a message.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('yui-media', 'yui-media', false, 52428800, array[
  'image/jpeg', 'image/png', 'image/webp', 'image/gif', 'image/heic',
  'video/mp4', 'video/quicktime'])
on conflict (id) do update set public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- The agent a media path belongs to, or null when the path is not ours.
create or replace function public.yui_media_agent(name text) returns uuid
language sql immutable
set search_path = ''
as $$
  select case when name ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/(agent|user)/[A-Za-z0-9._-]{1,80}$'
              then split_part(name, '/', 2)::uuid end
$$;

-- True when this user owns the agent (app side). Invoker rights: yui_user
-- already sees exactly its own agents through RLS.
create or replace function public.yui_owns_agent(agent uuid) returns boolean
language sql stable security invoker
set search_path = ''
as $$
  select exists (select 1 from public.yui_agents a where a.id = agent and a.user_id = public.yui_uid())
$$;

revoke all on function public.yui_media_agent(text) from public, anon, authenticated;
revoke all on function public.yui_owns_agent(uuid) from public, anon, authenticated;
grant execute on function public.yui_media_agent(text) to yui_user, yui_connector, service_role;
grant execute on function public.yui_owns_agent(uuid) to yui_user, service_role;

grant usage on schema storage to yui_user, yui_connector;
grant select on storage.buckets to yui_user, yui_connector;
grant select, insert, delete on storage.objects to yui_user;
grant select, insert on storage.objects to yui_connector;

drop policy if exists yui_media_bucket on storage.buckets;
create policy yui_media_bucket on storage.buckets for select to yui_user, yui_connector
  using (id = 'yui-media');

drop policy if exists yui_media_user_read on storage.objects;
drop policy if exists yui_media_user_write on storage.objects;
drop policy if exists yui_media_user_delete on storage.objects;
create policy yui_media_user_read on storage.objects for select to yui_user
  using (bucket_id = 'yui-media' and split_part(name, '/', 1) = public.yui_uid()::text);
create policy yui_media_user_write on storage.objects for insert to yui_user
  with check (bucket_id = 'yui-media' and split_part(name, '/', 1) = public.yui_uid()::text
              and split_part(name, '/', 3) = 'user'
              and public.yui_owns_agent(public.yui_media_agent(name)));
create policy yui_media_user_delete on storage.objects for delete to yui_user
  using (bucket_id = 'yui-media' and split_part(name, '/', 1) = public.yui_uid()::text);

drop policy if exists yui_media_connector_read on storage.objects;
drop policy if exists yui_media_connector_write on storage.objects;
create policy yui_media_connector_read on storage.objects for select to yui_connector
  using (bucket_id = 'yui-media' and split_part(name, '/', 1) = public.yui_uid()::text
         and public.yui_connector_serves(public.yui_media_agent(name)));
create policy yui_media_connector_write on storage.objects for insert to yui_connector
  with check (bucket_id = 'yui-media' and split_part(name, '/', 1) = public.yui_uid()::text
              and split_part(name, '/', 3) = 'agent'
              and public.yui_connector_serves(public.yui_media_agent(name)));

-- Server side (yui-delete, the sweep): every object name under a user, and
-- every object with the facts the sweep needs. Storage refuses direct SQL
-- deletes, so callers remove through the Storage API with these names.
create or replace function public.yui_media_names(uid uuid) returns setof text
language sql stable security definer
set search_path = ''
as $$
  select o.name from storage.objects o
  where o.bucket_id = 'yui-media' and split_part(o.name, '/', 1) = uid::text
$$;

create or replace function public.yui_media_orphans(grace interval default '1 day') returns setof text
language sql stable security definer
set search_path = ''
as $$
  select o.name from storage.objects o
  where o.bucket_id = 'yui-media'
    and (
      -- owner or agent gone (account or agent deleted), or a path we never issue
      not exists (select 1 from public.yui_agents a
                  where a.id = public.yui_media_agent(o.name)
                    and a.user_id::text = split_part(o.name, '/', 1))
      -- uploaded, then never sent, or its message was deleted
      or (o.created_at < now() - grace
          and not exists (select 1 from public.yui_messages m
                          where m.user_id::text = split_part(o.name, '/', 1)
                            and (strpos(m.body, o.name) > 0 or strpos(m.meta::text, o.name) > 0)))
    )
$$;
revoke all on function public.yui_media_names(uuid) from public, anon, authenticated;
revoke all on function public.yui_media_orphans(interval) from public, anon, authenticated;
grant execute on function public.yui_media_names(uuid) to service_role;
grant execute on function public.yui_media_orphans(interval) to service_role;

notify pgrst, 'reload schema';
