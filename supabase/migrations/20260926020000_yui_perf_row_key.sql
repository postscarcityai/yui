-- YUI-107: a speed row lands once (spec yuigui/spec/PERF.md, section 10).
--
-- The phone sends at least once: it drops a batch from perf-pending.json only
-- after the server answers, so a send that lands while iOS suspends or kills
-- the app goes out again on the next launch (seen on build 135: one batch
-- stored twice, 19 s apart, across a relaunch).
--
-- Each row now carries row_key, a uuid the phone makes once when it queues the
-- row and keeps with it on disk. unique (user_id, row_key) plus the phone's
-- `Prefer: resolution=ignore-duplicates` (on_conflict=user_id,row_key) turns a
-- resend into INSERT ... ON CONFLICT DO NOTHING: still a 201, nothing stored
-- twice, no retry loop. Rows from builds before this carry no key (null) and
-- land as before: nulls never conflict.
--
-- Numbers only still holds: a uuid is random, not anything a person wrote.
-- A resent row still passes the flood guard's before-insert trigger, but a
-- skipped row is not stored, so it never counts toward perf_rows_per_day.

alter table public.yui_perf add column if not exists row_key uuid;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'yui_perf_user_row_key') then
    alter table public.yui_perf add constraint yui_perf_user_row_key unique (user_id, row_key);
  end if;
end $$;

-- The phone may write the key; still no id, no created_at, no update.
grant insert (row_key) on public.yui_perf to yui_user;

notify pgrst, 'reload schema';
