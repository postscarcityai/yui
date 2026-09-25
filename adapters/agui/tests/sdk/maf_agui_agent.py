"""A Microsoft Agent Framework agent served over AG-UI, for INT-21.

Agent Framework's own AG-UI hosting, unchanged: add_agent_framework_fastapi_endpoint
(agent-framework-ag-ui) on FastAPI. Nothing in it knows about Yui: the agent's
instructions never mention it. Yui's bridge brings everything else in the
RunAgentInput: the thread's messages, the yui_show tool (a declaration-only
client tool, so the run ends when the model calls it), and the channel guide.
The model is local (Ollama qwen2.5:7b through agent-framework-ollama), no key.
Set MAF_MODEL to another Ollama model to swap it.

    uv run --python 3.12 --with 'agent-framework-ag-ui>=1.4.0' --with 'agent-framework-ollama>=1.0.0b0' \
        --with uvicorn maf_agui_agent.py PORT

(agent-framework-ollama is a beta. Allow it by name, not with --prerelease=allow,
which also pulls httpx 1.0.dev.)
"""
import os
import sys

os.environ.setdefault("OTEL_SDK_DISABLED", "true")

import uvicorn
from agent_framework import Agent
from agent_framework_ag_ui import add_agent_framework_fastapi_endpoint
from agent_framework_ollama import OllamaChatClient
from fastapi import FastAPI

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8793

agent = Agent(
    name="maf_helper",
    description="A small helper built with Microsoft Agent Framework.",
    instructions="You are a friendly helper. Keep answers short.",
    client=OllamaChatClient(model=os.environ.get("MAF_MODEL", "qwen2.5:7b"),
                            host=os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434")),
    default_options={"num_ctx": 8192},  # the guide plus a few turns; Ollama's default is smaller
)

app = FastAPI()
add_agent_framework_fastapi_endpoint(app, agent, "/")

if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=PORT, log_level="warning")
