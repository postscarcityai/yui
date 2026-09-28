// Copied from runtime/src/types.ts by runtime/scripts/build.mjs. Do not edit here.
// Native Yui (NATIVE-1, yuigui spec/NATIVE.md): the shapes every part of the
// runtime shares. Runtime-neutral: no Node or Deno APIs anywhere in src/.

/** A profile as written in runtime/profiles/<name>/, or as a person's copy of one. */
export interface Profile {
  base: string; // the shelf profile it came from ("gouda"), or "custom"
  name: string;
  handle: string;
  role: string;
  tagline?: string; // one line under its name: what it helps with, under 8 words (YUI-165)
  about?: string; // what it does, two short sentences, for About and Add agent
  can?: string[]; // three things to ask it, each sent as the person's message when tapped
  version: number;
  color: "lavender" | "mint" | "butter" | "brand";
  favorites: string[]; // Yui Lines it reaches for first
  model: string; // a model id, or "default"
  soul: string; // who the agent is, how it talks, what it never does
  first: string; // its first answer: text plus a ```yui fence
  shelf?: boolean; // offered on the shelf
  maker?: boolean; // can make, change and remove other agents (Yui)
  careful?: boolean; // health: asks first, never diagnoses
  sees?: boolean; // reads photos first-hand (every agent can; this one leans on it)
  blank?: boolean; // runs the setup flow on its first turns
}

/** One of this person's native agents. */
export interface NativeAgent {
  id: string;
  userId: string;
  profile: Profile;
}

/** A row of yui_messages, as the runtime reads it. */
export interface Row {
  id: string;
  sender: "user" | "agent" | string;
  kind: string; // text, event, control
  body: string;
  meta?: any;
  created_at: string;
}

/** Something an agent remembers. agentId null: the shared "about you" card. */
export interface MemoryItem {
  id: string;
  userId?: string;
  agentId: string | null;
  kind: "note" | "about";
  key?: string; // about only: "name", "allergies", ...
  body: string;
  updatedAt: string;
}

/** A check-in an agent set (yui_native_schedules). `rule` is schedule.ts's Rule. */
export interface ScheduleItem {
  id: string;
  userId: string;
  agentId: string;
  note: string;
  rule: { every: string; at: string } | { once: string };
  tz: string;
  nextAt: string | null;
  paused?: boolean;
  firedAt?: string | null;
}

/** A person's own model key (yui_native_keys), when they added one. */
export interface OwnKey {
  provider: "openrouter" | "trustedrouter" | "groq" | "custom";
  baseUrl: string;
  model: string | null;
  key: string;
}

/** One web lookup taken from the person's allowance (yui_limits native_searches_*). */
export interface SearchTake {
  ok: boolean;
  used: number; // this month, this one included when ok
  limit: number; // free a month on Yui's key
  perTurn: number; // lookups one turn may make
  why?: "month" | "day"; // which cap said no
}

/** Which model serves which kind of turn (yui_native_models). */
export interface Routes {
  text: string;
  vision: string;
}

export const DEFAULT_ROUTES: Routes = { text: "z-ai/glm-5.2", vision: "z-ai/glm-5v-turbo" };

/** Every Yui Lines preset the app draws (Packages/YuiLines Presets.swift). Favorites come from here. */
export const PRESETS = new Set([
  "timer", "ask", "choose", "pick", "slide", "form",
  "list", "table", "card", "image", "camera", "mic",
  "gallery", "video", "compare", "storyboard",
  "chart", "stat", "math", "step", "calc",
  "deck", "page", "plan", "project", "narrate",
  "timeline", "done", "now", "next",
  "sketch", "row", "after",
  "shapes", "shape",
  "game",
  "loop", "drums", "keys", "chords", "tuner", "metronome",
]);

export const COLORS = ["lavender", "mint", "butter", "brand"] as const;
