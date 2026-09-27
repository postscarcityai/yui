// What a native agent writes for the runtime, not for the person: memory
// (a ```remember fence) and agent changes (an ```agents fence). The runtime
// takes both out of the reply before it reaches the thread.
//
//   ```remember
//   note: likes to train before work
//   me: allergies = peanuts
//   forget n2
//   forget me allergies
//   ```
//
//   ```agents
//   make gouda
//   make "Spanish tutor" color=mint favorites=ask,deck,page soul="You are a patient Spanish tutor..."
//   fork arnold "Arnold 2" soul="You are Arnold, gentler..."
//   rename quill "Professor Q"
//   remove penny
//   self name="Luna" color=butter favorites=list,card soul="You are Luna..."
//   ```
//
//   ```schedule                ```search                   ```handoff
//   every mon,wed 07:00 "..."   lo-fi drum patterns 80 bpm  gouda "Wants a lo-fi beat, plays bass"
//   cancel s1                   ```                         ```
//   ```

export type MemoryOp =
  | { op: "note"; body: string }
  | { op: "about"; key: string; body: string }
  | { op: "forget_note"; ref: string } // "n2"
  | { op: "forget_about"; key: string };

export interface AgentOp {
  op: "make" | "fork" | "rename" | "remove" | "self";
  target?: string; // a shelf name or one of the person's handles
  name?: string;
  args: Record<string, string>;
}

export interface Handoff { target: string; note: string }

export interface Extracted {
  text: string;
  memory: MemoryOp[];
  agents: AgentOp[];
  schedule: string[]; // raw lines, parsed with the person's time zone (schedule.ts)
  search: string | null; // one query per turn
  handoff: Handoff[];
}

const FENCE = /```(remember|agents|schedule|search|handoff)[ \t]*\n([\s\S]*?)(?:\n```|$)/g;

/** Splits a reply into what the person sees and what the runtime does. */
export function extract(reply: string): Extracted {
  const out: Extracted = { text: "", memory: [], agents: [], schedule: [], search: null, handoff: [] };
  out.text = reply.replace(FENCE, (_m, kind: string, body: string) => {
    for (const line of body.split("\n")) {
      const l = line.trim();
      if (!l || l.startsWith("#")) continue;
      if (kind === "remember") {
        const op = memoryLine(l);
        if (op) out.memory.push(op);
      } else if (kind === "agents") {
        const op = agentLine(l);
        if (op) out.agents.push(op);
      } else if (kind === "schedule") {
        out.schedule.push(l);
      } else if (kind === "search") {
        out.search ??= l.slice(0, 200);
      } else {
        const h = l.match(/^@?([a-z0-9-]+)\s+"((?:[^"\\]|\\.)*)"$/i);
        if (h) out.handoff.push({ target: h[1].toLowerCase(), note: h[2].replace(/\\(.)/g, "$1").slice(0, 500) });
      }
    }
    return "";
  }).replace(/\n{3,}/g, "\n\n").trim();
  return out;
}

export function memoryLine(l: string): MemoryOp | null {
  let m = l.match(/^note\s*:\s*(.+)$/i);
  if (m) return { op: "note", body: m[1].trim() };
  m = l.match(/^(?:me|about)\s*:\s*([^=]+?)\s*=\s*(.+)$/i);
  if (m) return { op: "about", key: cleanKey(m[1]), body: m[2].trim() };
  m = l.match(/^forget\s+(?:me|about)\s+(.+)$/i);
  if (m) return { op: "forget_about", key: cleanKey(m[1]) };
  m = l.match(/^forget\s+(n\d+)$/i);
  if (m) return { op: "forget_note", ref: m[1].toLowerCase() };
  return null;
}

export function cleanKey(s: string): string {
  return s.trim().toLowerCase().replace(/[^a-z0-9]+/g, " ").trim().slice(0, 40);
}

/** Words, "quoted words" and key=value / key="quoted value". */
export function tokens(line: string): string[] {
  const out: string[] = [];
  const re = /([A-Za-z_]+=)?"((?:[^"\\]|\\.)*)"|(\S+)/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(line))) {
    if (m[3] !== undefined) out.push(m[3]);
    else out.push((m[1] ?? "") + "\u0000" + m[2].replace(/\\(.)/g, "$1")); // \0 marks "was quoted"
  }
  return out;
}

export function agentLine(l: string): AgentOp | null {
  const t = tokens(l);
  const verb = (t.shift() ?? "").toLowerCase();
  if (!["make", "fork", "rename", "remove", "self"].includes(verb)) return null;
  const args: Record<string, string> = {};
  const words: string[] = [];
  let firstQuoted = false;
  for (const tok of t) {
    const kv = tok.match(/^([A-Za-z_]+)=\u0000?([\s\S]*)$/);
    if (kv) args[kv[1].toLowerCase()] = kv[2];
    else {
      if (!words.length) firstQuoted = tok.startsWith("\u0000");
      words.push(tok.replace(/^\u0000/, ""));
    }
  }
  const op: AgentOp = { op: verb as AgentOp["op"], args };
  if (verb === "self") return op;
  if (verb === "make") {
    // `make gouda` (the shelf) or `make "Spanish tutor" ...` (a new one)
    const w = words[0];
    if (!w) return null;
    if (!firstQuoted && /^[a-z0-9-]+$/.test(w)) op.target = w;
    else op.name = w;
    return op;
  }
  op.target = words[0]?.toLowerCase();
  if (!op.target) return null;
  if (words[1]) op.name = words[1];
  if ((verb === "rename") && !op.name) return null;
  return op;
}
