// yui-vault: see handler.ts. Deployed with verify_jwt = false (config.toml): the
// caller is an agent host with a yui_ct_ connection token, checked in the handler.
import { admin, connectorByToken } from "../_shared/yui.ts";
import { KEY_ID, PUBLIC_KEY, ROTATED_AT } from "./connector_key.ts";
import { createHandler } from "./handler.ts";
import { supabaseStore } from "./store.ts";

Deno.serve(createHandler({
  store: supabaseStore(admin(), connectorByToken),
  fetch: (...a) => fetch(...a),
  env: (n) => Deno.env.get(n),
  wellKnown: { key_id: Deno.env.get("YUI_VAULT_KEY_ID") ?? KEY_ID, public_key: Deno.env.get("YUI_VAULT_PUBLIC_KEY") ?? PUBLIC_KEY, rotated_at: Deno.env.get("YUI_VAULT_ROTATED_AT") ?? ROTATED_AT },
}));
