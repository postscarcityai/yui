// Writes YuiTests/Resources/visual-plan.json: visual.mjs's numbers for VisualPlanTests (YUI-124).
//   node scripts/visual-plan-fixture.mjs [path/to/yuigui] > YuiTests/Resources/visual-plan.json
import { pathToFileURL } from "node:url";
import { resolve } from "node:path";
const hub = resolve(process.argv[2] || "../yuigui", "site/lib/yl");
const { visualColors, scrimFor, envelope, visualPlan, follow, shown, levelOf, BUDGET } = await import(pathToFileURL(`${hub}/visual.mjs`));
const { SETS } = await import(pathToFileURL(`${hub}/look.mjs`));
const tones = [...Object.values(SETS).map(s => s.accent), "#FF6B3D", "#000000", "#FFFFFF", "#808080", "#4DA8FF"];
const colors = [];
for (const t of tones) for (const dark of [true, false]) {
  const c = visualColors(t, dark);
  colors.push({ tone: t, dark, ...c, scrim: scrimFor(c, BUDGET.behindDim) });
}
const envs = [];
for (const pace of ["slow", "even", "quick", undefined]) for (const pulse of ["soft", "beat", "tick", "still", undefined]) envs.push({ pace: pace ?? null, pulse: pulse ?? null, env: envelope({ pace, pulse }) });
const follows = [];
for (const env of [envelope({pulse:"soft"}), envelope({pulse:"beat"}), envelope({pulse:"tick", pace:"quick"})]) {
  let y = 0; const out = [], seen = [];
  for (const [x, dt] of [[0.8, 33], [0.8, 33], [0.2, 33], [0.0, 100], [1.5, 16], [0.5, 0]]) { y = follow(y, x, dt, env); out.push(y); seen.push(shown(y, env)); }
  follows.push({ env, out, shown: seen });
}
const plans = [];
const cases = [
  [{ look: "aurora" }, { theme: { preset: "mint", accent: "#2FB58C", motion: "calm" }, dark: true }],
  [{ look: "grain", tone: "sky", react: "music" }, { words: true, dark: false }],
  [{}, { reduced: true }], [{ look: "bloom" }, { lowPower: true }], [{ look: "waves" }, { thermal: "fair" }],
  [{ look: "orb", react: "off" }, { theme: { pace: "quick", pulse: "tick" } }], [{ look: "orb" }, { thermal: "critical" }],
  [{ look: "stars", react: "loud" }, { hidden: true }],
];
for (const [props, o] of cases) { const p = visualPlan(props, o); plans.push({ props, opts: o, plan: { look: p.look, react: p.react, tone: p.tone, env: p.env, speed: p.speed, dim: p.dim, scrim: p.scrim, fps: p.fps, scale: p.scale, still: p.still, why: p.why, label: p.label, colors: p.colors } }); }
const levels = [[[]], [[0.5, -0.5, 0.5, -0.5]], [[0.03, -0.03]], [[0.001]], [[1, 1]]].map(([s]) => ({ samples: s, level: levelOf(s) }));
console.log(JSON.stringify({ colors, envs, follows, plans, levels }, null, 1));
