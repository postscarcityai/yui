// Profiles: the folder format (runtime/profiles/<name>/) and the shelf.
// A profile folder holds profile.json, soul.md and first.yui. scripts/build.mjs
// bakes every folder into crew.gen.ts, so the edge function needs no files.
import { COLORS, PRESETS, type Profile } from "./types.ts";
import { CREW } from "./crew.gen.ts";

/** The files of one profile folder -> a Profile. Throws with what is wrong. */
export function parseProfile(base: string, files: { "profile.json": string; "soul.md": string; "first.yui": string }): Profile {
  let meta: any;
  try {
    meta = JSON.parse(files["profile.json"]);
  } catch (e: any) {
    throw new Error(`${base}/profile.json: ${e.message}`);
  }
  const p: Profile = {
    base,
    name: String(meta.name ?? ""),
    handle: String(meta.handle ?? base),
    role: String(meta.role ?? ""),
    version: Number(meta.version ?? 1),
    color: meta.color ?? "lavender",
    favorites: Array.isArray(meta.favorites) ? meta.favorites.map(String) : [],
    model: String(meta.model ?? "default"),
    soul: files["soul.md"].trim(),
    first: files["first.yui"].trim(),
    ...(meta.shelf ? { shelf: true } : {}),
    ...(meta.maker ? { maker: true } : {}),
    ...(meta.careful ? { careful: true } : {}),
    ...(meta.sees ? { sees: true } : {}),
    ...(meta.blank ? { blank: true } : {}),
  };
  const bad = checkProfile(p);
  if (bad.length) throw new Error(`${base}: ${bad.join("; ")}`);
  return p;
}

/** What is wrong with a profile, in plain words; empty when it is fine. */
export function checkProfile(p: Profile): string[] {
  const out: string[] = [];
  if (!p.name || p.name.length > 40) out.push("name must be 1 to 40 characters");
  if (!/^[a-z0-9][a-z0-9-]{0,31}$/.test(p.handle)) out.push(`handle "${p.handle}" must be lowercase letters, digits and dashes`);
  if (!Number.isInteger(p.version) || p.version < 1) out.push("version must be a whole number from 1");
  if (!(COLORS as readonly string[]).includes(p.color)) out.push(`color must be one of ${COLORS.join(", ")}`);
  const unknown = p.favorites.filter((f) => !PRESETS.has(f));
  if (unknown.length) out.push(`favorites not drawn by the app: ${unknown.join(", ")}`);
  if (!p.soul) out.push("soul.md is empty");
  if (p.soul.length > 4000) out.push("soul.md is over 4000 characters");
  if (!/```yui\n[\s\S]+?\n```/.test(p.first)) out.push("first.yui needs a ```yui fence");
  if (/\u2014/.test(p.soul + p.first)) out.push("no em dashes");
  return out;
}

/** Every built-in profile, by base name. */
export function crew(): Record<string, Profile> {
  return CREW;
}

/** The profiles every person starts with, Yui first. */
export function starters(): Profile[] {
  return ["yui", "arnold", "basil", "gouda", "penny", "quill"].map((b) => CREW[b]).filter(Boolean);
}

/** Profiles Yui can hand out from the shelf. */
export function shelf(): Profile[] {
  return Object.values(CREW).filter((p) => p.shelf);
}
