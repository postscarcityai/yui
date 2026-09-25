"""A LangGraph agent served over A2A, for INT-14 (LangGraph agents in Yui).

No model: the nodes are plain functions, so the test needs no key and gives the
same answer every run. LangGraph's Agent Server (`langgraph dev` here, the same
server LangSmith deployments run) serves any graph with a `messages` key over
A2A at /a2a/{assistant_id}; its card is at
/.well-known/agent-card.json?assistant_id={assistant_id}.

    uv run --with 'langgraph-cli[inmem]' langgraph dev --config langgraph.json --port PORT --no-browser

What it shows: how a graph gets Yui's channel guide. LangGraph's A2A endpoint
turns data parts into keys of the graph's input, so for a LangGraph card the
bridge sends the guide as {"yui_channel_guide": {"version", "body"}} and taps
as {"yui_events": [...]}. Declare those keys in the state and the graph can
read them; the guide stays in the thread's state for later turns. A graph with
a model would put the guide body into its system prompt; this one only draws
a screen when the guide says `choose` is a thing it may use.
"""
from typing import Annotated, Any, TypedDict

from langgraph.graph import END, START, StateGraph
from langgraph.graph.message import add_messages


class State(TypedDict, total=False):
    messages: Annotated[list, add_messages]
    yui_channel_guide: dict[str, Any]  # {"version", "body"}, sent when a task starts
    yui_events: list[dict[str, Any]]  # taps on a screen: {"id", "preset", "value", "row", ...}


def text_of(message) -> str:
    c = message.content
    if isinstance(c, list):
        return "\n".join(b.get("text", "") for b in c if isinstance(b, dict))
    return str(c)


def route(state: State) -> str:
    said = text_of(state["messages"][-1]).strip()
    if said.startswith("[yui] ") or state.get("yui_events"):
        return "tapped"
    if any(w in said.lower() for w in ("pick", "choose", "buttons")):
        return "screen"
    return "hello"


def hello(state: State) -> State:
    return {"messages": [{"role": "assistant", "content": "Hi! I'm a small LangGraph helper. I can help you pick things."}]}


def screen(state: State) -> State:
    guide = (state.get("yui_channel_guide") or {}).get("body", "")
    if "choose" not in guide:  # no guide, no screen: plain text still reads fine
        return {"messages": [{"role": "assistant", "content": "Tea or Coffee?"}]}
    return {"messages": [{"role": "assistant",
                          "content": 'Pick one for this afternoon.\n```yui\nchoose "Tea or Coffee?" Tea|Coffee\n```'}]}


def tapped(state: State) -> State:
    taps = state.get("yui_events") or []
    value = (taps[-1].get("value") or {}) if taps else {}
    choice = value.get("choice") or text_of(state["messages"][-1]).rpartition("choice=")[2].strip() or "That"
    via = "the tap's data" if taps else "the tap's text"
    return {"messages": [{"role": "assistant", "content": f"{choice} it is. (read from {via})"}],
            "yui_events": []}  # used up: the next turn starts clean


builder = StateGraph(State)
builder.add_node("hello", hello)
builder.add_node("screen", screen)
builder.add_node("tapped", tapped)
builder.add_conditional_edges(START, route, ["hello", "screen", "tapped"])
for n in ("hello", "screen", "tapped"):
    builder.add_edge(n, END)
graph = builder.compile(name="Yui LangGraph helper")
