-- Claude, ChatGPT, Gemini and Grok keys (YUI-139 step 2): the provider list grows.
alter table public.yui_native_keys drop constraint if exists yui_native_keys_provider_check;
alter table public.yui_native_keys add constraint yui_native_keys_provider_check
  check (provider in ('openrouter', 'trustedrouter', 'groq', 'custom', 'anthropic', 'openai', 'gemini', 'xai'));
