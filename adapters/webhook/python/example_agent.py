# A ten-line agent for Yui: every turn gets a screen back. Start it, then: yui_webhook.py run --webhook http://127.0.0.1:8787
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
class Agent(BaseHTTPRequestHandler):
    def do_POST(self):
        turn = json.loads(self.rfile.read(int(self.headers["content-length"])))
        taps = [m["event"]["echo"] for m in turn["messages"] if (m["event"] or {}).get("echo")]  # taps on our screen
        reply = f"{taps[-1]} it is. Enjoy!" if taps else 'Hi! What sounds good?\n```yui\nchoose "Pick one" Coffee|Walk|Nap\n```'
        self.send_response(200); self.send_header("content-type", "application/json"); self.end_headers()
        self.wfile.write(json.dumps({"reply": reply}).encode())
HTTPServer(("127.0.0.1", int(__import__("os").environ.get("PORT", 8787))), Agent).serve_forever()
