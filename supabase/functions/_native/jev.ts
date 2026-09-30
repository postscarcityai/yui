// Copied from runtime/src/jev.ts by runtime/scripts/build.mjs. Do not edit here.
// Jev as the crew's tool router, shadow only (YUI-215). Spec: yuigui docs/proposals/the-jev-layer.md (PROP-2).
//
// A turn no hand-written pattern caught (planAsks, mealAsks, ...) is about to go to the model. Here Jev is asked
// which of the agent's tools the words ask for, in parallel with the model call. The answer is only logged, next to
// what the patterns did (nothing: that is why we are here). Nothing is routed, nothing waits: 600 ms, no retry, no key
// means no call, any error means no line. The numbers are in yuigui docs/research/jev-results.md.
import type { NativeAgent } from "./types.ts";

export const JEV_URL = "https://openrouter.ai/api/alpha/decisions";
export const JEV_MODEL = "typesafe/jev-1.13";
export const JEV_TIMEOUT_MS = 600;
export const JEV_CUT = 0.8; // choice confidence at or above: a route (not acted on in shadow)
const MESSAGE_CAP = 400;

/** The tools each crew agent answers itself from words (the patterns in planner.ts, mealplan.ts, music.ts, study.ts, workouts.ts). Same table as hermes-plugin/jev_eval/tools.json. */
export const JEV_TOOLS: Record<string, Record<string, string>> = {
  penny: {
    plan_week: "The person wants their week planned, sorted, organized or laid out.",
    whats_next: "The person asks what is next, what is on their plate, or what to do now.",
    evening_review: "The person wants to review, wrap up or recap their day.",
    add_todo: "The person wants a task or reminder added to their to-do list.",
  },
  basil: {
    plan_meals: "The person wants a meal plan, a menu or the week's meals planned.",
    add_grocery: "The person wants something added to the grocery or shopping list.",
    share_grocery: "The person wants the grocery list sent, shared or copied.",
  },
  gouda: {
    learn_song: "The person wants to learn or be taught a song or its chords.",
    log_practice: "The person wants to log a practice session or says how long they practiced.",
  },
  quill: {
    learn_topic: "The person wants to be taught or to study a topic.",
    review_cards: "The person wants to be quizzed or to review their flashcards now.",
    whats_due: "The person asks what to review next or which cards are due.",
    walk_problem: "The person wants a problem worked through step by step.",
  },
  arnold: {
    start_workout: "The person wants to start today's workout or session now.",
    log_workout: "The person wants a workout or session logged.",
    build_plan: "The person wants a workout plan, routine, split or program built.",
  },
};
const NONE = "Chat, a question, thanks, or anything else that needs none of these tools.";

export interface JevOptions {
  key: string; // OpenRouter key from the function's environment, never stored or logged
  fetch?: typeof fetch;
}

export interface JevRoute {
  tool: string; // a tool name, or "none"
  confidence: number;
  ms: number;
  cost: number;
}

export function toolsOf(agent: NativeAgent): Record<string, string> | null {
  return JEV_TOOLS[String(agent.profile.handle ?? "").toLowerCase()] ?? null;
}

/** Jev's pick among the agent's tools for one message, or null (no tools, no key, slow, failed). Never throws. */
export async function jevRoute(jev: JevOptions | undefined, agent: NativeAgent, message: string): Promise<JevRoute | null> {
  const tools = toolsOf(agent);
  if (!jev?.key || !tools || !message.trim()) return null;
  const t = Date.now();
  try {
    const res = await (jev.fetch ?? fetch)(JEV_URL, {
      method: "POST",
      headers: { Authorization: `Bearer ${jev.key}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        model: JEV_MODEL,
        state: { message: message.slice(0, MESSAGE_CAP), agent: String(agent.profile.handle) },
        questions: { tool: { type: "choice", instructions: "Which tool, if any, is the person asking the agent to use?", criteria: { ...tools, none: NONE } } },
      }),
      signal: AbortSignal.timeout(JEV_TIMEOUT_MS),
    });
    if (!res.ok) return null;
    const d = await res.json();
    const a = d?.answers?.tool;
    if (!a?.choice) return null;
    return { tool: String(a.choice), confidence: Number(a.confidence ?? 0), ms: Date.now() - t, cost: Number(d?.usage?.cost ?? 0) };
  } catch {
    return null;
  }
}

/** The one log line for a shadow route. Never the words. */
export function jevLine(agent: NativeAgent, r: JevRoute): string {
  const acts = r.tool !== "none" && r.confidence >= JEV_CUT;
  return `${agent.profile.name}: jev shadow ${r.tool} ${r.confidence.toFixed(2)} ${acts ? "(would route)" : "(no route)"} ${r.ms} ms, patterns caught nothing`;
}
