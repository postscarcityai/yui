'use agent';
import { createProvider } from '@earendil-works/pi-ai';
import { openAICompletionsApi } from '@earendil-works/pi-ai/api/openai-completions.lazy';
import { setProvider, useModel } from '@flue/runtime';
import * as v from 'valibot';
import { withYuiGuide } from 'yui-flue';

// A local model with no key (Ollama). Any Flue model works: set FLUE_MODEL,
// e.g. anthropic/claude-haiku-4-5 with ANTHROPIC_API_KEY.
const LOCAL = process.env.OLLAMA_MODEL ?? 'qwen2.5:7b';
setProvider(
  createProvider({
    id: 'ollama',
    // Ollama ignores the key, but pi-ai 0.83's OpenAI client wants one.
    auth: { apiKey: { name: 'Ollama (keyless)', resolve: async () => ({ auth: { apiKey: 'ollama' } }) } },
    models: [
      {
        id: LOCAL,
        name: `${LOCAL} (local)`,
        api: 'openai-completions',
        provider: 'ollama',
        baseUrl: process.env.OLLAMA_BASE_URL ?? 'http://localhost:11434/v1',
        reasoning: false,
        input: ['text'],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 32768,
        maxTokens: 2048,
      },
    ],
    api: openAICompletionsApi(),
  }),
);

export function Assistant() {
  useModel(process.env.FLUE_MODEL ?? `ollama/${LOCAL}`);
  // Nothing here mentions Yui: the screens come from the channel guide.
  return withYuiGuide('You are a friendly lunch helper. Keep answers short.');
}

Assistant.initialData = v.object({ yuiAgentId: v.string(), name: v.string() });
