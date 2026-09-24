"""Yui media: pictures and videos in and out of the app (YUI-21).

Storage is the private `yui-media` bucket in PROOF (migration
20260924040000_yui_media.sql). Paths are `<user>/<agent>/<from>/<uuid>.<ext>`.
The host writes under from=agent with its yui_connector token and hands the
app signed URLs; the app writes the person's photos under from=user.

Out: `rewrite()` walks the ```yui fences of a reply. A local media file (an
absolute path, `~/...` or `file://`) or a remote media URL on a media line is
uploaded, and the token is swapped for a signed URL. Everything else in the
reply is left alone.
In: `localize()` finds the person's photos in an event (`[yui] c1 camera
photo=<path>`), downloads them next to Hermes' other cached media and swaps
the path for the local file, so the agent can open it and vision sees it.

Stdlib only: the gateway, `hermes send --to yui` and `hermes yui media` share it.
"""
import json, mimetypes, os, re, time, urllib.error, urllib.parse, urllib.request, uuid
from pathlib import Path

try:
    from . import connector
except ImportError:  # connector.py run as a script
    import connector

BUCKET = "yui-media"
STORAGE = f"{connector.SUPABASE_URL}/storage/v1"
MAX_BYTES = 50 * 1024 * 1024        # the bucket's file_size_limit
SIGN_SECONDS = 7 * 24 * 3600        # the app re-signs an expired link with its own token
TYPES = {  # extension -> content type the bucket accepts
    "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "webp": "image/webp",
    "gif": "image/gif", "heic": "image/heic", "mp4": "video/mp4", "m4v": "video/mp4", "mov": "video/quicktime",
}
EXT = {"image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/gif": "gif",
       "image/heic": "heic", "video/mp4": "mp4", "video/quicktime": "mov"}
# Lines whose remote URLs are media to keep (a `card` or `list` link stays a link).
MEDIA_PRESETS = {"image", "gallery", "video", "compare", "storyboard", "page", "card"}
# Generators whose output URLs carry no extension or expire.
MEDIA_HOSTS = ("fal.media", "fal.run", "fal.ai", "replicate.delivery", "oaidalleapiprodscus.blob.core.windows.net")

_FENCE = re.compile(r"```yui[^\n]*\n(.*?)```", re.S)
_LOCAL = re.compile(r"(?:file://)?(?:~|/)[^\s\"|]+\.(?:" + "|".join(TYPES) + r")\b", re.I)
_REMOTE = re.compile(r"https?://[^\s\"|]+")
USER_PATH = re.compile(r"[0-9a-f-]{36}/[0-9a-f-]{36}/user/[A-Za-z0-9._-]{1,80}")
# Never upload these, whatever the extension says.
_BLOCKED = (".ssh", ".gnupg", ".aws", ".config/gcloud", "Keychains", ".hermes/.env", "auth.json")


class MediaError(Exception):
    pass


def sniff(data: bytes) -> str | None:
    """Content type from the bytes. Extensions lie; the bucket trusts the header we send."""
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if data[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if data[:6] in (b"GIF87a", b"GIF89a"):
        return "image/gif"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    if data[4:8] == b"ftyp":
        brand = data[8:12]
        if brand in (b"heic", b"heix", b"mif1", b"msf1", b"hevc"):
            return "image/heic"
        if brand == b"qt  ":
            return "video/quicktime"
        return "video/mp4"
    return None


def _http(method: str, url: str, headers: dict, data: bytes | None = None, timeout: int = 60):
    req = urllib.request.Request(url, data=data, method=method, headers={"user-agent": "hermes-yui", **headers})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read(MAX_BYTES + 1)
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def _auth(token: str) -> dict:
    return {"apikey": connector.PUBLISHABLE, "authorization": f"Bearer {token}"}


def local_path(token: str) -> Path | None:
    p = urllib.parse.unquote(token[7:]) if token.startswith("file://") else token
    path = Path(p).expanduser()
    if not path.is_absolute() or any(b in str(path) for b in _BLOCKED):
        return None
    return path if path.is_file() else None


def read_source(src: str) -> tuple[bytes, str]:
    """Bytes and content type of a local file or a remote URL."""
    if src.startswith(("http://", "https://")):
        s, data = _http("GET", src, {}, timeout=120)
        if s >= 300:
            raise MediaError(f"download {s}")
    else:
        path = local_path(src)
        if not path:
            raise MediaError("not a readable media file")
        if path.stat().st_size > MAX_BYTES:
            raise MediaError("over 50 MB")
        data = path.read_bytes()
    if len(data) > MAX_BYTES:
        raise MediaError("over 50 MB")
    ctype = sniff(data)
    if not ctype:
        raise MediaError("not an image or video Yui can show (jpg, png, webp, gif, heic, mp4, mov)")
    return data, ctype


def upload(db_token: str, user_id: str, agent_id: str, data: bytes, ctype: str) -> str:
    path = f"{user_id}/{agent_id}/agent/{uuid.uuid4()}.{EXT[ctype]}"
    s, body = _http("POST", f"{STORAGE}/object/{BUCKET}/{path}", {**_auth(db_token), "content-type": ctype}, data)
    if s >= 300:
        raise MediaError(f"upload {s}: {body[:200]!r}")
    return path


def sign(db_token: str, path: str, seconds: int = SIGN_SECONDS) -> str:
    s, body = _http("POST", f"{STORAGE}/object/sign/{BUCKET}/{path}",
                    {**_auth(db_token), "content-type": "application/json"},
                    json.dumps({"expiresIn": seconds}).encode())
    if s >= 300:
        raise MediaError(f"sign {s}: {body[:200]!r}")
    return f"{STORAGE}{json.loads(body)['signedURL']}"


def is_ours(url: str) -> bool:
    return url.startswith(f"{STORAGE}/object/") and f"/{BUCKET}/" in url


def host(db_token: str, user_id: str, agent_id: str, src: str) -> str:
    """Upload a file or URL into this agent's thread and return a signed URL."""
    data, ctype = read_source(src)
    return sign(db_token, upload(db_token, user_id, agent_id, data, ctype))


def _wants(url: str) -> bool:
    """A remote URL worth re-hosting: a media file, or a generator's output."""
    bare = url.split("?")[0].split("#")[0].lower()
    return (bare.rsplit(".", 1)[-1] in TYPES or any(h in urllib.parse.urlsplit(url).netloc for h in MEDIA_HOSTS)) \
        and not is_ours(url)


def rewrite(body: str, hoster, log=None) -> str:
    """Swap local media and media URLs inside ```yui fences for signed URLs.

    `hoster(src) -> url` does the upload. A failure leaves that token as it was.
    """
    if "```yui" not in body:
        return body
    done: dict[str, str] = {}

    def swap(src: str) -> str:
        if src not in done:
            try:
                done[src] = hoster(src)
            except Exception as e:  # keep the line; the app shows a broken picture, not a lost reply
                if log:
                    log.warning("[yui] media %s not sent: %s", src[:120], e)
                done[src] = src
        return done[src]

    def line(ln: str) -> str:
        head = ln.strip().split(" ", 1)[0].split("@", 1)[0]
        ln = _LOCAL.sub(lambda m: swap(m.group(0)) if local_path(m.group(0)) else m.group(0), ln)
        if head in MEDIA_PRESETS:
            ln = _REMOTE.sub(lambda m: swap(m.group(0)) if _wants(m.group(0)) else m.group(0), ln)
        return ln

    def fence(m: re.Match) -> str:
        inner = "\n".join(line(x) for x in m.group(1).split("\n"))
        return m.group(0).replace(m.group(1), inner, 1)

    return _FENCE.sub(fence, body)


def fetch(db_token: str, path: str) -> bytes:
    s, data = _http("GET", f"{STORAGE}/object/authenticated/{BUCKET}/{path}", _auth(db_token), timeout=120)
    if s >= 300:
        raise MediaError(f"fetch {s}")
    return data


def cache_dir() -> Path:
    d = connector.hermes_root() / "cache" / "yui"
    d.mkdir(parents=True, exist_ok=True)
    return d


def localize(text: str, meta: dict, db_token: str, log=None) -> tuple[str, list[str], list[str]]:
    """Download the person's photos named in an event; return (text, paths, types)."""
    found = list(dict.fromkeys(USER_PATH.findall(text) + USER_PATH.findall(json.dumps(meta or {}))))
    paths, types = [], []
    for p in found:
        try:
            data = fetch(db_token, p)
        except Exception as e:
            if log:
                log.warning("[yui] photo %s not fetched: %s", p[-40:], e)
            continue
        ctype = sniff(data) or mimetypes.guess_type(p)[0] or "application/octet-stream"
        dest = cache_dir() / f"{int(time.time())}-{p.rsplit('/', 1)[-1]}"
        dest.write_bytes(data)
        os.chmod(dest, 0o600)
        text = text.replace(p, str(dest))
        paths.append(str(dest))
        types.append(ctype)
    return text, paths, types


# -- generation: fal nano-banana-2 on the owner's own FAL_KEY (no new paid service)

FAL = "https://queue.fal.run/fal-ai/nano-banana-2"


def fal_key() -> str | None:
    if os.environ.get("FAL_KEY"):
        return os.environ["FAL_KEY"]
    home = Path(os.environ.get("HERMES_HOME") or connector.hermes_root())
    for env in (home / ".env", connector.hermes_root() / ".env"):
        try:
            for ln in env.read_text().splitlines():
                if ln.startswith("FAL_KEY="):
                    return ln.split("=", 1)[1].strip().strip("'\"")
        except FileNotFoundError:
            pass
    return None


def generate(prompt: str, aspect: str = "1:1", edit: str | None = None, resolution: str = "2K") -> str:
    """Render one image and return its fal URL. `edit` = a file or URL to change."""
    key = fal_key()
    if not key:
        raise MediaError("no FAL_KEY in the environment or this profile's .env")
    body = {"prompt": prompt, "num_images": 1, "output_format": "jpeg", "resolution": resolution}
    url = FAL
    if edit:
        if edit.startswith(("http://", "https://")):
            ref = edit
        else:
            import base64
            data, ctype = read_source(edit)
            ref = f"data:{ctype};base64,{base64.b64encode(data).decode()}"
        body["image_urls"] = [ref]
        url = f"{FAL}/edit"
    else:
        body["aspect_ratio"] = aspect
    auth = {"authorization": f"Key {key}", "content-type": "application/json"}
    s, r = _http("POST", url, auth, json.dumps(body).encode())
    if s >= 300:
        raise MediaError(f"fal {s}: {r[:300]!r}")
    job = json.loads(r)
    status_url = job.get("status_url") or f"{FAL}/requests/{job['request_id']}/status"
    result_url = job.get("response_url") or f"{FAL}/requests/{job['request_id']}"
    for _ in range(180):
        s, r = _http("GET", status_url, auth)
        state = json.loads(r).get("status") if s < 300 else None
        if state == "COMPLETED":
            break
        if s >= 300 and s != 202:
            raise MediaError(f"fal status {s}: {r[:200]!r}")
        time.sleep(2)
    else:
        raise MediaError("fal timed out")
    s, r = _http("GET", result_url, auth)
    out = json.loads(r) if s < 300 else {}
    images = out.get("images") or []
    if not images:
        raise MediaError(f"fal returned no image: {r[:300]!r}")
    return images[0]["url"]
