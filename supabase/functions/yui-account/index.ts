// yui-account: the signed-in person's own account settings. Today: the app
// look (spec yuigui/spec/RESTYLE.md, section 6; migration
// 20260925100000_yui_user_look.sql).
//
// POST, Authorization: Bearer <yui access token> (role yui_user). Nothing
// else gets in: a connector token, a management token or an OAuth token is a
// 401, so a host has no write path to the look.
//
//   {"action": "get"}                      -> {user: {id, email}, look}
//   {"action": "look"}                     -> {look}          (read; null = Yui's own look)
//   {"action": "set_look", "look": {...}}  -> {look}          (set; the cleaned, stored value)
//   {"action": "set_look", "look": null}   -> {look: null}    (back to Yui's own look)
// ("look" with a "look" key also writes, same as set_look.)
//
// A look is flat: preset, accent, bg, radius, font, weight, motion,
// agents_keep_looks, via, at, by, and "prev": one recipe of the same keys
// (no prev inside; {} means Undo goes back to Yui's own look).
//
// The look is written only on the person's tap (Apply, Undo, Reset, Settings).
// It is cleaned strictly, unlike an agent's theme: an unknown key or a bad
// value is a 400 `bad_look` naming the key, and nothing is stored. The server
// sets `at` and `by: "user"`; whatever the app sent for them is ignored.
import { admin, assertActive, failure, json, take, verifyAccessToken } from "../_shared/yui.ts";

// Named sets, same names as AgentLook.sets (app) and SETS (site/lib/yl/look.mjs).
export const SETS = new Set([
  "yui", "candy", "berry", "cherry", "coral", "sunset", "peach", "autumn", "honey", "lemon",
  "lime", "matcha", "forest", "mint", "teal", "sky", "ocean", "midnight", "lavender", "grape",
  "slate", "mono", "wizard", "coach", "zen", "studio", "night", "counsel",
]);
const PAPERS = new Set(["cream", "paper", "white", "mist", "sand", "blush"]);
const HEX = /^#[0-9A-Fa-f]{6}$/;
const WORDS: Record<string, Set<string>> = {
  radius: new Set(["round", "soft", "square"]),
  font: new Set(["rounded", "default", "serif", "mono"]),
  weight: new Set(["regular", "bold", "heavy"]),
  motion: new Set(["bouncy", "calm", "snappy"]),
};
const KEYS = new Set([
  "preset", "accent", "bg", "radius", "font", "weight", "motion",
  "prev", "agents_keep_looks", "at", "by", "via",
]);
const ISO = /^\d{4}-\d{2}-\d{2}[T ][0-9:.]+(Z|[+-]\d{2}(:?\d{2})?)?$/;

export class BadLook extends Error {
  constructor(public key: string) {
    super(key);
  }
}

// deno-lint-ignore no-explicit-any
type Obj = Record<string, any>;

function isObj(v: unknown): v is Obj {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function cleanVia(v: unknown): string {
  if (typeof v !== "string") throw new BadLook("via");
  const t = v.trim().replace(/\s+/g, " ");
  // deno-lint-ignore no-control-regex
  if (t.length < 1 || t.length > 60 || /[\u0000-\u001f\u007f]/.test(t)) throw new BadLook("via");
  return t;
}

// One recipe. `nested` is the `prev` inside a look: it may not hold a `prev`,
// and its `at`/`by` (copied from the look it replaced) are kept if they are sane.
function cleanRecipe(v: Obj, nested: boolean): Obj {
  const out: Obj = {};
  const where = (k: string) => (nested ? `prev.${k}` : k);
  for (const [k, x] of Object.entries(v)) {
    if (!KEYS.has(k)) throw new BadLook(where(k));
    if (x === null || x === undefined) continue; // an absent key, said out loud
    switch (k) {
      case "preset": {
        const s = typeof x === "string" ? x.toLowerCase() : "";
        if (!SETS.has(s)) throw new BadLook(where(k));
        out.preset = s;
        break;
      }
      case "accent": {
        if (typeof x !== "string") throw new BadLook(where(k));
        if (HEX.test(x)) out.accent = x.toUpperCase();
        else if (SETS.has(x.toLowerCase())) out.accent = x.toLowerCase();
        else throw new BadLook(where(k));
        break;
      }
      case "bg": {
        if (typeof x !== "string") throw new BadLook(where(k));
        if (HEX.test(x)) out.bg = x.toUpperCase();
        else if (PAPERS.has(x.toLowerCase())) out.bg = x.toLowerCase();
        else throw new BadLook(where(k));
        break;
      }
      case "radius":
      case "font":
      case "weight":
      case "motion": {
        const s = typeof x === "string" ? x.toLowerCase() : "";
        if (!WORDS[k].has(s)) throw new BadLook(where(k));
        out[k] = s;
        break;
      }
      case "agents_keep_looks":
        if (typeof x !== "boolean") throw new BadLook(where(k));
        out.agents_keep_looks = x;
        break;
      case "via":
        out.via = cleanVia(x);
        break;
      case "prev":
        if (nested) throw new BadLook("prev.prev");
        if (!isObj(x)) throw new BadLook("prev");
        // {} is kept: Undo goes back to Yui's own look.
        out.prev = cleanRecipe(x, true);
        break;
      case "at":
        // The server stamps the top level; a prev keeps the stamp it had.
        if (nested) {
          if (typeof x !== "string" || !ISO.test(x) || isNaN(Date.parse(x))) throw new BadLook(where(k));
          out.at = x;
        }
        break;
      case "by":
        if (nested) {
          if (x !== "user") throw new BadLook(where(k));
          out.by = "user";
        }
        break;
    }
  }
  return out;
}

// The look to store: cleaned, stamped. Throws BadLook.
export function cleanAppLook(v: unknown, now = new Date()): Obj {
  if (!isObj(v)) throw new BadLook("look");
  const out = cleanRecipe(v, false);
  out.at = now.toISOString();
  out.by = "user";
  return out;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  let userId: string;
  try {
    userId = await verifyAccessToken(req);
  } catch {
    return json({ error: "unauthorized" }, 401);
  }
  let body: Obj;
  try {
    body = await req.json();
    if (!isObj(body)) throw new Error("not an object");
  } catch {
    return json({ error: "invalid_request" }, 400);
  }

  try {
    const db = admin();
    switch (body.action) {
      case "get": {
        const { data, error } = await db.from("yui_users").select("id, email, look")
          .eq("id", userId).maybeSingle();
        if (error) throw error;
        if (!data) return json({ error: "not_found" }, 404);
        return json({ user: { id: data.id, email: data.email }, look: data.look ?? null });
      }
      case "look":
      case "set_look": {
        if (body.action === "look" && !("look" in body)) {
          const { data, error } = await db.from("yui_users").select("look").eq("id", userId).maybeSingle();
          if (error) throw error;
          if (!data) return json({ error: "not_found" }, 404);
          return json({ look: data.look ?? null });
        }
        if (!("look" in body)) return json({ error: "bad_look", key: "look" }, 400);
        let look: Obj | null = null;
        if (body.look !== null) {
          try {
            look = cleanAppLook(body.look);
          } catch (e) {
            if (e instanceof BadLook) return json({ error: "bad_look", key: e.key }, 400);
            throw e;
          }
          if (new TextEncoder().encode(JSON.stringify(look)).length > 1800) {
            return json({ error: "bad_look", key: "size" }, 400);
          }
        }
        await assertActive(db, userId);
        await take(db, `account:u:${userId}`, "agents_api");
        const { data, error } = await db.from("yui_users").update({ look })
          .eq("id", userId).select("look");
        if (error) throw error;
        if (!data?.length) return json({ error: "not_found" }, 404);
        return json({ look: data[0].look ?? null });
      }
      default:
        return json({ error: "unknown_action" }, 400);
    }
  } catch (e) {
    return failure("yui-account", e);
  }
});
