-- YUI-63 step 2: the working row says what the agent is doing (yuigui spec/YL.md
-- section 5, The working row).
--
-- Mid-turn the host writes the agent's newest `doing` onto the person's rows
-- that turn is answering: yui_messages.doing, {text?, step?, of?}, or null
-- after `doing off`. It is a column on a row that already exists, so a doing
-- adds no row to the thread, starts no turn and sends no push. The app reads
-- it while it waits (it already polls the person's newest row for
-- delivered_at) and draws it in place of the working word; the reply ends the
-- working row as before. A group's rows are per agent (one copy per member),
-- so each member's doing lands in its own row.
--
-- 1. The column: a small object, nothing else.
-- 2. The host may set it, under the same policy as delivered_at and
--    handled_at (yui_messages_connector_ack: the person's rows, threads it
--    serves). The app reads it with the rest of the row.
-- 3. doing_min_build: the oldest app build a host sends a doing to. An older
--    app would never show it, so there the host leaves it out. High until the
--    build that draws the row is VALID on TestFlight, then lowered to it.

-- 1.
alter table public.yui_messages add column if not exists doing jsonb;
alter table public.yui_messages drop constraint if exists yui_messages_doing_check;
alter table public.yui_messages add constraint yui_messages_doing_check
  check (doing is null or (jsonb_typeof(doing) = 'object' and pg_column_size(doing) <= 1024));

-- 2.
grant update (doing) on public.yui_messages to yui_connector;

-- 3.
insert into public.yui_limits (name, value, note) values
  ('doing_min_build', 10000, 'oldest app build a host sends `doing` to (YUI-63); the app card sets it to the first build that draws the working row''s words')
on conflict (name) do nothing;
