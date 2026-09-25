-- INT-3: the Yui MCP server (functions/yui-mcp, spec yuigui/spec/MCP.md).
-- An MCP client is a connector of kind 'mcp' (already allowed since
-- 20260924090000). Its calls get their own bucket, because a model waiting on
-- taps calls far more often than a host's heartbeat (connect_* is 6 a minute).
-- Agent replies it writes still count against msg_connector_*.
insert into public.yui_limits (name, value, note) values
  ('mcp_burst',   60, 'MCP tool calls one MCP connection can make at once'),
  ('mcp_per_min', 30, 'sustained MCP tool calls per MCP connection per minute')
on conflict (name) do update set value = excluded.value, note = excluded.note;
