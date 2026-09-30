-- One send takes as many photos as one model call can (Chris, 2026-09-30).
-- photos_per_message is the lowest per-request image cap of the big three, read live by the app
-- (Attachments.maxPhotos) and by yui-native, so it moves without a build:
--   Claude API   100 per request on 200k-context models, 600 on the rest (20 on claude.ai)
--                https://platform.claude.com/docs/en/build-with-claude/vision
--   OpenAI       1,500 per request, 512 MB payload
--                https://developers.openai.com/api/docs/guides/images-vision
--   Gemini       3,600 per request, 20 MB when sent inline
--                https://ai.google.dev/gemini-api/docs/image-understanding
-- Past 20 images Claude also wants each side at 2000 px or less (YuiMedia.maxSide).
-- The day's upload quota moves with it: a full send is 100 pictures.
insert into public.yui_limits (name, value, note) values
  ('photos_per_message',    100, 'photos one message carries; the lowest per-request image cap of Claude, OpenAI and Gemini'),
  ('media_uploads_per_day', 1000, 'pictures per account per day, each side (person, agents)')
on conflict (name) do update set value = excluded.value, note = excluded.note;
