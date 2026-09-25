-- YUI-56: invites. A person asks for one on yuigui.com, Chris approves it,
-- Apple sends the TestFlight email, and their first Sign in with Apple claims
-- it.
--
--   requested  the site's form wrote it (service key, via the API route)
--   approved   Chris said yes (supabase/scripts/invite.py approve): a one-time
--              code exists; nothing has been sent yet
--   invited    the person is a tester in the external TestFlight group
--              "Invited" (App Store Connect betaTesters); Apple emailed them
--   claimed    a Yui account took it: by the email on their Apple ID, or by
--              the code (yuigui.com/i/<code>, or typed on the sign-in screen)
--   declined   Chris said no
--
-- Server only: RLS on, no policies, no grants. Only the service role (the
-- site's API route, yui-auth, invite.py) reads or writes it; never anon,
-- authenticated, yui_user or yui_connector. The code is stored as its SHA-256.
-- Deleting the claiming account deletes the row (on delete cascade); yui-delete
-- also removes any row with the account's email.
create table if not exists public.yui_invites (
  id uuid primary key default gen_random_uuid(),
  first_name text check (char_length(first_name) <= 80),
  last_name text check (char_length(last_name) <= 80),
  email text not null check (char_length(email) <= 254),
  phone text check (char_length(phone) <= 32),
  source text check (char_length(source) <= 60),
  utm text check (char_length(utm) <= 500),
  referrer text check (char_length(referrer) <= 500),
  user_agent text check (char_length(user_agent) <= 500),
  status text not null default 'requested'
    check (status in ('requested', 'approved', 'invited', 'claimed', 'declined')),
  code_hash text unique,
  agent_template text check (agent_template ~ '^[a-z0-9][a-z0-9-]{0,39}$'),
  notes text check (char_length(notes) <= 2000),
  asc_tester_id text,
  asc_error text,
  claimed_user_id uuid references public.yui_users(id) on delete cascade,
  created_at timestamptz not null default now(),
  approved_at timestamptz,
  invited_at timestamptz,
  claimed_at timestamptz,
  declined_at timestamptz,
  updated_at timestamptz not null default now()
);
create unique index if not exists yui_invites_email_lower on public.yui_invites (lower(email));
create index if not exists yui_invites_status_idx on public.yui_invites (status, created_at);
create index if not exists yui_invites_claimed_user_idx on public.yui_invites (claimed_user_id);

revoke all on public.yui_invites from public, anon, authenticated;
alter table public.yui_invites enable row level security;

create or replace function public.yui_invites_touch() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists yui_invites_touch on public.yui_invites;
create trigger yui_invites_touch before update on public.yui_invites
  for each row execute function public.yui_invites_touch();

-- Claims one invite for an account, all or nothing: by code when one is given
-- (the hash of the normalized code), else by the Apple ID email Apple
-- verified. yui-auth tries the code first, then the email. Only approved or invited rows, never one already claimed or
-- declined; an account holds at most one invite. Returns the claimed row's
-- id, first name and template, or nothing.
create or replace function public.yui_claim_invite(uid uuid, code_sha text, verified_email text)
returns table (id uuid, first_name text, agent_template text)
language plpgsql volatile security definer
set search_path = ''
as $$
#variable_conflict use_column
begin
  if exists (select 1 from public.yui_invites i where i.claimed_user_id = uid) then
    return;
  end if;
  return query
  update public.yui_invites i
     set status = 'claimed', claimed_user_id = uid, claimed_at = now()
   where i.id = (
     select j.id from public.yui_invites j
      where j.status in ('approved', 'invited') and j.claimed_user_id is null
        and (case when code_sha is not null then j.code_hash = code_sha
                  else verified_email is not null and lower(j.email) = lower(verified_email) end)
      limit 1 for update)
  returning i.id, i.first_name, i.agent_template;
end $$;
revoke all on function public.yui_claim_invite(uuid, text, text) from public, anon, authenticated;
grant execute on function public.yui_claim_invite(uuid, text, text) to service_role;

-- A wrong code costs a token: 10 at once, then about one a minute per account.
insert into public.yui_limits (name, value, note) values
  ('invite_code_burst',   10, 'invite codes one account can try at once'),
  ('invite_code_per_min',  1, 'sustained invite code tries per account per minute')
on conflict (name) do update set value = excluded.value, note = excluded.note;

-- The waitlist becomes invite requests. Waitlist rows have no first/last name
-- or phone; whatever they have (a single name, the note with UTM tags, the
-- source) comes along.
insert into public.yui_invites (email, first_name, source, utm, referrer, user_agent, notes, created_at)
select lower(w.email), left(w.name, 80), w.source,
       case when w.note ~ 'utm_' then left(w.note, 500) end,
       w.referrer, w.user_agent,
       case when w.note !~ 'utm_' then w.note end, w.created_at
  from public.yui_waitlist w
on conflict (lower(email)) do nothing;

notify pgrst, 'reload schema';
