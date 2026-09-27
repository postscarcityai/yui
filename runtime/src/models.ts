// What a person can pick (Controls, Model) and which providers take their own
// key (Settings, Your model key). A model joins MODELS only after the channel
// eval scores it (spec/NATIVE.md section 6).

export interface ModelChoice { id: string; label: string; sees: boolean }

export const MODELS: ModelChoice[] = [
  { id: "default", label: "Yui's pick (GLM 5.2, GLM-5V-Turbo for photos)", sees: true },
  { id: "z-ai/glm-5.2", label: "GLM 5.2", sees: false },
  { id: "z-ai/glm-5v-turbo", label: "GLM-5V-Turbo", sees: true },
];

export interface ProviderChoice { id: "openrouter" | "trustedrouter" | "groq" | "custom"; label: string; url: string; needsModel: boolean; web: boolean }

export const PROVIDERS: ProviderChoice[] = [
  { id: "openrouter", label: "OpenRouter", url: "https://openrouter.ai/api/v1", needsModel: false, web: true },
  // TrustedRouter takes OpenRouter's model ids, so Yui's picks work there unless you name another.
  { id: "trustedrouter", label: "TrustedRouter", url: "https://api.trustedrouter.com/v1", needsModel: false, web: false },
  { id: "groq", label: "Groq", url: "https://api.groq.com/openai/v1", needsModel: true, web: false },
  { id: "custom", label: "Another server", url: "", needsModel: true, web: false },
];
