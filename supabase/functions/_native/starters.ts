// Copied from runtime/src/starters.ts by runtime/scripts/build.mjs. Do not edit here.
// The crew every person starts with, offered again in Add agent (YUI-145,
// Chris's feedback APsS404f7C): each starter by name, one tap each, and a tap
// only ever adds. yui-agents lists the offer and runs `crew_add`.
import { MAX_NATIVE_AGENTS } from "./agents.ts";
import { crew, describe, type Described, starters } from "./profiles.ts";
import type { Profile } from "./types.ts";

/**
 * One starter as Add agent shows it: its name, role and what it does (YUI-165).
 * `agentId` is set while it is in the person's list.
 */
export interface CrewOffer extends Described {
  base: string;
  name: string;
  role: string;
  color: string;
  agentId: string | null;
}

/** The person's native profiles, as yui_native_profiles holds them. */
export interface NativeRow {
  agent_id: string;
  base: string | null;
}

/** Every starter, Yui first, with the agent it already is (if any). */
export function crewOffer(rows: NativeRow[]): CrewOffer[] {
  return starters().map((p) => ({
    base: p.base,
    name: p.name,
    role: p.role,
    color: p.color,
    ...describe(p),
    agentId: rows.find((r) => r.base === p.base)?.agent_id ?? null,
  }));
}

/** A native agent's profile as the list reads it: its base and what it says it does. */
export interface DescribedRow extends NativeRow {
  tagline?: string | null;
  about?: string | null;
  can?: string[] | null;
}

/**
 * What each native agent in the list does, by agent id (YUI-165): its own
 * profile's words, else (a crew agent made before profiles carried them) its
 * starter's. A custom agent that never said stays empty, never a starter's words.
 */
export function describeAgents(rows: DescribedRow[]): Record<string, Described> {
  const out: Record<string, Described> = {};
  for (const r of rows) {
    const own = r.tagline || r.about || r.can?.length;
    const from = own ? { tagline: r.tagline ?? undefined, about: r.about ?? undefined, can: r.can ?? undefined }
      : r.base && r.base !== "custom" ? crew()[r.base] : null;
    out[r.agent_id] = describe(from);
  }
  return out;
}

/** The starter profile for a base name, or null when it isn't one. */
export function starter(base: unknown): Profile | null {
  return typeof base === "string" ? starters().find((p) => p.base === base) ?? null : null;
}

/** An agent in the person's list: its kind and place. */
export interface ListedAgent {
  kind: string;
  sort: number;
}

/**
 * Where a re-added starter goes: after the other native agents and above every
 * paired one, so the crew stays together at the top. Nothing moves to make room.
 */
export function readdSort(agents: ListedAgent[]): number {
  const hosted = agents.filter((a) => a.kind === "hosted").map((a) => a.sort);
  const paired = agents.filter((a) => a.kind !== "hosted").map((a) => a.sort);
  const after = hosted.length ? Math.max(...hosted) + 1 : null;
  const above = paired.length ? Math.min(...paired) - 1 : null;
  if (after == null) return above ?? 0;
  return above == null ? after : Math.min(after, above);
}

/** Why a starter can't be added now, or null when it can. */
export function crewRefusal(offer: CrewOffer[] | null, base: string, hostedCount: number): string | null {
  if (!offer) return "native_off";
  if (!offer.some((o) => o.base === base)) return "invalid_base";
  if (hostedCount >= MAX_NATIVE_AGENTS) return "too_many_agents";
  return null;
}
