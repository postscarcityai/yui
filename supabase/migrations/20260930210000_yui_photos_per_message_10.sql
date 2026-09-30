-- The cap is 10 photos per send (Chris, 2026-09-30: "if the limits are that high let's just do 10").
-- Same number as Attachments.fallbackLimit (app) and DEFAULT_PHOTO_LIMIT (runtime).
insert into public.yui_limits (name, value, note) values
  ('photos_per_message', 10, 'photos one message carries; one send goes to the model in one call')
on conflict (name) do update set value = excluded.value, note = excluded.note;
