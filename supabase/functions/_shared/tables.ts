// Tables for any agent (YUI-171, yuigui spec/TABLES.md section 8): the one
// server path behind yui-connect /tables and the yui-mcp tool yui_tables. The
// Hermes plugin's yui_tables tool calls yui-connect; an MCP client calls
// yui-mcp; both end here, on the store native agents keep (YUI-170,
// _native/tables.ts, yui_native_tables). No adapter talks to the database and
// there is no second copy of the rules.
//
// One call, for one agent the caller serves:
//   1. takes from the agent's `tables` bucket (60 a minute);
//   2. settles deletes waiting on a tap: the person's Delete runs them, Keep
//      or a week with no tap drops them;
//   3. runs `lines` (the agent's table words, in order) or `reply` (a whole
//      answer, the native way: queries drawn into screens);
//   4. refuses the whole call past a limit (50 lines, 100 tables a person),
//      writing nothing;
//   5. saves what changed, marks what was read, and puts any delete in front of
//      the person as a Delete or Keep ask.
import { SupabaseStore } from "../_native/supabase.ts";
import { validZone } from "../_native/schedule.ts";
import { changed, clock, diff, type TableStore } from "../_native/tables.ts";
import {
  CALL_LIMITS,
  callLines,
  holdAsk,
  holding,
  holdTap,
  refuseCall,
  runLines,
  runReply,
  settleHold,
} from "../_native/tablecall.ts";
import { take } from "./yui.ts";

// deno-lint-ignore no-explicit-any
type DB = any;
// deno-lint-ignore no-explicit-any
type Json = any;

export interface TablesAgent { id: string; user_id: string; name: string }
export interface TablesInput {
  lines?: unknown;
  reply?: unknown;
  via: string; // "hermes", "mcp", ... (kept on the ask it writes)
  token?: string; // the caller's bearer, to buzz the phone for a delete ask
}

/** A call the caller can fix: 400 with the reason, nothing written. */
export class TablesRefused extends Error {
  constructor(public code: string, message: string) {
    super(message);
  }
}

const HOLD_MS = CALL_LIMITS.holdDays * 24 * 3600_000;

function storeFor(): SupabaseStore {
  return new SupabaseStore(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
}

export async function tablesCall(db: DB, agent: TablesAgent, input: TablesInput): Promise<Json> {
  const hasLines = typeof input.lines === "string";
  const hasReply = typeof input.reply === "string";
  if (hasLines && hasReply) throw new TablesRefused("invalid_request", "Send lines or reply, not both.");
  if (input.lines != null && !hasLines) throw new TablesRefused("invalid_request", "lines is a string of table lines.");
  if (input.reply != null && !hasReply) throw new TablesRefused("invalid_request", "reply is the whole answer as a string.");
  const lines = hasLines ? callLines(input.lines as string) : [];
  const refused = refuseCall(lines);
  if (refused) throw new TablesRefused("too_many_lines", refused);
  if (hasReply && (input.reply as string).length > 32000) throw new TablesRefused("too_long", "reply is 32000 characters at most.");

  await take(db, `tables:a:${agent.id}`, "tables");
  const store = storeFor();
  const clk = clock(Date.now(), validZone(await store.timezone(agent.user_id)));
  const native = { id: agent.id, userId: agent.user_id, profile: {} as Json };
  const newId = () => crypto.randomUUID();

  // Deletes waiting on a tap, settled before anything else reads the tables.
  let tables: TableStore = await store.tables(agent.id);
  const settled: { id: string; choice: string; deleted: number }[] = [];
  const { data: holds, error: hErr } = await db.from("yui_table_holds").select("id, lines, created_at")
    .eq("agent_id", agent.id).is("done_at", null).order("created_at");
  if (hErr) throw hErr;
  for (const h of holds ?? []) {
    const { data: taps, error } = await db.from("yui_messages").select("body")
      .eq("agent_id", agent.id).eq("user_id", agent.user_id).eq("sender", "user")
      .gte("created_at", h.created_at).like("body", `[yui] ${h.id} %`)
      .order("created_at", { ascending: false }).limit(5);
    if (error) throw error;
    const tap = (taps ?? []).map((t: Json) => holdTap(t.body)).find((t: Json) => t?.id === h.id);
    let choice: string | null = tap?.choice ?? null;
    let deleted = 0;
    if (!choice && Date.now() - Date.parse(h.created_at) > HOLD_MS) choice = "expired";
    if (!choice) continue;
    if (choice === "Delete") {
      const done = settleHold(tables, h.lines, clk);
      const ch = diff(tables, done.store);
      if (changed(ch)) await store.saveTables(native, ch, done.store);
      tables = done.store;
      deleted = done.done;
    }
    await db.from("yui_table_holds").update({ done_at: new Date().toISOString(), choice })
      .eq("agent_id", agent.id).eq("id", h.id);
    settled.push({ id: h.id, choice, deleted });
  }

  const before = tables;
  let out: Json;
  let after: TableStore;
  let held: { id: string; lines: string[]; ask: string } | null;
  let read: string[] = [];
  if (hasReply) {
    const r = runReply(input.reply as string, tables, clk, newId);
    after = r.store;
    held = r.held;
    out = { text: r.text, failed: r.problems.map((error) => ({ line: "", error })), wrote: r.wrote };
  } else {
    const r = runLines(lines, tables, clk, newId);
    after = r.store;
    held = r.held;
    read = r.read;
    out = { ok: r.ok, failed: r.failed, results: r.results };
  }

  const made = Object.keys(after.tables).filter((n) => !before.tables[n]).length;
  if (made) {
    const { count, error } = await db.from("yui_native_tables").select("name", { count: "exact", head: true })
      .eq("user_id", agent.user_id).neq("agent_id", agent.id);
    if (error) throw error;
    if ((count ?? 0) + Object.keys(after.tables).length > CALL_LIMITS.tablesPerPerson) {
      throw new TablesRefused("limit", `${CALL_LIMITS.tablesPerPerson} tables per person across all their agents; `
        + `they have ${(count ?? 0) + Object.keys(before.tables).length}. Nothing was written.`);
    }
  }

  const ch = diff(before, after);
  if (changed(ch)) await store.saveTables(native, ch, after);
  if (read.length) {
    await db.from("yui_native_tables").update({ read_at: new Date().toISOString() })
      .eq("agent_id", agent.id).in("name", read);
  }

  let hold: Json = null;
  if (held) {
    let messageId: string | null = null;
    if (!hasReply) {
      // A call has no answer to carry the ask: it goes into the thread on its own.
      const { data: msg, error } = await db.from("yui_messages").insert({
        user_id: agent.user_id, agent_id: agent.id, sender: "agent", kind: "text",
        body: holdAsk(held), meta: { via: input.via, tables_hold: held.id },
      }).select("id").single();
      if (error) throw error;
      messageId = msg.id;
      if (input.token) await buzz(input.token, msg.id);
    }
    const { error } = await db.from("yui_table_holds").insert({
      id: held.id, agent_id: agent.id, user_id: agent.user_id, lines: held.lines, ask: held.ask.slice(0, 300),
      message_id: messageId,
    });
    if (error) throw error;
    hold = { id: held.id, ask: held.ask, lines: held.lines, waiting: true, ...(messageId ? { message_id: messageId } : {}) };
  }

  return { agent: agent.name, ...out, held: hold, settled, tables: holding(after) };
}

async function buzz(token: string, messageId: string): Promise<void> {
  try {
    await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/yui-push`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
      body: JSON.stringify({ action: "notify", message_id: messageId, handoff: false }),
      signal: AbortSignal.timeout(5000),
    });
  } catch (e) {
    console.error("tables buzz", e);
  }
}

/** Plain words for a model reading a tool result. */
export function tablesSummary(r: Json): string {
  const parts: string[] = [];
  for (const s of r.settled ?? []) {
    parts.push(s.choice === "Delete" ? `The person tapped Delete on ${s.id}: ${s.deleted} gone.`
      : s.choice === "Keep" ? `The person tapped Keep on ${s.id}: nothing deleted.` : `${s.id} waited a week with no tap: nothing deleted.`);
  }
  if (r.text !== undefined) parts.push(`Reply ready (${r.wrote} write${r.wrote === 1 ? "" : "s"}); send the text as your answer.`);
  if (r.ok?.length) parts.push(`${r.ok.length} line${r.ok.length === 1 ? "" : "s"} done.`);
  for (const f of r.failed ?? []) parts.push(`Refused${f.line ? ` "${f.line}"` : ""}: ${f.error}.`);
  if (r.held) parts.push(`Nothing deleted yet: the person sees "${r.held.ask}" with Delete or Keep. Their tap settles it on your next yui_tables call.`);
  if (!r.ok?.length && !r.failed?.length && r.text === undefined && !r.held) {
    parts.push(r.tables?.length
      ? "You hold: " + r.tables.map((t: Json) => `${t.name} (${t.rows} rows: ${t.cols.join(", ")})`).join(", ")
      : "You hold no tables yet.");
  }
  return parts.join(" ");
}
