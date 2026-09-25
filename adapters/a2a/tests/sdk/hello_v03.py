"""An a2a-sdk 0.3 agent (A2A 0.3, JSON-RPC), the same shape as hello_v1.py. No model.
Run: uv run --with 'a2a-sdk[http-server]>=0.3,<0.4' --with uvicorn hello_v03.py PORT"""
import sys
import uvicorn
from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.apps import A2AStarletteApplication
from a2a.server.events import EventQueue
from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.tasks import InMemoryTaskStore, TaskUpdater
from a2a.types import AgentCapabilities, AgentCard, AgentSkill, Part, TaskState, TextPart
from a2a.utils import new_agent_text_message, new_task

PORT = int(sys.argv[1])


class Hello(AgentExecutor):
    async def execute(self, context: RequestContext, q: EventQueue) -> None:
        task = context.current_task or new_task(context.message)
        if not context.current_task:
            await q.enqueue_event(task)
        up = TaskUpdater(q, task.id, task.context_id)
        await up.update_status(TaskState.working, new_agent_text_message("Processing...", task.context_id, task.id))
        words = [p.root.text for p in context.message.parts if isinstance(p.root, TextPart)][-1:] or [""]
        await up.add_artifact([Part(root=TextPart(text=f"Hello from 0.3! ({words[0]})"))])
        await up.complete()

    async def cancel(self, context, q):
        raise NotImplementedError


card = AgentCard(
    name="Hello 0.3", description="An a2a-sdk 0.3 agent", url=f"http://127.0.0.1:{PORT}/", version="0.0.1",
    default_input_modes=["text/plain"], default_output_modes=["text/plain"],
    capabilities=AgentCapabilities(streaming=True),
    skills=[AgentSkill(id="hi", name="Hi", description="Says hello", tags=["a2a"])],
)
app = A2AStarletteApplication(agent_card=card, http_handler=DefaultRequestHandler(agent_executor=Hello(), task_store=InMemoryTaskStore()))
uvicorn.run(app.build(), host="127.0.0.1", port=PORT, log_level="warning")
