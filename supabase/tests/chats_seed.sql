-- Threads that exist before chats: A has Basil (kind text, event, control, stop) and a shared-in agent, B has one agent.
insert into yui_users(id, apple_sub) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'test.a'), ('bbbbbbbb-0000-0000-0000-000000000001', 'test.b');
insert into yui_agents(id, user_id, name, handle, is_default) values
  ('a1a1a1a1-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 'Basil', 'basil', true),
  ('a2a2a2a2-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000001', 'Arnold', 'arnold', false),
  ('b1b1b1b1-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000001', 'Bee', 'bee', true);
insert into yui_devices(user_id, name, app_build) values ('aaaaaaaa-0000-0000-0000-000000000001', 'phone', 500);
insert into yui_messages(id, user_id, agent_id, sender, body, kind, created_at) values
  ('00000001-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001', 'user', 'what is for dinner', 'text', now() - interval '3 hours'),
  ('00000001-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001', 'agent', 'Tacos.', 'text', now() - interval '2 hours'),
  ('00000001-0000-0000-0000-000000000003', 'aaaaaaaa-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001', 'user', '[yui] n1 ask answer=Yes', 'event', now() - interval '1 hour'),
  ('00000001-0000-0000-0000-000000000004', 'aaaaaaaa-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001', 'user', 'controls: list', 'control', now() - interval '50 minutes'),
  ('00000001-0000-0000-0000-000000000005', 'aaaaaaaa-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001', 'user', 'stop', 'control', now() - interval '40 minutes'),
  ('00000002-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000001', 'b1b1b1b1-0000-0000-0000-000000000001', 'user', 'hello bee', 'text', now() - interval '1 hour');
