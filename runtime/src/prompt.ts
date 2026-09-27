// What one turn sends the model (spec/NATIVE.md section 3): the channel guide,
// the runtime's rules, the agent's soul and favorite screens, what it
// remembers, the crew (for Yui), then the newest thread that fits and the turn.
// The first parts are the same every turn, so providers cache them.
import { alternate, toMessage, tokens } from "./thread.ts";
import type { ChatMessage } from "./openai.ts";
import { memoryPrompt } from "./memory.ts";
import { shelf } from "./profiles.ts";
import { describe, nowLine } from "./schedule.ts";
import type { MemoryItem, NativeAgent, Profile, Row, ScheduleItem } from "./types.ts";

export const RULES = `## You are a native Yui agent

You live inside the person's Yui. Nothing is installed anywhere; you have no shell, no files and no email. You can draw every Yui screen, remember, check in later, look things up, and pass the person to another agent on their Yui.

### Remembering
When you learn something worth keeping, add a \`remember\` block at the end of your reply. The person never sees it.
\`\`\`remember
me: name = Sam
me: allergies = peanuts
note: trains before work, 3 days a week
forget n2
forget me allergies
\`\`\`
- \`me: key = value\` goes on the about-you card every agent on their Yui reads: name, goals, allergies, injuries, instruments, level. One fact per line; the same key replaces the old value.
- \`note:\` is yours alone: what you are working on together, what worked, what to do next time.
- \`forget n2\` drops your note [n2]; \`forget me key\` drops a fact. Forget at once when they ask you to.
- Keep each line short. Never store passwords, card numbers, keys or anything they asked you not to keep.`;

export const TOOL_RULES = `### Checking in later
To come back at a time (a workout check-in, a lunch question, a practice reminder), add a \`schedule\` block. Times are the person's local time; only set one when they want it.
\`\`\`schedule
every mon,wed,fri 07:00 "Check in about today's workout"
every day 12:30 "Ask what they're having for lunch"
once 2026-09-28 18:00 "Remind them to prep tomorrow's meals"
in 2h "Ask how the run went"
cancel s1
\`\`\`
\`every\` takes day, weekday, weekend or days like mon,thu. When it fires you get a line \`[yui] check-in s1 "note"\`: open with the check-in itself, short, a screen if it helps.

### Looking things up
When you need something current or a fact you are not sure of, write only a \`search\` block with one query, and nothing else; you get the results and answer then. At most one search a turn.
\`\`\`search
lo-fi hip hop drum pattern 80 bpm
\`\`\`

### Handing off
When another agent on their Yui fits the job better, say so in one line and hand it over with what they need to know. That agent opens its own thread with it.
\`\`\`handoff
gouda "Wants a lo-fi beat at 80 bpm to practice bass over"
\`\`\``;

export const MAKER_RULES = `### Making agents
You can make, change and remove the agents on this person's Yui with an \`agents\` block at the end of your reply. The person never sees it; tell them in words what you did.
\`\`\`agents
make gouda
make "Spanish tutor" color=mint favorites=ask,deck,page soul="You are a patient Spanish tutor. ..."
fork arnold "Arnold 2" soul="You are Arnold, but gentler. ..."
rename quill "Professor Q"
remove penny
\`\`\`
- \`make <shelf name>\` adds one from the shelf; \`make "Name"\` makes a new one. A soul is four to six plain lines in the second person: who it is, how it talks, what it never does.
- colors: lavender, mint, butter. favorites: Yui Lines that fit the job.
- Remove only when the person asks for it by name.`;

export const SELF_RULES = `### Becoming yourself
When the setup is done, write yourself down with one \`agents\` block:
\`\`\`agents
self name="Luna" color=butter favorites=list,card,timer soul="You are Luna, a cooking coach. ..."
\`\`\``;

export const CAREFUL_RULES = `### Health
You are a careful coach: ask about injuries, conditions and allergies before the first plan, never diagnose, never give medical or drug advice, and say once, briefly, to check with a doctor when it matters.`;

export interface CrewEntry { handle: string; name: string; role: string }

export interface PromptInput {
  guide: string;
  agent: NativeAgent;
  memory: MemoryItem[];
  crew?: CrewEntry[]; // the person's native agents, for a maker
  history: Row[];
  turn: Row[];
  images?: string[]; // signed URLs of photos in this turn
  now?: number; // ms; the prompt says the time in the person's zone
  tz?: string;
  schedules?: ScheduleItem[];
  context?: number; // tokens the model takes (default 32768)
  reserve?: number; // tokens kept for the answer (default 2048)
}

export function systemPrompt(p: Profile, memory: MemoryItem[], agentId: string, crew?: CrewEntry[],
                             extra: { now?: number; tz?: string; schedules?: ScheduleItem[] } = {}): string {
  const parts = [RULES, TOOL_RULES];
  if (p.maker) parts.push(MAKER_RULES);
  if (p.blank) parts.push(SELF_RULES);
  if (p.careful) parts.push(CAREFUL_RULES);
  parts.push(`## Who you are: ${p.name}${p.role ? `, ${p.role.toLowerCase()}` : ""}\n\n${p.soul}`);
  if (p.favorites.length) parts.push(`Screens you reach for first: ${p.favorites.map((f) => `\`${f}\``).join(", ")}. Use any other screen when it fits better.`);
  if (crew) {
    const lines = ["## This person's crew", ...crew.map((c) => `- ${c.name} (@${c.handle}): ${c.role || "custom"}`)];
    if (p.maker) {
      const have = new Set(crew.map((c) => c.handle));
      const more = shelf().filter((s) => !have.has(s.handle));
      if (more.length) lines.push("On the shelf, not added yet: " + more.map((s) => `${s.handle} (${s.role.toLowerCase()})`).join(", "));
    }
    parts.push(lines.join("\n"));
  }
  parts.push(memoryPrompt(memory, agentId));
  const tz = extra.tz ?? "UTC";
  const when = [`## Now\n${nowLine(extra.now ?? Date.now(), tz)}${extra.tz ? "" : ". Their time zone is not known yet; UTC until the phone says."}`];
  const sch = extra.schedules ?? [];
  when.push(sch.length ? "Your check-ins:\n" + sch.map((x, i) => `- [s${i + 1}] ${describe(x.rule, x.tz)}: ${x.note}`).join("\n") : "Your check-ins: none.");
  parts.push(when.join("\n"));
  return parts.join("\n\n");
}

/** The guide, then everything above, then the thread. */
export function buildTurn(input: PromptInput): { messages: ChatMessage[]; dropped: number } {
  const system = `${input.guide.trim()}\n\n${systemPrompt(input.agent.profile, input.memory, input.agent.id, input.crew,
                                                           { now: input.now, tz: input.tz, schedules: input.schedules })}`;
  const now = alternate(input.turn.map(toMessage).filter((m): m is ChatMessage => !!m));
  let budget = (input.context ?? 32768) - (input.reserve ?? 2048) - tokens(system)
    - now.reduce((n, m) => n + tokens(String(m.content)), 0) - (input.images?.length ?? 0) * 1200;
  const past = input.history.map(toMessage).filter((m): m is ChatMessage => !!m);
  const kept: ChatMessage[] = [];
  for (let i = past.length - 1; i >= 0; i--) {
    const cost = tokens(String(past[i].content));
    if (cost > budget) break;
    budget -= cost;
    kept.unshift(past[i]);
  }
  // A thread opens with the agent's first answer; many chat templates want the person
  // first, so a line stands in for opening the thread and the model sees what it asked.
  const opener: ChatMessage[] = kept[0]?.role === "assistant" ? [{ role: "user", content: "[yui] opened this thread" }] : [];
  const messages = alternate([...opener, ...kept, ...now]);
  // Photos ride on the last message from the person, as image parts.
  if (input.images?.length) {
    const last = messages[messages.length - 1];
    if (last?.role === "user") {
      last.content = [{ type: "text", text: String(last.content) }, ...input.images.map((url) => ({ type: "image_url" as const, image_url: { url } }))];
    }
  }
  messages.unshift({ role: "system", content: system });
  return { messages, dropped: past.length - kept.length };
}

/** Storage paths of the person's photos in these rows: `[yui] c1 camera photo=<path>`. */
export function photoPaths(rows: Row[]): string[] {
  const out: string[] = [];
  for (const r of rows) {
    for (const m of (r.body ?? "").matchAll(/\bphotos?=("([^"]+)"|(\S+))/g)) {
      for (const p of (m[2] ?? m[3]).split("|")) if (p && !out.includes(p)) out.push(p);
    }
    for (const p of r.meta?.media ?? []) if (typeof p === "string" && !out.includes(p)) out.push(p);
  }
  return out.slice(0, 4);
}
