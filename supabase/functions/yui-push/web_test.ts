import { reminderPayload, webPayload, webQuiet } from "./payload.ts";
import { validEndpoint, validKey, validTz } from "./web.ts";

const eq = (a: unknown, b: unknown) => {
  if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${JSON.stringify(a)} != ${JSON.stringify(b)}`);
};

Deno.test("a reply opens the agent's thread, in its chat", () => {
  const p = webPayload({ id: "a1", name: "Penny" }, { id: "m1", body: "Dinner is at 7", chat_id: "c9" });
  eq(p.url, "/web/agent/a1/chat/c9");
  eq(p.tag, "a1");
  eq(p.title, "Penny");
  eq(p.body, "Dinner is at 7");
});

Deno.test("a screen-only reply reads as something for you", () => {
  const p = webPayload({ id: "a1", name: "Penny" }, { id: "m1", body: "```yui\nstage\n```" });
  eq(p.body, "Penny has something for you in Yui");
  eq(p.url, "/web/agent/a1");
});

Deno.test("quiet messages carry no words", () => {
  eq(webQuiet("clear", "a1"), { kind: "clear", agent_id: "a1", tag: "a1" });
});

Deno.test("endpoints are https and keys are base64url", () => {
  eq(validEndpoint("https://web.push.apple.com/abc"), true);
  eq(validEndpoint("http://example.com/x"), false);
  eq(validEndpoint("https://u:p@example.com/x"), false);
  eq(validEndpoint(42), false);
  eq(validKey("BMkwrpZbYs69NGq39KD8ZQb8s39L8uYd3MpTp6m2p9FS"), true);
  eq(validKey("short"), false);
});

Deno.test("a reminder carries the open tab's tag and opens the thread", () => {
  const p = reminderPayload({ id: "a1", name: "Penny" }, "task-7", "  Stand   up\n now ");
  eq(p, { kind: "reminder", title: "Penny", body: "Stand up now", agent_id: "a1", key: "task-7", tag: "yui.reminder.a1.task-7", url: "/web/agent/a1" });
});

Deno.test("a reminder with no words still says who set it", () => {
  eq(reminderPayload({ id: "a1", name: "Penny" }, "k", "").body, "Penny set a reminder");
  eq(reminderPayload({ id: "a1", name: "Penny" }, "k", "x".repeat(400)).body.length, 160);
});

Deno.test("time zones are IANA names", () => {
  eq(validTz("America/New_York"), true);
  eq(validTz("Etc/GMT+5"), true);
  eq(validTz("America/New York; drop"), false);
  eq(validTz(""), false);
  eq(validTz(5), false);
});
