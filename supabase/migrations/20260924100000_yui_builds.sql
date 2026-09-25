-- YUI-55: test builds by link. One private Storage bucket, `yui-builds`, for
-- ad hoc builds of the app: the .ipa and its itms-services manifest, reached
-- only through signed URLs that expire in 7 days.
-- No user data. No policies: only the service role (scripts/devbuild.sh) reads
-- or writes it, never yui_user, yui_connector, anon or authenticated.
-- Ad hoc builds install only on devices registered to the developer account,
-- so a leaked link installs nowhere else. Old builds are removed by
-- supabase/scripts/media_sweep.py.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('yui-builds', 'yui-builds', false, 52428800,
        array['application/octet-stream', 'text/xml'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;
