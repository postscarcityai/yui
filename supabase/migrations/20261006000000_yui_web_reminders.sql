-- YUI-258: reminders ring in a browser with no Yui tab open. An agent reply that changes the person's reminders
-- carries the whole set in meta.native.reminders as [{key, text, at}] (at = the person's local time, "2026-09-29T08:50").
-- The tab fires them while it is open (site lib/web/reminders.mjs); this is the closed-tab half:
--   * yui_web_reminders keeps the newest set per person and agent. A newer reply replaces it, an older one never does.
--   * yui_devices.web_tz is the browser's time zone, sent by register_web. `at` is read in the zone of the person's
--     newest browser that has one.
--   * pg_cron every minute claims what is due (once: `fired` remembers key and time) and asks yui-push to send a Web Push
--     to that person's browsers only. Never skipped for an open thread: the service worker drops a double.

alter table public.yui_devices add column if not exists web_tz text
  check (web_tz is null or (char_length(web_tz) between 1 and 64 and web_tz ~ '^[A-Za-z0-9_+/-]+$'));

create table if not exists public.yui_web_reminders (
  user_id uuid not null references public.yui_users(id) on delete cascade,
  agent_id uuid not null references public.yui_agents(id) on delete cascade,
  -- created_at of the reply the set came from: the order a newer set wins by.
  set_at timestamptz not null,
  items jsonb not null default '[]'::jsonb check (jsonb_typeof(items) = 'array' and pg_column_size(items) <= 16384),
  -- {key: at} for every reminder already sent: a reminder moved to a new time rings again, an unmoved one never twice.
  fired jsonb not null default '{}'::jsonb check (jsonb_typeof(fired) = 'object'),
  updated_at timestamptz not null default now(),
  primary key (user_id, agent_id)
);
alter table public.yui_web_reminders enable row level security;
revoke all on public.yui_web_reminders from public, anon, authenticated, yui_user, yui_connector;

-- A reply with a set: keep it when it is the newest. Only for people with a browser registered. ----------------
create or replace function public.yui_web_reminders_changed() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  list jsonb := new.meta->'native'->'reminders';
  keep jsonb;
begin
  if new.sender <> 'agent' or jsonb_typeof(list) is distinct from 'array' then return null; end if;
  if not exists (select 1 from public.yui_devices where user_id = new.user_id and web_endpoint is not null) then
    return null;
  end if;
  -- Only well-formed items, at most 64.
  select coalesce(jsonb_agg(jsonb_build_object('key', e->>'key', 'text', coalesce(left(e->>'text', 200), ''), 'at', e->>'at')), '[]'::jsonb)
    into keep
    from (select e from jsonb_array_elements(list) e
           where jsonb_typeof(e) = 'object' and jsonb_typeof(e->'key') = 'string' and e->>'key' <> ''
             and left(e->>'key', 200) = e->>'key'
             and e->>'at' ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$' limit 64) s;
  insert into public.yui_web_reminders as r (user_id, agent_id, set_at, items)
  values (new.user_id, new.agent_id, new.created_at, keep)
  on conflict (user_id, agent_id) do update
    set set_at = excluded.set_at, items = excluded.items, updated_at = now(),
        -- Keep what already rang, for the keys still in the set.
        fired = coalesce((select jsonb_object_agg(f.key, f.value) from jsonb_each(r.fired) f
                           where excluded.items @> jsonb_build_array(jsonb_build_object('key', f.key))), '{}'::jsonb)
  where r.set_at < excluded.set_at;
  return null;
exception when others then
  raise warning 'yui_web_reminders_changed: %', sqlerrm;
  return null;
end $$;
revoke all on function public.yui_web_reminders_changed() from public, anon, authenticated;
drop trigger if exists yui_web_reminders_changed on public.yui_messages;
create trigger yui_web_reminders_changed after insert on public.yui_messages
  for each row execute function public.yui_web_reminders_changed();

-- What is due now, claimed. A reminder is sent within 10 minutes of its time (a late tick still rings it), and one
-- older than that is marked and never sent. Returns [{user_id, agent_id, key, text}].
create or replace function public.yui_web_reminders_claim(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  r record;
  it jsonb;
  tz text;
  due timestamptz;
  nf jsonb;
  out jsonb := '[]'::jsonb;
begin
  for r in select * from public.yui_web_reminders order by updated_at for update skip locked loop
    -- The zone of the newest browser that told us one.
    select d.web_tz into tz from public.yui_devices d
     where d.user_id = r.user_id and d.web_endpoint is not null and d.web_tz is not null
     order by d.updated_at desc limit 1;
    continue when tz is null or not exists (select 1 from pg_catalog.pg_timezone_names n where n.name = tz);
    nf := r.fired;
    for it in select value from jsonb_array_elements(r.items) loop
      continue when nf->>(it->>'key') = (it->>'at');
      begin
        due := (it->>'at')::timestamp at time zone tz;
      exception when others then
        continue;
      end;
      continue when due > p_now;
      nf := nf || jsonb_build_object(it->>'key', it->>'at');
      if due > p_now - interval '10 minutes' then
        out := out || jsonb_build_array(jsonb_build_object(
          'user_id', r.user_id, 'agent_id', r.agent_id, 'key', it->>'key', 'text', it->>'text'));
      end if;
    end loop;
    if nf <> r.fired then
      update public.yui_web_reminders set fired = nf, updated_at = now()
       where user_id = r.user_id and agent_id = r.agent_id;
    end if;
  end loop;
  return out;
end $$;
revoke all on function public.yui_web_reminders_claim(timestamptz) from public, anon, authenticated;

-- The minute tick: claim, then ask yui-push (same URL and secret as the widget push) to send. A failure never loops:
-- what was claimed is marked, so a failed send is lost rather than repeated.
create or replace function public.yui_web_reminders_tick() returns integer
language plpgsql security definer set search_path = '' as $$
declare
  due jsonb;
  u text;
  s text;
begin
  select decrypted_secret into u from vault.decrypted_secrets where name = 'yui_widgets_url';
  select decrypted_secret into s from vault.decrypted_secrets where name = 'yui_widgets_secret';
  if u is null or s is null then return 0; end if;
  due := public.yui_web_reminders_claim();
  if jsonb_array_length(due) = 0 then return 0; end if;
  perform net.http_post(
    url := u,
    body := jsonb_build_object('action', 'reminders', 'due', due),
    headers := jsonb_build_object('content-type', 'application/json', 'x-yui-widgets', s),
    timeout_milliseconds := 5000
  );
  return jsonb_array_length(due);
exception when others then
  raise warning 'yui_web_reminders_tick: %', sqlerrm;
  return 0;
end $$;
revoke all on function public.yui_web_reminders_tick() from public, anon, authenticated;

do $$
begin
  perform cron.unschedule('yui-web-reminders-tick');
exception when others then null;
end $$;
select cron.schedule('yui-web-reminders-tick', '* * * * *', 'select public.yui_web_reminders_tick()');
