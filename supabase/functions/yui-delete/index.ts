// yui-delete: in-app account deletion (App Store Review Guideline 5.1.1(v)).
//
// Authorization: Bearer <yui access token>. Revokes the user's Sign in with
// Apple token, then deletes the yui_users row; ON DELETE CASCADE removes
// every other yui_* row (sessions, Apple token, devices, agents, pairings,
// messages). Media in the yui-media bucket has no foreign key, so it goes
// first, through the Storage API; anything left behind is an orphan the
// media sweep removes (supabase/scripts/media_sweep.py).
import {
  admin,
  APPLE_ISSUER,
  appleClientId,
  appleClientSecret,
  json,
  verifyAccessToken,
} from "../_shared/yui.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  let userId: string;
  try {
    userId = await verifyAccessToken(req);
  } catch {
    return json({ error: "unauthorized" }, 401);
  }

  try {
    const db = admin();
    const { data: tok } = await db.from("yui_apple_tokens")
      .select("refresh_token").eq("user_id", userId).maybeSingle();

    let appleRevoked = false;
    if (tok?.refresh_token) {
      const res = await fetch(`${APPLE_ISSUER}/auth/revoke`, {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({
          client_id: appleClientId(),
          client_secret: await appleClientSecret(),
          token: tok.refresh_token,
          token_type_hint: "refresh_token",
        }),
      });
      appleRevoked = res.ok;
      if (!res.ok) console.error("apple revoke failed", res.status, await res.text());
    }

    let mediaRemoved = 0;
    const { data: names, error: listErr } = await db.rpc("yui_media_names", { uid: userId });
    if (listErr) console.error("media list failed", listErr);
    for (let i = 0; names && i < names.length; i += 1000) {
      const { data: gone, error: rmErr } = await db.storage.from("yui-media")
        .remove(names.slice(i, i + 1000));
      if (rmErr) console.error("media remove failed", rmErr);
      mediaRemoved += gone?.length ?? 0;
    }

    // The user asked for deletion: delete even if Apple's revoke failed.
    const { data: gone, error } = await db.from("yui_users")
      .delete().eq("id", userId).select("id");
    if (error) throw error;
    if (!gone?.length) return json({ error: "not_found" }, 404);

    return json({ deleted: true, apple_token_revoked: appleRevoked, media_removed: mediaRemoved });
  } catch (e) {
    console.error("yui-delete", e);
    return json({ error: "server_error" }, 500);
  }
});
