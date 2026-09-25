// Yui Lines -> Telegram Bot API messages (INT-4). Spec: yuigui spec/TELEGRAM.md.
//
// The same reply an agent sends to the Yui app, drawn in Telegram for when the
// app is not around. Questions become inline keyboards whose taps come back as
// the exact event line the phone sends (`[yui] n1 choose choice=Legs`). Text
// presets become formatted messages. Everything Telegram cannot draw (a timer,
// a chart, a deck, a form) is gathered into one message with an "Open in Yui"
// button that opens the whole screen in the Telegram Mini App at yuigui.com/tg.
//
// Runtime neutral: no Node APIs, so a Worker or a Deno bot runs the same code.
// The parser is yuigui's yl.mjs (src/vendor, synced), never a fork.
import { apply, initialState, parse } from "./vendor/yl.mjs";
import { encodeYL } from "./share.ts";

export const MINI_APP = "https://www.yuigui.com/tg";
export const MAX_TEXT = 4096; // Telegram's limit for one message
export const MAX_URL = 4096; // longest Mini App link we put on a button

export type Button = { text: string; callback_data?: string; url?: string; web_app?: { url: string } };
export type Keyboard = { inline_keyboard: Button[][] };
// A sendMessage call, minus chat_id.
export type Message = { text: string; parse_mode: "HTML"; link_preview_options: { is_disabled: true }; reply_markup?: Keyboard };

// What a keyboard remembers between the message and the tap. callback_data
// holds at most 64 bytes, so a button carries `y:<token>:<index>` and the rest
// lives here, under the token.
export type Entry = {
  id: string; // the component's YL id: the event's id
  preset: "ask" | "choose" | "pick" | "card";
  q: string;
  options: string[]; // ask, choose, pick
  answer?: unknown; // graded quiz
  max?: number; // pick
  submit?: string; // pick's Done label
  cta?: string; // card
  other?: string; // Mini App link for "Type your own"
  saved?: string; // the screen came back with `show <name>`
  picked: string[]; // pick: toggled on, in tap order
  last?: string; // the last value sent, JSON: an identical answer is not sent twice
};

export interface Store {
  get(token: string): Promise<Entry | undefined>;
  put(token: string, entry: Entry): Promise<void>;
}

// Fine for one process. A bot that restarts or runs on many machines passes a
// Store on its KV or database.
export class MemoryStore implements Store {
  map = new Map<string, Entry>();
  async get(token: string) { return this.map.get(token); }
  async put(token: string, entry: Entry) { this.map.set(token, structuredClone(entry)); }
}

export type Options = {
  store: Store;
  miniApp?: string; // default yuigui.com/tg
  bridge?: string; // the bot's own https endpoint for Mini App taps (see webapp.ts)
  agent?: string; // the name the Mini App shows
  token?: () => string;
};

// placed: every component id in the fence and where it went, so nothing is
// dropped without a trace (the tests check every preset).
export type Rendered = { messages: Message[]; errors: string[]; placed: Record<string, "keyboard" | "text" | "app" | "member"> };

// Every preset, and what Telegram gets. `keyboard`: a message with buttons
// that answer in place. `text`: a formatted message. `app`: listed in the
// "Open in Yui" message. `member`: drawn with its group's head.
export const HOW: Record<string, "keyboard" | "text" | "app" | "member"> = {
  ask: "keyboard", choose: "keyboard", pick: "keyboard",
  say: "text", list: "text", card: "text", stat: "text", table: "text", step: "text", timeline: "text",
  done: "member", now: "member", next: "member",
  sketch: "text", row: "text", after: "member",
  timer: "app", slide: "app", form: "app", image: "app", camera: "app", mic: "app",
  gallery: "app", video: "app", compare: "app", storyboard: "app",
  chart: "app", math: "app", calc: "app",
  deck: "app", page: "app", plan: "app", project: "app", narrate: "app",
  game: "app", flow: "app", custom: "app",
};

const ICON: Record<string, string> = {
  timer: "⏱", slide: "🎚", form: "📝", image: "🖼", camera: "📷", mic: "🎙", gallery: "🖼", video: "🎬",
  compare: "↔️", storyboard: "🎞", chart: "📈", math: "∑", calc: "🧮", deck: "📚", page: "📄", plan: "🗂",
  project: "📁", narrate: "🔊", game: "🎮", flow: "🧭", custom: "✨", table: "📋", timeline: "🗓",
};

export const esc = (s: unknown) => String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

function clip(s: string, n = MAX_TEXT) {
  return s.length <= n ? s : `${s.slice(0, n - 1)}…`;
}

const msg = (text: string, rows?: Button[][]): Message => ({
  text: clip(text), parse_mode: "HTML", link_preview_options: { is_disabled: true },
  ...(rows && rows.length ? { reply_markup: { inline_keyboard: rows } } : {}),
});

function newToken() {
  const a = new Uint8Array(6);
  crypto.getRandomValues(a);
  return btoa(String.fromCharCode(...a)).replace(/\+/g, "-").replace(/\//g, "_"); // 8 chars
}

// ```yui fences, and the chat text around them. An unclosed fence still
// renders, like in the app (a reply cut short keeps its screen).
export function split(reply: string): { text?: string; yl?: string }[] {
  const out: { text?: string; yl?: string }[] = [];
  const re = /```yui[^\n]*\n([\s\S]*?)(?:```|$)/g;
  let at = 0;
  for (let m; (m = re.exec(reply));) {
    if (m.index > at) out.push({ text: reply.slice(at, m.index) });
    out.push({ yl: m[1] });
    at = m.index + m[0].length;
    if (!m[0].endsWith("```")) break;
  }
  if (at < reply.length) out.push({ text: reply.slice(at) });
  return out.filter((b) => b.yl !== undefined ? b.yl.trim() : b.text!.trim());
}

// A whole agent reply: chat text plus fences.
export async function render(reply: string, opts: Options): Promise<Rendered> {
  const out: Rendered = { messages: [], errors: [], placed: {} };
  for (const b of split(reply)) {
    if (b.yl === undefined) { out.messages.push(msg(esc(b.text!.trim()))); continue; }
    const r = await renderYL(b.yl, opts);
    out.messages.push(...r.messages);
    out.errors.push(...r.errors);
    Object.assign(out.placed, r.placed);
  }
  return out;
}

type Node = { id: string; key: string; preset: string; props: Record<string, any>; seq: number; in?: string; saved?: string };

// One fence of Yui Lines.
export async function renderYL(yl: string, opts: Options): Promise<Rendered> {
  let s = initialState();
  for (const op of parse(yl)) s = apply(s, op);
  // Telegram has no room for screens or a stage: everything in line order (YL.md 10).
  const nodes: Node[] = (Object.values(s.screens).flat() as Node[]).sort((a, b) => a.seq - b.seq);
  const errors: string[] = [...s.errors];
  const messages: Message[] = [];
  const later: Node[] = []; // for the Mini App
  const placed: Rendered["placed"] = {};
  let appAt = -1; // where the "Open in Yui" message goes: at the first thing it holds
  const link = await appLink(yl, opts);
  const holdForApp = (n: Node) => { if (appAt < 0) appAt = messages.length; later.push(n); placed[n.id] = "app"; };

  for (let i = 0; i < nodes.length; i++) {
    const n = nodes[i];
    const p = n.props || {};
    const how = HOW[n.preset];
    if (n.in && nodes.some((h) => h.id === n.in)) { placed[n.id] = "member"; continue; } // drawn with its head
    if (!how) { errors.push(`telegram: no mapping for ${n.preset}`); holdForApp(n); continue; }
    if (how === "app") { holdForApp(n); continue; }
    placed[n.id] = how === "member" ? "text" : how;
    switch (n.preset) {
      case "say": messages.push(msg(esc(p.text))); break;
      case "list": messages.push(msg(list(p))); break;
      case "stat": messages.push(msg(stat(p))); break;
      case "table":
        if (!Array.isArray(p.rows) || !p.rows.length) holdForApp(n); // a live data table lives in the app
        else messages.push(msg(table(p)));
        break;
      case "step": {
        const run = [n];
        while (nodes[i + 1]?.preset === "step") { run.push(nodes[++i]); placed[nodes[i].id] = "text"; }
        messages.push(msg(steps(run)));
        break;
      }
      case "timeline": {
        messages.push(msg(timeline(p, nodes.filter((m) => m.in === n.id))));
        if (p.reorder) holdForApp(n); // dragging the order needs the screen
        break;
      }
      case "done": case "now": case "next":
        messages.push(msg(timeline({}, [n])));
        break;
      case "sketch":
        messages.push(msg(sketch(p, nodes.filter((m) => m.in === n.id))));
        break;
      case "row":
        messages.push(msg(sketch({}, [n])));
        break;
      case "after": break; // outside a sketch it draws nothing, in the app too
      case "card": messages.push(await card(n, opts)); break;
      case "ask": case "choose": case "pick":
        messages.push(await question(n, opts, link));
        break;
    }
  }

  if (later.length) {
    // At most 10 names, so the button's note is never clipped off the end.
    const lines = later.slice(0, 10).map((n) => `${ICON[n.preset] || "•"} ${esc(clip(label(n), 120))}`);
    if (later.length > 10) lines.push(`and ${later.length - 10} more`);
    const text = `<b>Open in Yui</b> for the rest of this screen:\n${lines.join("\n")}`;
    const open: Message = link
      ? msg(text, [[{ text: "Open in Yui", web_app: { url: link } }]])
      : msg(`${text}\n\n<i>Too big for a Telegram link. It is waiting in the Yui app.</i>`);
    if (!link) errors.push("telegram: screen too big for a Mini App link");
    messages.splice(appAt, 0, open);
  }
  return { messages, errors, placed };
}

// The Mini App link for a fence: the whole fence, packed like a share link
// (yuigui lib/share-code.mjs), so the app draws it with the same ids.
export async function appLink(yl: string, opts: Pick<Options, "miniApp" | "bridge" | "agent">): Promise<string | null> {
  const u = new URL(opts.miniApp || MINI_APP);
  u.searchParams.set("yl", await encodeYL(yl.trim()));
  if (opts.agent) u.searchParams.set("agent", opts.agent);
  if (opts.bridge) u.searchParams.set("bridge", opts.bridge);
  const s = u.toString();
  return s.length <= MAX_URL ? s : null;
}

// A short name for a component in the "Open in Yui" list.
export function label(n: { preset: string; props?: Record<string, any> }): string {
  const p = n.props || {};
  const named = p.title || p.label || p.q || p.prompt || p.caption || p.name || p.text;
  switch (n.preset) {
    case "timer": {
      const work = Number(p.work ?? 60), rest = Number(p.rest ?? 0), rounds = Number(p.rounds ?? 1);
      const t = rest ? `${dur(work)} on, ${dur(rest)} off` : dur(work);
      return `${p.label || "Timer"}: ${t}${rounds > 1 ? `, ${rounds} rounds` : ""}`;
    }
    case "form": return named || `Form: ${(p.fields || []).map((f: any) => f.key).join(", ")}`;
    case "game": return named || `Play ${p.kind || "a game"}`;
    case "math": return p.caption || "An equation";
    case "custom": return "A custom screen";
    case "timeline": return `Reorder: ${named || "the timeline"}`;
    case "table": return `Table: ${named || "your data"}`;
    default: return named || n.preset[0].toUpperCase() + n.preset.slice(1);
  }
}

function dur(s: number) {
  if (s >= 60 && s % 60 === 0) return `${s / 60} min`;
  if (s >= 60) return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
  return `${s}s`;
}

// ---------- text presets ----------

function list(p: any) {
  // A checklist's ticks are quiet events that stay on the phone, so here it is boxes to copy.
  const items = (p.items || []).map((it: string, i: number) => `${p.check ? "☐" : p.num ? `${i + 1}.` : "•"} ${esc(it)}`);
  return [p.title ? `<b>${esc(p.title)}</b>` : "", ...items].filter(Boolean).join("\n");
}

const num = (v: unknown) => typeof v === "number" ? String(Number(v.toPrecision(12))) : String(v ?? "");
const withUnit = (v: unknown, unit: string) => unit ? (/^[%°]/.test(unit) ? `${num(v)}${unit}` : `${num(v)} ${unit}`) : num(v);

// "Weight 178.9 lb, down 2.3 (this week)"
export function statText(p: any) {
  let s = [p.label, withUnit(p.value, p.unit || "")].filter((x) => x !== "").join(" ");
  if (typeof p.delta === "number" && p.delta !== 0) s += `, ${p.delta < 0 ? "down" : "up"} ${num(Math.abs(p.delta))}`;
  if (p.sub) s += ` (${p.sub})`;
  return s;
}
const stat = (p: any) => esc(statText(p));

function table(p: any) {
  const cols: string[] | null = Array.isArray(p.cols) ? p.cols.map((c: string, i: number) => p.units?.[i] ? `${c} (${p.units[i]})` : c) : null;
  const rows: string[][] = [...(cols ? [cols] : []), ...p.rows.map((r: unknown[]) => r.map((c) => num(c)))];
  const w = rows.reduce((acc: number[], r) => r.map((c, i) => Math.max(acc[i] || 0, c.length)), []);
  const line = (r: string[]) => r.map((c, i) => c.padEnd(w[i])).join("  ").trimEnd();
  const body = rows.map(line);
  if (cols) body.splice(1, 0, w.map((x) => "-".repeat(x)).join("  "));
  return `${p.name ? `<b>${esc(p.name)}</b>\n` : ""}<pre>${esc(body.join("\n"))}</pre>`;
}

function steps(run: Node[]) {
  const title = run.find((n) => n.props.title)?.props.title;
  const lines = run.map((n, i) => `${i + 1}. ${esc(n.props.text)}${n.props.tex ? `\n    <code>${esc(n.props.tex)}</code>` : ""}`);
  return [title ? `<b>${esc(title)}</b>` : "", ...lines].filter(Boolean).join("\n");
}

function timeline(p: any, members: Node[]) {
  const mark: Record<string, string> = { done: "✓", now: "▶", next: "○" };
  const lines = members.map((m) => {
    const q = m.props;
    const tail = [q.tag, q.at].filter(Boolean).join(", ");
    return `${mark[m.preset]} ${m.preset === "now" ? `<b>${esc(q.text)}</b>` : esc(q.text)}${tail ? ` <i>${esc(tail)}</i>` : ""}${q.sub ? `\n    ${esc(q.sub)}` : ""}`;
  });
  return [p.title ? `<b>${esc(p.title)}</b>` : "", ...lines].filter(Boolean).join("\n");
}

// sketch (YUI-83): the drawing as text. Struck rows struck through,
// highlighted rows bold, buttons in brackets, notes after an arrow, blank
// filler rows left out; an `after` line starts the second half, labelled.
function sketch(p: any, members: Node[]) {
  const cut = members.findIndex((m) => m.preset === "after");
  const row = (q: any) => {
    if (!q.text) return "";
    let t = esc(q.text);
    if (q.button) t = `[ ${t} ]`;
    if (q.x) t = `<s>${t}</s>`;
    else if (q.hi) t = `<b>${t}</b>`;
    return `${q.dim ? "  " : ""}${t}${q.note ? ` <i>← ${esc(q.note)}</i>` : ""}`;
  };
  const rows = (list: Node[]) => list.filter((m) => m.preset === "row").map((m) => row(m.props || {})).filter(Boolean);
  const body = cut < 0 ? rows(members) : [
    `<i>${esc(p.before || "Before")}</i>`, ...rows(members.slice(0, cut)),
    `<i>${esc(members[cut].props?.label || "After")}</i>`, ...rows(members.slice(cut + 1)),
  ];
  return [p.title ? `<b>${esc(p.title)}</b>` : "", ...body].filter(Boolean).join("\n") || "✏️";
}

async function card(n: Node, opts: Options): Promise<Message> {
  const p = n.props;
  const text = [p.tag ? `[${esc(p.tag)}]` : "", p.sub ? `<i>${esc(p.sub)}</i>` : "", p.title ? `<b>${esc(p.title)}</b>` : "", p.body ? esc(p.body) : ""]
    .filter(Boolean).join("\n") || esc(label(n));
  // url= opens a page and sends nothing, like the app (YUI-67). Telegram url
  // buttons take https; anything else stays a plain card.
  if (typeof p.url === "string" && /^https:\/\//i.test(p.url)) return msg(text, [[{ text: p.cta || "Open", url: p.url }]]);
  if (!p.cta) return msg(text);
  const token = (opts.token || newToken)();
  await opts.store.put(token, { id: n.id, preset: "card", q: p.title || "", options: [], cta: p.cta, picked: [], ...(n.saved ? { saved: n.saved } : {}) });
  return msg(text, [[{ text: p.cta, callback_data: `y:${token}:c` }]]);
}

// ---------- questions ----------

async function question(n: Node, opts: Options, link: string | null): Promise<Message> {
  const p = n.props;
  const preset = n.preset as "ask" | "choose" | "pick";
  const options: string[] = preset === "ask" && !p.options ? ["Yes", "No"] : (p.options || []);
  const q: string = p.q || (preset === "ask" ? "Continue?" : "");
  const text = `<b>${esc(q || (preset === "pick" ? "Pick any" : "Pick one"))}</b>`;
  if (p.lock) return msg(text); // frozen on purpose: nothing to tap
  const token = (opts.token || newToken)();
  const e: Entry = {
    id: n.id, preset, q, options, picked: [],
    ...(p.answer !== undefined && p.answer !== true ? { answer: p.answer } : {}),
    ...(preset === "pick" ? { submit: p.submit || "Done", ...(p.max ? { max: p.max } : {}) } : {}),
    ...(p.other && preset !== "ask" && link ? { other: link } : {}),
    ...(n.saved ? { saved: n.saved } : {}),
  };
  await opts.store.put(token, e);
  return msg(text, keyboard(e, token));
}

// The buttons for an entry, as sent and after each tap.
export function keyboard(e: Entry, token: string, chosen?: string): Button[][] {
  const mark = (o: string) => e.preset === "pick" ? `${e.picked.includes(o) ? "☑" : "☐"} ${o}` : chosen === o ? `✓ ${o}` : o;
  const rows = pack(e.options.map((o, i) => ({ text: mark(o), callback_data: `y:${token}:${i}` })));
  if (e.other) rows.push([{ text: "Type your own", web_app: { url: e.other } }]);
  if (e.preset === "pick") rows.push([{ text: e.picked.length ? `${e.submit} (${e.picked.length})` : e.submit!, callback_data: `y:${token}:d` }]);
  return rows;
}

// Short labels share a row, long ones get their own: up to 3 a row, about 30 characters.
function pack(buttons: Button[]): Button[][] {
  const rows: Button[][] = [];
  let row: Button[] = [], width = 0;
  for (const b of buttons) {
    const w = [...b.text].length;
    if (row.length && (row.length >= 3 || width + w > 30)) { rows.push(row); row = []; width = 0; }
    row.push(b); width += w;
  }
  if (row.length) rows.push(row);
  return rows;
}
