// The APNs payload for one agent message (yui-push notify). No Deno or npm
// imports, so the native runtime's tests and the check-in end-to-end run
// (YUI-143) build exactly what yui-push sends.

export interface PushAgent { id: string; name: string }
export interface PushMessage { id: string; body: string; meta?: Record<string, unknown> | null; chat_id?: string | null }
export interface PushOptions { from?: string | null; handoff?: boolean }

// Text outside ```yui fences, squashed to one line.
export function preview(body: string): string {
  return body.replace(/```yui[\s\S]*?(```|$)/g, " ").replace(/\s+/g, " ").trim().slice(0, 160);
}

export function alertFor(agent: PushAgent, msg: PushMessage, o: PushOptions = {}): { title: string; body: string } {
  const who = o.from ?? agent.name;
  const text = preview(msg.body);
  // A check-in the agent set earlier (a native schedule firing): it opens the thread itself.
  if (msg.meta?.checkin === true && !o.from && !o.handoff) return { title: agent.name, body: text || `${agent.name} is checking in` };
  return { title: agent.name, body: o.handoff || o.from || !text ? `${who} has something for you in Yui` : text };
}

export function apnsPayload(agent: PushAgent, msg: PushMessage, o: PushOptions = {}) {
  return {
    aps: { alert: alertFor(agent, msg, o), sound: "default", "thread-id": agent.id, "mutable-content": 1 },
    agent_id: agent.id,
    message_id: msg.id,
    // The chat the reply is in (YUI-169), so the app opens that chat and not the newest. An old app ignores the key.
    ...(msg.chat_id ? { chat: msg.chat_id } : {}),
    url: `yui://agent/${agent.id}/thread`,
  };
}

/** A WidgetKit push (YUI-40 step 4): asks the phone's widget for a new timeline. Apple wants
 * `apns-push-type: widgets` and the topic `<bundle id>.push-type.widgets`, nothing else in aps. */
export function widgetPush(topic: string) {
  return {
    topic: `${topic}.push-type.widgets`,
    type: "widgets",
    payload: { aps: { "content-changed": true } },
  };
}
