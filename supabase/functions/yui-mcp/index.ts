// yui-mcp: the Yui MCP server (INT-3). Spec: yuigui/spec/MCP.md, path D in
// yuigui/spec/ADAPTERS.md. Any MCP client (Claude Code, Claude, ChatGPT,
// Cursor, n8n) puts a screen on the person's phone with a tool call, and reads
// their taps back. The conversation stays in the other app; Yui is the second
// screen.
//
// Transport: MCP streamable HTTP, stateless. One POST per JSON-RPC message
// (or batch), answered with application/json. No sessions, no SSE, so GET and
// DELETE answer 405.
//
// Auth (step 1): Bearer yui_ct_..., a connector token of kind 'mcp', minted by
// the same pairing as every host (yui-connect pair with kind "mcp"). OAuth
// (Sign in with Apple through Yui) is step 2. A bad token answers 401, a
// suspended host or account 403, an empty rate bucket (`mcp` in yui_limits)
// 429.
//
// Tools:
//   yui_show     Yui Lines -> one agent row in the thread; returns its id (the
//                screen id) and the ids its taps will carry. Lines that do not
//                parse are refused with the parser's message, nothing is sent.
//   yui_answers  What the person sent back (taps and typed text), oldest first,
//                optionally waiting up to 25 s. Each row is returned once: it
//                is marked delivered and handled.
//   yui_say      A plain message.
//   yui_threads  The agents this token serves, with unread counts.
// The channel guide: short form in the tool descriptions, the full text as the
// prompt `yui_guide` and the resource `yui://guide`.
import {
  admin,
  bearer,
  CONNECTOR_PREFIX,
  failure,
  Refused,
  sha256Hex,
  take,
} from "../_shared/yui.ts";
import { parse } from "./yl.mjs";

const VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];
const SERVER = { name: "yui", title: "Yui", version: "0.1.0" };
const MAX_BODY = 32000;
const MAX_WAIT = 25;
const SIGN_SECONDS = 3600;
const USER_PATH = /[0-9a-f-]{36}\/[0-9a-f-]{36}\/user\/[A-Za-z0-9._-]{1,80}/g;

// deno-lint-ignore no-explicit-any
type Json = any;
// deno-lint-ignore no-explicit-any
type DB = any;
type Connector = { id: string; user_id: string; name: string; token: string };
type Agent = { id: string; name: string; handle: string; remote_ref: string | null };

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "POST, OPTIONS",
  "access-control-allow-headers": "authorization, content-type, accept, mcp-protocol-version, mcp-session-id",
  "access-control-expose-headers": "mcp-session-id, www-authenticate",
};

function reply(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(body === null ? null : JSON.stringify(body), {
    status,
    headers: { ...CORS, ...(body === null ? {} : { "content-type": "application/json" }), ...extra },
  });
}

const rpcError = (id: Json, code: number, message: string) => ({ jsonrpc: "2.0", id: id ?? null, error: { code, message } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return reply(null, 204);
  if (req.method !== "POST") return reply(rpcError(null, -32000, "Use POST (stateless server, no SSE stream)"), 405, { allow: "POST" });
  let msg: Json;
  try {
    msg = await req.json();
  } catch {
    return reply(rpcError(null, -32700, "Parse error"), 400);
  }
  const db = admin();
  let c: Connector | null;
  try {
    c = await connectorFor(db, req);
  } catch (e) {
    if (e instanceof Refused) return reply(rpcError(null, -32000, e.code), e.status);
    return failure("yui-mcp auth", e);
  }
  if (!c) {
    return reply(rpcError(null, -32001, "Unauthorized: pair with a code from the Yui app, then send Authorization: Bearer yui_ct_..."),
      401, { "www-authenticate": 'Bearer realm="yui", error="invalid_token"' });
  }
  const batch = Array.isArray(msg);
  const out = [];
  for (const m of batch ? msg : [msg]) {
    const r = await handle(db, c, m);
    if (r) out.push(r);
  }
  if (!out.length) return reply(null, 202); // notifications and responses only
  return reply(batch ? out : out[0]);
});

// The connector behind the bearer token: kind mcp, not revoked, not suspended.
// Every authenticated request takes one token from its `mcp` bucket.
async function connectorFor(db: DB, req: Request): Promise<Connector | null> {
  const token = bearer(req);
  if (!token.startsWith(CONNECTOR_PREFIX)) return null;
  const { data } = await db.from("yui_connectors").select("id, user_id, name, kind, suspended_at")
    .eq("token_hash", await sha256Hex(token)).is("revoked_at", null).maybeSingle();
  if (!data) return null;
  if (data.kind !== "mcp") throw new Refused(403, "not_an_mcp_connector");
  const { data: owner } = await db.from("yui_users").select("suspended_at").eq("id", data.user_id).maybeSingle();
  if (data.suspended_at || owner?.suspended_at) throw new Refused(403, "suspended");
  await take(db, `mcp:c:${data.id}`, "mcp");
  await db.from("yui_connectors").update({ last_seen_at: new Date().toISOString(), stopped_at: null }).eq("id", data.id);
  return { id: data.id, user_id: data.user_id, name: data.name, token };
}

async function handle(db: DB, c: Connector, m: Json): Promise<Json | null> {
  if (!m || typeof m !== "object" || m.jsonrpc !== "2.0") return rpcError(m?.id, -32600, "Invalid Request");
  if (m.method === undefined) return null; // a response to us; we never ask anything
  const notification = m.id === undefined || m.id === null;
  try {
    const result = await dispatch(db, c, m.method, m.params ?? {});
    return notification ? null : { jsonrpc: "2.0", id: m.id, result };
  } catch (e) {
    if (notification) return null;
    if (e instanceof RpcError) return rpcError(m.id, e.code, e.message);
    console.error("yui-mcp", m.method, e);
    return rpcError(m.id, -32603, "Internal error");
  }
}

class RpcError extends Error {
  constructor(public code: number, message: string) {
    super(message);
  }
}

async function dispatch(db: DB, c: Connector, method: string, p: Json): Promise<Json> {
  switch (method) {
    case "initialize":
      return {
        protocolVersion: VERSIONS.includes(p.protocolVersion) ? p.protocolVersion : VERSIONS[1],
        capabilities: { tools: { listChanged: false }, prompts: { listChanged: false }, resources: { listChanged: false } },
        serverInfo: SERVER,
        instructions: INSTRUCTIONS,
      };
    case "ping":
      return {};
    case "notifications/initialized":
    case "notifications/cancelled":
      return {};
    case "tools/list":
      return { tools: TOOLS };
    case "tools/call":
      return await callTool(db, c, p.name, p.arguments ?? {});
    case "prompts/list":
      return { prompts: [{ name: "yui_guide", title: "Yui channel guide", description: GUIDE_BLURB }] };
    case "prompts/get": {
      if (p.name !== "yui_guide") throw new RpcError(-32602, `Unknown prompt: ${p.name}`);
      const g = await guide(db);
      return { description: GUIDE_BLURB, messages: [{ role: "user", content: { type: "text", text: g.text } }] };
    }
    case "resources/list":
      return { resources: [{ uri: "yui://guide", name: "yui_guide", title: "Yui channel guide", description: GUIDE_BLURB, mimeType: "text/markdown" }] };
    case "resources/templates/list":
      return { resourceTemplates: [] };
    case "resources/read": {
      if (p.uri !== "yui://guide") throw new RpcError(-32002, `Resource not found: ${p.uri}`);
      const g = await guide(db);
      return { contents: [{ uri: "yui://guide", mimeType: "text/markdown", text: g.text }] };
    }
    default:
      throw new RpcError(-32601, `Method not found: ${method}`);
  }
}

// -- tools --------------------------------------------------------------------

// A problem the model can fix: comes back as a tool result with isError.
class ToolError extends Error {}

const ok = (text: string, data: Json) => ({ content: [{ type: "text", text: `${text}\n${JSON.stringify(data)}` }] });
const bad = (text: string) => ({ content: [{ type: "text", text }], isError: true });

async function callTool(db: DB, c: Connector, name: string, a: Json): Promise<Json> {
  try {
    switch (name) {
      case "yui_show":
        return await show(db, c, a);
      case "yui_answers":
        return await answers(db, c, a);
      case "yui_say":
        return await say(db, c, a);
      case "yui_threads":
        return await threads(db, c);
      default:
        throw new RpcError(-32602, `Unknown tool: ${name}`);
    }
  } catch (e) {
    if (e instanceof RpcError) throw e;
    if (e instanceof ToolError) return bad(e.message);
    const code = (e as { code?: string })?.code ?? "";
    if (e instanceof Refused || /^PT429$/.test(code)) {
      return bad(code === "PT429" || (e as Refused).status === 429
        ? "Rate limited: too many messages. Wait a minute and try again."
        : `Refused: ${(e as Error).message}`);
    }
    if (/^PT403$/.test(code)) return bad("This Yui account is switched off.");
    throw e;
  }
}

async function agents(db: DB, c: Connector): Promise<Agent[]> {
  const { data, error } = await db.from("yui_agents").select("id, name, handle, remote_ref")
    .eq("connector_id", c.id).eq("user_id", c.user_id).order("sort");
  if (error) throw error;
  return data ?? [];
}

// The agent a call is for: the `agent` argument (id, handle, ref or name), or
// the first one this token serves.
async function pick(db: DB, c: Connector, want: unknown): Promise<Agent> {
  const list = await agents(db, c);
  if (!list.length) throw new ToolError("This token serves no agent any more. Add the agent again in the Yui app and pair.");
  if (want === undefined || want === null || want === "") return list[0];
  const w = String(want).toLowerCase();
  const a = list.find((x) => [x.id, x.handle, x.remote_ref, x.name].some((v) => (v ?? "").toLowerCase() === w));
  if (!a) throw new ToolError(`No agent "${want}". Call yui_threads for the list.`);
  return a;
}

// A fence the model wrapped around its lines anyway comes off.
function unfence(s: string): string {
  const m = s.match(/```(?:yui)?[^\n]*\n([\s\S]*?)```/);
  return (m ? m[1] : s).trim();
}

async function write(db: DB, c: Connector, agent: Agent, body: string): Promise<{ id: string; created_at: string }> {
  const { data, error } = await db.from("yui_messages").insert({
    user_id: c.user_id,
    agent_id: agent.id,
    sender: "agent",
    kind: "text",
    body,
    meta: { via: "mcp" },
  }).select("id, created_at").single();
  if (error) throw error;
  await notify(c, data.id);
  return data;
}

// Buzz the phone. yui-push skips it when that thread is already open.
async function notify(c: Connector, messageId: string): Promise<void> {
  try {
    await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/yui-push`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${c.token}` },
      body: JSON.stringify({ action: "notify", message_id: messageId, handoff: false }),
      signal: AbortSignal.timeout(5000),
    });
  } catch (e) {
    console.error("yui-mcp notify", e);
  }
}

async function show(db: DB, c: Connector, a: Json): Promise<Json> {
  if (typeof a.lines !== "string" || !a.lines.trim()) return bad("`lines` is required: Yui Lines, one component per line.");
  const lines = unfence(a.lines);
  const ops = parse(lines);
  const errors = ops.filter((o: Json) => o.op === "error");
  if (errors.length) {
    return bad("Nothing was sent. Fix these lines and call yui_show again:\n" +
      errors.map((o: Json) => `- ${o.line.trim()}\n  ${o.message}`).join("\n"));
  }
  if (!ops.length) return bad("Nothing to show: `lines` holds no Yui Lines.");
  const text = typeof a.text === "string" ? a.text.trim() : "";
  const body = `${text ? text + "\n" : ""}\`\`\`yui\n${lines}\n\`\`\``;
  if (body.length > MAX_BODY) return bad(`Too long: ${body.length} characters, the limit is ${MAX_BODY}.`);
  const agent = await pick(db, c, a.agent);
  const row = await write(db, c, agent, body);
  const ids = ops.filter((o: Json) => o.op === "add").map((o: Json) => ({ id: o.id, preset: o.preset }));
  return ok(
    `On ${agent.name}'s screen in Yui. Screen id ${row.id}. Taps come back as [yui] <id> <preset> key=value; ` +
      `read them with yui_answers(screen_id="${row.id}", wait=25).`,
    { screen_id: row.id, agent: agent.name, ids },
  );
}

async function say(db: DB, c: Connector, a: Json): Promise<Json> {
  const text = typeof a.text === "string" ? a.text.trim() : "";
  if (!text) return bad("`text` is required.");
  if (text.length > MAX_BODY) return bad(`Too long: ${text.length} characters, the limit is ${MAX_BODY}.`);
  const agent = await pick(db, c, a.agent);
  const row = await write(db, c, agent, text);
  return ok(`Sent to ${agent.name}'s thread in Yui.`, { message_id: row.id, agent: agent.name });
}

async function answers(db: DB, c: Connector, a: Json): Promise<Json> {
  let agent: Agent;
  let since: string | null = null;
  if (a.screen_id) {
    if (typeof a.screen_id !== "string" || !/^[0-9a-f-]{36}$/i.test(a.screen_id)) return bad("`screen_id` is the id yui_show returned.");
    const list = await agents(db, c);
    const { data: screen } = await db.from("yui_messages").select("agent_id, created_at")
      .eq("id", a.screen_id).eq("user_id", c.user_id).eq("sender", "agent").maybeSingle();
    const found = screen && list.find((x) => x.id === screen.agent_id);
    if (!found) return bad(`No screen ${a.screen_id} in a thread this token serves.`);
    agent = found;
    since = screen.created_at;
  } else {
    agent = await pick(db, c, a.agent);
  }
  const wait = Math.max(0, Math.min(MAX_WAIT, Number(a.wait) || 0));
  const end = Date.now() + wait * 1000;
  let rows: Json[] = [];
  for (;;) {
    let q = db.from("yui_messages").select("id, body, kind, meta, created_at")
      .eq("agent_id", agent.id).eq("user_id", c.user_id).eq("sender", "user").is("handled_at", null)
      .order("created_at", { ascending: true }).order("id", { ascending: true }).limit(50);
    if (since) q = q.gt("created_at", since);
    const { data, error } = await q;
    if (error) throw error;
    rows = data ?? [];
    if (rows.length || Date.now() >= end) break;
    await new Promise((r) => setTimeout(r, 1000));
  }
  if (rows.length) {
    const now = new Date().toISOString();
    const ids = rows.map((r) => r.id);
    await db.from("yui_messages").update({ delivered_at: now }).in("id", ids).is("delivered_at", null);
    await db.from("yui_messages").update({ handled_at: now }).in("id", ids);
  }
  const out = [];
  for (const r of rows) {
    const item: Json = { id: r.id, at: r.created_at, kind: r.kind, text: r.body };
    if (r.kind === "event") item.event = r.meta;
    const photos = await signPhotos(db, c, agent, r);
    if (photos.length) item.photos = photos;
    out.push(item);
  }
  const head = out.length
    ? out.map((x) => (x.kind === "event" ? x.text : `They wrote: ${x.text}`)).join("\n")
    : wait
    ? `Nothing yet from ${agent.name}'s thread after ${wait} s. Call again to keep waiting.`
    : `Nothing new in ${agent.name}'s thread.`;
  return ok(head, { agent: agent.name, answers: out });
}

// The person's photos live in the private bucket; hand the model an hour-long
// link, only for files in this thread.
async function signPhotos(db: DB, c: Connector, agent: Agent, r: Json): Promise<string[]> {
  const own = `${c.user_id}/${agent.id}/user/`;
  const paths = [...new Set([...(r.body + JSON.stringify(r.meta ?? {})).matchAll(USER_PATH)].map((m) => m[0]))]
    .filter((p) => p.startsWith(own));
  const urls = [];
  for (const p of paths) {
    const { data } = await db.storage.from("yui-media").createSignedUrl(p, SIGN_SECONDS);
    if (data?.signedUrl) urls.push(data.signedUrl);
  }
  return urls;
}

async function threads(db: DB, c: Connector): Promise<Json> {
  const list = await agents(db, c);
  const out = [];
  for (const a of list) {
    const { count } = await db.from("yui_messages").select("id", { count: "exact", head: true })
      .eq("agent_id", a.id).eq("user_id", c.user_id).eq("sender", "user").is("handled_at", null);
    out.push({ agent: a.name, handle: a.handle, ref: a.remote_ref, id: a.id, unread: count ?? 0 });
  }
  return ok(
    out.length ? out.map((x, i) => `${x.agent} (${x.handle})${i === 0 ? ", the default" : ""}: ${x.unread} unread`).join("\n")
      : "This token serves no agent.",
    { threads: out },
  );
}

// -- the channel guide ----------------------------------------------------------

const GUIDE_BLURB = "How to talk in Yui: every screen you can draw with Yui Lines, how taps come back, and the rules.";

const MCP_PREAMBLE = `You reach Yui through MCP tools, not a chat channel. Where the guide below says to write a \`\`\`yui block, call yui_show with those lines in \`lines\` (no fence) and any short chat text in \`text\`. Taps and anything the person types come back from yui_answers. Plain messages go through yui_say. Hermes-only parts (hermes yui media, board=<profile>) do not apply here.\n\n`;

async function guide(db: DB): Promise<{ version: string; text: string }> {
  const { data } = await db.from("yui_channel_guides").select("version, body")
    .order("created_at", { ascending: false }).limit(1).maybeSingle();
  if (!data) throw new RpcError(-32603, "The channel guide is not published yet.");
  return { version: data.version, text: MCP_PREAMBLE + data.body };
}

const INSTRUCTIONS = `Yui is an app on the person's phone that draws what you send as native screens: buttons, pickers, sliders, forms, timers, cards, charts, decks. The conversation stays here; Yui is their second screen. Use yui_show when a screen beats text (a choice, a timer, a check-in, a plan), then yui_answers with wait=25 to get their taps. Read the yui_guide prompt (or resource yui://guide) for the full grammar. Never ask for passwords, keys or card numbers on a screen.`;

const SHOW_DESC = `Put a screen on the person's phone in Yui. \`lines\` is Yui Lines: one component per line, no fence. Returns the screen id and the ids its taps will carry; then call yui_answers(screen_id, wait=25).

Components:
- buttons: ask "Log this set?" | ask "Which slot?" "3:00 pm"|"4:00 pm"
- one choice: choose "Split?" Push|Pull|Legs +other; several: pick "Gear" DB|Bench|Bands
- scale: slide "How sore?" 1-5 Fresh|Wrecked; facts: form "Check-in" sleep:1-10 goal:voice
- items: list Today "Squat 5x5" "Bench 5x5" +check; rows: table Tiers Plan|Price "Starter|$500"
- highlight: card "Sunday plan" body="3 sessions" cta="Start"; link: card "Docs" cta="Open" url=https://...
- time: timer 40/20x8 Tabata (work/rest x rounds), timer 5m Plank
- numbers: stat 178.9lb Weight delta=-2.3; chart line "Weight" x=Mon|Tue y=180|179
- media: image https://... caption; gallery URL URL +pick; video URL
- flows: plan "Title" then page "Step" body="..." lines and one choose/pick/form per question (one submit); deck "Title" then page lines
- progress: timeline "This week" then done "X" at=Mon / now "Y" / next "Z"
- game: game tictactoe | game snake | game memory; a note: say Nice work.
- routing: >full shows anything full screen; >2 ... puts it on side screen 2
- change what is on screen: ~timer rounds=10, ~card body="Thu rest" (bare preset name in a later call)

Options are ONE token joined by | with no spaces: choose "Where?" "Camera roll"|Drafts. Quote anything with spaces. At most 6 components. Only Yui Lines draw UI (no HTML, JSON or markdown). No acknowledge-only buttons ("OK", "Got it"). Never ask for passwords, keys or card numbers.

Tap ids: the @id you gave (timer@hiit -> hiit), else n1, n2... in line order. A tap arrives as [yui] n1 choose choice=Legs: treat it as their reply and act on it. Full guide: prompt yui_guide.`;

const agentArg = {
  type: "string",
  description: "Which agent's thread (id, handle or name) when this token serves several. Default: the first. See yui_threads.",
};

const TOOLS = [
  {
    name: "yui_show",
    title: "Show a screen in Yui",
    description: SHOW_DESC,
    inputSchema: {
      type: "object",
      properties: {
        lines: { type: "string", description: "Yui Lines, one component per line, no ``` fence." },
        text: { type: "string", description: "Optional short chat line shown above the screen (under about 50 words)." },
        agent: agentArg,
      },
      required: ["lines"],
    },
    annotations: { title: "Show a screen in Yui", readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
  },
  {
    name: "yui_answers",
    title: "Read taps and replies from Yui",
    description:
      "What the person sent back in Yui, oldest first: taps on your screens (`[yui] <id> <preset> key=value`, with the structured event) and anything they typed. Each answer is returned once. With screen_id, only what came after that screen. wait (0-25 s) holds the call open until something arrives; call again to keep waiting. A tap on the same component again comes with changed=true: the newest wins.",
    inputSchema: {
      type: "object",
      properties: {
        screen_id: { type: "string", description: "The screen id yui_show returned." },
        wait: { type: "number", minimum: 0, maximum: MAX_WAIT, description: "Seconds to wait for an answer (0-25). Default 0." },
        agent: agentArg,
      },
    },
    annotations: { title: "Read taps and replies from Yui", readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
  },
  {
    name: "yui_say",
    title: "Send a message in Yui",
    description: "Send a plain chat message to the person's Yui thread (their phone buzzes unless the thread is open). For anything they would tap, use yui_show instead. Keep it under about 50 words.",
    inputSchema: {
      type: "object",
      properties: { text: { type: "string", description: "The message." }, agent: agentArg },
      required: ["text"],
    },
    annotations: { title: "Send a message in Yui", readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
  },
  {
    name: "yui_threads",
    title: "List Yui threads",
    description: "The Yui agents (threads) this connection can write to, with how many of the person's messages are unread. The first is the default for the other tools.",
    inputSchema: { type: "object", properties: {} },
    annotations: { title: "List Yui threads", readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
];
