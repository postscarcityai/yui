-- YUI-142: native web search on Firecrawl, with caps (spec yuigui spec/NATIVE.md).
--
-- Native agents look things up (a `search` or `fetch` block) through Yui's own
-- Firecrawl key. Each person gets a number of free lookups a month
-- (native_searches_per_month) and a day (native_searches_per_day); a turn makes
-- at most native_searches_per_turn. When the month runs out the agent answers
-- from what it knows and invites them to add their own Firecrawl key in
-- Settings (never in chat). Their key is kept in Vault, like their model key,
-- and lifts the month and day caps; the turn cap stays.
--
-- Needs the function secret YUI_FIRECRAWL_KEY for Yui's own key; without it,
-- agents say they couldn't look it up.

insert into public.yui_limits (name, value, note) values
  ('native_searches_per_month', 50, 'free web lookups (Firecrawl search or page fetch) a month per person on Yui''s key'),
  ('native_searches_per_turn', 2, 'web lookups one native turn may make, own key or not')
on conflict (name) do nothing;
update public.yui_limits set note = 'free web lookups a day per person on Yui''s key (an own Firecrawl key lifts it)'
 where name = 'native_searches_per_day';

-- Lookups this month sit next to turns this month.
alter table public.yui_native_usage add column if not exists searches integer not null default 0;

-- Takes one lookup. On Yui's key (own = false) it must fit the month and the
-- day; with the person's own key it is only counted. why says which cap said no.
drop function if exists public.yui_native_take_search(uuid);
create or replace function public.yui_native_take_search(uid uuid, own boolean default false)
returns table (ok boolean, used integer, lim integer, per_turn integer, why text)
language plpgsql security definer set search_path = '' as $$
declare
  cap_month integer := coalesce(public.yui_limit('native_searches_per_month'), 50)::integer;
  cap_day integer := coalesce(public.yui_limit('native_searches_per_day'), 20)::integer;
  turn_cap integer := greatest(coalesce(public.yui_limit('native_searches_per_turn'), 2)::integer, 1);
  m date := date_trunc('month', now())::date;
  month_used integer;
  day_used integer;
begin
  select u.searches into month_used from public.yui_native_usage u where u.user_id = uid and u.month = m for update;
  month_used := coalesce(month_used, 0);
  if not own then
    if month_used >= cap_month then
      return query select false, month_used, cap_month, turn_cap, 'month'::text;
      return;
    end if;
    select d.searches into day_used from public.yui_native_daily d where d.user_id = uid and d.day = current_date for update;
    if coalesce(day_used, 0) >= cap_day then
      return query select false, month_used, cap_month, turn_cap, 'day'::text;
      return;
    end if;
  end if;
  insert into public.yui_native_daily as d (user_id, day, searches) values (uid, current_date, 1)
    on conflict (user_id, day) do update set searches = d.searches + 1;
  insert into public.yui_native_usage as u (user_id, month, turns, searches) values (uid, m, 0, 1)
    on conflict (user_id, month) do update set searches = u.searches + 1
    returning u.searches into month_used;
  return query select true, month_used, cap_month, turn_cap, null::text;
end $$;

-- The person's own Firecrawl key ------------------------------------------------------
-- One per person, in Vault. The table holds the vault id and the last four,
-- which is all the app ever sees. Only the service role reads the key.
create table if not exists public.yui_native_search_keys (
  user_id uuid primary key references public.yui_users(id) on delete cascade,
  secret_id uuid not null,
  hint text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.yui_native_search_keys enable row level security;
revoke all on public.yui_native_search_keys from public, anon, authenticated;
grant select (user_id, hint, created_at, updated_at) on public.yui_native_search_keys to yui_user;
drop policy if exists yui_native_search_keys_owner on public.yui_native_search_keys;
create policy yui_native_search_keys_owner on public.yui_native_search_keys for select to yui_user
  using (user_id = public.yui_uid());

create or replace function public.yui_native_search_key_set(uid uuid, secret text)
returns void
language plpgsql security definer set search_path = '' as $$
declare sid uuid;
begin
  select secret_id into sid from public.yui_native_search_keys where user_id = uid;
  if sid is null then
    sid := vault.create_secret(secret, 'yui_native_search_key:' || uid::text, 'a person''s own Firecrawl key (YUI-142)');
  else
    perform vault.update_secret(sid, secret);
  end if;
  insert into public.yui_native_search_keys (user_id, secret_id, hint) values (uid, sid, right(secret, 4))
    on conflict (user_id) do update set secret_id = excluded.secret_id, hint = excluded.hint, updated_at = now();
end $$;

create or replace function public.yui_native_search_key_get(uid uuid)
returns text
language sql stable security definer set search_path = '' as $$
  select s.decrypted_secret
    from public.yui_native_search_keys k join vault.decrypted_secrets s on s.id = k.secret_id
   where k.user_id = uid
$$;

create or replace function public.yui_native_search_key_remove(uid uuid)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  delete from public.yui_native_search_keys where user_id = uid; -- the trigger takes the vault secret
end $$;

-- The key goes with the row (and so with the person): same trigger as model keys.
drop trigger if exists yui_native_search_keys_gone on public.yui_native_search_keys;
create trigger yui_native_search_keys_gone after delete on public.yui_native_search_keys
  for each row execute function public.yui_native_keys_gone();

revoke all on function public.yui_native_take_search(uuid, boolean) from public, anon, authenticated;
revoke all on function public.yui_native_search_key_set(uuid, text) from public, anon, authenticated;
revoke all on function public.yui_native_search_key_get(uuid) from public, anon, authenticated;
revoke all on function public.yui_native_search_key_remove(uuid) from public, anon, authenticated;
grant execute on function public.yui_native_take_search(uuid, boolean) to service_role;
grant execute on function public.yui_native_search_key_set(uuid, text) to service_role;
grant execute on function public.yui_native_search_key_get(uuid) to service_role;
grant execute on function public.yui_native_search_key_remove(uuid) to service_role;

notify pgrst, 'reload schema';
