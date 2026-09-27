"""A music take reaches the agent as links (YUI-116 step 5): the event carries
signed https links to the .m4a and .mid, and localize() leaves them whole. A
bare photo path next to them is still fetched and swapped for the local file.

    ~/.hermes/hermes-agent/venv/bin/python hermes-plugin/tests/test_media_takes.py

Needs only the plugin source (fetch is stubbed).
"""

import os
import sys
import tempfile
import unittest
from pathlib import Path

os.environ["HERMES_HOME"] = tempfile.mkdtemp(prefix="yui-takes-")

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "yui"))
import media  # noqa: E402  (connector.py beside it, imported as a script)

U, A = "0b7e4c1a-2f7e-4a55-9d5e-1c2b3a4d5e6f", "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d"
PHOTO = f"{U}/{A}/user/1f2e3d4c-5b6a-4978-8695-a4b3c2d1e0f9.jpg"
TAKE = f"{U}/{A}/user/2a3b4c5d-6e7f-4081-9203-a4b5c6d7e8f9.m4a"
MIDI = f"{U}/{A}/user/2a3b4c5d-6e7f-4081-9203-a4b5c6d7e8fa.mid"
SIGN = "https://txuibjxyfpalzvpneqgp.supabase.co/storage/v1/object/sign/yui-media/{}?token=eyJhbGciOiJIUzI1NiJ9.x.y"


class TakeLinks(unittest.TestCase):
    def setUp(self):
        self.fetched = []
        self._fetch = media.fetch

        def fake(token, path):
            self.fetched.append(path)
            return b"\xff\xd8\xff" + b"jpeg"

        media.fetch = fake

    def tearDown(self):
        media.fetch = self._fetch

    def test_take_links_stay_whole(self):
        audio, midi = SIGN.format(TAKE), SIGN.format(MIDI)
        text = f"[yui] beat loop audio={audio} midi={midi} seconds=4.1 bpm=120"
        meta = {"id": "beat", "preset": "loop", "audio": audio, "midi": midi, "seconds": 4.1}
        out, paths, types = media.localize(text, meta, "tok")
        self.assertEqual(out, text)
        self.assertEqual(paths, [])
        self.assertEqual(self.fetched, [])
        self.assertIsNone(media.USER_PATH.search(text + str(meta)))

    def test_photo_path_still_localized(self):
        audio = SIGN.format(TAKE)
        text = f"[yui] c1 camera photo={PHOTO} audio={audio}"
        out, paths, types = media.localize(text, {"photo": PHOTO}, "tok")
        self.assertEqual(self.fetched, [PHOTO])
        self.assertEqual(types, ["image/jpeg"])
        self.assertNotIn(f"photo={PHOTO}", out)
        self.assertIn(f"photo={paths[0]}", out)
        self.assertIn(f"audio={audio}", out, "the take link was rewritten")

    def test_json_meta_photo(self):
        self.assertTrue(media.USER_PATH.search(f'{{"photo": "{PHOTO}"}}'))


if __name__ == "__main__":
    unittest.main(verbosity=2)
