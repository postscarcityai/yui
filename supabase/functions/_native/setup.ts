// Copied from runtime/src/setup.ts by runtime/scripts/build.mjs. Do not edit here.
// Start blank (YUI-138): a new, empty agent opens on a setup flow (name, how it talks, look, favorite
// screens, model). The answers arrive as one `plan@setup` event; this turns them into the agent's
// profile with no model turn, then it greets in the voice it was just given. Typed words still go to
// the model, which can set the agent up from the blank soul's own rules (agents.ts `self`).
import { MODELS } from "./models.ts";
import { readEvent } from "./workouts.ts";
import type { NativeAgent, Profile, Row } from "./types.ts";

export const SETUP_ID = "setup";
const NOT_SURE = new Set(["not sure", "skip", ""]);

/** Is this agent still waiting to be set up? */
export const isBlank = (a: NativeAgent) => a.profile.blank === true;

/** The setup flow's answers in this turn (the plan event for `plan@setup`), and the rows left for the model. */
export function setupAsks(rows: Row[]): { asks: { row: Row; answers: Record<string, unknown> }[]; rest: Row[] } {
  const asks: { row: Row; answers: Record<string, unknown> }[] = [];
  const rest: Row[] = [];
  for (const r of rows) {
    const e = /^\[yui\]\s/.test(r.body ?? "") || r.kind === "event" ? readEvent(r) : null;
    const plan = e?.value.plan && typeof e.value.plan === "object" ? (e.value.plan as Record<string, unknown>) : null;
    if (e && e.preset === "plan" && e.id === SETUP_ID && plan) asks.push({ row: r, answers: plan });
    else rest.push(r);
  }
  return { asks, rest };
}

const one = (v: unknown): string => String(Array.isArray(v) ? v[0] ?? "" : v ?? "").trim();
const said = (v: unknown): string | null => (NOT_SURE.has(one(v).toLowerCase()) ? null : one(v));

/** How each voice sounds: the soul's line and the greeting. */
const VOICES: Record<string, { soul: string; hello: (n: string) => string }> = {
  warm: { soul: "You talk warm and kind, in short plain sentences. You are glad they are here.", hello: (n) => `Hi, I'm ${n}. Glad you made me.` },
  short: { soul: "You talk in as few words as you can. One line, then a screen. No filler.", hello: (n) => `${n}. Ready.` },
  playful: { soul: "You talk playful and quick. A little joke is fine. You never talk down to them.", hello: (n) => `Hey! ${n} here, fresh out of the box.` },
  calm: { soul: "You talk calm and slow. You never rush them and you never pile things on.", hello: (n) => `Hello. I'm ${n}. No rush.` },
  blunt: { soul: "You talk straight. You say the answer first and the reason second. No cushioning.", hello: (n) => `I'm ${n}. Tell me what you need.` },
};

/** Screen words the person picks, as the Yui Lines they mean. */
const SCREENS: Record<string, string> = {
  buttons: "choose", lists: "list", cards: "card", timers: "timer", forms: "form", charts: "chart", decks: "deck",
};

const COLORS: Record<string, "lavender" | "mint" | "butter"> = { lavender: "lavender", mint: "mint", butter: "butter" };

/** The model names the flow offers, as model ids. Yui's pick is "default". */
const MODEL_IDS: Record<string, string> = Object.fromEntries([
  ["yui's pick", "default"],
  ...MODELS.filter((m) => m.id !== "default").map((m) => [m.label.toLowerCase(), m.id]),
]);

export interface Setup { profile: Profile; hello: string }

/** The profile the answers make, and the line the agent greets with. Skipped or "Not sure" answers take a plain default. */
export function applySetup(p: Profile, answers: Record<string, unknown>): Setup {
  const name = (said(answers.name) ?? "Kit").slice(0, 40);
  const voiceWords = said(answers.voice);
  const voice = voiceWords ? VOICES[voiceWords.toLowerCase()] : undefined;
  const voiceSoul = voice?.soul ?? (voiceWords ? `You talk like this: ${voiceWords.slice(0, 200)}.` : VOICES.warm.soul);
  const color = COLORS[(said(answers.look) ?? "").toLowerCase()] ?? p.color;
  const picked = (Array.isArray(answers.screens) ? answers.screens : [answers.screens]).map((s) => String(s ?? "").trim().toLowerCase());
  const favorites = [...new Set(picked.map((s) => SCREENS[s]).filter(Boolean))];
  if (!favorites.length) favorites.push("choose", "list", "card");
  const model = MODEL_IDS[(said(answers.model) ?? "").toLowerCase()] ?? "default";
  const soul = [
    `You are ${name}, an agent in the Yui app that this person made from a blank start.`,
    voiceSoul,
    `You answer with screens, not paragraphs. You reach for ${favorites.map((f) => `\`${f}\``).join(", ")} first and use any other screen when it fits better.`,
    `You do not know yet what you are for. Ask, then stay on that job and remember it.`,
    `You never ask for a password, a card number or a key.`,
  ].join("\n");
  const profile: Profile = {
    ...p, name, role: "Made by you", color, favorites, model, soul, blank: false, base: "custom",
    tagline: "Yours, made in a minute", about: `Made by you. Tell ${name} what it is for and it gets good at it.`,
    can: ["Help me cook", "Help me with money", "Teach me a language"],
  };
  const hello = `${(voice ?? VOICES.warm).hello(name)}\n\`\`\`yui\nchoose "What should I help with?" Cooking|Money|"A language"|Writing|"A hobby" +other\n\`\`\``;
  return { profile, hello };
}
