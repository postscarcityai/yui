-- YUI-116 step 5: music takes. The app records what its sound engine plays and
-- sends it like a camera photo: an AAC file (.m4a, audio/mp4) and a MIDI file
-- (.mid, audio/midi) under <user>/<agent>/user/, the event carrying signed
-- links. Same bucket, same rules, same 50 MB cap (a 2 minute take is ~2 MB);
-- only the allowed types grow.

update storage.buckets
   set allowed_mime_types = array[
     'image/jpeg', 'image/png', 'image/webp', 'image/gif', 'image/heic',
     'video/mp4', 'video/quicktime',
     'audio/mp4', 'audio/midi']
 where id = 'yui-media';
