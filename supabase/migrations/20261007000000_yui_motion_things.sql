-- MOTION-29: drawings native agents learn. A film about a noun the kit and the
-- shipped seed lack (a camel, a kayak) draws it once on the spot; after the film
-- is over a background job draws it again, a judge looks at the render, and a
-- pass is kept here under its narrow word forms. The next ask for that noun, from
-- anyone, finds the kept drawing and the film starts at once (the same as the
-- Hermes plugin's learner, hermes-plugin/yui/motion_hero.py).
--
-- Shared across people, keyed by the noun. A row holds the noun, its label, the
-- parts (the kit's shape vocabulary only) and the word pattern. Never a message,
-- an ask or a user id.
--
-- status: claimed (a drawing is being made), drawn (made, waiting for the judge),
-- kept (the judge passed it: films use it), failed (no parts, or the judge said no).
-- The judge runs on a machine with a browser (site/scripts/motion/judge_things.py
-- in yuigui), not here. Server only: no grant to anon, authenticated, yui_user.

create table if not exists public.yui_motion_things (
  name text primary key check (name ~ '^[a-z][a-z0-9_]{1,23}$'),
  label text not null check (char_length(label) between 2 and 24),
  parts jsonb check (parts is null or (jsonb_typeof(parts) = 'array' and pg_column_size(parts) <= 16384)),
  words text check (words is null or char_length(words) <= 200),
  status text not null default 'claimed' check (status in ('claimed', 'drawn', 'kept', 'failed')),
  tries integer not null default 0,
  why text check (why is null or char_length(why) <= 120),
  claimed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (status <> 'kept' or (parts is not null and words is not null))
);
create index if not exists yui_motion_things_status_idx on public.yui_motion_things(status);
alter table public.yui_motion_things enable row level security;
revoke all on public.yui_motion_things from public, anon, authenticated;
grant select, insert, update on public.yui_motion_things to service_role;

-- Drawings the learner started per day: the daily cap.
create table if not exists public.yui_motion_learn_day (
  day date primary key,
  n integer not null default 0
);
alter table public.yui_motion_learn_day enable row level security;
revoke all on public.yui_motion_learn_day from public, anon, authenticated;
grant select, insert, update on public.yui_motion_learn_day to service_role;

-- Takes the right to draw `p_name` again: at most p_inflight drawings under way
-- (a claim older than five minutes died), p_daily a day, two tries per noun ever,
-- and never a noun already drawn or kept. True when this run has it.
create or replace function public.yui_motion_learn_claim(p_name text, p_daily integer, p_inflight integer)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  r public.yui_motion_things;
  today date := (now() at time zone 'utc')::date;
  used integer;
begin
  if p_name !~ '^[a-z][a-z0-9_]{1,23}$' then return false; end if;
  perform pg_advisory_xact_lock(hashtext('yui_motion_learn'));
  select * into r from public.yui_motion_things where name = p_name;
  if found then
    if r.status in ('drawn', 'kept') or r.tries >= 2 then return false; end if;
    if r.status = 'claimed' and r.claimed_at > now() - interval '5 minutes' then return false; end if;
  end if;
  if (select count(*) from public.yui_motion_things where status = 'claimed' and claimed_at > now() - interval '5 minutes') >= p_inflight then
    return false;
  end if;
  select n into used from public.yui_motion_learn_day where day = today;
  if coalesce(used, 0) >= p_daily then return false; end if;
  insert into public.yui_motion_learn_day(day, n) values (today, 1)
    on conflict (day) do update set n = public.yui_motion_learn_day.n + 1;
  insert into public.yui_motion_things(name, label, status, tries, claimed_at)
    values (p_name, replace(p_name, '_', ' '), 'claimed', 1, now())
    on conflict (name) do update set status = 'claimed', tries = public.yui_motion_things.tries + 1,
      claimed_at = now(), updated_at = now();
  return true;
end;
$$;
revoke all on function public.yui_motion_learn_claim(text, integer, integer) from public, anon, authenticated;
grant execute on function public.yui_motion_learn_claim(text, integer, integer) to service_role;

-- A claimed noun's drawing arrives (waits for the judge), or the run gives up (failed, with why).
create or replace function public.yui_motion_learn_put(p_name text, p_label text, p_parts jsonb, p_words text, p_why text)
returns void
language sql security definer set search_path = '' as $$
  update public.yui_motion_things
     set status = case when p_parts is null then 'failed' else 'drawn' end,
         label = coalesce(p_label, label), parts = p_parts, words = p_words,
         why = left(p_why, 120), updated_at = now()
   where name = p_name and status = 'claimed';
$$;
revoke all on function public.yui_motion_learn_put(text, text, jsonb, text, text) from public, anon, authenticated;
grant execute on function public.yui_motion_learn_put(text, text, jsonb, text, text) to service_role;

-- The judge's answer for a drawn noun: kept, or failed (a second try is allowed once).
create or replace function public.yui_motion_learn_judged(p_name text, p_ok boolean, p_why text)
returns void
language sql security definer set search_path = '' as $$
  update public.yui_motion_things
     set status = case when p_ok then 'kept' else 'failed' end, why = left(p_why, 120), updated_at = now()
   where name = p_name and status = 'drawn';
$$;
revoke all on function public.yui_motion_learn_judged(text, boolean, text) from public, anon, authenticated;
grant execute on function public.yui_motion_learn_judged(text, boolean, text) to service_role;
