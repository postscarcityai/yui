-- INT-1: OpenClaw agents pair through their own channel plugin, so their
-- connector (and the agents on it) carry kind 'openclaw'. Same contract as
-- 'hermes'; the app never branches on it.
alter table public.yui_connectors drop constraint if exists yui_connectors_kind_check;
alter table public.yui_connectors add constraint yui_connectors_kind_check
  check (kind in ('hermes', 'openclaw', 'http', 'mcp', 'hosted'));
alter table public.yui_agents drop constraint if exists yui_agents_kind_check;
alter table public.yui_agents add constraint yui_agents_kind_check
  check (kind in ('hermes', 'openclaw', 'http', 'mcp', 'hosted'));
