-- YUI-96: the app look (spec yuigui/spec/RESTYLE.md, section 6).
--
-- yui_users.look is the look of everything that is nobody's thread: the agent
-- list, the tab bar, Settings, sheets and Yui's own thread. Same recipe keys as
-- yui_agents.theme without `style`, plus `prev` (one step of Undo),
-- `agents_keep_looks` and `via`:
--   {"preset": "autumn", "font": "serif", "prev": {"preset": "ocean"},
--    "agents_keep_looks": true, "at": "...", "by": "user", "via": "Coach"}
-- null means Yui's own look.
--
-- Written only on the person's tap, through the `yui-account` function
-- (action "set_look"), which cleans it strictly and stamps `at` and `by`. Neither
-- token role can write it:
--   yui_user      reads its own row (whole-table select + yui_users_self RLS,
--                 20260923230000_yui_accounts.sql), so it can read `look`;
--                 it holds no insert or update on yui_users.
--   yui_connector holds no privilege on yui_users at all. A host has no path.
-- The check below keeps even a service-role write to a small JSON object.

alter table public.yui_users add column if not exists look jsonb;

alter table public.yui_users drop constraint if exists yui_users_look_check;
alter table public.yui_users add constraint yui_users_look_check
  check (look is null or (jsonb_typeof(look) = 'object' and pg_column_size(look) <= 2048));

-- Belt and braces: no write path for either token role, whatever a later
-- migration grants by default.
revoke insert, update, delete on public.yui_users from yui_user;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'yui_connector') then
    revoke all on public.yui_users from yui_connector;
  end if;
end $$;
