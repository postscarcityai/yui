// Agent tables for native agents (YUI-170): each agent keeps its own little
// database, the three words of yuigui spec/TABLES.md (`table create`, `put`,
// `query`) kept on the server instead of the phone. The store is a port of
// yuigui site/lib/yl/tables.mjs (same limits, same types, same errors), plus
// `group=Day:week` and `group=Day:month` and `table drop`.
//
// A turn reads the agent's tables, the agent writes the words in its yui block,
// and the runtime takes them out: writes land in the store, a delete waits for
// the person's tap, and every `query` is drawn as a plain `table`, `list`,
// `chart` or `stat` the app already draws. A ```tables block with only query
// lines is the agent reading before it answers (like a search).
//
// Pure: a store in, a new store out. The Store (store.ts) keeps them.

export type ColType = "text" | "number" | "date" | "bool";
export type Cell = string | number | boolean | null;

export interface TableCol { name: string; type: ColType; unit?: string }
export interface Table {
  name: string;
  cols: TableCol[];
  rows: Record<string, Record<string, Cell>>;
  order: string[]; // keys, in the order they were first written
  next: number; // the next r<n> key an unkeyed put gets
}
export interface TableStore { tables: Record<string, Table> }

/** A starter table a profile ships with (profiles/<name>/tables.yui), rows in order. */
export interface TableSeed {
  name: string;
  cols: TableCol[];
  rows: { key: string; values: Record<string, Cell> }[];
  next: number;
}

export const TYPES: ColType[] = ["text", "number", "date", "bool"];

export const LIMITS = {
  tables: 20, // per agent
  cols: 12, // per table
  rows: 5000, // per table
  text: 1000, // characters in one text cell
  key: 64, // characters in a row key
  name: 32, // characters in a table name
  limit: 50, // rows a query shows by default
  maxLimit: 500, // rows a query can ask for
  read: 60, // rows a read (```tables) hands the agent
  prompt: 5, // newest rows of each table in the prompt
};

const NAME = /^[A-Za-z][\w-]*$/;
const COL = /^[A-Za-z_][\w-]*$/;
const NUMBER = /^-?\d+(\.\d+)?$/;
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const STAMP = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/;
const REL = /^today(?:([+-])(\d{1,4}))?$/i;

/** `today` and `now` in the person's time zone. */
export interface Clock { today: string; now: string }

export function clock(ms: number, tz: string): Clock {
  const parts = Object.fromEntries(new Intl.DateTimeFormat("en-CA", {
    timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23",
  }).formatToParts(new Date(ms)).map((p) => [p.type, p.value]));
  const today = `${parts.year}-${parts.month}-${parts.day}`;
  return { today, now: `${today}T${parts.hour}:${parts.minute}` };
}

export function emptyStore(): TableStore {
  return { tables: {} };
}

function shiftDay(day: string, n: number): string {
  const [y, m, d] = day.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d + n)).toISOString().slice(0, 10);
}

function realDate(s: string): boolean {
  const [y, m, d] = s.slice(0, 10).split("-").map(Number);
  const t = new Date(Date.UTC(y, m - 1, d));
  return t.getUTCFullYear() === y && t.getUTCMonth() === m - 1 && t.getUTCDate() === d;
}

/** One value into a column's type: {value} or {error}. null is an empty cell. */
export function cell(type: ColType, v: unknown, ctx: Partial<Clock> = {}): { value?: Cell; error?: string } {
  if (v === "" || v === null || v === undefined) return { value: null };
  if (Array.isArray(v)) v = v.join("|");
  switch (type) {
    case "text": {
      const s = String(v);
      if (s.length > LIMITS.text) return { error: `text over ${LIMITS.text} characters` };
      return { value: s };
    }
    case "number": {
      if (typeof v === "number") return Number.isFinite(v) ? { value: v } : { error: "not a number" };
      if (typeof v === "string" && NUMBER.test(v.trim())) return { value: Number(v) };
      return { error: `"${v}" is not a number` };
    }
    case "date": {
      const s = String(v).trim();
      const today = ctx.today ?? new Date().toISOString().slice(0, 10);
      const rel = s.match(REL);
      if (rel) return { value: rel[1] ? shiftDay(today, (rel[1] === "-" ? -1 : 1) * Number(rel[2])) : today };
      if (s.toLowerCase() === "now") return { value: ctx.now ?? new Date().toISOString().slice(0, 16) };
      if ((DAY.test(s) || STAMP.test(s)) && realDate(s)) return { value: s };
      return { error: `"${s}" is not a date (YYYY-MM-DD, today, today-7, now)` };
    }
    case "bool": {
      if (typeof v === "boolean") return { value: v };
      const s = String(v).toLowerCase();
      if (["on", "true", "yes", "1"].includes(s)) return { value: true };
      if (["off", "false", "no", "0"].includes(s)) return { value: false };
      return { error: `"${v}" is not on or off` };
    }
  }
  return { error: `unknown type ${type}` };
}

function copyTable(t: Table): Table {
  return { ...t, cols: t.cols.map((c) => ({ ...c })), rows: { ...t.rows }, order: [...t.order] };
}

// ---------- writes ----------

export type TableOp =
  | { op: "table"; name: string; cols: TableCol[]; line?: string }
  | { op: "drop"; name: string; line?: string }
  | { op: "put"; table: string; key?: string; values: Record<string, unknown>; delete?: boolean; line?: string };

export interface WriteResult { store: TableStore; error?: string; key?: string }

function create(store: TableStore, op: Extract<TableOp, { op: "table" }>, ctx: Partial<Clock>): WriteResult {
  const { name, cols } = op;
  if (!NAME.test(name || "") || name.length > LIMITS.name) return { store, error: `table: bad name "${name}"` };
  if (!cols?.length) return { store, error: "table create: needs at least one col:type" };
  if (cols.length > LIMITS.cols) return { store, error: `table create: ${LIMITS.cols} columns at most` };
  const seen = new Set<string>();
  for (const c of cols) {
    if (!COL.test(c.name || "")) return { store, error: `table create: bad column "${c.name}"` };
    if (c.name.toLowerCase() === "key") return { store, error: "table create: key is the row key, not a column" };
    if (seen.has(c.name.toLowerCase())) return { store, error: `table create: column "${c.name}" twice` };
    if (!TYPES.includes(c.type)) return { store, error: `table create: "${c.type}" is not text, number, date or bool` };
    seen.add(c.name.toLowerCase());
  }
  const old = store.tables[name];
  if (!old && Object.keys(store.tables).length >= LIMITS.tables) return { store, error: `table: ${LIMITS.tables} tables per agent at most` };
  const clean = cols.map((c) => ({ name: c.name, type: c.type, ...(c.unit ? { unit: c.unit } : {}) }));
  if (!old) return { store: { tables: { ...store.tables, [name]: { name, cols: clean, rows: {}, order: [], next: 1 } } } };
  // The same columns again changes nothing (an agent may send it every reply).
  if (JSON.stringify(old.cols) === JSON.stringify(clean)) return { store };
  const t = copyTable(old);
  const prev = Object.fromEntries(old.cols.map((c) => [c.name, c]));
  for (const key of t.order) {
    const row = old.rows[key];
    const next: Record<string, Cell> = {};
    for (const c of clean) {
      const was = prev[c.name];
      if (!was || row[c.name] == null) continue;
      const v = was.type === c.type ? { value: row[c.name] } : cell(c.type, row[c.name], ctx);
      if (v.value != null && !v.error) next[c.name] = v.value;
    }
    t.rows[key] = next;
  }
  t.cols = clean;
  return { store: { tables: { ...store.tables, [name]: t } } };
}

function put(store: TableStore, op: Extract<TableOp, { op: "put" }>, ctx: Partial<Clock>): WriteResult {
  const t0 = store.tables[op.table];
  if (!t0) return { store, error: `put: no table "${op.table}"` };
  if (op.key != null && (String(op.key).length === 0 || String(op.key).length > LIMITS.key)) {
    return { store, error: `put: a key is 1 to ${LIMITS.key} characters` };
  }
  const t = copyTable(t0);
  if (op.delete) {
    if (op.key == null) return { store, error: "put +delete: needs a key" };
    const k = findKey(t, String(op.key));
    if (k == null) return { store };
    delete t.rows[k];
    t.order = t.order.filter((x) => x !== k);
    return { store: { tables: { ...store.tables, [op.table]: t } }, key: k };
  }
  const byName = Object.fromEntries(t.cols.map((c) => [c.name.toLowerCase(), c]));
  const vals: Record<string, Cell> = {};
  for (const [k, v] of Object.entries(op.values || {})) {
    const c = byName[k.toLowerCase()];
    if (!c) return { store, error: `put: ${op.table} has no column "${k}"` };
    const r = cell(c.type, v, ctx);
    if (r.error) return { store, error: `put: ${c.name}: ${r.error}` };
    vals[c.name] = r.value ?? null;
  }
  let key = op.key != null ? findKey(t, String(op.key)) ?? String(op.key) : null;
  if (key == null) {
    do key = `r${t.next++}`; while (key in t.rows);
  }
  const had = key in t.rows;
  if (!had && t.order.length >= LIMITS.rows) return { store, error: `put: ${op.table} is full (${LIMITS.rows} rows)` };
  const row = { ...(had ? t.rows[key] : {}) };
  for (const [k, v] of Object.entries(vals)) {
    if (v == null) delete row[k];
    else row[k] = v;
  }
  t.rows[key] = row;
  if (!had) t.order.push(key);
  return { store: { tables: { ...store.tables, [op.table]: t } }, key };
}

/** A key as written, or the same key in another case ("Milk" finds "milk"): models are loose with case. */
export function findKey(t: Table, k: string): string | null {
  if (k in t.rows) return k;
  const low = k.toLowerCase();
  return t.order.find((x) => x.toLowerCase() === low) ?? null;
}

/** Applies one op. On an error the store is unchanged. */
export function write(store: TableStore, op: TableOp, ctx: Partial<Clock> = {}): WriteResult {
  if (op.op === "table") return create(store, op, ctx);
  if (op.op === "put") return put(store, op, ctx);
  if (!store.tables[op.name]) return { store };
  const tables = { ...store.tables };
  delete tables[op.name];
  return { store: { tables } };
}

// ---------- query ----------

const CLAUSE = /^([A-Za-z_][\w-]*)\s*(>=|<=|!=|=|>|<|~)\s*(.*)$/;
const AGGS = ["sum", "avg", "min", "max"] as const;

function cmp(a: Cell, b: Cell): number {
  if (a == null && b == null) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  if (typeof a === "number" && typeof b === "number") return a - b;
  if (typeof a === "boolean" && typeof b === "boolean") return (a ? 1 : 0) - (b ? 1 : 0);
  return String(a).localeCompare(String(b), undefined, { sensitivity: "base" });
}

const asList = (v: unknown): string[] =>
  (v == null || typeof v === "boolean" ? [] : Array.isArray(v) ? v : [v]).map(String).filter((x) => x !== "");

/** Monday of a date's week, as YYYY-MM-DD. */
function weekOf(v: string): string {
  const [y, m, d] = v.slice(0, 10).split("-").map(Number);
  const t = new Date(Date.UTC(y, m - 1, d));
  return shiftDay(t.toISOString().slice(0, 10), -((t.getUTCDay() + 6) % 7));
}

export interface QueryResult {
  cols?: TableCol[];
  rows?: Cell[][];
  keys?: (string | null)[];
  count?: number;
  missing?: string;
  error?: string;
}

/** A query's props against a store (spec/TABLES.md section 1, query). */
export function query(store: TableStore, props: Record<string, unknown>, ctx: Partial<Clock> = {}): QueryResult {
  const name = String(props.table ?? "");
  const t = store.tables[name] ?? Object.values(store.tables).find((x) => x.name.toLowerCase() === name.toLowerCase());
  if (!t) return { missing: name };
  const colOf = (n: string): TableCol | undefined => {
    if (String(n).toLowerCase() === "key") return { name: "key", type: "text" };
    return t.cols.find((c) => c.name.toLowerCase() === String(n).toLowerCase());
  };
  const tests: ((row: Record<string, Cell>) => boolean)[] = [];
  for (const w of asList(props.where)) {
    const m = w.match(CLAUSE);
    if (!m) return { error: `where: cannot read "${w}"` };
    const c = colOf(m[1]);
    if (!c) return { error: `where: no column "${m[1]}"` };
    const op = m[2];
    const raw = m[3].trim().replace(/^"(.*)"$/, "$1");
    if (raw === "") {
      if (op !== "=" && op !== "!=") return { error: `where: "${w}" needs a value` };
      tests.push((row) => (row[c.name] == null) === (op === "="));
      continue;
    }
    let want: Cell;
    if (op === "~") want = raw.toLowerCase();
    else {
      const r = cell(c.type, raw, ctx);
      if (r.error) return { error: `where: ${c.name}: ${r.error}` };
      want = r.value ?? null;
    }
    const byDay = c.type === "date" && typeof want === "string" && want.length === 10;
    tests.push((row) => {
      let v = row[c.name];
      if (v == null && c.type === "bool") v = false; // a box never ticked is off: Got=off finds it
      if (v == null) return op === "!=";
      if (byDay) v = String(v).slice(0, 10);
      if (op === "~") return String(v).toLowerCase().includes(String(want));
      const d = cmp(v, want);
      if (op === "=") return d === 0;
      if (op === "!=") return d !== 0;
      if (op === ">") return d > 0;
      if (op === "<") return d < 0;
      if (op === ">=") return d >= 0;
      return d <= 0;
    });
  }
  let rows: Record<string, Cell>[] = t.order.map((k) => ({ key: k, ...t.rows[k] })).filter((r) => tests.every((f) => f(r)));

  let cols: TableCol[];
  let keyed = true;
  const aggs = AGGS.flatMap((a) => asList(props[a]).map((n) => ({ a, n })));
  const groupRaw = props.group != null && props.group !== "" && props.group !== true ? String(props.group) : null;
  if (aggs.length || props.count || groupRaw) {
    keyed = false;
    // group=Day:week (or :month, :day) buckets a date column.
    const [gName, bucket] = (groupRaw ?? "").split(":");
    const g0 = groupRaw ? colOf(gName) : null;
    if (groupRaw && !g0) return { error: `group: no column "${gName}"` };
    if (bucket && (!g0 || g0.type !== "date" || !["day", "week", "month"].includes(bucket))) {
      return { error: `group: ${groupRaw} (a date column can group by :day, :week or :month)` };
    }
    const label = bucket === "week" ? "Week" : bucket === "month" ? "Month" : g0?.name;
    const bucketOf = (v: Cell): Cell => {
      if (v == null || !bucket) return v ?? null;
      const s = String(v);
      return bucket === "week" ? weekOf(s) : bucket === "month" ? s.slice(0, 7) : s.slice(0, 10);
    };
    type Out = TableCol & { from: string | null; a: string | null };
    const out: Out[] = [];
    if (g0) out.push({ name: label!, type: bucket === "month" ? "text" : g0.type, from: g0.name, a: null });
    const used = new Set(out.map((c) => c.name.toLowerCase()));
    for (const { a, n } of aggs) {
      const c = colOf(n);
      if (!c) return { error: `${a}: no column "${n}"` };
      if (c.type !== "number" && (a === "sum" || a === "avg")) return { error: `${a}: ${c.name} is not a number column` };
      // A second use of a column is named after what it is (spec: `avg Weight`); no spaces, so it stays one header token.
      const lab = used.has(c.name.toLowerCase()) ? `${a[0].toUpperCase()}${a.slice(1)}-${c.name}` : c.name;
      used.add(lab.toLowerCase());
      out.push({ name: lab, type: c.type, ...(c.unit ? { unit: c.unit } : {}), from: c.name, a });
    }
    if (props.count) out.push({ name: "Count", type: "number", from: null, a: "count" });
    const groups = new Map<string, Record<string, Cell>[]>();
    for (const r of rows) {
      const gk = g0 ? JSON.stringify(bucketOf(r[g0.name] ?? null)) : "";
      if (!groups.has(gk)) groups.set(gk, []);
      groups.get(gk)!.push(r);
    }
    if (!g0 && !groups.size) groups.set("", []);
    rows = [...groups.values()].map((list) => {
      const row: Record<string, Cell> = {};
      for (const c of out) {
        if (c.a === null) row[c.name] = bucketOf(list[0][c.from!] ?? null);
        else if (c.a === "count") row[c.name] = list.length;
        else {
          const vs = list.map((r) => r[c.from!]).filter((v) => v != null) as Cell[];
          if (!vs.length) row[c.name] = c.a === "sum" ? 0 : null;
          else if (c.a === "sum") row[c.name] = round((vs as number[]).reduce((s, v) => s + v, 0));
          else if (c.a === "avg") row[c.name] = round((vs as number[]).reduce((s, v) => s + v, 0) / vs.length);
          else row[c.name] = vs.reduce((best, v) => ((c.a === "min" ? cmp(v, best) < 0 : cmp(v, best) > 0) ? v : best));
        }
      }
      return row;
    });
    cols = out.map(({ from: _f, a: _a, ...c }) => c);
  } else {
    const pick = asList(props.cols);
    const picked = pick.length ? pick.map(colOf) : t.cols;
    const bad = pick.find((_n, i) => !picked[i]);
    if (bad) return { error: `cols: no column "${bad}"` };
    cols = (picked as TableCol[]).map((c) => ({ ...c }));
  }

  const sorts: { name: string; desc: boolean }[] = [];
  for (const s of asList(props.sort)) {
    const desc = s.startsWith("-");
    const n = desc ? s.slice(1) : s;
    const c = keyed ? colOf(n) : cols.find((x) => x.name.toLowerCase() === n.toLowerCase());
    if (!c) return { error: `sort: no column "${n}"` };
    sorts.push({ name: c.name, desc });
  }
  if (sorts.length) {
    rows = rows.map((r, i) => ({ r, i })).sort((x, y) => {
      for (const { name: n, desc } of sorts) {
        const a = x.r[n], b = y.r[n];
        if (a == null || b == null) {
          if (a == null && b == null) continue;
          return a == null ? 1 : -1;
        }
        const d = cmp(a, b);
        if (d) return desc ? -d : d;
      }
      return x.i - y.i;
    }).map((x) => x.r);
  }
  const count = rows.length;
  const asked = props.limit != null && props.limit !== "" ? Math.floor(Number(props.limit)) : NaN;
  const lim = Math.max(0, Math.min(LIMITS.maxLimit, Number.isFinite(asked) ? asked : LIMITS.limit));
  rows = rows.slice(0, lim);
  return {
    cols,
    rows: rows.map((r) => cols.map((c) => (r[c.name] === undefined ? null : r[c.name]))),
    keys: rows.map((r) => (keyed ? String(r.key) : null)),
    count,
  };
}

const round = (n: number) => Math.round(n * 1e6) / 1e6;

// ---------- lines ----------

interface Tok { text: string; quoted: boolean; key?: string; flag?: boolean }

/** Words, "quoted words", key=value, key="quoted value" and +flags. */
export function toks(line: string): Tok[] {
  const out: Tok[] = [];
  const re = /\+([A-Za-z_][\w-]*)|([A-Za-z_][\w-]*)=("(?:[^"\\]|\\.)*"|\S*)|"((?:[^"\\]|\\.)*)"|(\S+)/g;
  let m: RegExpExecArray | null;
  const unq = (s: string) => s.replace(/\\(.)/g, "$1");
  while ((m = re.exec(line))) {
    if (m[1] !== undefined) out.push({ text: m[1], quoted: false, flag: true });
    else if (m[2] !== undefined) {
      const v = m[3];
      const q = v.startsWith('"') && v.endsWith('"') && v.length >= 2;
      out.push({ key: m[2], text: q ? unq(v.slice(1, -1)) : v, quoted: q });
    } else if (m[4] !== undefined) out.push({ text: unq(m[4]), quoted: true });
    else out.push({ text: m[5], quoted: false });
  }
  return out;
}

const WRITE_HEAD = /^\s*(?:table\s+(?:create|drop)\s|put\s)/;
const QUERY_HEAD = /^\s*query(?:@[\w-]+)?\s/;

/** `table create`, `table drop` or `put` as an op; null for any other line. */
export function writeLine(line: string): TableOp | { error: string; line: string } | null {
  if (!WRITE_HEAD.test(line)) return null;
  const t = toks(line.trim());
  const head = t.shift()!.text;
  if (head === "table") {
    const verb = t.shift()!.text;
    const name = t.shift()?.text ?? "";
    if (verb === "drop") return { op: "drop", name, line };
    const cols: TableCol[] = [];
    for (const c of t) {
      const [n, type, ...unit] = c.text.split(":");
      if (!n || !type || c.key || c.flag) return { error: `table create: "${c.text}" is not col:type`, line };
      cols.push({ name: n, type: type as ColType, ...(unit.length ? { unit: unit.join(":") } : {}) });
    }
    return { op: "table", name, cols, line };
  }
  const table = t.shift()?.text ?? "";
  if (!table) return { error: "put: needs a table", line };
  const values: Record<string, unknown> = {};
  let key: string | undefined;
  let del = false;
  for (const x of t) {
    if (x.flag) {
      if (x.text === "delete") del = true;
      else values[x.text] = true;
    } else if (x.key) values[x.key] = x.quoted ? x.text : x.text;
    else if (key === undefined) key = x.text;
    else return { error: `put: one key at most ("${x.text}")`, line };
  }
  if (del && Object.keys(values).length) return { error: "put +delete: takes no values", line };
  if (!del && !Object.keys(values).length) return { error: "put: needs a value", line };
  return { op: "put", table, ...(key !== undefined ? { key } : {}), values, ...(del ? { delete: true } : {}), line };
}

const LISTY = new Set(["where", "sort", "cols", "y", "sum", "avg", "min", "max"]);
const VIEWS = new Set(["table", "list", "chart", "stat", "send"]);
const CHART_TYPES = new Set(["line", "bar", "area", "scatter", "pie", "donut"]);

/** A `query` line's props: {table, where: [...], ..., as, type, title}. Null when it is not one. */
export function queryLine(line: string): Record<string, unknown> | null {
  if (!QUERY_HEAD.test(line)) return null;
  const t = toks(line.trim());
  const head = t.shift()!.text;
  const props: Record<string, unknown> = { table: t.shift()?.text ?? "" };
  const id = head.match(/@([\w-]+)/)?.[1];
  if (id) props.id = id;
  const title: string[] = [];
  for (let i = 0; i < t.length; i++) {
    const x = t[i];
    if (x.flag) props[x.text] = true;
    else if (x.key) props[x.key] = LISTY.has(x.key) ? (x.quoted ? [x.text] : x.text.split("|")) : x.text;
    else if (!x.quoted && x.text === "as" && VIEWS.has(t[i + 1]?.text ?? "")) {
      props.as = t[++i].text;
      if (props.as === "chart" && CHART_TYPES.has(t[i + 1]?.text ?? "")) props.type = t[++i].text;
    } else title.push(x.text);
  }
  if (title.length) props.title = title.join(" ");
  return props;
}

// ---------- drawing ----------

const clean = (s: string) => s.replace(/[\r\n]+/g, " ").replace(/\|/g, "/").replace(/"/g, "'").replace(/\\/g, "").trim();
const q = (s: string) => `"${clean(s)}"`;
/** One option in an options token: bare when it can be. */
const opt = (s: string) => (/^[^\s"|=+]+$/.test(s) && !/^[A-Za-z_][\w-]*=/.test(s) ? s : q(s));

function show(v: Cell, c?: TableCol): string {
  if (v == null) return "";
  if (typeof v === "boolean") return v ? "yes" : "";
  if (typeof v === "number") return String(round(v));
  if (c?.type === "date" && typeof v === "string") return v.replace("T", " ");
  return String(v);
}

export function pretty(name: string): string {
  return name.replace(/[_-]+/g, " ").replace(/^./, (c) => c.toUpperCase());
}

/**
 * A query as Yui Lines the app draws today: an inline `table`, a `list`, a
 * `chart` with its numbers, or one `stat`. The rows are real, so the phone
 * never needs the store.
 */
export function draw(store: TableStore, props: Record<string, unknown>, ctx: Partial<Clock> = {}): string[] {
  const res = query(store, props, ctx);
  const name = String(props.table ?? "");
  const title = String(props.title ?? "") || pretty(name);
  const id = props.id ? `@${props.id}` : "";
  if (res.missing != null) return [`card ${q(title)} body=${q(`No table called ${name} yet.`)}`];
  if (res.error) return [`card ${q(title)} body=${q(`That view can't run: ${res.error}.`)}`];
  const cols = res.cols!, rows = res.rows!;
  const view = String(props.as ?? "table");
  if (!rows.length && view !== "stat") return [`card ${q(title)} body=${q(`Nothing in ${pretty(name).toLowerCase()} yet.`)}`];

  if (view === "list") {
    const check = props.check ? cols.findIndex((c) => c.name.toLowerCase() === String(props.check).toLowerCase()) : -1;
    const items = rows.map((r) => {
      // A number says what it is: "Cal 300 kcal", "Sets 3".
      const cells = r.map((v, i) => (i === check || v == null || v === "" ? ""
        : cols[i].type === "number" ? `${cols[i].name} ${show(v, cols[i])}${cols[i].unit ? ` ${cols[i].unit}` : ""}` : show(v, cols[i])))
        .filter(Boolean).join(" · ");
      return q(`${check >= 0 && r[check] === true ? "Done: " : ""}${cells}`);
    });
    return [`list${id} title=${q(title)} ${items.join(" ")}`];
  }

  if (view === "chart") {
    const numeric = (i: number) => cols[i].type === "number";
    const find = (n: unknown) => cols.findIndex((c) => c.name.toLowerCase() === String(n).toLowerCase());
    const xi = props.x != null ? find(props.x) : cols.findIndex((_c, i) => !numeric(i));
    const ys = (asList(props.y).length ? asList(props.y).map(find) : cols.map((_c, i) => i).filter((i) => numeric(i) && i !== xi))
      .filter((i) => i >= 0 && numeric(i));
    if (!ys.length) return [`card ${q(title)} body=${q("There's no number to chart.")}`];
    const xs = rows.map((r, n) => (xi >= 0 ? show(r[xi], cols[xi]) : String(n + 1)) || "-");
    const series = ys.map((i, n) => `y${n ? n + 1 : ""}=${rows.map((r) => (r[i] == null ? 0 : show(r[i]))).join("|")}`);
    const units = [...new Set(ys.map((i) => cols[i].unit).filter(Boolean))];
    const type = String(props.type ?? (xi >= 0 && cols[xi].type === "date" ? "line" : "bar"));
    return [[`chart${id} ${CHART_TYPES.has(type) ? type : "bar"} ${q(title)} x=${xs.map(opt).join("|")}`, ...series,
      ...(ys.length > 1 ? [`names=${ys.map((i) => opt(cols[i].name)).join("|")}`] : []),
      ...(units.length === 1 ? [`unit=${opt(units[0]!)}`] : [])].join(" ")];
  }

  if (view === "stat") {
    const yi = props.y != null ? cols.findIndex((c) => c.name.toLowerCase() === String(asList(props.y)[0]).toLowerCase())
      : cols.findIndex((c) => c.type === "number");
    if (yi < 0) return [`card ${q(title)} body=${q("There's no number to show.")}`];
    const vals = rows.map((r) => r[yi]).filter((v): v is number => typeof v === "number");
    const last = vals.length ? vals[vals.length - 1] : 0;
    const unit = cols[yi].unit;
    const value = unit && /^[A-Za-z%]+$/.test(unit) ? `${round(last)}${unit}` : String(round(last));
    const label = String(props.label ?? "") || title;
    const extra: string[] = [];
    if (vals.length >= 2) {
      extra.push(`delta=${round(last - vals[vals.length - 2])}`, `spark=${vals.slice(-12).map(round).join("|")}`);
    }
    if (props.good === "up" || props.good === "down") extra.push(`good=${props.good}`);
    if (unit && !/^[A-Za-z%]+$/.test(unit)) extra.push(`sub=${q(unit)}`);
    return [`stat${id} ${value} ${q(label)}${extra.length ? " " + extra.join(" ") : ""}`];
  }

  // table (and send, which on the server is the same rows)
  const header = cols.map((c) => opt(c.name)).join("|");
  const body = rows.map((r) => `"${r.map((v, i) => clean(show(v, cols[i]))).join("|")}"`);
  const units = cols.some((c) => c.unit) ? ` units=${cols.map((c) => (c.unit ? clean(c.unit).replace(/\s+/g, "") : "")).join("|")}` : "";
  const more = (res.count ?? 0) > rows.length ? [`say ${q(`First ${rows.length} of ${res.count}.`)}`] : [];
  return [`table${id} name=${q(title)} ${header} ${body.join(" ")}${units}`, ...more];
}

/** Rows as plain text for the agent to read (a ```tables block, the prompt). */
export function asText(store: TableStore, props: Record<string, unknown>, ctx: Partial<Clock> = {}): string {
  const res = query(store, { limit: LIMITS.read, ...props }, ctx);
  const name = String(props.table ?? "");
  if (res.missing != null) return `No table called ${name}.`;
  if (res.error) return `That query can't run: ${res.error}.`;
  const cols = res.cols!;
  const head = [...(res.keys!.some((k) => k != null) ? ["key"] : []), ...cols.map((c) => c.name + (c.unit ? ` (${c.unit})` : ""))].join(" | ");
  const lines = res.rows!.map((r, i) => [...(res.keys![i] != null ? [res.keys![i]] : []), ...r.map((v, j) => show(v, cols[j]))].join(" | "));
  const more = (res.count ?? 0) > lines.length ? `\n(${res.count} rows match; the first ${lines.length} are here.)` : "";
  return `${head}\n${lines.join("\n") || "(no rows)"}${more}`;
}

// ---------- an answer ----------

export interface Held { id: string; lines: string[]; ask: string }

export interface TablesApplied {
  text: string;
  store: TableStore;
  problems: string[]; // writes that were refused, in plain words
  slipped: string[]; // the tables those refused writes were for ("" when the line named none)
  made: string[]; // tables a put made because they did not exist yet
  held: Held | null; // deletes waiting for the person's tap
  wrote: number;
}

const YUI_BLOCK = /(^```yui[^\n]*\n)([\s\S]*?)(^```[ \t]*$)/gm;

/**
 * Table words the model left outside a yui block: a fence with no tag (or yl, sql) holding them becomes a yui
 * block, and loose `put` / `table create` / `table drop` / `query` lines in the words move into the answer's
 * yui block, so they are applied and never reach the phone as text.
 */
export function gather(text: string): string {
  const isTableLine = (l: string) => !!writeLine(l) || !!queryLine(l);
  let out = text.replace(/^```(?:yl|sql|text)?[ \t]*\n([\s\S]*?)^```[ \t]*$/gm, (m, body: string) =>
    body.split("\n").some(isTableLine) ? "```yui\n" + body + "```" : m);
  const parts = out.split(/(^```[^\n]*\n[\s\S]*?^```[ \t]*$)/m);
  const loose: string[] = [];
  for (let i = 0; i < parts.length; i += 2) {
    parts[i] = parts[i].split("\n").filter((l) => (isTableLine(l) ? (loose.push(l.trim()), false) : true)).join("\n");
  }
  out = parts.join("");
  if (!loose.length) return out;
  const blocks = [...out.matchAll(YUI_BLOCK)];
  if (!blocks.length) return `${out.trim()}\n\`\`\`yui\n${loose.join("\n")}\n\`\`\``;
  const b = blocks[0];
  const at = b.index! + b[1].length;
  return out.slice(0, at) + loose.join("\n") + "\n" + out.slice(at);
}

/**
 * Takes the table words out of every yui block in an answer: writes land in
 * the store (all or nothing per line), deletes wait for a tap, and each
 * `query` (or bare `table <name>`, or `chart data=<name>`) becomes a drawn
 * view of the store after every write.
 */
export function applyTables(text: string, store: TableStore, ctx: Partial<Clock>, newId: () => string): TablesApplied {
  text = gather(text);
  const problems: string[] = [];
  const slipped: string[] = [];
  const made: string[] = [];
  const deletes: TableOp[] = [];
  let wrote = 0;
  const ops: TableOp[] = [];
  for (const m of text.matchAll(YUI_BLOCK)) {
    for (const line of m[2].split("\n")) {
      const op = writeLine(line);
      if (!op) continue;
      if ("error" in op) {
        problems.push(`${op.error}`);
        slipped.push(/^\s*put\s/.test(line) ? line.trim().split(/\s+/)[1] ?? "" : "");
        continue;
      }
      ops.push(op);
    }
  }
  // Writes first, in order, across every block; then draw.
  for (let op of ops) {
    if (op.op === "put") op = { ...op, table: tableName(store, op.table) };
    if (op.op === "drop" || (op.op === "put" && op.delete)) {
      deletes.push(op);
      continue;
    }
    // A put to a table that isn't there makes it, from the columns the answer names for it (YUI-188).
    if (op.op === "put" && !store.tables[op.table]) {
      const r = write(store, { op: "table", name: op.table, cols: inferCols(ops, op.table) }, ctx);
      if (!r.error) {
        store = r.store;
        made.push(op.table);
      }
    }
    const r = mend(store, op, ops, ctx);
    if (r.error) {
      problems.push(r.error);
      slipped.push(op.op === "put" ? op.table : op.name);
    } else if (r.store !== store) wrote++;
    store = r.store;
  }
  let held: Held | null = null;
  const real = deletes.filter((d) => (d.op === "drop" ? !!store.tables[d.name] : d.op === "put" && !!store.tables[d.table]
    && findKey(store.tables[d.table], String(d.key)) != null));
  if (real.length) {
    const id = `del-${newId().replace(/[^A-Za-z0-9]/g, "").slice(0, 8)}`;
    held = { id, lines: real.map((d) => d.line!.trim()), ask: deleteAsk(store, real) };
  }
  let out = text.replace(YUI_BLOCK, (_m, open: string, body: string, close: string) => {
    const lines: string[] = [];
    for (const line of body.split("\n")) {
      if (writeLine(line)) continue;
      const props = queryLine(line) ?? boundLine(line, store);
      if (props) lines.push(...draw(store, props, ctx));
      else lines.push(line);
    }
    const kept = lines.join("\n").replace(/\n{3,}/g, "\n\n");
    return kept.trim() ? `${open}${kept.replace(/\n*$/, "\n")}${close}` : "";
  });
  if (held) {
    // Nothing is gone until the tap: words that say otherwise are replaced.
    const said = out.split(/(^```[^\n]*\n[\s\S]*?^```[ \t]*$)/m);
    if (said.some((p, i) => i % 2 === 0 && /\b(?:gone|deleted|removed|done|off (?:the|your) list)\b/i.test(p))) {
      out = ["Tap Delete to confirm.\n", ...said.filter((_p, i) => i % 2 === 1)].join("").replace(/\n{3,}/g, "\n\n");
    }
    const ask = `choose@${held.id} ${q(held.ask)} Delete|Keep`;
    const blocks = [...out.matchAll(YUI_BLOCK)];
    const lastBlock = blocks[blocks.length - 1];
    out = lastBlock ? out.slice(0, lastBlock.index! + lastBlock[0].length - lastBlock[3].length) + `${ask}\n` + out.slice(lastBlock.index! + lastBlock[0].length - lastBlock[3].length)
      : `${out.trim()}\n\`\`\`yui\n${ask}\n\`\`\``;
  }
  return { text: out.replace(/\n{3,}/g, "\n\n").trim(), store, problems, slipped, made, held, wrote };
}

/**
 * A put the store refuses, mended where the meaning is plain (YUI-188): a column the table doesn't have yet is
 * added (typed by the values), and a value that isn't its column's type is left out so the rest of the row lands.
 * Anything else is refused as before.
 */
function mend(store: TableStore, op: TableOp, ops: TableOp[], ctx: Partial<Clock>): WriteResult {
  const was = store;
  let r = write(store, op, ctx);
  if (op.op !== "put" || op.delete) return r;
  let put = op;
  for (let tries = 0; r.error && tries < LIMITS.cols; tries++) {
    const t = store.tables[put.table];
    const noCol = r.error.match(/^put: \S+ has no column "(.+)"$/);
    const badVal = r.error.match(/^put: ([^:]+): /);
    if (t && noCol && t.cols.length < LIMITS.cols && COL.test(noCol[1]) && noCol[1].toLowerCase() !== "key") {
      const col = inferCols(ops.filter((o) => o.op === "put" && o.table.toLowerCase() === put.table.toLowerCase()), put.table)
        .find((c) => c.name.toLowerCase() === noCol[1].toLowerCase()) ?? { name: noCol[1], type: "text" as ColType };
      const grown = write(store, { op: "table", name: t.name, cols: [...t.cols, col] }, ctx);
      if (grown.error) break;
      store = grown.store;
    } else if (badVal && Object.keys(put.values).length > 1) {
      const drop = Object.keys(put.values).find((k) => k.toLowerCase() === badVal[1].toLowerCase());
      if (!drop) break;
      const { [drop]: _gone, ...rest } = put.values;
      put = { ...put, values: rest };
    } else break;
    r = write(store, put, ctx);
  }
  return r.error ? { store: was, error: r.error } : r;
}

/**
 * The table a put means: its own name, or the one there is in another case or number ("Groceries",
 * "grocery" and "groceries" are one list). A name with no match stays as written.
 */
export function tableName(store: TableStore, name: string): string {
  if (store.tables[name]) return name;
  const forms = (n: string) => {
    const low = n.toLowerCase().replace(/[\s-]+/g, "_");
    const one = low.replace(/ies$/, "y").replace(/(ch|sh|x|ss)es$/, "$1").replace(/s$/, "");
    return [low, one];
  };
  const [low, one] = forms(name);
  const names = Object.keys(store.tables);
  return names.find((n) => forms(n)[0] === low) ?? names.find((n) => forms(n)[1] === one) ?? name;
}

/** Columns for a table a put makes: every column the answer's puts name for it, in order, typed by their values. */
export function inferCols(ops: TableOp[], table: string): TableCol[] {
  const seen = new Map<string, unknown[]>();
  for (const op of ops) {
    if (op.op !== "put" || op.delete || op.table.toLowerCase() !== table.toLowerCase()) continue;
    for (const [k, v] of Object.entries(op.values)) {
      const had = [...seen.keys()].find((x) => x.toLowerCase() === k.toLowerCase());
      if (had) seen.get(had)!.push(v);
      else if (COL.test(k) && k.toLowerCase() !== "key") seen.set(k, [v]);
    }
  }
  const typeOf = (vs: unknown[]): ColType => {
    const filled = vs.filter((v) => v !== "" && v != null);
    if (!filled.length) return "text";
    const all = (t: ColType) => filled.every((v) => !cell(t, v).error);
    if (filled.every((v) => typeof v === "boolean" || /^(on|off|yes|no|true|false)$/i.test(String(v)))) return "bool";
    if (all("number")) return "number";
    if (all("date")) return "date";
    return "text";
  };
  return [...seen].slice(0, LIMITS.cols).map(([name, vs]) => ({ name, type: typeOf(vs) }));
}

/** `table meals` (bound, no header) or `chart ... data=meals` on one of the agent's tables, as a query. */
function boundLine(line: string, store: TableStore): Record<string, unknown> | null {
  const b = line.trim().match(/^table(@[\w-]+)?\s+([A-Za-z][\w-]*)\s*$/);
  if (b && store.tables[b[2]]) return { table: b[2], ...(b[1] ? { id: b[1].slice(1) } : {}) };
  const c = line.trim();
  if (/^chart(?:@[\w-]+)?\s/.test(c) && /\sdata=([A-Za-z][\w-]*)/.test(c)) {
    const name = c.match(/\sdata=([A-Za-z][\w-]*)/)![1];
    if (!store.tables[name]) return null;
    const p = queryLine(`query ${name} ${c.replace(/^chart(@[\w-]+)?\s/, "").replace(/\sdata=\S+/, "")}`)!;
    const id = c.match(/^chart@([\w-]+)/)?.[1];
    const type = String(p.title ?? "").split(" ")[0];
    if (CHART_TYPES.has(type)) {
      p.type = type;
      p.title = String(p.title).split(" ").slice(1).join(" ") || undefined;
    }
    return { ...p, as: "chart", ...(id ? { id } : {}) };
  }
  return null;
}

export function deleteAsk(store: TableStore, ops: TableOp[]): string {
  const drops = ops.filter((o): o is Extract<TableOp, { op: "drop" }> => o.op === "drop");
  const puts = ops.filter((o): o is Extract<TableOp, { op: "put" }> => o.op === "put");
  if (drops.length && !puts.length) {
    return drops.length === 1 ? `Delete the ${pretty(drops[0].name).toLowerCase()} table and everything in it?` : `Delete ${drops.length} tables and everything in them?`;
  }
  const tables = [...new Set(puts.map((p) => p.table))];
  if (puts.length === 1 && !drops.length) {
    const t = store.tables[puts[0].table];
    const k = findKey(t, String(puts[0].key))!;
    const first = t.cols.find((c) => c.type === "text");
    const what = (first && t.rows[k]?.[first.name]) || k;
    return `Delete ${clean(String(what))} from ${pretty(puts[0].table).toLowerCase()}?`;
  }
  return `Delete ${puts.length} row${puts.length > 1 ? "s" : ""} from ${tables.map((x) => pretty(x).toLowerCase()).join(" and ")}${drops.length ? `, and ${drops.length} table${drops.length > 1 ? "s" : ""}` : ""}?`;
}

/** Runs deletes the person said yes to. */
export function applyHeld(store: TableStore, lines: string[], ctx: Partial<Clock> = {}): { store: TableStore; done: number } {
  let done = 0;
  for (const line of lines) {
    let op = writeLine(line);
    if (!op || "error" in op) continue;
    if (op.op === "put") op = { ...op, table: tableName(store, op.table) };
    const r = write(store, op, ctx);
    if (!r.error && r.store !== store) done++;
    store = r.store;
  }
  return { store, done };
}

/** The read block: query lines alone, answered before the agent answers the person. */
export function readQueries(body: string): Record<string, unknown>[] {
  return body.split("\n").map((l) => l.trim()).filter(Boolean).map((l) => queryLine(/^query/.test(l) ? l : `query ${l}`))
    .filter((p): p is Record<string, unknown> => !!p).slice(0, 4);
}

// ---------- the prompt ----------

export function tablesPrompt(store: TableStore, ctx: Partial<Clock> = {}): string {
  const names = Object.keys(store.tables);
  if (!names.length) return "## Your tables\nNone yet. Make one when the person wants to keep a list or a log.";
  const out = ["## Your tables"];
  for (const n of names) {
    const t = store.tables[n];
    const cols = t.cols.map((c) => `${c.name}:${c.type}${c.unit ? `:${c.unit}` : ""}`).join(" ");
    out.push(`- ${n} (${t.order.length} row${t.order.length === 1 ? "" : "s"}): ${cols}`);
    const keys = t.order.slice(-LIMITS.prompt);
    for (const k of keys) {
      const cells = t.cols.map((c) => (t.rows[k][c.name] == null ? null : `${c.name}=${show(t.rows[k][c.name], c)}`)).filter(Boolean);
      out.push(`  [${k}] ${cells.join(", ")}`);
    }
    if (t.order.length > keys.length) out.push(`  (the newest ${keys.length}; read the rest with a tables block)`);
  }
  void ctx;
  return out.join("\n");
}

// ---------- seeds and saving ----------

/** A profile's tables.yui (table create and put lines) as seeds. Throws on any line the store refuses. */
export function parseSeeds(base: string, text: string): TableSeed[] {
  let store = emptyStore();
  for (const [i, raw] of text.split("\n").entries()) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const op = writeLine(line);
    if (!op) throw new Error(`${base}/tables.yui line ${i + 1}: only table create and put lines`);
    if ("error" in op) throw new Error(`${base}/tables.yui line ${i + 1}: ${op.error}`);
    if (op.op === "drop" || (op.op === "put" && op.delete)) throw new Error(`${base}/tables.yui line ${i + 1}: no deletes in seeds`);
    // Seeds are written by SQL at provisioning, which reads no date words: a seed says what it means.
    if (/\b(?:today|now)\b/i.test(line.replace(/"(?:[^"\\]|\\.)*"/g, ""))) throw new Error(`${base}/tables.yui line ${i + 1}: no today or now in seeds`);
    const r = write(store, op);
    if (r.error) throw new Error(`${base}/tables.yui line ${i + 1}: ${r.error}`);
    store = r.store;
  }
  return Object.values(store.tables).map((t) => ({ name: t.name, cols: t.cols, next: t.next,
    rows: t.order.map((k) => ({ key: k, values: t.rows[k] })) }));
}

export function fromSeeds(seeds: TableSeed[] | undefined): TableStore {
  const out = emptyStore();
  for (const s of seeds ?? []) {
    out.tables[s.name] = { name: s.name, cols: s.cols.map((c) => ({ ...c })), next: s.next,
      rows: Object.fromEntries(s.rows.map((r) => [r.key, { ...r.values }])), order: s.rows.map((r) => r.key) };
  }
  return out;
}

/** What changed between two stores, for a store that keeps rows (Postgres). */
export interface TableChange {
  tables: { name: string; cols: TableCol[]; next: number }[]; // made or changed
  dropTables: string[];
  rows: { table: string; key: string; values: Record<string, Cell>; isNew: boolean }[]; // in table order
  dropRows: { table: string; key: string }[];
}

export function diff(before: TableStore, after: TableStore): TableChange {
  const ch: TableChange = { tables: [], dropTables: [], rows: [], dropRows: [] };
  for (const name of Object.keys(before.tables)) if (!after.tables[name]) ch.dropTables.push(name);
  for (const [name, t] of Object.entries(after.tables)) {
    const old = before.tables[name];
    if (old === t) continue;
    if (!old || old.next !== t.next || JSON.stringify(old.cols) !== JSON.stringify(t.cols)) ch.tables.push({ name, cols: t.cols, next: t.next });
    for (const k of t.order) {
      if (!old || old.rows[k] !== t.rows[k]) ch.rows.push({ table: name, key: k, values: t.rows[k], isNew: !old || !(k in old.rows) });
    }
    if (old) for (const k of old.order) if (!(k in t.rows)) ch.dropRows.push({ table: name, key: k });
  }
  return ch;
}

export function changed(ch: TableChange): boolean {
  return !!(ch.tables.length || ch.dropTables.length || ch.rows.length || ch.dropRows.length);
}
