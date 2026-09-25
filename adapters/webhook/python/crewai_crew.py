"""A CrewAI crew in Yui through the webhook bridge (path E, INT-15).

For crews you run as a script rather than serve over A2A. Two ways, same crew:

    uv run --with 'crewai[litellm]' crewai_crew.py            # a webhook: each turn kicks off the crew
    python3 yui_webhook.py run --webhook http://127.0.0.1:8788

    uv run --with 'crewai[litellm]' crewai_crew.py send "Plan my Saturday"   # once, e.g. from cron

The first answers every turn in the thread: the bridge POSTs the turn, the
crew runs, its answer is the reply. The second runs the crew once and puts the
answer in the thread with `yui_webhook.py send` (the phone gets a push).

Yui's channel guide goes in the writer's backstory, which is CrewAI's system
prompt, so the crew can answer with screens (a ```yui fence). The webhook gets
it on every turn; `yui_webhook.py guide` prints it for the script. The model is
local Ollama qwen2.5:7b (no key); set CREWAI_MODEL to use another.
"""
import json
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

os.environ.setdefault("CREWAI_DISABLE_TELEMETRY", "true")
os.environ.setdefault("CREWAI_TRACING_ENABLED", "false")
from crewai import LLM, Agent, Crew, Task

BRIDGE = [sys.executable, str(Path(__file__).with_name("yui_webhook.py"))]
LLM_ = LLM(model=os.environ.get("CREWAI_MODEL", "ollama/qwen2.5:7b"))


def crew(guide: str) -> Crew:
    planner = Agent(role="Planner", goal="Work out what the person needs.",
                    backstory="You think before anyone writes.", llm=LLM_, max_iter=2)
    writer = Agent(role="Writer", goal="Answer the person in a few short lines.",
                   backstory="You write short, friendly answers.\n\n" + guide, llm=LLM_, max_iter=2)
    return Crew(agents=[planner, writer], tasks=[
        Task(description="The person wrote:\n{text}\n\nList what they need, in two or three bullets.",
             expected_output="Two or three bullets.", agent=planner),
        Task(description="Answer the person, who wrote:\n{text}\nUse Yui's screens when the answer is a choice.",
             expected_output="The reply to the person.", agent=writer),
    ])


class Webhook(BaseHTTPRequestHandler):
    def do_POST(self):
        turn = json.loads(self.rfile.read(int(self.headers["content-length"])))
        reply = crew(turn["guide"]["body"]).kickoff(inputs={"text": turn["text"]}).raw
        self.send_response(200); self.send_header("content-type", "application/json"); self.end_headers()
        self.wfile.write(json.dumps({"reply": reply}).encode())


if __name__ == "__main__":
    if sys.argv[1:2] == ["send"]:
        guide = subprocess.check_output(BRIDGE + ["guide"], text=True)
        answer = crew(guide).kickoff(inputs={"text": " ".join(sys.argv[2:])}).raw
        subprocess.run(BRIDGE + ["send", answer], check=True)
    else:
        HTTPServer(("127.0.0.1", int(os.environ.get("PORT", 8788))), Webhook).serve_forever()
