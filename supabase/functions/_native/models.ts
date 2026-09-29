// Copied from runtime/src/models.ts by runtime/scripts/build.mjs. Do not edit here.
// What a person can pick (Controls, Model) and which providers take their own
// key (Settings, Your model key). A model joins MODELS only after the channel
// eval scores it (spec/NATIVE.md section 6).

export interface ModelChoice { id: string; label: string; sees: boolean }

export const MODELS: ModelChoice[] = [
  { id: "default", label: "Yui's pick (GLM 5.2, GLM-5V-Turbo for photos)", sees: true },
  { id: "z-ai/glm-5.2", label: "GLM 5.2", sees: false },
  { id: "z-ai/glm-5v-turbo", label: "GLM-5V-Turbo", sees: true },
];

/** Where a person's own key runs. `model` and `vision` are the defaults when they name none, so a key needs no model id;
 *  `vision` null means the provider has no seeing default (a photo turn says so). `scored` is false until the channel eval
 *  passes the provider on a live turn (spec/NATIVE.md section 6): the app is not offered it and key_set refuses it. */
export interface ProviderChoice {
  id: ProviderId; label: string; url: string; needsModel: boolean; web: boolean;
  model?: string; vision?: string | null; scored: boolean;
  keyUrl?: string; // where to make a key, shown as a link in the key sheet
  signIn?: boolean; // one tap sign-in (OAuth PKCE) instead of a pasted key
  keyless?: boolean; // a server on their own computer may need no key (Ollama, LM Studio)
  plan?: string; // one line when a chat plan can't pay for it
}
export type ProviderId = "openrouter" | "trustedrouter" | "groq" | "custom" | "anthropic" | "openai" | "gemini" | "xai";

const PLAN = "A Claude Pro or Max plan can't pay for another app. Only an API key can.";

export const PROVIDERS: ProviderChoice[] = [
  { id: "openrouter", label: "OpenRouter", url: "https://openrouter.ai/api/v1", needsModel: false, web: true, scored: true, signIn: true,
    keyUrl: "https://openrouter.ai/keys" },
  // TrustedRouter takes OpenRouter's model ids, so Yui's picks work there unless you name another.
  { id: "trustedrouter", label: "TrustedRouter", url: "https://api.trustedrouter.com/v1", needsModel: false, web: false, scored: true },
  { id: "groq", label: "Groq", url: "https://api.groq.com/openai/v1", needsModel: true, web: false, scored: true },
  { id: "custom", label: "My computer", url: "", needsModel: true, web: false, scored: true, keyless: true },
  { id: "anthropic", label: "Claude", url: "https://api.anthropic.com/v1", needsModel: false, web: false, scored: false,
    model: "claude-sonnet-5-5", vision: "claude-sonnet-5-5", keyUrl: "https://console.anthropic.com/settings/keys", plan: PLAN },
  { id: "openai", label: "ChatGPT", url: "https://api.openai.com/v1", needsModel: false, web: false, scored: false,
    model: "gpt-5.5", vision: "gpt-5.5", keyUrl: "https://platform.openai.com/api-keys", plan: "A ChatGPT Plus or Pro plan can't pay for another app. Only an API key can." },
  { id: "gemini", label: "Gemini", url: "https://generativelanguage.googleapis.com/v1beta/openai", needsModel: false, web: false, scored: false,
    model: "gemini-3-flash", vision: "gemini-3-flash", keyUrl: "https://aistudio.google.com/apikey" },
  { id: "xai", label: "Grok", url: "https://api.x.ai/v1", needsModel: false, web: false, scored: false,
    model: "grok-4.7", vision: "grok-4.7", keyUrl: "https://console.x.ai" },
];

/** The words for "your own ___ key" (controls, errors). */
export function providerLabel(id: string): string {
  return id === "custom" ? "computer" : PROVIDERS.find((p) => p.id === id)?.label ?? id;
}

/** The model a key runs a turn on: the one they named, else the provider's default (the seeing one for a photo). Null: the caller's own routing. */
export function keyModel(id: string, named: string | null, photo: boolean): string | null {
  if (named) return named;
  const p = PROVIDERS.find((x) => x.id === id);
  return (photo ? p?.vision : p?.model) ?? null;
}
