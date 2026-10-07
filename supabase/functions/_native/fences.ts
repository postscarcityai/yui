// Copied from adapters/openai-compat/src/fences.ts by runtime/scripts/build.mjs. Do not edit here.
// Small models draw screens in the wrong fence (INT-23): qwen2.5:7b tags a Yui
// Lines block ```yml, ```yaml or nothing at all. The app only draws ```yui, so
// the bridge retags a fence whose first line is a Yui Lines head. Runtime-neutral, no I/O.

/** The heads of a Yui Line (site/lib/yl/yl.mjs PRESETS and CORE). */
const HEADS = [
  "timer", "ask", "choose", "pick", "slide", "form", "list", "table", "card", "image", "camera", "mic",
  "gallery", "video", "compare", "storyboard", "chart", "stat", "math", "step", "calc",
  "deck", "page", "plan", "project", "narrate", "timeline", "done", "now", "next", "sketch", "row", "after",
  "shapes", "shape", "game", "flow", "query", "loop", "drums", "keys", "chords", "tuner", "metronome",
  "motion", "say", "custom", "save", "show", "forget", "clear", "end", "theme", "close", "talk", "menu", "put", "doing", "visual",
];
const HEAD = new RegExp(`^(?:>\\w*|%%.*|(?:${HEADS.join("|")})(?:@[\\w-]+)?(?:\\s|$))`);
/** Tags a model puts on a block that is not code: yml and yaml for the look of it, none, text. */
const PLAIN_TAGS = new Set(["", "yml", "yaml", "yl", "text", "txt", "plain", "plaintext", "markdown", "md", "ini", "toml"]);

/** Heads a model writes with no fence at all, and only when the line carries an argument (quote, bar or digit). Prose says "list of" and "show me"; it rarely says `timer 5m`. */
const LOOSE_HEADS = new Set(["timer", "ask", "choose", "pick", "slide", "form", "list", "table", "card", "stat", "chart", "step", "calc"]);
const unTick = (l: string): string => l.trim().replace(/^`([^`]+)`$/, "$1"); // `slide ...` in one pair of backticks
const isLooseLine = (l: string): boolean => {
  const t = unTick(l);
  if (/^motion\s+\S+(?:\s+\S+){4,}/.test(t)) return true; // a film ask is prose, five words or more (INT-28)
  const head = /^([a-z]+)(?:@[\w-]+)?\s+\S/.exec(t)?.[1];
  return !!head && LOOSE_HEADS.has(head) && /["|\d]/.test(t);
};
/** A lone `[yui]`, `[ yui ]` or `[/yui]` line: the tap marker a model copies from the guide, never a screen. */
const STRAY_MARK = /^[ \t]*\[\s*\/?\s*yui\s*\][ \t]*\n?/gim;

/** A ```yui fence the model never closed (it ran out, or stopped early): close it. */
function closeFence(text: string): string {
  const fences = text.split("\n").filter((l) => /^`{3,}/.test(l));
  const last = fences[fences.length - 1];
  return fences.length % 2 === 1 && /^`{3,}yui[ \t]*$/.test(last) ? `${text.replace(/\n*$/, "")}\n${last.match(/^`+/)![0]}` : text;
}

const QUOTES = /["“”]/g;
/** A model splits a `motion` ask over lines, leaves its quote open, or forgets the quotes (INT-28): join the lines, then write `motion "<ask>"`. Inside fences and out; one line in, one line out. */
function repairMotion(text: string): string {
  const lines = text.split("\n");
  const out: string[] = [];
  let fence = "", mine = true; // mine: the open fence is a Yui block (or a plain-tagged one), not code
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const f = /^[ \t]*(`{3,})([\w-]*)/.exec(line);
    if (f) { mine = fence ? true : f[2].toLowerCase() === "yui" || PLAIN_TAGS.has(f[2].toLowerCase()); fence = fence ? "" : f[1]; out.push(line); continue; }
    // `motion "..."`, [motion "..."], `Motion "..."` and `motions "..."` (INT-29): a small model dresses the line in brackets or backticks
    const m = /^(\s*)[`\[]?[ \t]*motions?\s+(.*?)[ \t]*[`\]]?\s*$/i.exec(line);
    const quotedOpen = !!m && /^["“]/.test(m[2]);
    if (!m || !mine || !m[2].trim() || (!fence && !quotedOpen && (!/^\s*`?motion\s/.test(line) || m[2].trim().split(/\s+/).length < 5))) { out.push(line); continue; }
    let ask = m[2];
    const quoted = /^["“]/.test(ask);
    let j = i;
    // an open quote reads on to its close; an unquoted ask reads on while the next line is prose (not blank, fence or Yui Line)
    while (j + 1 < lines.length && j - i < 6) {
      const next = lines[j + 1];
      if (!next.trim() || /^[ \t]*`{3,}/.test(next) || HEAD.test(next.trim())) break;
      if (quoted && (ask.match(QUOTES) ?? []).length % 2 === 0) break;
      if (!quoted && !fence) break; // outside a fence a bare ask is one line
      ask += ` ${next.trim()}`;
      j++;
    }
    ask = ask.replace(/\s*[\]`]$/, "").replace(/^["“”'‘]|["“”'’]$/g, "").replace(QUOTES, "'").replace(/\s+/g, " ").trim();
    out.push(`${m[1]}motion "${ask}"`);
    i = j;
  }
  return out.join("\n");
}

/** A small model puts the options of a choice on the next line (INT-28): `choose "Drink"` then `  Tea|Coffee`. Join them when the head line has only a title. */
function joinOptions(text: string): string {
  const lines = text.split("\n");
  const out: string[] = [];
  let fence = false;
  for (const line of lines) {
    if (/^[ \t]*`{3,}/.test(line)) fence = !fence;
    const prev = out[out.length - 1];
    if (fence && prev !== undefined && /^(?:choose|pick)(?:@[\w-]+)?\s+"[^"\n]*"\s*$/.test(prev.trim()) && /^[ \t]*[^\s|][^|\n]*(?:\|[^|\n]+)+\s*$/.test(line) && !HEAD.test(line.trim())) {
      out[out.length - 1] = `${prev.trim()} ${line.trim()}`;
      continue;
    }
    out.push(line);
  }
  return out.join("\n");
}

/** What the guide answers with a film (SMALL_GUIDE, CHANNEL.md "Explain by picture"): "how does", "why", "explain". */
export const isExplainAsk = (s: string): boolean => /^\W*(?:how (?:does|do|did|can|come)|why|explain|what makes)\b/i.test(s);

/** One line of a film ask a small model wrapped in its own marks: "a quoted line", [a bracketed one], or `quote "..."`. */
const WRAPPED = /^\s*(?:quote\s+)?(?:"([^"\n]*)"|“([^”\n]*)”|\[([^\]\n]*)\]|`([^`\n]*)`)[ \t,]*$/;
const unwrap = (l: string): string => { const m = WRAPPED.exec(l); return (m ? (m[1] ?? m[2] ?? m[3] ?? m[4]) : l).trim(); };

/**
 * A small model answers an explain question with the film's ask and forgets the film (INT-29): the sentences come bare,
 * each in its own quotes or brackets, the whole reply in one pair of quotes, or the last one ends in a stray closing quote (the `motion "` opener was dropped).
 * The guide says an explain question gets one line and one `motion` line, so when the person asked one and the whole reply
 * is 2 to 4 short sentences carrying one of those two marks, wrap it. A plain text answer has neither mark and stays.
 * An unknown line like `sign "Path" ... "text"` is not a dropped opener (the guide has no rule that makes it a film;
 * it may be a card or pick gone wrong), so it is never guessed into a motion.
 */
function restoreFilm(text: string, ask: string | undefined): string {
  if (!ask || !isExplainAsk(ask) || text.includes("```")) return text;
  const opener = /^[\[`\s]*motions?\s+(?=["“])/i; // a garbled opener: `[ motion "`, `` `Motion "``, `motions "`
  if (opener.test(text)) text = text.replace(opener, "").replace(/\s*[\]`]\s*$/, "");
  const lines = text.split("\n").map((l) => l.trim()).filter(Boolean);
  if (!lines.length || lines.length > 6 || lines.some((l) => HEAD.test(l) || /^motion\b/i.test(l))) return text;
  const joined = lines.join("\n");
  const marks = (joined.match(QUOTES) ?? []).length;
  let inner: string, lead = "Here's how it works.";
  if (lines.length >= 2 && lines.every((l) => WRAPPED.test(l))) {
    inner = lines.map(unwrap).join("\n"); // every line in its own marks
  } else if (lines.length >= 3 && !WRAPPED.test(lines[0]) && !/["“”`\[\]]/.test(lines[0]) && lines[0].split(/\s+/).length <= 30 && lines.slice(1).every((l) => WRAPPED.test(l))) {
    lead = /[.!?:]$/.test(lines[0]) ? lines[0] : `${lines[0]}.`; // one plain line, then the film's sentences in marks
    inner = lines.slice(1).map(unwrap).join("\n");
  } else if (marks === 2 && /^["“]/.test(joined) && /["”]$/.test(joined)) {
    inner = joined.slice(1, -1); // the whole reply in one pair of quotes
  } else if (marks % 2 === 1 && /["”]$/.test(joined) && !/^["“]/.test(joined)) {
    inner = joined.slice(0, -1); // the closing quote of an opener that never came
  } else return text;
  const sentences = inner.split(/\n+|(?<=[.!?])\s+/).map((x) => x.trim()).filter(Boolean).map((x) => (/[.!?]$/.test(x) ? x : `${x}.`));
  const words = sentences.join(" ").split(/\s+/).length;
  if (sentences.length < 2 || sentences.length > 4 || words >= 80) return text;
  return `${lead}\n\`\`\`yui\nmotion "${sentences.join(" ").replace(QUOTES, "'").replace(/\s+/g, " ")}"\n\`\`\``;
}

const LEAD = /^(?:here|how|why|this|that|watch|let me|so\b|sure|ok)|[:?]$/i; // a title or a lead-in, not a fact
/**
 * A small model splits the film (INT-29): its facts come as plain lines above the fence and the `motion` line gets one scrap
 * (`motion "The colors always come in the same order."`). The film is made from the ask alone, so for an explain question
 * the facts above go into the ask, in order, when together they make 2 to 4 sentences under 80 words; the line above is
 * then the plain "Here's how it works." Lead-ins ("Here is how...", a question) are not facts: those replies stay as they are.
 */
function mergeFilmAsk(text: string, ask: string | undefined): string {
  if (!ask || !isExplainAsk(ask)) return text;
  const lines = text.split("\n");
  const open = lines.findIndex((l) => /^[ \t]*`{3,}yui[ \t]*$/.test(l));
  if (open < 1 || lines.slice(0, open).some((l) => /`{3,}/.test(l))) return text;
  const at = lines.findIndex((l, i) => i > open && /^[ \t]*motion\s+"[^"\n]*"[ \t]*$/.test(l));
  const close = lines.findIndex((l, i) => i > open && /^[ \t]*`{3,}[ \t]*$/.test(l));
  if (at < 0 || (close >= 0 && at > close)) return text;
  const own = /"([^"\n]*)"/.exec(lines[at])![1].trim();
  const norm = (x: string) => x.replace(/\s+/g, " ").trim();
  if ((own.split(/(?<=[.!?])\s+/).filter(Boolean).length) >= 2) {
    // the film's ask already says it all and the same words sit above the fence: the line above is the plain lead
    const above = norm(lines.slice(0, open).join(" "));
    return above.length > 20 && norm(own).startsWith(above) ? ["Here's how it works.", ...lines.slice(open)].join("\n") : text;
  }
  const prose = lines.slice(0, open).map((l) => l.trim()).filter(Boolean)
    .map(unwrap).filter(Boolean);
  if (!prose.length || prose.length > 3 || prose.some((l) => LEAD.test(l))) return text;
  const sentences = [...prose, own].flatMap((x) => x.split(/\n+|(?<=[.!?])\s+/)).map((x) => x.trim()).filter(Boolean)
    .map((x) => (/[.!?]$/.test(x) ? x : `${x}.`));
  const merged = sentences.join(" ").replace(QUOTES, "'").replace(/\s+/g, " ");
  if (sentences.length < 2 || sentences.length > 4 || merged.split(" ").length >= 80) return text;
  return ["Here's how it works.", ...lines.slice(open, at), `${lines[at].match(/^[ \t]*/)![0]}motion "${merged}"`, ...lines.slice(at + 1)].join("\n");
}

/** A small model puts an attribute on the line under its component (INT-29): `card "Grow"` then `body="..."`. Join it to the line above. */
function joinAttrs(text: string): string {
  const out: string[] = [];
  let fence = false;
  for (const line of text.split("\n")) {
    if (/^[ \t]*`{3,}/.test(line)) fence = !fence;
    const prev = out[out.length - 1];
    if (fence && prev !== undefined && HEAD.test(prev.trim()) && /^[ \t]*(?:[a-z][\w-]*=(?:"[^"\n]*"|[^\s"=]+)[ \t]*)+$/.test(line)) {
      out[out.length - 1] = `${prev.trimEnd()} ${line.trim()}`;
      continue;
    }
    out.push(line);
  }
  return out.join("\n");
}

/** Wraps a run of bare Yui Lines (a model that forgot the fence), dropping a lone `yui` line above it. */
function fenceBare(text: string): string {
  if (text.includes("```")) return text;
  const lines = text.split("\n");
  const out: string[] = [];
  for (let i = 0; i < lines.length; i++) {
    if (!isLooseLine(lines[i])) { out.push(lines[i]); continue; }
    let j = i;
    while (j < lines.length && isLooseLine(lines[j])) j++;
    if (out.length && out[out.length - 1].trim().toLowerCase() === "yui") out.pop();
    out.push("```yui", ...lines.slice(i, j).map(unTick), "```");
    i = j - 1;
  }
  return out.join("\n");
}

/** A role label a small model puts in front of its own bubble (INT-27): `[Response:]`, `Response:`, `Assistant:`, `[Assistant]`, `[yui] `. Bare `Response:` and `Assistant:` only; "Answer:" and "Reply:" are plain words. */
const ROLE_LABEL = /^[ \t]*(?:\[\s*(?:response|assistant|reply|answer|yui|ai|bot)\s*:?\s*\]|(?:response|assistant)[ \t]*:)[ \t]*/i;
const isFence = (l: string): boolean => /^[ \t]*`{3,}/.test(l);

/** Strips a leading role label from each bubble line, drops a line with nothing left, and never touches a fenced or quoted line. */
function stripLabels(text: string): string {
  let inFence = false;
  const out: string[] = [];
  for (const line of text.split("\n")) {
    if (isFence(line)) { inFence = !inFence; out.push(line); continue; }
    if (inFence || /^[ \t]*(?:>|["“'‘])/.test(line)) { out.push(line); continue; }
    const m = ROLE_LABEL.exec(line);
    if (!m) { out.push(line); continue; }
    const rest = line.slice(m[0].length);
    if (rest.trim()) out.push(rest);
  }
  return out.join("\n");
}

/** After a tap, a small model stacks a second ```yui screen nobody asked for right under the first (INT-27): keep the first of a run of back-to-back screens. */
export function firstScreen(text: string): string {
  const out: string[] = [];
  let fence = "", yui = false, skip = false, run = false, gap: string[] = []; // run: a yui screen just closed, only blank lines since
  for (const line of text.split("\n")) {
    const m = /^[ \t]*(`{3,})([\w-]*)[ \t]*$/.exec(line);
    if (fence) {
      if (m && !m[2] && m[1].length >= fence.length) { // the closing fence
        fence = "";
        run = yui;
        if (!skip) out.push(line);
        skip = false;
      } else if (!skip) out.push(line);
      continue;
    }
    if (m && m[2]) { // an opening fence
      fence = m[1];
      yui = m[2].toLowerCase() === "yui";
      skip = yui && run;
      if (!skip) out.push(...gap, line);
      gap = [];
      continue;
    }
    if (run && !line.trim()) { gap.push(line); continue; }
    run = false;
    out.push(...gap, line);
    gap = [];
  }
  return out.join("\n");
}

/** A reply with a film has nothing else to say (INT-28): the film is the explanation, so keep the one short line above it and drop the prose a small model tacks on below (quoted lines, "tap to continue"). A fenced screen after it, like a quiz `choose`, stays. */
function filmOnly(text: string): string {
  if (!/^[ \t]*`{3,}yui[ \t]*\n(?:(?!`{3,})[^\n]*\n)*?[ \t]*motion\s/m.test(text)) return text;
  const out: string[] = [];
  let fence = "", opened = false, said = false; // opened: the film fence has been seen
  for (const line of text.split("\n")) {
    const m = /^[ \t]*(`{3,})([\w-]*)[ \t]*$/.exec(line);
    if (fence) {
      if (m && !m[2] && m[1].length >= fence.length) fence = "";
      out.push(line);
      continue;
    }
    if (m && m[2]) { fence = m[1]; opened ||= m[2].toLowerCase() === "yui"; out.push(line); continue; }
    if (!line.trim()) { out.push(line); continue; }
    if (opened || said) continue; // below the film, or a second line above it
    said = true;
    out.push(line);
  }
  return out.join("\n").replace(/\n{3,}/g, "\n\n").trim();
}

/** Retags every ```yml / ```yaml / plain fence that opens with a Yui Line head as ```yui, and fences bare Yui Lines. */
export function asYui(text: string, ask?: string): string {
  const clean = mergeFilmAsk(closeFence(joinAttrs(joinOptions(repairMotion(restoreFilm(stripLabels(text.replace(STRAY_MARK, "")), ask))))), ask);
  return filmOnly(fenceBare(clean.replace(/^(`{3,})([\w-]*)[ \t]*\n([\s\S]*?)\n\1[ \t]*$/gm, (whole, ticks: string, tag: string, body: string) => {
    if (tag.toLowerCase() === "yui" || !PLAIN_TAGS.has(tag.toLowerCase())) return whole;
    const lines = body.split("\n");
    if (lines[0]?.trim().toLowerCase() === "yui") lines.shift(); // ```\nyui\n...: the tag landed inside the fence
    const first = lines.find((l) => l.trim())?.trim() ?? "";
    return HEAD.test(first) ? `${ticks}yui\n${lines.join("\n")}\n${ticks}` : whole;
  })));
}

/** The channel guide in about 600 tokens, for a model with a small window. Every example parses. */
export const SMALL_GUIDE = `You are talking to someone in Yui, a phone app. You can put buttons, pickers and cards on their screen. Taps come back to you as lines starting with [yui].

To draw a screen, write a fenced block whose tag is exactly yui, one line per component. Never tag it yml, yaml or text. Text outside the block is a chat bubble. Keep it short.

Example:
Pick your gear and I'll build the session.
\`\`\`yui
pick "What do you have?" Dumbbells|Barbell|Bands +other
\`\`\`

To explain how or why something works, only when asked "how does", "why" or "explain" (a request for a screen is still a screen): write ONE short line, then ONE motion line, and nothing else. The motion line is in quotes: 3 short sentences, each ending with a period, with every fact. Do not chain facts with commas. Example:
How a rainbow forms.
\`\`\`yui
motion "Sunlight enters a raindrop and bends. It splits into colors, bounces off the back, and exits. We see the colors as a rainbow."
\`\`\`

Lines (a title in quotes, options split with |):
choose "Drink" Tea|Coffee       one choice
pick "Gear" DB|Bench|Bands      several choices
ask "Log this set?"             buttons (add options: ask "Slot?" "3 pm"|"4 pm")
slide "How sore?" 1-5 Fresh|Wrecked
form "Check-in" sleep:1-10 goal:voice
list Today "Squat 5x5" "Bench 5x5" +check
card "Sunday plan" body="3 sessions, 40 min" cta="Start"
timer 5m Plank
stat 178.9lb Weight delta=-2.3
chart line "Weight" x=Mon|Tue|Wed y=180|179|178.5

Rules: one component per line, no other keys, no YAML, no indentation. Use a screen when the person should tap something. A plain question gets a plain answer.`;

/** The guide to send: the full one when it takes no more than a third of the window, the small one when it would crowd the thread out. The live guide runs ~10k tokens, so an 8k or 16k window gets the small one too (INT-26). */
export function guideFor(guide: string, context: number | undefined, tokenCount: (s: string) => number): string {
  const room = context ?? 4096;
  return tokenCount(guide) > room / 3 ? SMALL_GUIDE : guide;
}
