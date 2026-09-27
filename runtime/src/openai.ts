// The model bridge's openai module (adapters/openai-compat), shared as is.
// scripts/build.mjs copies the real file in its place for the edge function.
export * from "../../adapters/openai-compat/src/openai.ts";
