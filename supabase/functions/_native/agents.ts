// Copied from runtime/src/agents.ts by runtime/scripts/build.mjs. Do not edit here.
// Yui makes agents (YUI-137) and a blank agent makes itself (YUI-138): the
// `agents` block, applied to the person's native agents through the store.
import type { AgentOp } from "./directives.ts";
import { checkProfile, crew } from "./profiles.ts";
import type { Store } from "./store.ts";
import { COLORS, PRESETS, type NativeAgent, type Profile } from "./types.ts";

export const MAX_NATIVE_AGENTS = 20;

/** What happened, in words the runtime can log and tests can read. */
export type AgentResult = { ok: true; did: string; agent?: NativeAgent } | { ok: false; why: string };

function slug(name: string): string {
  return (name.toLowerCase().normalize("NFKD").replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "agent").slice(0, 28);
}

/** A profile that is becoming someone new keeps nothing of what the blank said it does. */
function fresh(p: Profile): Profile {
  const { tagline: _t, about: _a, can: _c, ...rest } = p;
  return rest;
}

/** Soul, color, favorites and what it does from `key=value` args onto a profile. */
function withArgs(p: Profile, args: Record<string, string>): Profile {
  const out = { ...p, favorites: [...p.favorites] };
  if (args.name) out.name = args.name.trim().slice(0, 40);
  if (args.role) out.role = args.role.trim().slice(0, 60);
  if (args.soul) out.soul = args.soul.trim().slice(0, 4000);
  if (args.color && (COLORS as readonly string[]).includes(args.color) && args.color !== "brand") out.color = args.color as Profile["color"];
  if (args.favorites) out.favorites = args.favorites.split(/[,|\s]+/).filter((f) => PRESETS.has(f)).slice(0, 8);
  if (args.first) out.first = args.first;
  if (args.tagline) out.tagline = args.tagline.trim();
  if (args.about) out.about = args.about.trim();
  if (args.can) out.can = args.can.split("|").map((c) => c.trim()).filter(Boolean).slice(0, 3);
  return out;
}

/** The person's agent that a handle or a name points at. */
function find(mine: NativeAgent[], target: string): NativeAgent | undefined {
  const t = target.toLowerCase().replace(/^@/, "");
  return mine.find((a) => a.profile.handle === t) ?? mine.find((a) => a.profile.name.toLowerCase() === t);
}

export async function applyAgentOps(store: Store, self: NativeAgent, ops: AgentOp[]): Promise<AgentResult[]> {
  const out: AgentResult[] = [];
  for (const op of ops) {
    try {
      out.push(await applyOne(store, self, op));
    } catch (e: any) {
      out.push({ ok: false, why: `${op.op}: ${e?.message ?? e}` });
    }
  }
  return out;
}

async function applyOne(store: Store, self: NativeAgent, op: AgentOp): Promise<AgentResult> {
  if (op.op === "self") {
    // Any agent may rewrite itself only while blank; after that, only Yui changes agents.
    if (!self.profile.blank) return { ok: false, why: "self: only a new, blank agent sets itself up" };
    const next = withArgs({ ...fresh(self.profile), blank: false, base: "custom", version: self.profile.version }, op.args);
    const bad = checkProfile({ ...next, first: next.first || "```yui\nsay Hi\n```" });
    if (bad.length) return { ok: false, why: `self: ${bad.join("; ")}` };
    await store.updateAgent(self.id, next);
    self.profile = next;
    return { ok: true, did: `set up as ${next.name}` };
  }
  if (!self.profile.maker) return { ok: false, why: `${op.op}: only Yui makes and changes agents` };
  const mine = await store.agents(self.userId);

  if (op.op === "make") {
    if (mine.length >= MAX_NATIVE_AGENTS) return { ok: false, why: `make: ${MAX_NATIVE_AGENTS} agents is the most for now` };
    const fromShelf = op.target ? crew()[op.target] : undefined;
    let p: Profile;
    if (fromShelf) {
      p = withArgs(fromShelf, op.args);
    } else {
      const name = (op.name ?? op.target ?? "").trim();
      if (!name) return { ok: false, why: "make: needs a shelf name or a new name" };
      const blank = crew().blank;
      p = withArgs({ ...fresh(blank), blank: false, base: "custom", name, handle: slug(name), role: op.args.role ?? "",
                     first: op.args.first ?? `${name} here. What are we starting with?\n\`\`\`yui\nask "Ready when you are" Go\n\`\`\`` }, op.args);
      if (!op.args.soul) p.soul = `You are ${name}, an agent on this person's Yui. Be helpful, brief and kind, and use screens when they help.`;
    }
    const bad = checkProfile(p);
    if (bad.length) return { ok: false, why: `make: ${bad.join("; ")}` };
    const made = await store.createAgent(self.userId, p);
    return { ok: true, did: `made ${made.profile.name} (@${made.profile.handle})`, agent: made };
  }

  const target = find(mine, op.target ?? "");
  if (!target) return { ok: false, why: `${op.op}: no agent called ${op.target}` };

  if (op.op === "fork") {
    if (mine.length >= MAX_NATIVE_AGENTS) return { ok: false, why: `fork: ${MAX_NATIVE_AGENTS} agents is the most for now` };
    const name = (op.name ?? `${target.profile.name} ${target.profile.version + 1}`).slice(0, 40);
    const p = withArgs({ ...target.profile, name, version: target.profile.version + 1, handle: slug(name), maker: false }, op.args);
    const bad = checkProfile(p);
    if (bad.length) return { ok: false, why: `fork: ${bad.join("; ")}` };
    const made = await store.createAgent(self.userId, p);
    return { ok: true, did: `forked ${target.profile.name} as ${made.profile.name} (@${made.profile.handle}), version ${p.version}`, agent: made };
  }
  if (op.op === "rename") {
    const name = (op.name ?? "").trim().slice(0, 40);
    if (!name) return { ok: false, why: "rename: needs a new name" };
    await store.updateAgent(target.id, { ...target.profile, name });
    return { ok: true, did: `renamed ${target.profile.name} to ${name}` };
  }
  if (op.op === "remove") {
    if (target.id === self.id) return { ok: false, why: "remove: Yui stays" };
    await store.removeAgent(target.id);
    return { ok: true, did: `removed ${target.profile.name}` };
  }
  return { ok: false, why: `unknown ${op.op}` };
}
