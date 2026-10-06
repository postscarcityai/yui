// Small models draw screens in the wrong fence (INT-23): qwen2.5:7b tags a Yui
// Lines block ```yml, ```yaml or nothing at all. The app only draws ```yui, so
// the bridge retags a fence whose first line is a Yui Lines head. Runtime-neutral, no I/O.

/** The heads of a Yui Line (site/lib/yl/yl.mjs PRESETS and CORE). */
const HEADS = [
  "timer", "ask", "choose", "pick", "slide", "form", "list", "table", "card", "image", "camera", "mic",
  "gallery", "video", "compare", "storyboard", "chart", "stat", "math", "step", "calc",
  "deck", "page", "plan", "project", "narrate", "timeline", "done", "now", "next", "sketch", "row", "after",
  "shapes", "shape", "game", "flow", "query", "loop", "drums", "keys", "chords", "tuner", "metronome",
  "say", "custom", "save", "show", "forget", "clear", "end", "theme", "close", "talk", "menu", "put", "doing", "visual",
];
const HEAD = new RegExp(`^(?:>\\w*|%%.*|(?:${HEADS.join("|")})(?:@[\\w-]+)?(?:\\s|$))`);
/** Tags a model puts on a block that is not code: yml and yaml for the look of it, none, text. */
const PLAIN_TAGS = new Set(["", "yml", "yaml", "yl", "text", "txt", "plain", "plaintext", "markdown", "md", "ini", "toml"]);

/** Heads a model writes with no fence at all, and only when the line carries an argument (quote, bar or digit). Prose says "list of" and "show me"; it rarely says `timer 5m`. */
const LOOSE_HEADS = new Set(["timer", "ask", "choose", "pick", "slide", "form", "list", "table", "card", "stat", "chart", "step", "calc"]);
const unTick = (l: string): string => l.trim().replace(/^`([^`]+)`$/, "$1"); // `slide ...` in one pair of backticks
const isLooseLine = (l: string): boolean => {
  const t = unTick(l);
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

/** Retags every ```yml / ```yaml / plain fence that opens with a Yui Line head as ```yui, and fences bare Yui Lines. */
export function asYui(text: string): string {
  const clean = closeFence(stripLabels(text.replace(STRAY_MARK, "")));
  return fenceBare(clean.replace(/^(`{3,})([\w-]*)[ \t]*\n([\s\S]*?)\n\1[ \t]*$/gm, (whole, ticks: string, tag: string, body: string) => {
    if (tag.toLowerCase() === "yui" || !PLAIN_TAGS.has(tag.toLowerCase())) return whole;
    const lines = body.split("\n");
    if (lines[0]?.trim().toLowerCase() === "yui") lines.shift(); // ```\nyui\n...: the tag landed inside the fence
    const first = lines.find((l) => l.trim())?.trim() ?? "";
    return HEAD.test(first) ? `${ticks}yui\n${lines.join("\n")}\n${ticks}` : whole;
  }));
}

/** The channel guide in about 600 tokens, for a model with a small window. Every example parses. */
export const SMALL_GUIDE = `You are talking to someone in Yui, a phone app. You can put buttons, pickers and cards on their screen. Taps come back to you as lines starting with [yui].

To draw a screen, write a fenced block whose tag is exactly yui, one line per component. Never tag it yml, yaml or text. Text outside the block is a chat bubble. Keep it short.

Example:
Pick your gear and I'll build the session.
\`\`\`yui
pick "What do you have?" Dumbbells|Barbell|Bands +other
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
