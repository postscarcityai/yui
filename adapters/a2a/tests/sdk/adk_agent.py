"""A Google ADK agent served over A2A, for INT-9 (Gemini agents in Yui).

ADK is the kit Gemini Enterprise agents are built with; `to_a2a` serves any
ADK agent over A2A. Here the model is local (Ollama qwen2.5:7b through
LiteLLM), so no Google key is needed. Swap MODEL for "gemini-2.5-flash" and set
GEMINI_API_KEY to run the same agent on Gemini.

    uv run --with google-adk --with litellm --with 'a2a-sdk[http-server]' --with uvicorn adk_agent.py PORT

What it shows: an ADK agent can use Yui's channel guide. The bridge sends the
guide as a text part with metadata {"yui": "channel_guide"}; ADK keeps part
metadata, so before each model call the newest guide moves into the system
instruction and every copy leaves the conversation. The tap's JSON data part
leaves too (its text line says the same). History is kept short so the guide
and the turn fit a 4096-token local model.
"""
import os
import sys

import uvicorn
from google.adk.agents import LlmAgent
from google.adk.a2a.utils.agent_to_a2a import to_a2a
from google.adk.models.lite_llm import LiteLlm

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
MODEL = os.environ.get("ADK_MODEL", "ollama_chat/qwen2.5:7b")
KEEP = 4  # newest conversation turns sent to the model


def is_guide(part) -> bool:
    return (getattr(part, "part_metadata", None) or {}).get("yui") == "channel_guide"


def use_yui_guide(callback_context, llm_request):
    guide = None
    contents = []
    for c in llm_request.contents:
        parts = []
        for p in c.parts or []:
            if is_guide(p):
                guide = p.text
            elif p.text:
                parts.append(p)
            # else: the tap's data part (inline text/plain) or a file: the text line carries it
        if parts:
            c.parts = parts
            contents.append(c)
    llm_request.contents = contents[-KEEP:]
    if guide:
        llm_request.append_instructions([guide])
    return None


root_agent = LlmAgent(
    name="adk_helper",
    model=LiteLlm(model=MODEL) if "/" in MODEL else MODEL,
    description="A small helper built with Google's Agent Development Kit.",
    instruction="You are a friendly helper. Keep answers short.",
    before_model_callback=use_yui_guide,
)

app = to_a2a(root_agent, host="127.0.0.1", port=PORT)

if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=PORT, log_level="warning")
