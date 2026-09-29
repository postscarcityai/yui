-- One key per provider, and an agent can pick which one it runs on (YUI-139 step 2f).
-- Until now a person had one key that every native agent used. Now they can keep a Claude key
-- and a ChatGPT key side by side: `everywhere` marks the one agents follow by default (what
-- the single key was), and an agent's profile says "yui" or a provider to override it.
alter table public.yui_native_keys add column if not exists everywhere boolean not null default true;
alter table public.yui_native_keys drop constraint if exists yui_native_keys_pkey;
alter table public.yui_native_keys add primary key (user_id, provider);
drop index if exists public.yui_native_keys_everywhere;
create unique index yui_native_keys_everywhere on public.yui_native_keys (user_id) where everywhere;
grant select (everywhere) on public.yui_native_keys to yui_user;

drop function if exists public.yui_native_key_set(uuid, text, text, text, text);
create or replace function public.yui_native_key_set(uid uuid, prov text, url text, mdl text, secret text, every boolean default true)
returns void
language plpgsql security definer set search_path = '' as $$
declare sid uuid;
begin
  select secret_id into sid from public.yui_native_keys where user_id = uid and provider = prov;
  if sid is null then
    sid := vault.create_secret(secret, 'yui_native_key:' || uid::text || ':' || prov, 'a person''s own model key (NATIVE-1)');
  else
    perform vault.update_secret(sid, secret);
  end if;
  -- The key agents follow by default is the last one set for everyone; a per-agent key leaves it alone
  -- (and follows nobody by default, unless it is their only key).
  if every then update public.yui_native_keys set everywhere = false where user_id = uid and provider <> prov; end if;
  insert into public.yui_native_keys (user_id, provider, base_url, model, secret_id, hint, everywhere)
    values (uid, prov, url, nullif(mdl, ''), sid, right(secret, 4),
            every or not exists (select 1 from public.yui_native_keys k where k.user_id = uid and k.provider <> prov))
    on conflict (user_id, provider) do update set base_url = excluded.base_url, model = excluded.model,
      secret_id = excluded.secret_id, hint = excluded.hint, updated_at = now(),
      everywhere = public.yui_native_keys.everywhere or excluded.everywhere;
end $$;

-- The default key, or (prov given) that provider's.
drop function if exists public.yui_native_key_get(uuid);
create or replace function public.yui_native_key_get(uid uuid, prov text default null)
returns table (provider text, base_url text, model text, secret text)
language sql stable security definer set search_path = '' as $$
  select k.provider, k.base_url, k.model, s.decrypted_secret
    from public.yui_native_keys k join vault.decrypted_secrets s on s.id = k.secret_id
   where k.user_id = uid and case when prov is null then k.everywhere else k.provider = prov end
$$;

-- One provider's key, or (prov null) all of them. If the default goes, the newest key left takes over.
drop function if exists public.yui_native_key_remove(uuid);
create or replace function public.yui_native_key_remove(uid uuid, prov text default null)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  delete from public.yui_native_keys where user_id = uid and (prov is null or provider = prov);
  update public.yui_native_keys set everywhere = true
   where user_id = uid and provider = (select provider from public.yui_native_keys where user_id = uid order by updated_at desc limit 1)
     and not exists (select 1 from public.yui_native_keys where user_id = uid and everywhere);
end $$;

revoke all on function public.yui_native_key_set(uuid, text, text, text, text, boolean) from public, anon, authenticated;
revoke all on function public.yui_native_key_get(uuid, text) from public, anon, authenticated;
revoke all on function public.yui_native_key_remove(uuid, text) from public, anon, authenticated;
grant execute on function public.yui_native_key_set(uuid, text, text, text, text, boolean) to service_role;
grant execute on function public.yui_native_key_get(uuid, text) to service_role;
grant execute on function public.yui_native_key_remove(uuid, text) to service_role;
