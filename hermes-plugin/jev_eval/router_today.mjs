// What today's hand-written patterns route a message to, per crew agent (YUI-215 point 2).
//   RUNTIME=<yui>/runtime node router_today.mjs items.json > today.json
// items: [{agent, text}]. Prints [{agent, text, today}], today = a tool name or "none".
// Runs the runtime's own functions (planAsks, mealAsks, musicAsks, studyAsks, workoutAsks), no copy of the regexes.
import { readFileSync } from "node:fs";
const R = process.env.RUNTIME || new URL("../../runtime", import.meta.url).pathname;
const { planAsks } = await import(`${R}/src/planner.ts`);
const { mealAsks } = await import(`${R}/src/mealplan.ts`);
const { musicAsks } = await import(`${R}/src/music.ts`);
const { studyAsks } = await import(`${R}/src/study.ts`);
const { workoutAsks } = await import(`${R}/src/workouts.ts`);

// The ask kind each agent's patterns produce, as the tool name Jev is asked about.
const TOOL = {
  penny: { plan: "plan_week", next: "whats_next", review: "evening_review", add: "add_todo", added: "add_todo" },
  basil: { plan: "plan_meals", add: "add_grocery", added: "add_grocery", share: "share_grocery" },
  gouda: { learn: "learn_song", log: "log_practice", practiced: "log_practice" },
  quill: { learn: "learn_topic", review: "review_cards", next: "whats_due", problem: "walk_problem" },
  arnold: { start: "start_workout", log: "log_workout", planwords: "build_plan" },
};
const FN = { penny: planAsks, basil: mealAsks, gouda: musicAsks, quill: studyAsks, arnold: workoutAsks };

const items = JSON.parse(readFileSync(process.argv[2], "utf8"));
const out = items.map((it) => {
  const row = { id: "r1", sender: "user", kind: "text", body: it.text, created_at: "2026-09-30T12:00:00Z" };
  const { asks } = FN[it.agent]([row]);
  const kind = asks[0]?.kind;
  return { agent: it.agent, text: it.text, today: (kind && TOOL[it.agent][kind]) || "none" };
});
console.log(JSON.stringify(out));
