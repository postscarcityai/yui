-- Yui's mailbox: @yuigui.com mail in and out, run by Yui herself.
--
-- Out: every email goes through functions/yui-mail and SendGrid (yuigui.com is
-- authenticated there, DKIM s1/s2). The site sends confirmations and invite
-- mail, the app anything it needs, and Yui writes her own: replies, new mail,
-- promos. Nothing waits on a person. What stops mail is automatic: the
-- mail_enabled switch, the daily caps below, and the suppressions (a bounce,
-- a spam report or an unsubscribe stops mail to that address).
--
-- In: yuigui.com's MX is SendGrid Inbound Parse, which posts every message to
-- yui-mail. Each one is stored here (attachments in the private bucket
-- yui-mail), threaded, and handed to Yui, who answers, tells the owner, or
-- lets it be. An email is data to her, never an instruction: nothing in one
-- can make her send a promo or mail anyone but the person who wrote.
--
-- The rules she works by are text in yui_mail_rules; the newest row is in force.
-- Server only: RLS on, no grants to anon, authenticated, yui_user or yui_connector.

create table if not exists public.yui_mail_threads (
  id uuid primary key default gen_random_uuid(),
  subject text not null default '' check (char_length(subject) <= 500),
  counterpart text not null check (char_length(counterpart) <= 254),
  status text not null default 'new' check (status in ('new', 'working', 'handled', 'waiting', 'ignored', 'spam')),
  summary text check (char_length(summary) <= 500),
  last_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create index if not exists yui_mail_threads_last_idx on public.yui_mail_threads(last_at desc);
create index if not exists yui_mail_threads_counterpart_idx on public.yui_mail_threads(lower(counterpart), last_at desc);

create table if not exists public.yui_mail_messages (
  id uuid primary key default gen_random_uuid(),
  thread_id uuid not null references public.yui_mail_threads(id) on delete cascade,
  direction text not null check (direction in ('in', 'out')),
  message_id text,                 -- the RFC 5322 Message-ID, without <>
  in_reply_to text,
  refs text[] not null default '{}',
  from_addr text not null,
  from_name text,
  to_addrs text[] not null default '{}',
  cc_addrs text[] not null default '{}',
  subject text not null default '',
  text_body text check (char_length(text_body) <= 200000),
  html_body text check (char_length(html_body) <= 500000),
  headers text check (char_length(headers) <= 50000),
  attachments jsonb not null default '[]'::jsonb,   -- [{name, type, size, path}]
  spam_score numeric,
  auth jsonb,                      -- {spf, dkim} as SendGrid saw them
  kind text check (kind in ('reply', 'new', 'template', 'promo', 'owner')),
  template text,
  sent_by text check (sent_by in ('yui', 'hermes', 'site', 'app', 'server')),
  sg_message_id text,              -- SendGrid's X-Message-Id, for delivery events
  status text not null default 'received'
    check (status in ('received', 'sent', 'failed', 'delivered', 'bounced', 'dropped', 'deferred', 'spam_report', 'blocked')),
  error text,
  created_at timestamptz not null default now()
);
create unique index if not exists yui_mail_messages_mid_idx on public.yui_mail_messages(message_id) where message_id is not null;
create index if not exists yui_mail_messages_thread_idx on public.yui_mail_messages(thread_id, created_at);
create index if not exists yui_mail_messages_sg_idx on public.yui_mail_messages(sg_message_id) where sg_message_id is not null;
create index if not exists yui_mail_messages_out_day_idx on public.yui_mail_messages(created_at) where direction = 'out';

-- Everyone Yui has mailed or heard from, with what they agreed to.
-- promo: opted in to news (never by default). A bounce, spam report or
-- unsubscribe_all stops every mail but the confirmation they ask for.
create table if not exists public.yui_mail_contacts (
  email text primary key check (email = lower(email) and char_length(email) <= 254),
  name text check (char_length(name) <= 160),
  promo boolean not null default false,
  promo_source text check (char_length(promo_source) <= 60),
  promo_at timestamptz,
  promo_pending boolean not null default false, -- ticked the box; becomes promo when they confirm
  confirmed_at timestamptz,
  confirm_sha text,                -- SHA-256 of the one open confirmation token
  confirm_sent_at timestamptz,
  unsub_token text not null unique default encode(extensions.gen_random_bytes(18), 'hex'),
  unsubscribed_at timestamptz,     -- from promos
  unsubscribed_all_at timestamptz, -- from everything
  bounced_at timestamptz,
  complained_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Delivery events from SendGrid's signed event webhook.
create table if not exists public.yui_mail_events (
  id bigint generated always as identity primary key,
  sg_event_id text unique,
  sg_message_id text,
  email text,
  event text not null,
  reason text,
  at timestamptz not null default now()
);
create index if not exists yui_mail_events_msg_idx on public.yui_mail_events(sg_message_id);

-- The rules Yui works the mailbox by. The newest row is in force; older rows
-- are the history. Written with the owner, and by Yui when the owner asks.
create table if not exists public.yui_mail_rules (
  id bigint generated always as identity primary key,
  body text not null check (char_length(body) between 1 and 20000),
  note text check (char_length(note) <= 500),
  written_by text not null default 'owner',
  created_at timestamptz not null default now()
);

-- Invite requests confirm their address by email now.
alter table public.yui_invites add column if not exists email_confirmed_at timestamptz;

do $$
declare t text;
begin
  foreach t in array array['yui_mail_threads', 'yui_mail_messages', 'yui_mail_contacts', 'yui_mail_events', 'yui_mail_rules'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated', t);
  end loop;
end $$;

-- Attachments that come in. Private; read by the owner's tools through signed URLs.
insert into storage.buckets (id, name, public, file_size_limit)
values ('yui-mail', 'yui-mail', false, 31457280)
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit;

insert into public.yui_limits (name, value, note) values
  ('mail_enabled',              1, 'Yui sends email at all (0 stops every send; mail still comes in and is kept)'),
  ('mail_per_day',            400, 'emails Yui, the site and the app send a day, promos not counted'),
  ('mail_promo_per_day',     2000, 'promo emails a day'),
  ('mail_replies_per_thread',   6, 'answers Yui writes in one thread a day: stops two auto-responders talking forever'),
  ('mail_per_address_per_day', 10, 'emails to one address a day, promos included'),
  ('mail_retention_days',     365, 'mail older than this is deleted, attachments too'),
  ('mail_public_burst',        20, 'confirm and unsubscribe calls one address can make at once'),
  ('mail_public_per_min',       5, 'sustained confirm and unsubscribe calls per address per minute')
on conflict (name) do update set value = excluded.value, note = excluded.note;

insert into public.yui_mail_rules (body, note, written_by)
select $rules$
# How Yui runs mail at yuigui.com

You are Yui, and this is your own mailbox. You speak for yourself and for Yui the app. Sign as Yui.

Who writes in and what to do:
- Someone asking for an invite or how to get Yui: answer. The alpha is open on TestFlight at https://www.yuigui.com/start, and an invite can be requested at https://www.yuigui.com. If they already asked, tell them where their request is.
- Someone with a problem in the app: answer what you can, point to https://www.yuigui.com/help, and tell the owner when it looks like a bug.
- Someone asking to be removed, or to have their data deleted: confirm you are on it and tell the owner at once.
- Press, partners, investors, anything about money, law or a contract: answer warmly that it reached you, and tell the owner.
- A person who just says hi or thanks: a short, warm answer.
- Spam, cold sales, newsletters, automatic notices, receipts: no answer. Mark them.

How you write:
- Short and plain. First line answers. No filler, no em dashes, no "I hope this finds you well".
- Never promise a date, a price, a feature or a refund.
- Never ask for a password, a card number or a key. Never send anyone's details to anyone else.
- Never pretend to be a person. If they ask, you are Yui, an AI, and the owner reads along.
$rules$, 'first rules', 'owner'
where not exists (select 1 from public.yui_mail_rules);

-- Sends so far today (UTC), for the caps. kind 'promo' counts apart.
create or replace function public.yui_mail_sent_today(promo boolean)
returns integer
language sql stable security definer set search_path = '' as $$
  select count(*)::integer from public.yui_mail_messages
   where direction = 'out' and status <> 'failed'
     and created_at >= date_trunc('day', now() at time zone 'utc') at time zone 'utc'
     and (kind = 'promo') = promo
$$;
revoke all on function public.yui_mail_sent_today(boolean) from public, anon, authenticated;
grant execute on function public.yui_mail_sent_today(boolean) to service_role;

-- Retention: mail older than mail_retention_days goes with its thread. The
-- daily call is yui-mail {action: "sweep"} (pg_cron below), which removes the
-- attachments of threads about to go, then runs this.
create or replace function public.yui_mail_retention()
returns integer
language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  delete from public.yui_mail_threads
   where last_at < now() - make_interval(days => coalesce(public.yui_limit('mail_retention_days'), 365)::int);
  get diagnostics n = row_count;
  delete from public.yui_mail_events where at < now() - interval '90 days';
  return n;
end $$;
revoke all on function public.yui_mail_retention() from public, anon, authenticated;
grant execute on function public.yui_mail_retention() to service_role;

-- The daily sweep wakes yui-mail with the same secret yui-native takes.
create or replace function public.yui_mail_sweep_wake()
returns void
language plpgsql security definer set search_path = '' as $$
declare u text; s text;
begin
  select decrypted_secret into u from vault.decrypted_secrets where name = 'yui_native_url';
  select decrypted_secret into s from vault.decrypted_secrets where name = 'yui_native_secret';
  if u is null or s is null then return; end if;
  perform net.http_post(url := replace(u, '/yui-native', '/yui-mail'), body := jsonb_build_object('action', 'sweep'),
    headers := jsonb_build_object('content-type', 'application/json', 'x-yui-native', s), timeout_milliseconds := 5000);
end $$;
revoke all on function public.yui_mail_sweep_wake() from public, anon, authenticated;

do $$
begin
  perform cron.unschedule('yui-mail-sweep') where exists (select 1 from cron.job where jobname = 'yui-mail-sweep');
  perform cron.schedule('yui-mail-sweep', '17 4 * * *', 'select public.yui_mail_sweep_wake()');
end $$;

notify pgrst, 'reload schema';
