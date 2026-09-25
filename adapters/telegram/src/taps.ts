// A button tap (callback_query) back to the event the phone would send.
//
// render.ts put `y:<token>:<index>` on each button and the component under the
// token. tap() turns that into `[yui] n1 choose choice=Legs`, the same line,
// same keys and same rules as the app (spec/YL.md 7, spec/RELAY.md): answers
// can change and a changed one says `changed`, an identical answer is not sent
// twice, a pick toggles in place and goes out on Done.
import { echoFor, eventLine } from "./vendor/events.mjs";
import { keyboard, type Button, type Store } from "./render.ts";

export type Event = { id: string; preset: string; [k: string]: unknown };

export type Tap = {
  event?: Event; // goes to the agent
  line?: string; // the event as the agent reads it
  echo?: string; // what the person's side of the chat shows
  toast: string; // answerCallbackQuery text ("" = none)
  keyboard?: Button[][]; // the message's new buttons (editMessageReplyMarkup)
};

const DATA = /^y:([A-Za-z0-9_-]{1,40}):(\d{1,3}|d|c)$/;

// null: not one of ours (another plugin's button, or a stale token).
export async function tap(data: string, store: Store): Promise<Tap | null> {
  const m = DATA.exec(data || "");
  if (!m) return null;
  const [, token, key] = m;
  const e = await store.get(token);
  if (!e) return null;
  const tag = e.saved ? { saved: e.saved } : {};

  if (e.preset === "card") {
    if (key !== "c" || !e.cta) return null;
    return out({ id: e.id, preset: "card", cta: e.cta, ...tag });
  }

  if (e.preset === "pick" && key !== "d") {
    const o = e.options[Number(key)];
    if (o === undefined) return null;
    if (e.picked.includes(o)) e.picked = e.picked.filter((x) => x !== o);
    else if (e.max && e.picked.length >= e.max) return { toast: `Up to ${e.max}` };
    else e.picked = [...e.picked, o];
    await store.put(token, e);
    return { toast: "", keyboard: keyboard(e, token) };
  }

  let value: Record<string, unknown>;
  let chosen: string | undefined;
  if (e.preset === "pick") {
    if (!e.picked.length) return { toast: "Pick at least one" };
    value = { picked: e.picked, ...(e.answer !== undefined ? { correct: sameSet(e.picked, e.answer) } : {}) };
  } else {
    chosen = e.options[Number(key)];
    if (chosen === undefined || key === "d" || key === "c") return null;
    const k = e.preset === "ask" ? "answer" : "choice";
    value = { [k]: chosen, ...(e.answer !== undefined ? { correct: chosen === e.answer } : {}) };
  }

  const sig = JSON.stringify(e.preset === "pick" ? [...e.picked].sort() : chosen);
  if (e.last === sig) return { toast: "Already sent" };
  const changed = e.last !== undefined;
  e.last = sig;
  await store.put(token, e);
  const t = out({ id: e.id, preset: e.preset, ...value, ...(changed ? { changed: true } : {}), ...tag });
  t.keyboard = keyboard(e, token, chosen);
  return t;
}

function out(event: Event): Tap {
  const echo = echoFor(event);
  return { event, line: eventLine(event), ...(echo != null ? { echo } : {}), toast: echo ? `Sent: ${echo}`.slice(0, 190) : "Sent" };
}

function sameSet(a: string[], b: unknown) {
  const want = Array.isArray(b) ? b : [b];
  return a.length === want.length && a.every((x) => want.includes(x));
}

// The Bot API calls that answer a callback_query: the toast, then the new
// buttons on the message that was tapped.
export function replies(cb: { id: string; message?: { chat: { id: number | string }; message_id: number } }, t: Tap | null) {
  const calls: { method: string; params: Record<string, unknown> }[] = [
    { method: "answerCallbackQuery", params: { callback_query_id: cb.id, ...(t?.toast ? { text: t.toast } : {}) } },
  ];
  if (t?.keyboard && cb.message) {
    calls.push({ method: "editMessageReplyMarkup", params: { chat_id: cb.message.chat.id, message_id: cb.message.message_id, reply_markup: { inline_keyboard: t.keyboard } } });
  }
  return calls;
}
