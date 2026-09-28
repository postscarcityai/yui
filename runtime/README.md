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
| `profile.json` | name, handle, role, version, color (lavender, mint, butter), favorite Yui Lines, model (`default` or a model id), `shelf`, `visual` (its own quiet visual on the stage: look, hears, strength `dim` or `faint`, pace `slow` or `even`; none means the soft orb, [The visual](https://www.yuigui.com/developers/visual)) |
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

Tables (YUI-170): each agent keeps its own little database, in the words of [Agent tables](https://www.yuigui.com/developers/tables) (`table create`, `put`, `query`). The agent writes them in its yui block; the runtime (`src/tables.ts`) takes those lines out, writes the rows, and draws every `query` as a plain `table`, `list`, `chart` or `stat` with the real rows, so the app needs nothing new. A `tables` block of query lines alone is a read before the answer. `group=Day:week` and `group=Day:month` total by week or month. A row delete (`put t key +delete`) or `table drop t` never happens on the agent's say: the answer gets a Delete or Keep button, and only the tap deletes. Starter agents ship tables with starter rows: Yui (To-dos, Groceries, Notes), Basil (Foods with calories and macros, Meals, Recipes, his goal, the meal plan, Groceries), Arnold (Exercises with how-to cues, This week, Sessions), Penny (Tasks, Errands, Bills), Quill (Decks, Review), Gouda (Loops, Songs with their chords, Practice, Sessions, Studio). Controls lists them with row counts and deletes one after a confirm. Try it: `node runtime/cli.ts try "add oat milk to my groceries" --agent yui`.

Meals (YUI-103, [Meal photo to macros](https://www.yuigui.com/developers/meal)): nobody weighs anything. A photo to Basil is answered at once ("Got it, working out the macros") with no model call, and the work runs as a job after it (`src/meals.ts`, `yui_native_jobs`): the model that sees lists the items as JSON with portions in plain words, reusing the person's own foods; the runtime does the arithmetic, writes the rows in `meals`, keeps each food in `myfoods` (their food memory, with how often and when), and posts one breakdown: a line and a table of every item, then today so far with one chart. At most one short question (oil, butter, a portion), whose tap the runtime applies with no model turn. What they said no to ("no mayo") comes off the plate. A meal said in words is a `meal` block (`log "two eggs and toast"`) in Basil's answer, logged the same way. Jobs run right after the answer that queued them; the minute tick wakes one no run finished, three tries at most. Try it: `node runtime/cli.ts try "had two eggs and toast with butter" --agent basil`.

Workouts (YUI-182): Arnold's tools run from his tables with no model turn and no free turn (`src/workouts.ts`). "Start today's workout" (his shortcut, or a Start button) turns today's `this_week` row into one full-screen `plan`: what the session holds, then per move its sets to tick, reps and weight to nudge (starting from the last weight in `workouts`, the log), how it felt last, one Send. The Send writes a row per move, ticks the day and patches his pages: This week (done days ticked, a day picker), Today's workout and Progress (a streak of weeks, the best set, a chart per main lift). The first time, and when Progress gets a new lift, the pages are drawn again; otherwise only patches go, which never move the person. "Log today's workout" is a short plan for a session done off the app (the day's plan, or words like "squat 5x5 @135"), and a day tapped on This week is a plan for its focus and length. Try it: `node runtime/cli.ts try "Start today's workout" --agent arnold`.

Meal plans (YUI-183): Basil's tools run from his tables with no model turn and no free turn (`src/mealplan.ts`). "Plan my meals" (his shortcut, or a Plan button) is one full-screen `plan`: what the week aims for (his `goal`), then days, meals a day, likes, no-gos, budget and time to cook, one Send. The Send picks a week from `recipes` (a no-go never bends; budget, then time ease off when nothing fits; nothing twice a day or three times a week), writes `meal_plan`, keeps the answers in `plan_prefs`, adds up the ingredients into `groceries` by aisle, and lands as a deck: a page a day, each meal a button that swaps it. His pages stay current with patches: Today (calories and macros against the goal, the next planned meal with I ate it, each meal logged today as a button that opens its fix), This week's meals (a day a card, each meal a swap) and Groceries (a list per aisle; a tick sets Got and says nothing). "Add oat milk to my groceries", the list's Add form (a text box with a mic) and "share my grocery list" are answered the same way, and a meal logged by snap and say patches Today in its breakdown. Try it: `node runtime/cli.ts try "Plan my meals" --agent basil`.

Music (YUI-184): Gouda's tools run from his tables with no model turn and no free turn (`src/music.ts`), on the music presets ([Music tools](https://www.yuigui.com/developers/music)). "Learn a song" (his shortcut, or a Learn button) is one full-screen `plan`: what happens first, then the song (from `songs`, or their own chords pasted, any chart like `| G D | Em C |`), the key (as written, easiest on guitar, a step up or down) and how fast to start, one Send. The Send keeps the lesson in `studio` and draws his Chords page: the song's chords as buttons, the click counting in at that speed, a speed picker and a bar picker; slow it down and loop the hard bar are patches, and Keys follows the song's key. A song he has no chords for gets a form for them. `practice` is the log: "Log practice" is a short plan (how long, what, how it went), "I practiced 20 minutes on scales" logs too, and a click stopped after 10 seconds or more logs its minutes; Practice shows the streak, this week, a chart and one line on what to practice next. The Looper's Send (or a drum take) opens a short plan to name it; its Send keeps it in `sessions`, and Open a beat (or "open night drive") puts any one back on the looper. His pages: Looper, Chords, Keys, Practice (>2 to >5). Try it: `node runtime/cli.ts try "Learn a song" --agent gouda`.

Memory: each agent's notes are its own (at most 40, oldest go first); the about-you card (at most 30 facts) is shared by every native agent on the person's Yui and never by connected agents. People see, fix and forget both.

## On the server

- `supabase/migrations/20260927000000_yui_native.sql`: profiles, memory, free turns, model routes, locks, provisioning, presence for hosted agents, and the trigger that wakes the function. Ships dark: `native_enabled` is 0.
- `supabase/migrations/20260927060000_yui_native_jobs.sql`: work behind an answer (a meal's macros), claimed once (`yui_native_claim_job`), woken again by the tick when no run finished it.
- `supabase/migrations/20260927050000_yui_native_tables.sql`: each native agent's tables (`yui_native_tables`, rows as jsonb in `yui_native_table_rows`), server only, and the starter tables written by `yui_native_add_agent`.
- `supabase/functions/yui-native`: runs turns. `supabase/functions/_native` is a copy of `src/` made by the build; never edit it there.
- `yui-agents list` gives a person Yui and the crew the first time after `native_enabled` is 1.

## Tests

```
cd runtime && npm test          # parsing, memory, whole turns on a local store, the server store's requests
node runtime/scripts/build.mjs --check
```
