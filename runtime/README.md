# Native Yui (NATIVE-1)

The agent every person gets in the Yui app, and a starter anyone can run and fork. Spec: [Native Yui](https://www.yuigui.com/developers/native).

Yui is a helper and a maker. She answers on the first launch, knows the rest of the crew (Arnold the trainer, Basil the nutritionist, Gouda the musician, Penny the planner, Quill the study buddy) and makes new agents when you ask. Every native agent draws every Yui screen and remembers you.

```
 any Yui client  <-->  Yui relay (rows in yui_messages)  --new row-->  yui-native (this runtime)  -->  OpenRouter  -->  GLM 5.2 / GLM-5V-Turbo
```

## Try it on your machine

Needs Node 22.18 or newer. No dependencies.

```
export OPENROUTER_API_KEY=...          # in your shell, never in a file you share
export FIRECRAWL_API_KEY=...           # optional: web search and page reading (firecrawl.dev)
node runtime/cli.ts chat               # talk to Yui; /agents, /use gouda, /memory, /quit
node runtime/cli.ts try "make me a lo-fi beat" --agent gouda
node runtime/cli.ts memory             # what your agents remember about you
```

Any OpenAI-compatible server works instead of OpenRouter: `--url http://127.0.0.1:11434/v1 --model qwen3:8b` (add `--key-env NAME` when it needs a key). Everything lives in `~/.yui-native/state.json`; delete it to start over.

## Make your own agent

A profile is a folder in `profiles/`:

| File | What it holds |
|---|---|
| `profile.json` | name, handle, role, version, color (lavender, mint, butter), favorite Yui Lines, model (`default` or a model id), `shelf` |
| `soul.md` | who the agent is, how it talks, what it never does, in the second person |
| `first.yui` | its first answer: a line of text and a `yui` fence with a real question on a screen |
| `tables.yui` | optional: its starter tables, as `table create` and `put` lines (no `today` or `now`: seeds are written by SQL) |

Copy a folder, change it, run `node runtime/scripts/build.mjs` (it loads every folder with `loadProfile` from `src/profiles.ts`, stops on any that fails its check, bakes the rest into `src/crew.gen.ts` and refreshes the edge copy), then `node runtime/cli.ts profiles` to check it. The check wants a known color and handle, favorites the app draws, a soul under 4000 characters with no em dashes, and a first answer that is a line of text then a screen. Bump `version` to try a v2 next to v1.

## How a turn works

1. The person's new rows are marked delivered; the working row says "Thinking".
2. The prompt: the channel guide, the runtime's rules (`src/prompt.ts`), the agent's soul and favorite screens, what it remembers, the crew (for Yui), then the newest thread that fits.
3. A turn with a photo goes to the model that sees (`yui_native_models`); every other turn to the agent's model or the default.
4. An answer that is only a `search` block (a query) or a `fetch` block (a link) is looked up on Firecrawl (`src/search.ts`) and the model is asked again with what came back, a few times a turn at most. Sources the answer doesn't link show under it as cards. On Yui's key each person has free lookups a month and a day (`yui_limits`); past them the agent answers from what it knows and a card opens Settings, where a person's own Firecrawl key lifts the cap.
5. The agent may end its answer with a `remember` block (facts on the shared about-you card, its own notes, forgetting) and, for Yui or a blank agent, an `agents` block (make, fork, rename, remove, or set itself up). The runtime takes both out and applies them; the person sees only the answer.
6. The answer is written with `meta.turn`, the rows are marked handled, and a push goes out.

Tables (YUI-170): each agent keeps its own little database, in the words of [Agent tables](https://www.yuigui.com/developers/tables) (`table create`, `put`, `query`). The agent writes them in its yui block; the runtime (`src/tables.ts`) takes those lines out, writes the rows, and draws every `query` as a plain `table`, `list`, `chart` or `stat` with the real rows, so the app needs nothing new. A `tables` block of query lines alone is a read before the answer. `group=Day:week` and `group=Day:month` total by week or month. A row delete (`put t key +delete`) or `table drop t` never happens on the agent's say: the answer gets a Delete or Keep button, and only the tap deletes. Starter agents ship tables with starter rows: Yui (To-dos, Groceries, Notes), Basil (Foods with calories and macros, Meals), Arnold (Exercises with how-to cues, This week, Sessions), Penny (Tasks, Errands, Bills), Quill (Decks, Review), Gouda (Loops, Songs). Controls lists them with row counts and deletes one after a confirm. Try it: `node runtime/cli.ts try "add oat milk to my groceries" --agent yui`.

Memory: each agent's notes are its own (at most 40, oldest go first); the about-you card (at most 30 facts) is shared by every native agent on the person's Yui and never by connected agents. People see, fix and forget both.

## On the server

- `supabase/migrations/20260927000000_yui_native.sql`: profiles, memory, free turns, model routes, locks, provisioning, presence for hosted agents, and the trigger that wakes the function. Ships dark: `native_enabled` is 0.
- `supabase/migrations/20260927050000_yui_native_tables.sql`: each native agent's tables (`yui_native_tables`, rows as jsonb in `yui_native_table_rows`), server only, and the starter tables written by `yui_native_add_agent`.
- `supabase/functions/yui-native`: runs turns. `supabase/functions/_native` is a copy of `src/` made by the build; never edit it there.
- `yui-agents list` gives a person Yui and the crew the first time after `native_enabled` is 1.

## Tests

```
cd runtime && npm test          # parsing, memory, whole turns on a local store, the server store's requests
node runtime/scripts/build.mjs --check
```
