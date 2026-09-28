// An agent's home (YUI-168, yuigui spec/HOME.md): its shortcuts (`menu shortcut`)
// and its starter screens (`>2`, `>3` ... with lasting @ids), written once as a
// row in its thread. The app draws the chips over the bar and the screens a swipe
// away; the agent keeps them current with patches after that.
import type { Profile } from "./types.ts";

/** Shortcuts a home carries: at least this many, and the app shows at most MAX. */
export const MIN_SHORTCUTS = 2;
export const MAX_SHORTCUTS = 4;

/** home.yui as written, less its `#` comment lines and blank lines. */
export function homeLines(text: string): string[] {
  return text.split("\n").map((l) => l.trim()).filter((l) => l && !/^#(\s|$)/.test(l));
}

/** What is wrong with a home, in plain words; empty when it is fine. */
export function checkHome(text: string): string[] {
  const out: string[] = [];
  const lines = homeLines(text);
  const shortcuts = lines.filter((l) => /^menu\s+shortcut(@\S+)?\s/.test(l)).length;
  if (shortcuts < MIN_SHORTCUTS || shortcuts > MAX_SHORTCUTS) {
    out.push(`home.yui needs ${MIN_SHORTCUTS} to ${MAX_SHORTCUTS} shortcuts, has ${shortcuts}`);
  }
  const routes = lines.filter((l) => /^>\S+/.test(l)).map((l) => l.slice(1).split(/\s/)[0]);
  const bad = routes.filter((r) => !/^([2-9]|1[0-2])$/.test(r));
  if (bad.length) out.push(`home.yui routes only to screens 2 to 12, not >${bad.join(", >")}`);
  if (!routes.length) out.push("home.yui needs at least one starter screen (>2)");
  if (lines.some((l) => /^>([2-9]|1[0-2])\s+clear\b/.test(l))) out.push("home.yui never clears a screen");
  if (/—/.test(text)) out.push("no em dashes");
  return out;
}

/**
 * The home row's body for one agent: its lines in a ```yui fence, `{arnold}` put
 * in as the person's Arnold's agent id. A line naming an agent they don't have is
 * left out. Null when the profile has no home.
 */
export function homeBody(p: Pick<Profile, "home">, agents: Record<string, string> = {}): string | null {
  if (!p.home) return null;
  const lines: string[] = [];
  for (const l of homeLines(p.home)) {
    let missing = false;
    const filled = l.replace(/\{([a-z0-9-]+)\}/g, (_, base: string) => {
      if (!agents[base]) missing = true;
      return agents[base] ?? "";
    });
    if (!missing) lines.push(filled);
  }
  return lines.length ? "```yui\n" + lines.join("\n") + "\n```" : null;
}

/** The row's meta: the app keeps it out of the record, like a page's own lines. */
export const HOME_META = { native: "home" } as const;

/** A native agent's row as yui-agents reads it for its home. */
export interface HomeRow {
  agent_id: string;
  base: string | null;
  home?: string | null; // its own profile's home.yui, when it carries one
  home_at?: string | null; // its home was already written
}

/**
 * The homes still to write for a person's native agents, in list order: each one
 * not written yet, from its own profile's home or else its starter's (a crew agent
 * made before homes existed). `{base}` names the person's agent of that base.
 */
export function homesToWrite(rows: HomeRow[], starterHome: (base: string) => string | undefined): { agentId: string; body: string }[] {
  const ids: Record<string, string> = {};
  for (const r of rows) if (r.base && r.base !== "custom" && !ids[r.base]) ids[r.base] = r.agent_id;
  const out: { agentId: string; body: string }[] = [];
  for (const r of rows) {
    if (r.home_at) continue;
    const home = r.home || (r.base && r.base !== "custom" ? starterHome(r.base) : undefined);
    const body = homeBody({ home: home ?? undefined }, ids);
    if (body) out.push({ agentId: r.agent_id, body });
  }
  return out;
}
