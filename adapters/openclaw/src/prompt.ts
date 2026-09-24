// What the agent is told about Yui (spec/CHANNEL.md, served by yui-connect).
//
// OpenClaw puts a channel's GroupSystemPrompt into the trusted system prompt
// on every turn, for direct chats too, so the guide rides there. The guide
// version comes from the session, so a new guide reaches the agent without
// reinstalling the plugin.

/** OpenClaw's own app draws A2UI; the Yui phone draws Yui Lines only. */
export const YUI_NOT_A2UI = [
  "## You are on Yui",
  "This conversation is in Yui, a phone app. Yui draws screens from Yui Lines, written in a ```yui fence, as the guide below explains.",
  "On Yui, use Yui Lines, not A2UI. Do not use the canvas or A2UI tools here: the person cannot see them. A screen you want them to see goes in a ```yui fence in your reply.",
  "Lines that start with [yui] are the person tapping one of your screens, not typing.",
].join("\n");

export function guidePrompt(guide: { version?: string; body?: string }) {
  const body = (guide.body ?? "").trim();
  return body ? `${YUI_NOT_A2UI}\n\n${body}` : YUI_NOT_A2UI;
}

/** Shown in OpenClaw's inbound metadata as response_format. */
export const FORMATTING_HINTS = {
  text_markup: "markdown plus Yui Lines screens in ```yui fences",
  rules: [
    "Put a screen in a ```yui fence written in Yui Lines (see the Yui channel guide in the system prompt).",
    "Use Yui Lines, not A2UI: the canvas and A2UI tools do not reach the phone.",
    "A line that starts with [yui] is a tap on one of your screens.",
  ],
};
