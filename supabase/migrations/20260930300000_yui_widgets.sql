-- YUI-40 step 4: widget push relay. Spec: yuigui/spec/WIDGETS.md sections 3 and 5.
--
-- One row per saved screen a phone has pinned as a widget. The app tells yui-widgets
-- which screens are pinned (and the lasting ids on them); the widget extension holds
-- a widget token (only its hash is here) that can do two things for those agents:
-- read the newest rows and insert an event row (a button on the widget).
--
-- When an agent row patches a lasting id on a pinned screen (or saves the same name
-- again), yui-push sends that phone a WidgetKit push (apns-push-type: widgets). At most
-- one per pinned screen per 15 minutes: a patch in the window marks the row pending and
-- the next minute tick after the window sends it. A timer is the exception and goes at once.

create table if not exists public.yui_widgets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.yui_users(id) on delete cascade,
  agent_id uuid not null references public.yui_agents(id) on delete cascade,
  -- The saved screen's name, and the lasting ids on it: [{"id": "weight", "preset": "stat"}].
  screen text not null check (char_length(screen) between 1 and 80),
  ids jsonb not null default '[]'::jsonb check (jsonb_typeof(ids) = 'array' and pg_column_size(ids) <= 8192),
  -- sha256 of the widget token kept in the phone's shared keychain. One token per phone and account.
  token_hash text not null check (token_hash ~ '^[0-9a-f]{64}$'),
  -- The WidgetKit push token (WidgetPushHandler), not the notification token.
  push_token text check (push_token is null or push_token ~ '^[0-9a-f]{64,200}$'),
  environment text not null default 'production' check (environment in ('production', 'sandbox')),
  topic text,
  app_build integer,
  last_push_at timestamptz,
  -- A patch landed inside the 15 minute window: the tick sends it once the window is over.
  pending_at timestamptz,
  pushes integer not null default 0,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (token_hash, agent_id, screen)
);
create index if not exists yui_widgets_agent_idx on public.yui_widgets(agent_id, user_id);
create index if not exists yui_widgets_pending_idx on public.yui_widgets(pending_at) where pending_at is not null;

-- Only the edge functions (service role) touch it: no policy for yui_user, no grant for the app roles.
alter table public.yui_widgets enable row level security;
revoke all on public.yui_widgets from public, anon, authenticated, yui_user, yui_connector;

-- Which pinned screens does this agent row touch? -------------------------------------
-- A patch line to a lasting id (`~weight 178.4lb`, `>2 ~weight ...`), or a save of the
-- same name. Returns the ids of yui_widgets rows to push and marks the rest pending.
create or replace function public.yui_widgets_due(p_user uuid, p_agent uuid, p_body text)
returns uuid[]
language plpgsql security definer set search_path = '' as $$
declare
  r record;
  hit boolean;
  soon boolean;
  fire uuid[] := '{}';
begin
  for r in
    select w.id, w.screen, w.ids, w.last_push_at
      from public.yui_widgets w
     where w.user_id = p_user and w.agent_id = p_agent and w.push_token is not null
  loop
    hit := exists (
      select 1 from jsonb_array_elements(r.ids) e
       where p_body ~ ('(^|\n)[ \t]*(>[A-Za-z0-9_-]+[ \t]+)?~'
                       || regexp_replace(e->>'id', '([^A-Za-z0-9_ -])', '\\\1', 'g') || '([ \t]|$|\n)')
    ) or p_body ~ ('(^|\n)[ \t]*save[ \t]+'
                   || regexp_replace(r.screen, '([^A-Za-z0-9_ -])', '\\\1', 'g') || '([ \t]|$|\n)');
    continue when not hit;
    -- A timer starting or stopping goes at once.
    soon := exists (
      select 1 from jsonb_array_elements(r.ids) e
       where e->>'preset' = 'timer'
         and p_body ~ ('(^|\n)[ \t]*(>[A-Za-z0-9_-]+[ \t]+)?~'
                       || regexp_replace(e->>'id', '([^A-Za-z0-9_ -])', '\\\1', 'g') || '([ \t]|$|\n)')
    );
    if soon or r.last_push_at is null or r.last_push_at <= now() - interval '15 minutes' then
      fire := fire || r.id;
    else
      update public.yui_widgets set pending_at = coalesce(pending_at, now()) where id = r.id;
    end if;
  end loop;
  if cardinality(fire) > 0 then
    update public.yui_widgets set last_push_at = now(), pending_at = null where id = any(fire);
  end if;
  return fire;
end $$;
revoke all on function public.yui_widgets_due(uuid, uuid, text) from public, anon, authenticated;

-- Ask yui-push to send the widget pushes for these rows. A failure never stops the message.
create or replace function public.yui_widgets_send(p_ids uuid[]) returns void
language plpgsql security definer set search_path = '' as $$
declare
  u text;
  s text;
begin
  if p_ids is null or cardinality(p_ids) = 0 then return; end if;
  select decrypted_secret into u from vault.decrypted_secrets where name = 'yui_widgets_url';
  select decrypted_secret into s from vault.decrypted_secrets where name = 'yui_widgets_secret';
  if u is null or s is null then return; end if;
  perform net.http_post(
    url := u,
    body := jsonb_build_object('action', 'widgets', 'ids', to_jsonb(p_ids)),
    headers := jsonb_build_object('content-type', 'application/json', 'x-yui-widgets', s),
    timeout_milliseconds := 5000
  );
exception when others then
  raise warning 'yui_widgets_send: %', sqlerrm;
end $$;
revoke all on function public.yui_widgets_send(uuid[]) from public, anon, authenticated;

create or replace function public.yui_widgets_changed() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.sender <> 'agent' or new.kind <> 'text' then return null; end if;
  -- Cheap exit: no patch marker and no save word in the body.
  if position('~' in new.body) = 0 and new.body !~ 'save[ \t]' then return null; end if;
  if not exists (select 1 from public.yui_widgets where user_id = new.user_id and agent_id = new.agent_id) then
    return null;
  end if;
  perform public.yui_widgets_send(public.yui_widgets_due(new.user_id, new.agent_id, new.body));
  return null;
exception when others then
  raise warning 'yui_widgets_changed: %', sqlerrm;
  return null;
end $$;
revoke all on function public.yui_widgets_changed() from public, anon, authenticated;
drop trigger if exists yui_widgets_changed on public.yui_messages;
create trigger yui_widgets_changed after insert on public.yui_messages
  for each row execute function public.yui_widgets_changed();

-- Every minute: rows whose window is over and that a patch marked pending.
create or replace function public.yui_widgets_tick() returns integer
language plpgsql security definer set search_path = '' as $$
declare
  due uuid[];
begin
  select coalesce(array_agg(id), '{}') into due from public.yui_widgets
   where pending_at is not null and push_token is not null
     and (last_push_at is null or last_push_at <= now() - interval '15 minutes');
  if cardinality(due) = 0 then return 0; end if;
  update public.yui_widgets set last_push_at = now(), pending_at = null where id = any(due);
  perform public.yui_widgets_send(due);
  return cardinality(due);
end $$;
revoke all on function public.yui_widgets_tick() from public, anon, authenticated;

-- A widget push was accepted: count it (the reload budget, spec section 3).
create or replace function public.yui_widgets_pushed(p_id uuid) returns void
language sql security definer set search_path = '' as $$
  update public.yui_widgets set pushes = pushes + 1, last_error = null where id = p_id;
$$;
revoke all on function public.yui_widgets_pushed(uuid) from public, anon, authenticated;
grant execute on function public.yui_widgets_pushed(uuid) to service_role;

do $$
begin
  perform cron.unschedule('yui-widgets-tick');
exception when others then null;
end $$;
select cron.schedule('yui-widgets-tick', '* * * * *', 'select public.yui_widgets_tick()');
