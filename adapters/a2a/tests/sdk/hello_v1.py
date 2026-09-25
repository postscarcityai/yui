"""The a2a-sdk 1.x hello world (a2aproject/a2a-samples helloworld), trimmed.
A2A 1.0, JSON-RPC. No model. Run: uv run --with 'a2a-sdk[http-server]>=1.1,<2' --with uvicorn --with sse-starlette hello_v1.py PORT"""
import sys
import uvicorn
from a2a.helpers import get_message_text, new_task_from_user_message, new_text_message, new_text_part
from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.events import EventQueue
from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.routes import create_agent_card_routes, create_jsonrpc_routes
from a2a.server.tasks import InMemoryTaskStore, TaskUpdater
from a2a.types import AgentCapabilities, AgentCard, AgentInterface, AgentSkill, TaskState
from starlette.applications import Starlette

PORT = int(sys.argv[1])


class Hello(AgentExecutor):
    async def execute(self, context: RequestContext, q: EventQueue) -> None:
        task = context.current_task or new_task_from_user_message(context.message)
        if not context.current_task:
            await q.enqueue_event(task)
        up = TaskUpdater(event_queue=q, task_id=task.id, context_id=task.context_id)
        await up.update_status(state=TaskState.TASK_STATE_WORKING, message=new_text_message("Processing request..."))
        # The last text part is the person's words; the first may be Yui's channel guide.
        words = [p.text for p in context.message.parts if p.text][-1:] or [get_message_text(context.message)]
        await up.add_artifact(parts=[new_text_part(text=f"Hello, World! ({words[0]})", media_type="text/plain")])
        await up.update_status(state=TaskState.TASK_STATE_COMPLETED, message=new_text_message("Request is completed!"))

    async def cancel(self, context, q):
        raise NotImplementedError


card = AgentCard(
    name="Hello World Agent", description="Just a hello world agent", version="0.0.1",
    default_input_modes=["text/plain"], default_output_modes=["text/plain"],
    capabilities=AgentCapabilities(streaming=True),
    supported_interfaces=[AgentInterface(protocol_binding="JSONRPC", url=f"http://127.0.0.1:{PORT}", protocol_version="1.0")],
    skills=[AgentSkill(id="echo_bot", name="Echo Bot", description="Says hello", tags=["a2a"], examples=["hi"])],
)
handler = DefaultRequestHandler(agent_executor=Hello(), task_store=InMemoryTaskStore(), agent_card=card)
app = Starlette(routes=[*create_agent_card_routes(card), *create_jsonrpc_routes(handler, "/")])
uvicorn.run(app, host="127.0.0.1", port=PORT, log_level="warning")
