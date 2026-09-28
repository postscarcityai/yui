// Copied from runtime/src/tablecall.ts by runtime/scripts/build.mjs. Do not edit here.
// Tables for any agent (YUI-171, yuigui spec/TABLES.md section 8): the one
// server call every adapter reaches (yui-connect /tables, the yui-mcp and
// Hermes `yui_tables` tools). The store and its rules are tables.ts, the same
// ones a native agent's turn uses; this is only the call's shape around them.
//
//   lines:  the agent's `table create`, `put`, `table drop` and `query` lines,
//           run in order. Writes land (all or nothing per line), deletes wait
//           for the person's tap, each query hands the rows back.
//   reply:  a whole answer with those words in its yui blocks: the same as a
//           native turn (applyTables), the answer comes back with every query
//           drawn and a Delete or Keep ask for any delete.
//
// Pure: a store in, a new store out. The caller keeps it (SupabaseStore).
import {
  type Cell,
  type Clock,
  type Held,
  type TableOp,
  type TableStore,
  applyHeld,
  applyTables,
  deleteAsk,
  findKey,
  gather,
  LIMITS,
  query,
  queryLine,
  write,
  writeLine,
} from "./tables.ts";

export const CALL_LIMITS = {
  lines: 50, // lines in one call
  rows: 500, // rows one query hands back
  tablesPerPerson: 100, // across all of a person's agents
  holdDays: 7, // a delete waits this long for its tap
};

export interface CallRows {
  table: string;
  cols: { name: string; type: string; unit?: string }[];
  keys: (string | null)[];
  rows: Cell[][];
  count: number;
}

export interface CallResult {
  ok: string[];
  failed: { line: string; error: string }[];
  results: CallRows[];
  held: Held | null;
  store: TableStore;
  read: string[]; // tables a query read
}

/** A fence the agent wrapped around its lines anyway comes off; blank lines and # notes are skipped. */
export function callLines(input: string): string[] {
  const fenced = [...input.matchAll(/```[^\n]*\n([\s\S]*?)```/g)].map((m) => m[1]);
  const body = fenced.length ? fenced.join("\n") : input;
  return body.split("\n").map((l) => l.trim()).filter((l) => l && !l.startsWith("#"));
}

/** What a call refuses whole, before anything runs: null when it may run. */
export function refuseCall(lines: string[]): string | null {
  if (lines.length > CALL_LIMITS.lines) return `${lines.length} lines in one call; ${CALL_LIMITS.lines} at most. Nothing was written.`;
  return null;
}

/** Runs the lines of a call in order against one agent's tables. */
export function runLines(lines: string[], store: TableStore, ctx: Partial<Clock>, newId: () => string): CallResult {
  const ok: string[] = [];
  const failed: CallResult["failed"] = [];
  const results: CallRows[] = [];
  const read = new Set<string>();
  const deletes: TableOp[] = [];
  for (const line of lines) {
    const op = writeLine(line);
    if (op) {
      if ("error" in op) {
        failed.push({ line, error: op.error });
        continue;
      }
      if (op.op === "drop" || (op.op === "put" && op.delete)) {
        const t = store.tables[op.op === "drop" ? op.name : op.table];
        if (!t) failed.push({ line, error: `No table called ${op.op === "drop" ? op.name : op.table} yet` });
        else if (op.op === "put" && findKey(t, String(op.key ?? "")) == null) failed.push({ line, error: `No row ${op.key ?? "(no key)"} in ${op.table}` });
        else deletes.push(op);
        continue;
      }
      const r = write(store, op, ctx);
      if (r.error) failed.push({ line, error: r.error });
      else ok.push(line);
      store = r.store;
      continue;
    }
    const props = queryLine(line);
    if (props) {
      const want = Number(props.limit);
      const res = query(store, { ...props, limit: Math.min(Number.isFinite(want) && want > 0 ? want : LIMITS.limit, CALL_LIMITS.rows) }, ctx);
      if (res.missing != null) failed.push({ line, error: `No table called ${res.missing} yet` });
      else if (res.error) failed.push({ line, error: res.error });
      else {
        const name = String(props.table);
        const real = store.tables[name] ? name : Object.keys(store.tables).find((n) => n.toLowerCase() === name.toLowerCase()) ?? name;
        read.add(real);
        results.push({ table: real, cols: res.cols!.map((c) => ({ ...c })), keys: res.keys!, rows: res.rows!, count: res.count ?? res.rows!.length });
        ok.push(line);
      }
      continue;
    }
    failed.push({ line, error: "Not a table line: use table create, put, table drop or query" });
  }
  let held: Held | null = null;
  if (deletes.length) {
    const id = `del-${newId().replace(/[^A-Za-z0-9]/g, "").slice(0, 8)}`;
    held = { id, lines: deletes.map((d) => d.line!.trim()), ask: deleteAsk(store, deletes) };
  }
  return { ok, failed, results, held, store, read: [...read] };
}

/**
 * A reply that only reads (spec section 8, "In the reply"): nothing for the
 * person, just `query` lines in yui blocks (or a ```tables block, the native
 * way). Its query lines, or null when the reply has anything else in it.
 */
export function replyRead(text: string): string[] | null {
  const parts = gather(text).split(/(^```[^\n]*\n[\s\S]*?^```[ \t]*$)/m);
  const lines: string[] = [];
  for (const [i, part] of parts.entries()) {
    if (i % 2 === 0) {
      if (part.trim()) return null;
      continue;
    }
    const m = part.match(/^```(\w*)[^\n]*\n([\s\S]*?)^```/m);
    if (!m || !["yui", "tables"].includes(m[1])) return null;
    for (const raw of m[2].split("\n")) {
      const l = raw.trim();
      if (!l || l.startsWith("#")) continue;
      const line = m[1] === "tables" && !/^query\s/.test(l) ? `query ${l}` : l;
      if (!queryLine(line)) return null;
      lines.push(line);
    }
  }
  return lines.length ? lines.slice(0, CALL_LIMITS.lines) : null;
}

/** What a read hands back to the agent as its next turn: the rows, then answer the person. */
export function readNote(r: { results: CallRows[]; failed: { line: string; error: string }[] }): string {
  const found = r.results.map(rowsText);
  const bad = r.failed.map((f) => `Refused "${f.line}": ${f.error}.`);
  return `[yui] Your tables:\n\n${[...found, ...bad].join("\n\n") || "(nothing matched)"}\n\n`
    + "[yui] Answer the person now: a line, then a screen. A query line in your yui block draws these rows for them.";
}

/** A whole reply: the same as a native agent's answer (tables.ts applyTables). */
export function runReply(text: string, store: TableStore, ctx: Partial<Clock>, newId: () => string) {
  return applyTables(text, store, ctx, newId);
}

/** The ask the person sees for held deletes. */
export function holdAsk(held: Held): string {
  const clean = held.ask.replace(/[\r\n]+/g, " ").replace(/"/g, "'").trim();
  return "```yui\nchoose@" + held.id + ' "' + clean + '" Delete|Keep\n```';
}

const TAP = /^\[yui\]\s+(del-[A-Za-z0-9]+)\s+choose\b.*?\bchoice=("?)(Delete|Keep)\2/i;

/** A Delete or Keep tap on a held delete: its id and the choice, or null. */
export function holdTap(body: string): { id: string; choice: "Delete" | "Keep" } | null {
  const m = (body ?? "").match(TAP);
  if (!m) return null;
  return { id: m[1], choice: /^delete$/i.test(m[3]) ? "Delete" : "Keep" };
}

/** Runs the deletes the person said yes to. */
export function settleHold(store: TableStore, lines: string[], ctx: Partial<Clock> = {}) {
  return applyHeld(store, lines, ctx);
}

/** What the agent holds, one line: `foods(44 rows: Food, Cal) meals(12 rows: Day, Food)`. */
export function holding(store: TableStore): { name: string; rows: number; cols: string[] }[] {
  return Object.values(store.tables).map((t) => ({ name: t.name, rows: t.order.length, cols: t.cols.map((c) => c.name) }));
}

export function holdingLine(store: TableStore): string {
  const list = holding(store);
  if (!list.length) return "[yui] tables (none yet)";
  return "[yui] tables " + list.map((t) => `${t.name}(${t.rows} row${t.rows === 1 ? "" : "s"}: ${t.cols.join(", ")})`).join(" ");
}

/** Rows as plain text for a tool result the model reads. */
export function rowsText(r: CallRows): string {
  const withKey = r.keys.some((k) => k != null);
  const head = [...(withKey ? ["key"] : []), ...r.cols.map((c) => c.name + (c.unit ? ` (${c.unit})` : ""))].join(" | ");
  const body = r.rows.map((row, i) => [...(withKey ? [r.keys[i] ?? ""] : []), ...row.map((v) => (v == null ? "" : String(v)))].join(" | "));
  const more = r.count > r.rows.length ? `\n(${r.count} rows match; the first ${r.rows.length} are here.)` : "";
  return `${r.table}\n${head}\n${body.join("\n") || "(no rows)"}${more}`;
}
