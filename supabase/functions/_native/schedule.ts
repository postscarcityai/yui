// Copied from runtime/src/schedule.ts by runtime/scripts/build.mjs. Do not edit here.
// Check-ins an agent sets for later (YUI-143): "every mon,wed,fri 07:00",
// "every day 12:30", "once 2026-09-28 18:00", "in 2h". Times are the person's
// local time; next() finds the next moment in UTC with no date library.

export type Rule = { every: string; at: string } | { once: string }; // once: an ISO instant

const DAYS = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];

export function validZone(tz: string | null | undefined): string {
  if (!tz) return "UTC";
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: tz });
    return tz;
  } catch {
    return "UTC";
  }
}

/** Minutes the zone is ahead of UTC at this instant. */
function offset(at: number, tz: string): number {
  const parts = Object.fromEntries(new Intl.DateTimeFormat("en-US", {
    timeZone: tz, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit",
  }).formatToParts(new Date(at)).map((p) => [p.type, p.value]));
  const local = Date.UTC(+parts.year, +parts.month - 1, +parts.day, +parts.hour, +parts.minute, +parts.second);
  return Math.round((local - Math.floor(at / 1000) * 1000) / 60000);
}

/** A wall-clock time in a zone -> the UTC instant. */
export function zoned(y: number, mo: number, d: number, h: number, mi: number, tz: string): number {
  const guess = Date.UTC(y, mo, d, h, mi);
  let t = guess - offset(guess, tz) * 60000;
  t = guess - offset(t, tz) * 60000; // once more across a daylight-saving change
  return t;
}

/** The person's calendar date and weekday at an instant. */
function localDate(at: number, tz: string): { y: number; mo: number; d: number } {
  const p = Object.fromEntries(new Intl.DateTimeFormat("en-US", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" })
    .formatToParts(new Date(at)).map((x) => [x.type, x.value]));
  return { y: +p.year, mo: +p.month - 1, d: +p.day };
}

/** The next time this rule fires after `after` (ms), or null when it never will again. */
export function next(rule: Rule, tz: string, after: number): number | null {
  if ("once" in rule) {
    const t = Date.parse(rule.once);
    return Number.isFinite(t) && t > after ? t : null;
  }
  const m = rule.at.match(/^(\d{1,2}):(\d{2})$/);
  if (!m) return null;
  const days = rule.every === "day" ? DAYS : rule.every.split(",");
  const today = localDate(after, tz);
  for (let i = 0; i < 9; i++) {
    const base = new Date(Date.UTC(today.y, today.mo, today.d + i));
    if (!days.includes(DAYS[base.getUTCDay()])) continue;
    const t = zoned(base.getUTCFullYear(), base.getUTCMonth(), base.getUTCDate(), +m[1], +m[2], tz);
    if (t > after) return t;
  }
  return null;
}

/** One line of a `schedule` block -> a rule, or a cancel, or null. */
export function parseLine(line: string, tz: string, now: number): { rule: Rule; note: string } | { cancel: string } | null {
  const l = line.trim();
  const cancel = l.match(/^cancel\s+(s\d+)$/i);
  if (cancel) return { cancel: cancel[1].toLowerCase() };
  const note = l.match(/"((?:[^"\\]|\\.)*)"\s*$/)?.[1]?.replace(/\\(.)/g, "$1").trim();
  if (!note) return null;
  const head = l.slice(0, l.indexOf('"')).trim().toLowerCase();
  let m = head.match(/^every\s+(day|weekday|weekend|(?:(?:sun|mon|tue|wed|thu|fri|sat),?)+)\s+(\d{1,2}):(\d{2})$/);
  if (m) {
    const every = m[1] === "weekday" ? "mon,tue,wed,thu,fri" : m[1] === "weekend" ? "sat,sun" : m[1].replace(/,+$/, "");
    if (+m[2] > 23 || +m[3] > 59) return null;
    return { rule: { every, at: `${m[2].padStart(2, "0")}:${m[3]}` }, note };
  }
  m = head.match(/^once\s+(\d{4})-(\d{2})-(\d{2})\s+(\d{1,2}):(\d{2})$/);
  if (m) {
    const t = zoned(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], tz);
    return t > now ? { rule: { once: new Date(t).toISOString() }, note } : null;
  }
  m = head.match(/^in\s+(\d+)\s*(m|min|minutes?|h|hours?|d|days?)$/);
  if (m) {
    const unit = m[2][0] === "m" ? 60000 : m[2][0] === "h" ? 3600000 : 86400000;
    const t = now + +m[1] * unit;
    if (+m[1] < 1 || t - now > 60 * 86400000) return null;
    return { rule: { once: new Date(t).toISOString() }, note };
  }
  return null;
}

/** "every mon,wed 07:00" / "once Sep 28, 6:00 PM", for the prompt and the app. */
export function describe(rule: Rule, tz: string): string {
  if ("once" in rule) {
    return "once " + new Intl.DateTimeFormat("en-US", { timeZone: tz, month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }).format(new Date(rule.once));
  }
  return `every ${rule.every} ${rule.at}`;
}

/** "Saturday, September 27, 9:05 AM (America/New_York)". */
export function nowLine(at: number, tz: string): string {
  return new Intl.DateTimeFormat("en-US", { timeZone: tz, weekday: "long", month: "long", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit" })
    .format(new Date(at)) + ` (${tz})`;
}
