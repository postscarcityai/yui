-- YUI-103: work a native agent does behind the scenes, after it has answered.
-- The first job is a meal's macros: a photo to Basil is answered at once ("Got
-- it, working out the macros"), and the vision call, the arithmetic, the log
-- rows and the breakdown reply run as a job (runtime/src/meals.ts).
--
-- yui-native runs a job right after the answer that queued it, in the same
-- wake. This table is what makes that safe: a run claims the job first
-- (yui_native_claim_job), so two runs never do it twice, and the minute tick
-- wakes yui-native again for a job no run finished (queued for over a minute,
-- or claimed over five minutes ago), three tries at most. Done jobs go after
-- seven days.
-- Server only: no grant to anon, authenticated, yui_connector or yui_user.

create table if not exists public.yui_native_jobs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.yui_users(id) on delete cascade,
  agent_id uuid not null references public.yui_agents(id) on delete cascade,
  kind text not null check (kind in ('meal')),
  input jsonb not null check (jsonb_typeof(input) = 'object' and pg_column_size(input) <= 4096),
  status text not null default 'queued' check (status in ('queued', 'running', 'done', 'failed')),
  tries integer not null default 0,
  result jsonb,
  created_at timestamptz not null default now(),
  claimed_at timestamptz,
  finished_at timestamptz
);
create index if not exists yui_native_jobs_open_idx on public.yui_native_jobs(created_at) where status in ('queued', 'running');
create index if not exists yui_native_jobs_agent_idx on public.yui_native_jobs(agent_id);
create index if not exists yui_native_jobs_user_idx on public.yui_native_jobs(user_id);
alter table public.yui_native_jobs enable row level security;
revoke all on public.yui_native_jobs from public, anon, authenticated;

-- Takes a job to run: queued, or claimed by a run that died (over five minutes
-- ago), with tries left. Returns the job, or nothing when another run has it.
create or replace function public.yui_native_claim_job(jid uuid)
returns setof public.yui_native_jobs
language sql security definer set search_path = '' as $$
  update public.yui_native_jobs
     set status = 'running', tries = tries + 1, claimed_at = now()
   where id = jid and tries < 3
     and (status = 'queued' or (status = 'running' and claimed_at < now() - interval '5 minutes'))
  returning *;
$$;
revoke all on function public.yui_native_claim_job(uuid) from public, anon, authenticated;
grant execute on function public.yui_native_claim_job(uuid) to service_role;

-- The minute tick: check-ins as before, then jobs no run finished.
create or replace function public.yui_native_tick()
returns integer
language plpgsql security definer set search_path = '' as $$
declare
  u text;
  s text;
  r record;
  n integer := 0;
begin
  if coalesce(public.yui_limit('native_enabled'), 0) < 1 then return 0; end if;
  select decrypted_secret into u from vault.decrypted_secrets where name = 'yui_native_url';
  select decrypted_secret into s from vault.decrypted_secrets where name = 'yui_native_secret';
  if u is null or s is null then return 0; end if;
  for r in
    update public.yui_native_schedules set next_at = null, fired_at = now()
     where id in (select id from public.yui_native_schedules
                   where not paused
                     and (next_at <= now()
                          or (next_at is null and fired_at < now() - interval '10 minutes' and rule ? 'every'))
                   order by next_at nulls first limit 200 for update skip locked)
    returning id
  loop
    perform net.http_post(url := u, body := jsonb_build_object('schedule_id', r.id),
      headers := jsonb_build_object('content-type', 'application/json', 'x-yui-native', s), timeout_milliseconds := 5000);
    n := n + 1;
  end loop;
  for r in
    select id from public.yui_native_jobs
     where tries < 3 and created_at > now() - interval '1 hour'
       and ((status = 'queued' and coalesce(claimed_at, created_at) < now() - interval '1 minute')
            or (status = 'running' and claimed_at < now() - interval '5 minutes'))
     order by created_at limit 50
  loop
    perform net.http_post(url := u, body := jsonb_build_object('job_id', r.id),
      headers := jsonb_build_object('content-type', 'application/json', 'x-yui-native', s), timeout_milliseconds := 5000);
    n := n + 1;
  end loop;
  -- A job that ran out of tries is failed; finished ones go after a week.
  update public.yui_native_jobs set status = 'failed', finished_at = now()
   where status in ('queued', 'running') and (tries >= 3 or created_at < now() - interval '1 hour')
     and coalesce(claimed_at, created_at) < now() - interval '5 minutes';
  delete from public.yui_native_jobs where created_at < now() - interval '7 days';
  return n;
end $$;
revoke all on function public.yui_native_tick() from public, anon, authenticated;

notify pgrst, 'reload schema';
