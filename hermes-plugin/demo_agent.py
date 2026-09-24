#!/usr/bin/env python3
"""The App Review demo agent: a scripted agent that answers with screens.

Apple's reviewer signs in with the demo code from the review notes (yui-auth
grant "review"), which opens ONE throwaway account. A new Yui account has no
agent until its owner connects one, so this script is that account's agent.
It speaks the same host contract as the Hermes plugin (yui-connect session +
heartbeat, PostgREST on yui_messages as role yui_connector, delivered_at /
handled_at acks, yui-push notify), but its replies are canned Yui Lines, not a
model. No LLM, no tools, nothing from this machine reaches the reviewer.

    demo_agent.py setup      # pair (or re-pair) the demo account's agent
    demo_agent.py run        # serve it until stopped (launchd keeps it up)
    demo_agent.py reply "hi" # print the reply to a message, offline

Local config, never committed: ~/.hermes/yui/review.json (mode 600) holds
{"code": "<review code>"}. The connector token lives in
~/.hermes/yui/demo-connector.json, apart from this machine's real connector.
If the reviewer deletes the demo account, the connector token stops working;
`run` then signs in with the code (which recreates the account) and pairs a
fresh agent by itself.
"""
import json, os, sys, time, urllib.error, urllib.parse, urllib.request
from datetime import datetime, timezone
from pathlib import Path

HOME = Path.home() / ".hermes" / "yui"
os.environ.setdefault("YUI_CONNECTOR_FILE", str(HOME / "demo-connector.json"))
sys.path.insert(0, str(Path(__file__).resolve().parent / "yui"))
import connector  # noqa: E402  (reads YUI_CONNECTOR_FILE at import)

REVIEW = HOME / "review.json"
PROFILE = "yui-demo"
NAME = "Demo"
HOST = "Yui demo host"
REST = f"{connector.SUPABASE_URL}/rest/v1"
AUTH = f"{connector.SUPABASE_URL}/functions/v1/yui-auth"
AGENTS = f"{connector.SUPABASE_URL}/functions/v1/yui-agents"
POLL_SECONDS = 2
HEARTBEAT_SECONDS = 60


def log(*a):
    print(datetime.now().strftime("%H:%M:%S"), *a, flush=True)


# -- the script ---------------------------------------------------------------

MENU = ('choose@menu "What should we try?" Workout|"Plan dinner"|"Focus timer"|"My week"|"Quick lesson"')


def fence(*lines: str) -> str:
    return "```yui\n" + "\n".join(lines) + "\n```"


def greet() -> str:
    return ("Hi! I'm Demo, a sample agent. Real agents are the ones you connect. "
            "Pick something and I'll answer with a screen.\n" + fence(MENU))


def workout() -> str:
    return "Ten minutes, any room. What do you have?\n" + fence(
        'pick@gear "Gear" Dumbbells|Bands|"Just me"')


def circuit(gear: list) -> str:
    kit = set(gear or [])
    moves = ["Squats 12", "Push-ups 10", "Plank 30s", "Lunges 10 each"]
    if "Dumbbells" in kit:
        moves[0], moves[3] = "Goblet squats 12", "DB rows 10 each"
    elif "Bands" in kit:
        moves[3] = "Band pull-aparts 15"
    items = " ".join(json.dumps(m) for m in moves)
    return "Four moves, three rounds. Start the timer when you're ready.\n" + fence(
        f"list Circuit {items} +check", "timer@circuit 40/20x12 Circuit")


def circuit_done() -> str:
    return fence("say Done. That's ten minutes well spent.",
                 'ask@again "What next?" "Another round"|"Back to the menu"')


def dinner() -> str:
    return "Let's find tonight's dinner.\n" + fence('slide@hunger "How hungry?" 1-5 Snack|Starving value=3')


DINNERS = {
    "light": ("Miso soup and rice", ["Miso paste", "Tofu", "Scallions", "Rice"], "15 min"),
    "mid": ("Chicken stir fry", ["Chicken thighs", "Broccoli", "Soy sauce", "Garlic", "Rice"], "25 min"),
    "big": ("Pasta bolognese", ["Pasta", "Ground beef", "Tomatoes", "Onion", "Parmesan"], "40 min"),
}


def dinner_options(hunger: float) -> str:
    opts = ["Miso soup", "Stir fry"] if hunger <= 2 else ["Stir fry", "Bolognese"] if hunger <= 4 else ["Bolognese", "Stir fry"]
    return fence(f'choose@dinner "Sounds good?" {"|".join(json.dumps(o) for o in opts)}')


def dinner_card(choice: str) -> str:
    key = {"Miso soup": "light", "Stir fry": "mid", "Bolognese": "big"}.get(choice, "mid")
    name, shop, mins = DINNERS[key]
    items = " ".join(json.dumps(i) for i in shop)
    return fence(f'card {json.dumps(name)} body={json.dumps("About " + mins + ", one pan.")} cta="Start cooking"',
                 f"list Shopping {items} +check")


def focus() -> str:
    return "Twenty-five minutes, one thing. Put your phone face down.\n" + fence("timer@focus 25m Focus")


def week() -> str:
    return "Your week at a glance (sample numbers).\n" + fence(
        "stat 7842 Steps delta=+612 spark=6100|7200|6900|8100|7800|8400|7842",
        'chart bar "Active minutes" x=Mon|Tue|Wed|Thu|Fri|Sat|Sun y=32|45|28|50|41|60|38')


def lesson() -> str:
    return fence(
        'deck "Why the sky is blue"',
        'page "Sunlight is every color" body="White light is a mix of all the colors of the rainbow."',
        'page "Air scatters blue the most" body="Tiny gas molecules bounce short blue waves around far more than long red ones."',
        'page "So blue comes from everywhere" points="Scattered blue fills the whole sky|Sunsets look red: the light crosses more air, and the blue is scattered away"',
        'choose "Which color does air scatter most?" Red|Blue|Green answer=Blue why="Shorter waves scatter more."',
        "end")


def lesson_done(score, of) -> str:
    if of:
        return f"You got {score} of {of}. Want another?\n" + fence(MENU)
    return "That's the lesson. Want another?\n" + fence(MENU)


KEYWORDS = [
    (("workout", "exercise", "train", "gym"), workout),
    (("dinner", "cook", "eat", "food", "recipe", "hungry"), dinner),
    (("focus", "timer", "pomodoro"), focus),
    (("week", "steps", "stats", "chart"), week),
    (("lesson", "learn", "teach", "sky"), lesson),
]

MENU_ROUTES = {"Workout": workout, "Plan dinner": dinner, "Focus timer": focus, "My week": week, "Quick lesson": lesson}


def reply_to(row: dict) -> str | None:
    """The reply to one message row (a typed message or a tap event)."""
    if row.get("kind") == "event":
        meta = row.get("meta") or {}
        cid, preset, v = meta.get("id"), meta.get("preset"), meta.get("value") or {}
        if cid == "menu" and v.get("choice") in MENU_ROUTES:
            return MENU_ROUTES[v["choice"]]()
        if cid == "gear":
            return circuit(v.get("picked") or [])
        if cid == "circuit" and v.get("done"):
            return circuit_done()
        if cid == "again":
            return circuit([]) if v.get("answer") == "Another round" else fence(MENU)
        if cid == "hunger" and v.get("value") is not None:
            return dinner_options(float(v["value"]))
        if cid == "dinner" and v.get("choice"):
            return dinner_card(v["choice"])
        if cid == "focus" and v.get("done"):
            return fence("say Time's up. Stretch, then pick the next thing.", MENU)
        if preset == "deck" and v.get("done"):
            return lesson_done(v.get("score"), v.get("of"))
        if preset == "card":
            return "Enjoy it! Ask me anything else."
        return None  # a tick or a quiz answer: the screen already shows it
    text = (row.get("body") or "").lower()
    if text.startswith("/"):
        return None
    for words, fn in KEYWORDS:
        if any(w in text for w in words):
            return fn()
    if any(w in text for w in ("thank", "thx", "cool", "nice")):
        return "Anytime."
    return greet()


# -- plumbing -----------------------------------------------------------------

def http(method: str, url: str, body=None, token: str | None = None, params: dict | None = None,
         prefer: str | None = None) -> tuple[int, object]:
    if params:
        url += "?" + urllib.parse.urlencode(params)
    headers = {"content-type": "application/json", "apikey": connector.PUBLISHABLE, "user-agent": "yui-demo"}
    if token:
        headers["authorization"] = f"Bearer {token}"
    if prefer:
        headers["prefer"] = prefer
    req = urllib.request.Request(url, method=method, headers=headers,
                                 data=json.dumps(body).encode() if body is not None else None)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, {"error": f"http_{e.code}"}



def review_code() -> str:
    try:
        return json.loads(REVIEW.read_text())["code"]
    except (FileNotFoundError, KeyError, ValueError):
        sys.exit(f"no review code: write {{\"code\": ...}} to {REVIEW} (mode 600)")


def setup() -> int:
    """Sign in to the demo account with the review code and pair its agent here."""
    s, r = http("POST", AUTH, {"grant_type": "review", "code": review_code()})
    if s != 200:
        log("review sign-in failed:", s, r)
        return 1
    token = r["access_token"]
    s, r = http("POST", AGENTS, {"action": "list"}, token)
    agent = next((a for a in (r or {}).get("agents", []) if a.get("remote_ref") == PROFILE), None)
    if agent:
        s, p = http("POST", AGENTS, {"action": "pair_code", "agent_id": agent["id"]}, token)
        code = (p or {}).get("code")
    else:
        s, p = http("POST", AGENTS, {"action": "create", "name": NAME, "remote_ref": PROFILE,
                                     "color": "lavender", "pair": True}, token)
        code = ((p or {}).get("pairing") or {}).get("code")
    if not code:
        log("no pairing code:", s, p)
        return 1
    # A stale token from a deleted account would be sent as "this machine": start clean.
    connector.save({})
    s, r = connector.pair(code, PROFILE, HOST)
    if s != 200:
        log("pair failed:", s, r)
        return 1
    log("paired:", r["agent"]["name"], "on", r["connector"]["name"])
    return 0


class Demo:
    def __init__(self):
        self.token = None
        self.exp = 0.0
        self.user = None
        self.agents: list[str] = []
        self.last_beat = 0.0

    def session(self) -> bool:
        s, r = connector.call({"action": "session"}, connector.load().get("token"))
        if s == 401 or (s == 200 and not any(a.get("remote_ref") == PROFILE for a in r.get("agents") or [])):
            log("connector not accepted (account deleted or agent removed), pairing again")
            if setup() != 0:
                return False
            s, r = connector.call({"action": "session"}, connector.load().get("token"))
        if s != 200:
            log("session failed:", s, r)
            return False
        self.token, self.user = r["access_token"], r["user_id"]
        self.exp = datetime.fromisoformat(r["expires_at"].replace("Z", "+00:00")).timestamp()
        self.agents = [a["id"] for a in r.get("agents") or [] if a.get("remote_ref") == PROFILE]
        self.last_beat = time.time()
        return True

    def mark(self, ids: list, column: str) -> None:
        params = {"id": f"in.({','.join(ids)})"}
        if column == "delivered_at":
            params["delivered_at"] = "is.null"
        http("PATCH", f"{REST}/yui_messages", {column: datetime.now(tz=timezone.utc).isoformat()},
             self.token, params, "return=minimal")

    def send(self, agent_id: str, body: str, turn: list) -> None:
        s, r = http("POST", f"{REST}/yui_messages", {
            "user_id": self.user, "agent_id": agent_id, "sender": "agent", "kind": "text",
            "body": body, "meta": {"turn": turn}}, self.token, prefer="return=representation")
        if s >= 300:
            log("send refused:", s, r)
            return
        mid = r[0]["id"]
        connector.call_push(connector.notify_body(mid, None, False), connector.load().get("token"))

    def tick(self) -> None:
        if time.time() > self.exp - 120 or not self.token:
            if not self.session():
                time.sleep(30)
                return
        if time.time() - self.last_beat > HEARTBEAT_SECONDS:
            s, r = connector.heartbeat()
            if s == 401:
                self.token = None
                return
            self.last_beat = time.time()
        for aid in self.agents:
            s, rows = http("GET", f"{REST}/yui_messages", token=self.token, params={
                "select": "id,body,kind,meta,created_at", "agent_id": f"eq.{aid}", "sender": "eq.user",
                "handled_at": "is.null", "order": "created_at.asc", "limit": "20"})
            if s == 401:
                self.token = None
                return
            if s != 200 or not rows:
                continue
            ids = [r["id"] for r in rows]
            self.mark(ids, "delivered_at")
            for row in rows:
                out = reply_to(row)
                log("in", row.get("kind"), (row.get("body") or "")[:60].replace("\n", " "), "->",
                    (out or "(no reply)")[:40].replace("\n", " "))
                if out:
                    self.send(aid, out, [row["id"]])
            self.mark(ids, "handled_at")

    def run(self) -> int:
        log("demo agent starting")
        try:
            while True:
                try:
                    self.tick()
                except Exception as e:  # keep serving through network blips
                    log("tick failed:", e)
                    time.sleep(10)
                time.sleep(POLL_SECONDS)
        except KeyboardInterrupt:
            connector.call({"action": "bye"}, connector.load().get("token"))
            return 0


def main() -> int:
    cmd = sys.argv[1] if len(sys.argv) > 1 else "run"
    if cmd == "setup":
        return setup()
    if cmd == "run":
        return Demo().run()
    if cmd == "reply":
        print(reply_to({"kind": "text", "body": " ".join(sys.argv[2:])}))
        return 0
    sys.exit(__doc__)


if __name__ == "__main__":
    sys.exit(main())
