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

/** Retags every ```yml / ```yaml / plain fence that opens with a Yui Line head as ```yui. */
export function asYui(text: string): string {
  return text.replace(/^(`{3,})([\w-]*)[ \t]*\n([\s\S]*?)\n\1[ \t]*$/gm, (whole, ticks: string, tag: string, body: string) => {
    if (tag.toLowerCase() === "yui" || !PLAIN_TAGS.has(tag.toLowerCase())) return whole;
    const first = body.split("\n").find((l) => l.trim())?.trim() ?? "";
    return HEAD.test(first) ? `${ticks}yui\n${body}\n${ticks}` : whole;
  });
}

/** Below this many tokens of room the full channel guide leaves no space for a thread. */
export const SMALL_CONTEXT = 8192;

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

/** The guide to send: the full one when the window has room, the small one when it would crowd the thread out. */
export function guideFor(guide: string, context: number | undefined, tokenCount: (s: string) => number): string {
  const room = context ?? 4096;
  return room < SMALL_CONTEXT && tokenCount(guide) > room / 3 ? SMALL_GUIDE : guide;
}
