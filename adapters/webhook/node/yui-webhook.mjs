#!/usr/bin/env node
// Yui webhook bridge (INT-2): any agent that answers an HTTP POST can talk in Yui.
//
// Spec: yuigui/spec/RELAY.md (rows, acks, meta.turn) and spec/ADAPTERS.md path E.
// This process runs next to your agent. It dials out to Yui (no inbound ports),
// reads what the person sends, POSTs it to your webhook, and writes your answer
// back into their thread, exactly once. No dependencies, Node 20+.
//
//   node yui-webhook.mjs pair 123456 [--ref my-agent] [--host-name "Build box"]
//   node yui-webhook.mjs run --webhook http://127.0.0.1:8787/yui [--secret S]
//   node yui-webhook.mjs send "Your report is ready" [--agent <id|handle|ref>]
//   node yui-webhook.mjs guide        # print the channel guide your agent should read
//   node yui-webhook.mjs status
//
// Your webhook gets one POST per turn (JSON, see README.md) and answers with
// {"reply": "..."} or {"replies": [...]} or plain text; an empty 2xx means no
// reply. Anything else and the turn is tried again later, so a crash in your
// agent never loses a message.
//
// State (the connector token, a floor per agent, the reply outbox) lives in
// ~/.yui/webhook.json (mode 600), or --state / $YUI_WEBHOOK_STATE. Same file
// format as the Python bridge: either one can pick up where the other stopped.
import { createHash, createHmac, randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { hostname, homedir } from "node:os";
import { dirname, join } from "node:path";
import { parseArgs } from "node:util";

const SUPABASE_URL = process.env.YUI_SUPABASE_URL ?? "https://ewzzaoperdpxqxkshynx.supabase.co";
const CONNECT = `${SUPABASE_URL}/functions/v1/yui-connect`;
const PUSH = `${SUPABASE_URL}/functions/v1/yui-push`;
const REST = `${SUPABASE_URL}/rest/v1`;
// Public client key (anon role only; it cannot read any yui_ table).
const PUBLISHABLE = "sb_publishable_OhqLI7p27yiELT4tn8i7JA_TnnwPYsS";
const UA = "yui-webhook-js/1";
const HEARTBEAT_SECONDS = 45;
const REFRESH_MARGIN_SECONDS = 600; // the 60-minute session is renewed 10 minutes early
const BACKOFF_MAX = 60;
const MAX_BODY = 32000;

const nowIso = () => new Date().toISOString();
const sleep = (s) => new Promise((r) => setTimeout(r, s * 1000));
const log = (msg) => console.error(`${new Date().toTimeString().slice(0, 8)} yui: ${msg}`);

/** Yui said no for good (bad token, removed host): stop, don't retry. */
class Refused extends Error {}
/** Network or server trouble: try again later. */
class Retry extends Error {}

// -- state ---------------------------------------------------------------------

class State {
  constructor(path) {
    this.path = path;
    try {
      this.data = JSON.parse(readFileSync(path, "utf8"));
    } catch {
      this.data = {};
    }
    this.data.floors ??= {};
    this.data.outbox ??= [];
    this.data.acks ??= [];
  }
  save() {
    mkdirSync(dirname(this.path), { recursive: true });
    const tmp = this.path.replace(/\.json$/, "") + ".tmp";
    writeFileSync(tmp, JSON.stringify(this.data, null, 1), { mode: 0o600 });
    renameSync(tmp, this.path);
  }
}

// -- HTTP ------------------------------------------------------------------------

async function http(method, url, body, headers = {}, timeout = 20) {
  let r;
  try {
    r = await fetch(url, {
      method,
      body: body === undefined ? undefined : JSON.stringify(body),
      headers: { "content-type": "application/json", apikey: PUBLISHABLE, "user-agent": UA, ...headers },
      signal: AbortSignal.timeout(timeout * 1000),
    });
  } catch (e) {
    throw new Retry(String(e.cause?.code ?? e.message ?? e));
  }
  const text = await r.text();
  let data = null;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = text;
  }
  return [r.status, data];
}

async function connectCall(body, token) {
  const [s, r] = await http("POST", CONNECT, body, token ? { authorization: `Bearer ${token}` } : {});
  if (s === 401 || s === 403) throw new Refused(`yui-connect ${body.action}: ${s} ${r?.error ?? ""}`);
  if (s >= 300) throw new Retry(`yui-connect ${body.action}: ${s}`);
  return r ?? {};
}

// -- pairing ------------------------------------------------------------------------

async function pair(state, code, ref, name) {
  const auth = state.data.token ? { authorization: `Bearer ${state.data.token}` } : {};
  const [s, r] = await http("POST", CONNECT, {
    action: "pair", code, remote_ref: ref, host_name: name ?? (hostname().split(".")[0] || "My computer"), kind: "http",
  }, auth);
  if (s !== 200) throw new Refused(`pair failed: ${r?.error ?? s}`);
  if (r.connector_token) { // a new connector (first pairing, or another Yui account)
    Object.assign(state.data, { token: r.connector_token, connector: r.connector, floors: {}, outbox: [], acks: [] });
  }
  // Messages sent from the moment of pairing reach the agent, even before `run`.
  state.data.floors[r.agent.id] ??= nowIso();
  state.save();
  return r;
}

// -- the bridge -----------------------------------------------------------------------

class Bridge {
  constructor(state, { webhook, secret, interval = 2, timeout = 300 } = {}) {
    Object.assign(this, { state, webhook, secret, interval, webhookTimeout: timeout });
    this.token = this.userId = null;
    this.tokenExp = 0;
    this.agents = new Map();
    this.guide = { version: "", body: "" };
    this.running = true;
    this.retryAt = new Map(); // agent id -> time its failed turn may run again
    this.backoff = new Map();
  }

  get ct() {
    if (!this.state.data.token) throw new Refused("not paired: add an agent in the app, then run `pair <code>`");
    return this.state.data.token;
  }

  async session() {
    const r = await connectCall({ action: "session" }, this.ct);
    this.token = r.access_token;
    this.userId = r.user_id;
    this.tokenExp = Date.parse(r.expires_at) / 1000;
    this.guide = r.guide ?? this.guide;
    const agents = new Map((r.agents ?? []).map((a) => [a.id, a]));
    for (const [id, a] of agents) {
      if (this.agents.has(id)) continue;
      if (!this.state.data.floors[id]) { // an agent added later starts from now
        this.state.data.floors[id] = nowIso();
        this.state.save();
      }
      log(`serving ${a.name} (${id.slice(0, 8)})`);
    }
    this.agents = agents;
  }

  async ensureSession() {
    if (!this.token || this.tokenExp - Date.now() / 1000 < REFRESH_MARGIN_SECONDS) await this.session();
  }

  async rest(method, path, body, prefer) {
    const headers = () => ({ authorization: `Bearer ${this.token}`, ...(prefer ? { prefer } : {}) });
    let [s, r] = await http(method, `${REST}/${path}`, body, headers());
    if (s === 401) { // token expired under us: one fresh session, one more try
      await this.session();
      [s, r] = await http(method, `${REST}/${path}`, body, headers());
    }
    return [s, r];
  }

  // -- acks (RELAY.md, Delivery) --

  async mark(ids, column) {
    let q = `yui_messages?id=in.(${ids.join(",")})`;
    if (column === "delivered_at") q += "&delivered_at=is.null"; // keep the first pickup time
    try {
      const [s] = await this.rest("PATCH", q, { [column]: nowIso() }, "return=minimal");
      return s < 300;
    } catch (e) {
      if (e instanceof Retry) return false;
      throw e;
    }
  }

  async flushAcks() {
    const ids = [...this.state.data.acks];
    if (ids.length && await this.mark(ids, "handled_at")) {
      this.state.data.acks = this.state.data.acks.filter((i) => !ids.includes(i));
      this.state.save();
    }
  }

  /** An earlier run already answered this row: a reply names it in meta.turn,
   *  written or still waiting in the outbox. */
  async answered(row) {
    if (this.state.data.outbox.some((i) => (i.row.meta?.turn ?? []).includes(row.id))) return true;
    const [s, r] = await this.rest("GET", `yui_messages?select=id&agent_id=eq.${row.agent_id}&sender=eq.agent`
      + `&meta->turn=cs.${encodeURIComponent(JSON.stringify([row.id]))}&limit=1`);
    return s === 200 && r.length > 0;
  }

  // -- agent to phone --

  queueReply(agentId, text, turn, ack, handoff = false) {
    const row = { id: randomUUID(), user_id: this.userId, agent_id: agentId, sender: "agent", kind: "text",
                  body: text.trim().slice(0, MAX_BODY) };
    if (turn) row.meta = { turn }; // the rows this reply answers (restart dedupe)
    this.state.data.outbox.push({ row, ack: ack ?? [], handoff, queued_at: Date.now() / 1000 });
    this.state.save(); // on disk before the first try: a crash now still sends it
    return row.id;
  }

  /** Oldest first; a reply that can't go yet holds the ones behind it. */
  async flushOutbox() {
    while (this.state.data.outbox.length) {
      const item = this.state.data.outbox[0];
      const [s, r] = await this.rest("POST", "yui_messages", item.row, "return=minimal");
      if (s >= 300 && s !== 409) { // 409: an earlier try got through
        if ([408, 425, 429].includes(s) || s >= 500) throw new Retry(`reply ${item.row.id.slice(0, 8)}: ${s}`);
        log(`Yui refused reply ${item.row.id.slice(0, 8)}: ${s} ${JSON.stringify(r)}`);
      }
      this.state.data.outbox.shift();
      this.state.data.acks.push(...item.ack);
      this.state.save();
      if (s < 300) await this.notify(item.row.id, item.handoff);
    }
  }

  /** Buzz the phone (yui-push skips it when the thread is already open). */
  async notify(messageId, handoff) {
    try {
      await http("POST", PUSH, { action: "notify", message_id: messageId, handoff }, { authorization: `Bearer ${this.ct}` });
    } catch (e) {
      if (!(e instanceof Retry)) throw e;
    }
  }

  // -- phone to agent --

  async fetch(aid) {
    const floor = encodeURIComponent(this.state.data.floors[aid] ?? nowIso());
    const [s, r] = await this.rest("GET", "yui_messages?select=id,agent_id,body,kind,meta,created_at,delivered_at"
      + `&agent_id=eq.${aid}&sender=eq.user&handled_at=is.null&created_at=gt.${floor}`
      + "&order=created_at.asc,id.asc&limit=200");
    if (s !== 200) throw new Retry(`read ${aid.slice(0, 8)}: ${s}`);
    const pending = new Set(this.state.data.acks);
    return r.filter((row) => !pending.has(row.id));
  }

  turnPayload(agent, rows) {
    return {
      agent: { id: agent.id, name: agent.name, handle: agent.handle, ref: agent.remote_ref },
      turn: rows.map((r) => r.id),
      text: rows.map((r) => r.body).join("\n"),
      messages: rows.map((r) => ({
        id: r.id, kind: r.kind, body: r.body,
        event: r.kind === "event" ? (r.meta ?? null) : null, created_at: r.created_at,
      })),
      guide: this.guide,
    };
  }

  /** The replies (maybe none), or null when the turn should be tried again. */
  async callWebhook(payload) {
    const raw = JSON.stringify(payload);
    const headers = {
      "content-type": "application/json", "user-agent": UA,
      "x-yui-turn": createHash("sha256").update(payload.turn.join(",")).digest("hex").slice(0, 32),
    };
    if (this.secret) {
      const ts = String(Math.floor(Date.now() / 1000));
      headers["x-yui-timestamp"] = ts;
      headers["x-yui-signature"] = "sha256=" + createHmac("sha256", this.secret).update(`${ts}.${raw}`).digest("hex");
    }
    let r, body;
    try {
      r = await fetch(this.webhook, { method: "POST", body: raw, headers,
                                      signal: AbortSignal.timeout(this.webhookTimeout * 1000) });
      body = await r.text();
    } catch (e) {
      log(`webhook unreachable (${e.cause?.code ?? e.message}); trying this turn again later`);
      return null;
    }
    if (!r.ok) {
      log(`webhook answered ${r.status}; trying this turn again later`);
      return null;
    }
    if (!body.trim()) return [];
    if ((r.headers.get("content-type") ?? "").includes("json")) {
      let data;
      try {
        data = JSON.parse(body);
      } catch {
        log("webhook sent bad JSON; trying this turn again later");
        return null;
      }
      const replies = Array.isArray(data) ? data
        : data && typeof data === "object" ? ("replies" in data ? data.replies : [data.reply]) : [data];
      return (replies ?? []).filter((x) => typeof x === "string" && x.trim());
    }
    return [body];
  }

  async runTurns() {
    for (const [aid, agent] of this.agents) {
      if ((this.retryAt.get(aid) ?? 0) > Date.now() / 1000) continue;
      const rows = [];
      for (const row of await this.fetch(aid)) {
        if (row.delivered_at && await this.answered(row)) {
          log(`${row.id.slice(0, 8)} was answered before a restart, not sending it again`);
          this.state.data.acks.push(row.id);
          this.state.save();
          continue;
        }
        rows.push(row);
      }
      if (!rows.length) continue;
      const ids = rows.map((r) => r.id);
      await this.mark(ids, "delivered_at");
      log(`turn for ${agent.name}: ${rows.length} message(s)`);
      const replies = await this.callWebhook(this.turnPayload(agent, rows));
      if (replies === null) {
        const wait = Math.min((this.backoff.get(aid) ?? 1) * 2, BACKOFF_MAX);
        this.backoff.set(aid, wait);
        this.retryAt.set(aid, Date.now() / 1000 + wait + Math.random());
        continue;
      }
      this.backoff.delete(aid);
      this.retryAt.delete(aid);
      if (!replies.length) {
        this.state.data.acks.push(...ids);
        this.state.save();
      }
      replies.forEach((text, n) => this.queueReply(aid, text, ids, n === replies.length - 1 ? ids : null));
      await this.flushOutbox();
      await this.flushAcks();
    }
  }

  async run() {
    await this.session();
    log(`online as ${this.state.data.connector?.name}; guide ${this.guide?.version}; webhook ${this.webhook}`);
    // A timer, not the turn loop, so a slow webhook never makes the agent look asleep.
    this.beat = setInterval(() => {
      this.beating = connectCall({ action: "heartbeat" }, this.ct).catch((e) => log(`heartbeat: ${e.message}`));
    }, HEARTBEAT_SECONDS * 1000);
    let backoff = 1;
    while (this.running) {
      try {
        await this.ensureSession();
        await this.flushOutbox();
        await this.flushAcks();
        await this.runTurns();
        backoff = 1;
        await sleep(this.interval);
      } catch (e) {
        if (!(e instanceof Retry)) throw e;
        log(`${e.message}; retrying in ${backoff}s`);
        await sleep(backoff + Math.random());
        backoff = Math.min(backoff * 2, BACKOFF_MAX);
      }
    }
  }

  async stop() {
    this.running = false;
    clearInterval(this.beat);
    await this.beating; // a beat in flight must not land after the goodbye
    try { // goodbye: the app shows the agent offline at once, not asleep
      await connectCall({ action: "bye" }, this.ct);
    } catch {}
  }
}

function pick(agents, want) {
  const all = [...agents.values()];
  if (!want) return all[0] ?? null;
  want = want.toLowerCase();
  return all.find((a) => ["id", "handle", "remote_ref", "name"].some((k) => String(a[k] ?? "").toLowerCase() === want)) ?? null;
}

// -- CLI --------------------------------------------------------------------------------

const USAGE = `usage: yui-webhook.mjs [--state FILE] <command>
  pair <code> [--ref NAME] [--host-name NAME]   claim the code from the app's Add agent
  run --webhook URL [--secret S] [--interval 2] [--timeout 300]
  send <text> [--agent ID|HANDLE|REF]           send a message (a handoff) into a thread
  guide                                         print the channel guide
  status                                        show the connector and its agents`;

async function main(argv) {
  const { values: o, positionals: [cmd, arg] } = parseArgs({
    args: argv, allowPositionals: true,
    options: {
      state: { type: "string", default: process.env.YUI_WEBHOOK_STATE ?? join(homedir(), ".yui/webhook.json") },
      ref: { type: "string", default: "webhook" }, "host-name": { type: "string" },
      webhook: { type: "string", default: process.env.YUI_WEBHOOK_URL }, secret: { type: "string", default: process.env.YUI_WEBHOOK_SECRET },
      interval: { type: "string", default: "2" }, timeout: { type: "string", default: "300" },
      agent: { type: "string" }, help: { type: "boolean", short: "h" },
    },
  });
  if (o.help || !cmd) {
    console.log(USAGE);
    return cmd || o.help ? 0 : 2;
  }
  const state = new State(o.state.replace(/^~(?=\/)/, homedir()));
  if (cmd === "pair") {
    if (!arg) throw new Refused("pair needs the 6-digit code from the app");
    const r = await pair(state, arg, o.ref, o["host-name"]);
    console.log(`paired: ${r.agent.name} on ${r.connector.name}. Next: yui-webhook.mjs run --webhook <url>`);
    return 0;
  }
  if (cmd === "guide") {
    const g = (await connectCall({ action: "guide" })).guide ?? {};
    console.log(`Yui channel guide ${g.version}\n\n${g.body ?? ""}`);
    return 0;
  }
  const b = new Bridge(state, { webhook: o.webhook, secret: o.secret, interval: Number(o.interval), timeout: Number(o.timeout) });
  if (cmd === "status") {
    await b.session();
    console.log(`connector: ${state.data.connector?.name} (${state.path}); agents: `
      + ([...b.agents.values()].map((a) => `${a.name} (${a.remote_ref})`).join(", ") || "none"));
    return 0;
  }
  if (cmd === "send") {
    if (!arg) throw new Refused("send needs the text");
    await b.session();
    const a = pick(b.agents, o.agent);
    if (!a) throw new Refused(`no agent ${JSON.stringify(o.agent)} on this connector`);
    const id = b.queueReply(a.id, arg, null, null, true);
    try {
      await b.flushOutbox();
    } catch (e) {
      if (!(e instanceof Retry)) throw e;
      log(`${e.message}; it waits in the outbox and goes out with the next run`);
    }
    console.log(JSON.stringify({ message_id: id, agent: a.name }));
    return 0;
  }
  if (cmd === "run") {
    if (!o.webhook) throw new Refused("run needs --webhook URL (or $YUI_WEBHOOK_URL)");
    const done = new Promise((resolve) => {
      for (const sig of ["SIGINT", "SIGTERM"]) process.once(sig, async () => { await b.stop(); log("stopped"); resolve(); });
    });
    // The loop ends once stop() clears `running`; exit only after the goodbye went out.
    await Promise.race([b.run().then(() => done), done]);
    return 0;
  }
  console.error(USAGE);
  return 2;
}

main(process.argv.slice(2)).then((code) => process.exit(code), (e) => {
  console.error(`yui: ${e instanceof Refused ? e.message : e.stack ?? e}`);
  process.exit(1);
});
