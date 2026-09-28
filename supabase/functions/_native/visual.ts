// Copied from runtime/src/visual.ts by runtime/scripts/build.mjs. Do not edit here.
// Every agent's own quiet visual (YUI-180, yuigui spec/VISUAL.md section 6,
// Defaults): the look each crew profile ships with, what it hears and how
// strong it draws, so the stage has one from the first open. The agent's own
// `visual` line still wins, and `visual off` sticks until it sends another.
import type { Profile } from "./types.ts";

export const VISUAL_LOOKS = ["orb", "aurora", "waves", "grain", "bloom"] as const;
export const VISUAL_REACT = ["voice", "music", "mic", "off"] as const;
export const VISUAL_PACES = ["slow", "even"] as const;

/**
 * How strong a default draws, as the picture's alpha. A default is never full:
 * `dim` is the strength a visual has behind words (VISUAL.md BUDGET.behindDim),
 * `faint` lower still. Behind words a default sinks again by the same 0.7.
 */
export const VISUAL_STRENGTH = { dim: 0.7, faint: 0.45 } as const;
export type Strength = keyof typeof VISUAL_STRENGTH;

/** A profile's visual default (profile.json `visual`). `hears` is react=. */
export interface VisualDefault {
  look: (typeof VISUAL_LOOKS)[number];
  hears: (typeof VISUAL_REACT)[number];
  strength: Strength;
  pace: (typeof VISUAL_PACES)[number]; // a default never runs quicker than even
  tone?: string; // "accent" (the agent's color, the default), a theme set or #RRGGBB
}

/**
 * What an agent with no pick of its own gets: a connected Hermes agent, a
 * custom one, a crew agent made before defaults. The orb, soft and slow.
 */
export const FALLBACK_VISUAL: VisualDefault = { look: "orb", hears: "voice", strength: "faint", pace: "slow" };

/** profile.json's `visual` -> a VisualDefault, filling the quiet choices in. Null when absent. */
export function parseVisual(v: unknown): VisualDefault | null {
  if (v == null) return null;
  const o = (typeof v === "object" ? v : {}) as Record<string, unknown>;
  return {
    look: (o.look ?? "orb") as VisualDefault["look"],
    hears: (o.hears ?? "voice") as VisualDefault["hears"],
    strength: (o.strength ?? "dim") as Strength,
    pace: (o.pace ?? "slow") as VisualDefault["pace"],
    ...(o.tone != null ? { tone: String(o.tone) } : {}),
  };
}

/** What is wrong with a visual default, in plain words; empty when it is fine. */
export function checkVisual(v: VisualDefault): string[] {
  const out: string[] = [];
  if (!(VISUAL_LOOKS as readonly string[]).includes(v.look)) out.push(`visual look must be one of ${VISUAL_LOOKS.join(", ")}`);
  if (!(VISUAL_REACT as readonly string[]).includes(v.hears)) out.push(`visual hears must be one of ${VISUAL_REACT.join(", ")}`);
  if (!(v.strength in VISUAL_STRENGTH)) out.push(`visual strength must be ${Object.keys(VISUAL_STRENGTH).join(" or ")}: a default is never full`);
  if (!(VISUAL_PACES as readonly string[]).includes(v.pace)) out.push(`visual pace must be ${VISUAL_PACES.join(" or ")}: a default never runs quick`);
  if (v.tone != null && !/^(accent|[a-z]+|#[0-9a-fA-F]{6})$/.test(v.tone)) out.push("visual tone must be accent, a theme set or #RRGGBB");
  return out;
}

/** An agent's default: its own profile's, else its starter's by base, else the fallback. */
export function visualDefault(p: Pick<Profile, "visual"> | null | undefined, starter?: Pick<Profile, "visual"> | null): VisualDefault {
  return p?.visual ?? starter?.visual ?? FALLBACK_VISUAL;
}

/** One `visual` line's props: { look?, tone?, react? } or { off: true }. Null when the line is not one. */
export function visualLine(line: string): Record<string, string | boolean> | null {
  const t = line.trim().split(/\s+/);
  if (t[0] !== "visual") return null;
  if (t[1] === "off" && t.length === 2) return { off: true };
  const props: Record<string, string> = {};
  for (const w of t.slice(1)) {
    const kv = w.match(/^(tone|react)=(\S+)$/);
    if (kv) props[kv[1]] = kv[2];
    else if ((VISUAL_LOOKS as readonly string[]).includes(w) && !props.look) props.look = w;
    else return null; // VISUAL.md section 1: anything else is an error, never half a picture
  }
  if (props.react && !(VISUAL_REACT as readonly string[]).includes(props.react)) return null;
  return props;
}

/** The newest `visual` line in a run of agent bodies (oldest first), from their ```yui fences. Null when none. */
export function lastVisual(bodies: string[]): Record<string, string | boolean> | null {
  let last: Record<string, string | boolean> | null = null;
  for (const b of bodies) {
    for (const fence of b.matchAll(/```yui\n([\s\S]*?)```/g)) {
      for (const l of fence[1].split("\n")) last = visualLine(l) ?? last;
    }
  }
  return last;
}

/** What the stage draws. `from` says why: the agent's own line, its default, or nothing. */
export type StageVisual =
  | { from: "agent"; look: string; tone: string; react: string; strength: 1 }
  | { from: "default"; look: string; tone: string; react: string; strength: number; pace: string }
  | { from: "off" | "person"; off: true };

/**
 * The one rule every stage follows:
 *   1. the person switched the agent's visual off (Settings): nothing;
 *   2. the agent's newest `visual` line: `visual off` is nothing and sticks,
 *      any other is that visual at full strength, as the agent asked;
 *   3. else the agent's default, quiet.
 */
export function stageVisual(def: VisualDefault, own: Record<string, string | boolean> | null, personOff = false): StageVisual {
  if (personOff) return { from: "person", off: true };
  if (own?.off) return { from: "off", off: true };
  if (own) {
    return { from: "agent", look: String(own.look ?? "orb"), tone: String(own.tone ?? "accent"), react: String(own.react ?? "voice"), strength: 1 };
  }
  return { from: "default", look: def.look, tone: def.tone ?? "accent", react: def.hears, strength: VISUAL_STRENGTH[def.strength], pace: def.pace };
}

/** A default as the list sends it to the app, and as a `visual` line would say it (VISUAL.md section 1). */
export function visualView(def: VisualDefault) {
  const line = ["visual", def.look, def.tone && def.tone !== "accent" ? `tone=${def.tone}` : null,
                def.hears !== "voice" ? `react=${def.hears}` : null].filter(Boolean).join(" ");
  return { look: def.look, hears: def.hears, strength: def.strength, pace: def.pace, tone: def.tone ?? "accent", line };
}
