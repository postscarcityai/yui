-- YUI-20: every agent has its own look. yui_agents.theme (added in YUI-15)
-- holds a small recipe: {preset, accent, bg, radius, font, weight, motion,
-- style: {screen, gallery, chart, buttons}, at, by}. Spec: yuigui/spec/AGENTS.md.
-- The yui-agents function cleans it; this keeps a direct PostgREST write
-- (yui_user may update the column) to a small JSON object.
alter table public.yui_agents drop constraint if exists yui_agents_theme_check;
alter table public.yui_agents add constraint yui_agents_theme_check
  check (jsonb_typeof(theme) = 'object' and pg_column_size(theme) <= 2048);
