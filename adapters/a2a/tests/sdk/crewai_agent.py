"""A CrewAI agent served over A2A, for INT-15 (CrewAI in Yui).

CrewAI's A2A server support is an `A2AServerConfig` on the agent (its Agent
Card comes from `agent.to_agent_card(url)`) and `crewai.a2a.utils.task.execute`,
which runs one A2A task as one CrewAI task. CrewAI ships no server process, so
the official A2A SDK's Starlette app serves it (A2A 0.3, JSON-RPC, streaming).
The model is local (Ollama qwen2.5:7b through LiteLLM), so no key is needed.
Set CREWAI_MODEL (and that provider's key) to run the same agent elsewhere.

    uv run --with 'crewai[a2a,litellm]' --with uvicorn crewai_agent.py PORT

What it shows: a CrewAI agent can use Yui's channel guide. CrewAI joins every
text part of the message into the task's description and drops part metadata,
so left alone the guide would be read as part of the person's words. Here,
before CrewAI sees the message, the part marked {"yui": "channel_guide"} moves
into the agent's backstory (CrewAI's system prompt) and leaves the message.
The tap's JSON data part leaves too (CrewAI would append it as "Structured
Data"; its text line says the same). Each A2A task is a fresh CrewAI task, so
the prompt holds only the guide and the turn, which fits a 4096-token model.
"""
import os
import sys

os.environ.setdefault("CREWAI_DISABLE_TELEMETRY", "true")
os.environ.setdefault("CREWAI_TRACING_ENABLED", "false")
os.environ.setdefault("OTEL_SDK_DISABLED", "true")

import uvicorn
from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.apps import A2AStarletteApplication
from a2a.server.events import EventQueue
from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.tasks import InMemoryTaskStore
from crewai import LLM, Agent
from crewai.a2a import A2AServerConfig
from crewai.a2a.utils.task import cancel, execute

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8791
URL = f"http://127.0.0.1:{PORT}"
MODEL = os.environ.get("CREWAI_MODEL", "ollama/qwen2.5:7b")
BACKSTORY = "You are a friendly helper. Keep answers short."


def helper(guide: str | None = None) -> Agent:
    return Agent(
        role="Helper",
        goal="Help the person with what they ask.",
        backstory=BACKSTORY + (f"\n\n{guide}" if guide else ""),
        llm=LLM(model=MODEL, base_url=os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434"))
        if MODEL.startswith("ollama/") else LLM(model=MODEL),
        allow_delegation=False,
        max_iter=2,
        a2a=A2AServerConfig(
            name="crewai_helper",
            description="A small helper built with CrewAI.",
            url=URL,
        ),
    )


def is_guide(part) -> bool:
    return (part.root.metadata or {}).get("yui") == "channel_guide"


class YuiCrewExecutor(AgentExecutor):
    async def execute(self, context: RequestContext, event_queue: EventQueue) -> None:
        guide = None
        msg = context.message
        if msg and msg.parts:
            keep = []
            for p in msg.parts:
                if is_guide(p):
                    guide = p.root.text
                elif p.root.kind == "text":
                    keep.append(p)
                # else: the tap's data part or a file: the text line carries it
            msg.parts = keep
        await execute(helper(guide), context, event_queue)

    async def cancel(self, context: RequestContext, event_queue: EventQueue) -> None:
        await cancel(context, event_queue)


app = A2AStarletteApplication(
    agent_card=helper().to_agent_card(URL),
    http_handler=DefaultRequestHandler(agent_executor=YuiCrewExecutor(), task_store=InMemoryTaskStore()),
).build()

if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=PORT, log_level="warning")
