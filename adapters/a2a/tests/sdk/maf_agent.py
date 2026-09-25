"""A Microsoft Agent Framework agent served over A2A, for INT-16 (AutoGen's
successor in Yui).

Agent Framework's A2A hosting is `A2AExecutor` (agent-framework-a2a), an
executor for the official A2A SDK (1.x, so A2A 1.0, JSON-RPC, streaming). The
model is local (Ollama qwen2.5:7b through agent-framework-ollama), so no key
is needed. Set MAF_MODEL to another Ollama model to swap it.

    uv run --with 'agent-framework-a2a>=1.0.0b0' --with 'agent-framework-ollama>=1.0.0b0' \
        --with 'a2a-sdk[http-server]' --with uvicorn maf_agent.py PORT

(Both packages are betas. Allow them by name, not with --prerelease=allow,
which also pulls httpx 1.0.dev, and the A2A SDK breaks on it.)

What it shows: an Agent Framework agent can use Yui's channel guide. Left
alone, A2AExecutor runs the agent on `context.get_user_input()`, every text
part joined with newlines, so the guide would be read as part of the person's
words; data parts and part metadata are dropped. It also makes a fresh
AgentSession for each request (session_id = contextId, but empty), so the
agent forgets the thread. This executor keeps A2AExecutor's output side and
changes the input side: the part marked {"yui": "channel_guide"} goes into the
run's `instructions` option, which Agent Framework appends to the agent's own
instructions (its system prompt); only the person's words become the user
message; one session per contextId (the Yui agent) keeps the thread.
"""
import os
import sys
from asyncio import CancelledError

os.environ.setdefault("OTEL_SDK_DISABLED", "true")

import uvicorn
from a2a.helpers import new_task_from_user_message
from a2a.server.agent_execution import RequestContext
from a2a.server.events import EventQueue
from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.routes import create_agent_card_routes, create_jsonrpc_routes
from a2a.server.tasks import InMemoryTaskStore, TaskUpdater
from a2a.types import AgentCapabilities, AgentCard, AgentInterface, AgentSkill, Part, TaskState
from agent_framework import Agent, AgentSession
from agent_framework.a2a import A2AExecutor
from agent_framework_ollama import OllamaChatClient
from google.protobuf.json_format import MessageToDict
from starlette.applications import Starlette

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8792
URL = f"http://127.0.0.1:{PORT}"

agent = Agent(
    name="maf_helper",
    description="A small helper built with Microsoft Agent Framework.",
    instructions="You are a friendly helper. Keep answers short.",
    client=OllamaChatClient(model=os.environ.get("MAF_MODEL", "qwen2.5:7b"),
                            host=os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434")),
    default_options={"num_ctx": 8192},  # the guide plus a few turns; Ollama's default is smaller
)


def is_guide(part: Part) -> bool:
    return part.HasField("metadata") and MessageToDict(part.metadata).get("yui") == "channel_guide"


class YuiMAFExecutor(A2AExecutor):
    """A2AExecutor, with the guide in the instructions and one session per thread."""

    def __init__(self, agent: Agent):
        super().__init__(agent, stream=True)
        self.sessions: dict[str, AgentSession] = {}
        self.guides: dict[str, str] = {}

    async def execute(self, context: RequestContext, event_queue: EventQueue) -> None:
        msg = context.message
        guide = next((p.text for p in msg.parts if is_guide(p)), None)
        if guide:  # the guide rides on each new task's first message; a reply to a question has none
            self.guides[context.context_id] = guide
        # The person's words. The tap's data part leaves: its text line says the same.
        words = "\n".join(p.text for p in msg.parts if p.HasField("text") and not is_guide(p))

        task = context.current_task
        if not task:
            task = new_task_from_user_message(msg)
            await event_queue.enqueue_event(task)
        updater = TaskUpdater(event_queue, task.id, context.context_id)
        await updater.submit()
        try:
            await updater.start_work()
            session = self.sessions.setdefault(context.context_id, self._agent.create_session(session_id=context.context_id))
            self._run_kwargs = {"options": {"instructions": self.guides.get(context.context_id, "")}}
            await self._run_stream(words, session, updater)
            await updater.complete()
        except CancelledError:
            await updater.update_status(state=TaskState.TASK_STATE_CANCELED)
        except Exception as e:
            await updater.update_status(state=TaskState.TASK_STATE_FAILED,
                                        message=updater.new_agent_message([Part(text=str(e))]))


card = AgentCard(
    name="maf_helper", description="A small helper built with Microsoft Agent Framework.", version="1.0.0",
    default_input_modes=["text/plain"], default_output_modes=["text/plain"],
    capabilities=AgentCapabilities(streaming=True),
    supported_interfaces=[AgentInterface(protocol_binding="JSONRPC", url=URL, protocol_version="1.0")],
    skills=[AgentSkill(id="help", name="Help", description="Short answers to everyday asks.", tags=["helper"])],
)
handler = DefaultRequestHandler(agent_executor=YuiMAFExecutor(agent), task_store=InMemoryTaskStore(), agent_card=card)
app = Starlette(routes=[*create_agent_card_routes(card), *create_jsonrpc_routes(handler, "/")])

if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=PORT, log_level="warning")
