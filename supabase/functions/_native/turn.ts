// Copied from runtime/src/turn.ts by runtime/scripts/build.mjs. Do not edit here.
// One native turn, the same on a laptop and in the edge function (YUI-130):
// take the person's new rows, build the prompt, ask the model, keep what the
// agent chose to remember, apply its agent changes, check-ins, search and
// hand-offs, write the answer.
// Relay rules as every host (yuigui spec/RELAY.md): delivered when the turn
// starts, `doing` while it works, handled once the answer is written, and the
// answer names its rows in meta.turn.
//
// A turn can also start with no row from the person (a "synthetic" turn): a
// check-in firing (runScheduled) or another agent handing the person over.
// Those answer in the thread and are never marked on any row.
import { ChatClient, ModelError, ModelUnavailable, type Completion } from "./openai.ts";
import { extract } from "./directives.ts";
import { applyMemory } from "./memory.ts";
import { applyAgentOps } from "./agents.ts";
import { buildTurn, photoPaths, type CrewEntry } from "./prompt.ts";
import { next, parseLine, validZone } from "./schedule.ts";
import { Firecrawl, LookupError, searchInvite, sourceCards, type Source } from "./search.ts";
import type { Store } from "./store.ts";
import { Stopped, guard } from "./stop.ts";
import { crew } from "./profiles.ts";
import { type Clock, type TableStore, LIMITS, applyHeld, applyTables, asText, changed, clock, diff, draw, emptyStore, fromSeeds, pretty,
         readQueries, tablesPrompt } from "./tables.ts";
import type { NativeAgent, OwnKey, Row, ScheduleItem } from "./types.ts";
import { applyDay, applyLogged, applyRunner, editDayBody, logBody, loggedLine, progressShape, screenLines, session, splitDays, startReply,
         trains, workoutAsks, type Session, type WorkoutAsk } from "./workouts.ts";
import { ACK, type MealFix, applyFix, fixTaps, logsMeals, mealTurn, runMealJob, spoken } from "./meals.ts";
import { ADD_BODY, GOAL, GROCERIES, LOG_BODY, MEALS as MEAL_LOG, PLAN as MEAL_PLAN, addGroceries, applyMealFix, applyPlan, applySwap, ensureTools,
         drawnShape, fixBody, groceryText, lastPrefs, logPlanned, mealAsks, nextPlanned, planBody, plansMeals, readItems, screenLines as mealScreenLines, tickGrocery,
         weekDeck, type MealAsk } from "./mealplan.ts";
import { applyBar, applyLearn, applyOpen, applyPracticed, applySave, applyScale, applySpeed, drawnShape as musicShape, ensureTools as ensureMusic,
         keepDraft, learnBody, logPractice, musicAsks, musicPages, pasteBody, playBpm, lesson, playsMusic, practiceBody, readTake, saveBody,
         screenLines as musicScreenLines, streak, type MusicAsk, type Page as MusicPage } from "./music.ts";
import { ADD_BODY as TODO_BODY, TASKS, addTasks, applyMove, applyOrder, applyPlan as applyWeekPlan, applyReview, clockText, dayWord, drawnShape as plannerShape,
         ensureTools as ensurePlanner, moveBody, nextText, nextTask, planAsks, planBody as weekPlanBody, plansWeeks, remindLead, reminderMeta, reviewBody,
         screenLines as plannerScreenLines, syncReminders, tickTask, type Page as PlannerPage, type PlanAsk } from "./planner.ts";
import { card as handoffCard, cards as handoffCards, chatIsNew, chatOf, handedIn, handlesIn, oneThread, threadOf, withCard } from "./handoff.ts";
import { LESSON_PROMPT, PROBLEM_PROMPT, answerStep, applyQuiz, applyReview as applyCardReview, drawnShape as studyShape,
         ensureTools as ensureStudy, keepLesson, keepProblem, learnBody as lessonPlanBody, lessonAsk, lessonBody, nextText as dueText, parseLesson, parseProblem,
         problemAsk, problemBody, problems as problemRows, readLearn, readProblem, reviewBody as cardReviewBody, screenLines as studyScreenLines,
         stepLines, stepsOf, studies, studyAsks, studyPages, dueCards, type Page as StudyPage, type StudyAsk } from "./study.ts";

export interface Provider {
  url: string; // an OpenAI-compatible base URL
  key?: string;
  headers?: Record<string, string>;
  extra?: Record<string, unknown>; // sent with every request (OpenRouter's provider rules)
  model?: string; // this provider's own model, when it is not OpenRouter's ids (a person's Groq key)
  reasoning?: number; // tokens the model may think before it answers, on top of the answer's (OpenRouter's reasoning.max_tokens)
}

const OPENROUTER = "https://openrouter.ai/api/v1";
// GLM 5.2 left alone can think through the whole answer budget and say nothing
// (YUI-162): the thinking gets its own 1000 on top, and the answer keeps its 2000.
const REASONING = 1000;

/** OpenRouter, on Yui's key for now (spec/NATIVE.md section 7). */
export function openRouter(key: string): Provider {
  return {
    url: OPENROUTER,
    key,
    headers: { "HTTP-Referer": "https://www.yuigui.com", "X-Title": "Yui" },
    extra: { provider: { data_collection: "deny" } },
    reasoning: REASONING,
  };
}

/** A person's own key: OpenRouter keeps Yui's routes; any other server runs the model they named. */
export function ownProvider(k: OwnKey): Provider {
  if (k.provider === "openrouter") return { ...openRouter(k.key), ...(k.model ? { model: k.model } : {}) };
  return { url: k.baseUrl, key: k.key, ...(k.model ? { model: k.model } : {}) };
}

export interface TurnOptions {
  provider: Provider; // Yui's own; a person's own key replaces it
  search?: SearchOptions; // web lookups (Firecrawl); none: agents answer from what they know
  fetch?: typeof fetch; // the model side only (tests)
  fetchMedia?: typeof fetch; // fetching a person's photo to inline it (tests)
  maxTokens?: number; // default 2000
  context?: number; // default 32768
  historyRows?: number; // default 60
  maxTurns?: number; // turns in one wake, default 3
  log?: (msg: string) => void;
  now?: () => number;
  newId?: () => string;
  signal?: AbortSignal; // the person's Stop (YUI-190): aborted, the model call ends and nothing more is written
  stopPoll?: number; // ms between looks for a Stop while a turn runs, default 1500
}

export interface SearchOptions {
  key?: string; // Yui's Firecrawl key; a person's own key (Settings) replaces it and lifts the monthly cap
  fetch?: typeof fetch; // the Firecrawl side (tests)
  base?: string;
}

export interface TurnResult {
  turns: number;
  replies: string[]; // row ids written, in any thread (hand-offs write in another)
  busy?: boolean;
  jobs: string[]; // work queued to run after the answer (runJob): a meal's macros
}

const HISTORY_ROWS = 60;
const SYNTHETIC = "synthetic:";

/** Runs every turn waiting for this agent, one at a time. Safe to call twice: the second sees the lock. */
export async function runAgent(store: Store, agentId: string, opts: TurnOptions): Promise<TurnResult> {
  const log = opts.log ?? (() => {});
  const result: TurnResult = { turns: 0, replies: [], jobs: [] };
  if (!(await store.lock(agentId, 300))) return { ...result, busy: true };
  try {
    for (let i = 0; i < (opts.maxTurns ?? 3); i++) {
      const agent = await store.agent(agentId);
      if (!agent) break;
      // One thread a turn: a group's rows (YUI-144) and the agent's own are answered apart.
      const rows = oneThread(await store.pending(agentId));
      if (!rows.length) break;
      const done = await stoppable(store, agent, rows, opts, log, (s, o) => oneTurn(s, agent, rows, o, log, result, 0));
      result.turns++;
      if (!done.handled) break; // the model is away: the rows wait for the next message
    }
  } finally {
    await store.unlock(agentId);
  }
  return result;
}

/** A check-in fires: set its next time first, then the agent opens with it. */
export async function runScheduled(store: Store, scheduleId: string, opts: TurnOptions): Promise<TurnResult> {
  const log = opts.log ?? (() => {});
  const result: TurnResult = { turns: 0, replies: [], jobs: [] };
  const s = await store.schedule(scheduleId);
  if (!s || s.paused) return result;
  const agent = await store.agent(s.agentId);
  const now = (opts.now ?? Date.now)();
  // Its number as the agent's list shows it, read before a one-time check-in leaves the list.
  const n = agent ? (await store.schedules(agent.id)).findIndex((x) => x.id === s.id) + 1 || "x" : "x";
  const at = next(s.rule, s.tz, now + 60_000);
  if (at) await store.setScheduleNext(s.id, new Date(at).toISOString());
  else await store.dropSchedule(s.id); // a one-time check-in is done once it fires
  if (!agent) return result;
  await synthetic(store, agent, `[yui] check-in s${n} "${s.note.replace(/"/g, "'")}"`, opts, log, result, 0);
  return result;
}

/** A turn with no row from the person, under the agent's lock (waits a little for it). */
async function synthetic(store: Store, agent: NativeAgent, line: string, opts: TurnOptions, log: (m: string) => void,
                         result: TurnResult, depth: number): Promise<void> {
  let locked = false;
  for (let i = 0; i < 20 && !(locked = await store.lock(agent.id, 300)); i++) await new Promise((r) => setTimeout(r, 1500));
  if (!locked) {
    log(`${agent.profile.name}: busy, skipped "${line.slice(0, 60)}"`);
    return;
  }
  try {
    const row: Row = { id: `${SYNTHETIC}${uuid()}`, sender: "user", kind: "event", body: line, meta: {},
                       created_at: new Date((opts.now ?? Date.now)()).toISOString() };
    await oneTurn(store, agent, [row], opts, log, result, depth);
    result.turns++;
    // The person may have written while this ran: their own wake found the lock taken and left (t_a88dc3b5, a
    // macros ask sent four hand-offs to Basil and his answer to the ask never came). Answer them before letting go.
    for (let i = 0; i < (opts.maxTurns ?? 3); i++) {
      const rows = oneThread(await store.pending(agent.id));
      if (!rows.length) break;
      const done = await stoppable(store, agent, rows, opts, log, (s, o) => oneTurn(s, agent, rows, o, log, result, depth));
      result.turns++;
      if (!done.handled) break;
    }
  } finally {
    await store.unlock(agent.id);
  }
}

/**
 * A turn the person can stop (YUI-190): its writes ask about a Stop first and its model call
 * ends when one lands. Stopped, it wrote nothing and its rows are handled.
 */
async function stoppable(store: Store, agent: NativeAgent, rows: Row[], opts: TurnOptions, log: (m: string) => void,
                         run: (store: Store, opts: TurnOptions) => Promise<{ handled: boolean }>): Promise<{ handled: boolean }> {
  const real = rows.filter((r) => !r.id.startsWith(SYNTHETIC));
  if (!real.length) return run(store, opts);
  const who = (real[0] as Row & { user_id?: string }).user_id ?? agent.userId;
  const g = guard(store, agent.id, who, real[0].created_at, { fetch: opts.fetch, poll: opts.stopPoll, chat: chatOf(real[0]) });
  try {
    return await run(g.store, { ...opts, fetch: g.fetch, signal: g.signal });
  } catch (e) {
    if (!(e instanceof Stopped) && !g.signal.aborted) throw e;
    await store.markHandled(real.map((r) => r.id));
    log(`${agent.profile.name}: stopped by the person, nothing written`);
    return { handled: true };
  } finally {
    g.end();
  }
}

async function oneTurn(store: Store, agent: NativeAgent, rows: Row[], opts: TurnOptions, log: (m: string) => void,
                       result: TurnResult, depth: number): Promise<{ handled: boolean }> {
  agent = shelfSoul(agent);
  const real = rows.filter((r) => !r.id.startsWith(SYNTHETIC)).map((r) => r.id);
  const last = real[real.length - 1];
  const p = agent.profile;
  const now = (opts.now ?? Date.now)();
  const say = async (body: string, meta: Record<string, unknown>) => {
    const id = await store.reply(agent, body, meta);
    result.replies.push(id);
    return id;
  };
  if (real.length) await store.markDelivered(real);

  // Meals (YUI-103): a tap on a meal's one question is applied here, with no model turn.
  if (logsMeals(agent)) {
    const { taps, rest } = fixTaps(rows);
    if (taps.length) {
      await mealFixes(store, agent, taps, rows[0].created_at, now, say, log);
      const tapped = taps.map((t) => t.row.id).filter((id) => !id.startsWith(SYNTHETIC));
      if (tapped.length) await store.markHandled(tapped);
      if (!rest.length) return { handled: true };
      return oneTurn(store, agent, rest, opts, log, result, depth);
    }
    // A photo of a meal is answered at once; its macros are worked out behind the scenes (runJob).
    const meal = mealTurn(agent, rows, photoPaths(rows));
    if (meal) {
      const job = await store.addJob({ userId: agent.userId, agentId: agent.id, kind: "meal", input: meal });
      result.jobs.push(job);
      await say(ACK, { ...(real.length ? { turn: real } : {}), native: { meal: job, queued: true } });
      if (real.length) await store.markHandled(real);
      log(`${p.name}: meal queued (${job})`);
      return { handled: true };
    }
  }

  // Basil's tools (YUI-183): Plan my meals, a swap, the grocery list and a meal fixed from Today, with no model turn.
  if (plansMeals(agent)) {
    const { asks, rest } = mealAsks(rows);
    if (asks.length) {
      await mealTools(store, agent, asks, now, say, log);
      const done = asks.map((a) => a.row.id).filter((id) => !id.startsWith(SYNTHETIC));
      if (done.length) await store.markHandled(done);
      if (!rest.length) return { handled: true };
      return oneTurn(store, agent, rest, opts, log, result, depth);
    }
  }

  // Gouda's tools (YUI-184): learn a song, the practice log and saved sessions, with no model turn.
  if (playsMusic(agent)) {
    const { asks, rest } = musicAsks(rows, rows.some((r) => r.kind !== "event") ? await store.tables(agent.id) : undefined);
    if (asks.length) {
      await musicTools(store, agent, asks, now, say, log);
      const done = asks.map((a) => a.row.id).filter((id) => !id.startsWith(SYNTHETIC));
      if (done.length) await store.markHandled(done);
      if (!rest.length) return { handled: true };
      return oneTurn(store, agent, rest, opts, log, result, depth);
    }
  }

  // Penny's tools (YUI-185): plan my week, the today list, what's next, move a task and the evening review, with no model turn.
  if (plansWeeks(agent)) {
    const { asks, rest } = planAsks(rows);
    if (asks.length) {
      await plannerTools(store, agent, asks, now, say, log);
      const done = asks.map((a) => a.row.id).filter((id) => !id.startsWith(SYNTHETIC));
      if (done.length) await store.markHandled(done);
      if (!rest.length) return { handled: true };
      return oneTurn(store, agent, rest, opts, log, result, depth);
    }
  }

  // Quill's tools (YUI-186): learn a topic, review cards, walk through a problem. The model writes a lesson or a problem's steps; the rest is his tables.
  if (studies(agent)) {
    const { asks, rest } = studyAsks(rows);
    if (asks.length) {
      await studyTools(store, agent, asks, now, say, log, opts);
      const done = asks.map((a) => a.row.id).filter((id) => !id.startsWith(SYNTHETIC));
      if (done.length) await store.markHandled(done);
      if (!rest.length) return { handled: true };
      return oneTurn(store, agent, rest, opts, log, result, depth);
    }
  }

  // Arnold's tools (YUI-182): Start, the runner's Send, the log and a changed day are answered here, with no model turn.
  if (trains(agent)) {
    const { asks, rest } = workoutAsks(rows);
    if (asks.length) {
      await workoutTools(store, agent, asks, rows[0].created_at, now, say, log);
      const done = asks.map((a) => a.row.id).filter((id) => !id.startsWith(SYNTHETIC));
      if (done.length) await store.markHandled(done);
      if (!rest.length) return { handled: true };
      return oneTurn(store, agent, rest, opts, log, result, depth);
    }
  }

  // A person's own key: their model, no monthly cap. Otherwise Yui's key and free turns.
  const own = await store.ownKey(agent.userId);
  const provider = own ? ownProvider(own) : opts.provider;
  const budget = own ? { ok: true, left: Infinity, limit: 0 } : await store.takeTurn(agent.userId);
  if (!budget.ok) {
    if (real.length) {
      await say(outOfTurns(budget.limit), { turn: real, native: { limit: true } });
      await store.markHandled(real);
    }
    log(`${p.name}: free turns used up`);
    return { handled: true };
  }

  if (last) await store.doing(last, "Thinking");
  const thread = threadOf(rows[0]);
  const [history, memory, guide, routes, tzRaw, schedules, mine, tables0, others] = await Promise.all([
    store.history(agent.id, rows[0].created_at, opts.historyRows ?? HISTORY_ROWS, thread, chatOf(rows[0])),
    store.memory(agent.userId, agent.id),
    store.guide(),
    store.routes(),
    store.timezone(agent.userId),
    store.schedules(agent.id),
    store.agents(agent.userId),
    store.tables(agent.id),
    store.others(agent.userId),
  ]);
  const tz = validZone(tzRaw);
  const clk = clock(now, tz);
  // Tables (YUI-170): a starter agent added before tables existed gets its starter tables now, once.
  let tables = await seedOnce(store, agent, tables0, log);
  // Basil from before YUI-183 gets his recipes, goal, plan and grocery tables, once.
  if (plansMeals(agent)) tables = await ensureMealTools(store, agent, tables);
  // Gouda from before YUI-184 gets his practice, sessions and studio tables and his songs' chords, once.
  if (playsMusic(agent)) tables = await ensureMusicTools(store, agent, tables);
  // Penny from before YUI-185 gets her reminders, reviews and week tables and the new task columns, once.
  if (plansWeeks(agent)) tables = await ensurePlannerTools(store, agent, tables);
  // Quill from before YUI-186 gets his sessions, problems and steps tables and the new card columns, once.
  if (studies(agent)) tables = await ensureStudyTools(store, agent, tables);
  // A Delete or Keep tap on deletes held last turn: done here, and the agent hears what happened.
  let turnRows = rows;
  ({ tables, rows: turnRows } = await heldTaps(store, agent, rows, history, tables, clk, log));
  const crew: CrewEntry[] = [...mine.map((a) => ({ handle: a.profile.handle, name: a.profile.name, role: a.profile.role })),
                             ...others.map((o) => ({ handle: o.handle, name: o.name, role: "", connected: true }))];

  // One photo per turn, the newest (spec/NATIVE.md, limits); the model hears how many it missed.
  const photos = photoPaths(rows);
  const images = (await Promise.all(photos.slice(-1).map((x) => store.signMedia(x)))).filter((u): u is string => !!u);
  // A turn with a picture goes to the model that sees (spec/NATIVE.md section 6).
  const model = provider.model ?? (images.length ? routes.vision : p.model && p.model !== "default" ? p.model : routes.text);
  const { messages } = buildTurn({
    guide, agent, memory, crew, history: history.filter((h) => !real.includes(h.id)), turn: turnRows, chatNew: chatIsNew(rows), images, photosLeftOut: Math.max(photos.length - 1, 0),
    context: opts.context, reserve: (opts.maxTokens ?? 2000) + (provider.reasoning ?? 0), now, tz: tzRaw ? tz : undefined, schedules,
    tables: tablesPrompt(tables, clk),
  });
  const room = opts.maxTokens ?? 2000;
  const req: { model: string; messages: any[]; max_tokens: number; reasoning?: Record<string, unknown> } = provider.reasoning
    ? { model, messages, max_tokens: room + provider.reasoning, reasoning: { max_tokens: provider.reasoning } }
    : { model, messages, max_tokens: room };

  let answer: Completion;
  let looked: Looked = { sources: [] };
  try {
    let sent: typeof req & { messages: any[] } = req;
    try {
      answer = await ask(opts, provider, req);
    } catch (e) {
      // Some providers can't fetch every photo URL (Z.AI's fetcher gets turned away by some hosts):
      // fetch it here and send the bytes instead, once.
      if (!(e instanceof ModelError) || !images.length) throw e;
      const inlined = await inlineImages(messages, opts.fetchMedia ?? fetch);
      if (!inlined) throw e;
      log(`${p.name}: the model couldn't fetch the photo, sending it inline`);
      sent = { ...req, messages: inlined };
      answer = await ask(opts, provider, sent);
    }
    // A tables block alone: read the rows, then ask again with them (before any lookup).
    if (extract(answer.text).tables.length) {
      const read = await readTables(opts, provider, sent, answer, tables, clk, last, store, log, p.name);
      answer = read.answer;
      sent = { ...sent, messages: read.messages };
      looked.messages = read.messages;
    }
    // A search or fetch block alone: look it up, then ask again with what came back.
    if (hasLookup(answer.text)) {
      looked = await lookUp(store, agent, opts, provider, sent, answer, last, log);
      answer = looked.answer!;
    }
    // Thought the budget away and said nothing, or a few words cut off: ask once more without the thinking.
    if (thoughtOut(answer, req.max_tokens)) {
      log(`${p.name}: ${model} thought until it ran out of room, asking again without thinking`);
      answer = await ask(opts, provider, provider.reasoning
        ? { ...sent, messages: looked.messages ?? sent.messages, reasoning: { enabled: false } }
        : { ...sent, messages: [...(looked.messages ?? sent.messages), { role: "user", content: RETRY_NOTE }] });
    } else if (silent(answer.text)) {
      // Nothing the person would see (empty, or only notes to itself): ask once more, keep the notes.
      log(`${p.name}: ${model} answered nothing the person sees, asking again`);
      const again = await ask(opts, provider, { ...sent, messages: [...(looked.messages ?? sent.messages), { role: "user", content: SILENT_NOTE }],
                                                ...(provider.reasoning ? { reasoning: { enabled: false } } : {}) });
      answer = { ...again, text: `${answer.text.trim()}\n${again.text}`.trim() };
    }
  } catch (e: any) {
    if (last) await store.doing(last, null);
    if (e instanceof ModelUnavailable) {
      // Nothing retries the turn later on a serverless host: say so, keep the rows for the next message.
      if (real.length) await store.reply(agent, `${p.name} can't reach its model right now. Send that again in a minute.`, { bridge: "status" });
      log(`${p.name}: ${e.message}`);
      return { handled: false };
    }
    if (!(e instanceof ModelError)) throw e;
    const why = own ? `${e.message} (this is your own ${own.provider} key)` : e.message;
    await say(`${p.name} couldn't answer that: ${why}`, { turn: real });
    if (real.length) await store.markHandled(real);
    return { handled: true };
  }

  const out = extract(answer.text);
  const notes: string[] = [];
  if (out.memory.length) {
    const change = applyMemory(memory, agent.id, out.memory, new Date(now).toISOString(), opts.newId ?? uuid);
    if (change.put.length || change.drop.length) await store.saveMemory(agent.userId, change.put, change.drop);
  }
  if (out.agents.length) {
    const results = await applyAgentOps(store, agent, out.agents);
    for (const r of results) log(`${p.name}: ${r.ok ? r.did : r.why}`);
    for (const r of results) if (!r.ok) notes.push(r.why);
    if (!out.text.trim()) out.text = results.filter((r) => r.ok).map((r) => `Done: ${(r as { did: string }).did}.`).join("\n");
  }
  // Meals said in words (or a photo the agent chose to log): worked out behind the scenes, the breakdown follows.
  for (const words of logsMeals(agent) ? out.meal : []) {
    const job = await store.addJob({ userId: agent.userId, agentId: agent.id, kind: "meal",
                                     input: { words, said: spoken(rows), ...(photos.length ? { photo: photos[photos.length - 1] } : {}), ...(last ? { rowId: last } : {}) } });
    result.jobs.push(job);
    log(`${p.name}: meal queued from its answer (${job})`);
  }
  if (out.meal.length && logsMeals(agent) && !out.text.trim()) out.text = ACK;
  if (out.schedule.length) notes.push(...await applySchedules(store, agent, out.schedule, schedules, tzRaw ? tz : "UTC", now, log));
  // Table writes land, deletes wait for a tap, and every query is drawn with real rows.
  const t = applyTables(out.text, tables, clk, opts.newId ?? uuid);
  if (t.made.length) log(`${p.name}: made table(s) ${t.made.join(", ")} from its puts`);
  if (t.problems.length) log(`${p.name}: table writes refused: ${[...new Set(t.problems)].join("; ")}`);
  const tchange = diff(tables, t.store);
  // Penny's reminders follow the tasks the answer wrote (YUI-185): a to-do with a time gets one.
  let reminded: ReturnType<typeof reminderMeta> | undefined;
  if (plansWeeks(agent) && touches(tchange, TASKS)) {
    t.store = syncReminders(t.store, clk);
    reminded = reminderMeta(t.store);
  }
  if (changed(tchange)) {
    await store.saveTables(agent, diff(tables, t.store), t.store);
    log(`${p.name}: tables: ${tchange.rows.length} row(s) written, ${tchange.dropRows.length} gone, ${tchange.tables.length} table(s) made or changed`);
  }
  // Writes with no screen to show them: the table that changed, under the words (or "Saved.").
  if (t.wrote && !out.agents.length && !/^```yui\b/m.test(t.text)) {
    const touched = tchange.rows[tchange.rows.length - 1]?.table ?? tchange.tables[0]?.name;
    // A grocery list reads as what's still to get, not a grid of every column (YUI-188).
    const view = touched === "groceries" && t.store.tables.groceries?.cols.some((c) => c.name === "Got")
      ? { table: touched, where: ["Got=off"], cols: ["Item", "Qty"].filter((n) => t.store.tables.groceries.cols.some((c) => c.name === n)),
          as: "list", title: "Still to get", limit: 30 }
      : { table: touched, limit: 12 };
    if (touched) t.text = `${t.text.trim() || "Saved."}\n\`\`\`yui\n${draw(t.store, view, clk).join("\n")}\n\`\`\``;
  }
  out.text = t.text;
  let body = unsprawl(unmark(undeck(unend(unbreak(undash(out.text))))));
  // A slip is never the reply (YUI-188): logged in full, shown as one small card with a retry under what worked.
  const slip = slipLine(notes, t.slipped);
  if (slip) {
    log(`${p.name}: slips: ${[...new Set(notes)].join("; ")}`);
    body = withCard(body, `card@slip ${JSON.stringify(slip)} cta="Try again"`);
  }
  // Sources the answer didn't link, and the invite to add a Firecrawl key when the free lookups ran out.
  const cards = [...sourceCards(body, looked.sources), ...(looked.capped ? [searchInvite(looked.capped.why, looked.capped.limit)] : [])];
  if (cards.length && body.trim()) body = `${body.trim()}\n\`\`\`yui\n${cards.join("\n")}\n\`\`\``;
  // Basil's pages follow what the answer wrote to his log, plan, goal or grocery list (YUI-183): patches under it.
  const pages = plansMeals(agent) ? mealPages(tchange) : [];
  if (pages.length && body.trim()) body = await withMealScreens(store, agent, body, t.store, clk, pages);
  // Gouda's pages follow what the answer wrote to his songs, practice, sessions or studio (YUI-184).
  const mpages = playsMusic(agent) ? musicPages(tchange) : [];
  if (mpages.length && body.trim()) body = await withMusicScreens(store, agent, body, t.store, clk, mpages);
  // Penny's pages follow what the answer wrote to her tasks (YUI-185).
  if (reminded && body.trim()) body = await withPlannerScreens(store, agent, body, t.store, clk, ["today", "week"]);
  // Quill's pages follow what the answer wrote to his decks, cards or sessions (YUI-186).
  const spages = studies(agent) ? studyPages(tchange) : [];
  if (spages.length && body.trim()) body = await withStudyScreens(store, agent, body, t.store, clk, spages);
  // Hand-offs (YUI-144): one a turn, never from a turn another agent started, never inside a group.
  // The card goes under the answer, so the phone jumps to that agent once it has been read.
  const passes = depth === 0 && !handedIn(rows) && !thread;
  const drawn = handoffCards(body);
  const handoff = passes ? [...out.handoff, ...drawn].map((h) => ({ ...h, to: mine.find((a) => a.profile.handle === h.target) }))
                                                        .find((h) => h.to && h.to.id !== agent.id) : undefined;
  if (handoff && !drawn.some((d) => d.target === handoff.target)) body = withCard(body, handoffCard(handoff.to!.profile, handoff.note));
  // @handles in the words reach the person's other agents through the database, on a turn the person
  // started: a mention, or in a group an ask on its hop budget. Never the one being handed off to.
  const mentions = real.length && !handedIn(rows) ? handlesIn(body, [p.handle, ...(handoff ? [handoff.target] : [])]) : [];
  if (!body.trim() && answer.finish === "length") body = `${p.name} ran out of room before it could answer. Try a shorter message.`;
  // Never close a turn the person started without a word back.
  else if (real.length && silent(answer.text)) body = `${p.name} couldn't put an answer together. Send that again?`;

  if (last) await store.doing(last, null);
  if (body.trim()) {
    await say(body.trim(), {
      ...(real.length ? { turn: real } : {}),
      ...(mentions.length ? { mentions } : {}),
      native: { model, ...(answer.usage ? { usage: answer.usage } : {}), ...(budget.left <= 10 ? { left: budget.left } : {}),
                ...(looked.sources.length ? { sources: looked.sources.slice(0, 8) } : {}), ...(looked.capped ? { search_capped: looked.capped.why } : {}),
                ...(t.held ? { held: t.held } : {}), ...(reminded ? { reminders: reminded } : {}),
                ...(slip ? { slips: [...new Set([...t.problems, ...notes])].slice(0, 6) } : {}) },
      ...(depth === 0 && !real.length && rows[0]?.body.startsWith("[yui] check-in") ? { checkin: true } : {}),
    });
  }
  if (real.length) await store.markHandled(real);
  log(`${p.name}: ${model} answered, ${body.length} chars`);

  // Hand-offs last, so the person reads this answer first. One level only: a handed-off agent can't hand on.
  if (handoff) {
    await synthetic(store, handoff.to!, `[yui] handoff from=${p.handle} note="${handoff.note.replace(/"/g, "'")}"`, opts, log, result, 1);
  } else if (passes && (out.handoff.length || drawn.length)) {
    log(`${p.name}: no agent @${(out.handoff[0] ?? drawn[0]).target} to hand off to`);
  }
  return { handled: true };
}

/** Runs a queued job (a meal's macros) and writes its answer. Safe to call twice: the second finds it taken. */
export async function runJob(store: Store, jobId: string, opts: TurnOptions): Promise<TurnResult> {
  const log = opts.log ?? (() => {});
  const result: TurnResult = { turns: 0, replies: [], jobs: [] };
  const job = await store.claimJob(jobId);
  if (!job) return result;
  const agent = await store.agent(job.agentId);
  if (!agent) {
    await store.finishJob(job.id, "failed", { gone: true });
    return result;
  }
  const own = await store.ownKey(agent.userId);
  const provider = own ? ownProvider(own) : opts.provider;
  const routes = await store.routes();
  // The person's Stop (YUI-190) reaches a job too: nothing logged, no breakdown.
  const g = guard(store, job.agentId, job.userId, job.createdAt, { fetch: opts.fetch, poll: opts.stopPoll });
  const jobOpts = { ...opts, fetch: g.fetch, signal: g.signal };
  try {
    const done = await runMealJob(g.store, job, {
      // The job answers JSON: no thinking budget, the answer's room is enough.
      ask: (req) => ask(jobOpts, provider, provider.reasoning ? { ...req, reasoning: { enabled: false } } : req),
      route: (photo) => provider.model ?? (photo ? routes.vision : routes.text),
      inline: (messages) => inlineImages(messages, opts.fetchMedia ?? fetch),
      log: (m) => log(`${agent.profile.name}: ${m}`),
      now: opts.now ?? Date.now,
      say: async (a, body, meta) => {
        // A meal logged patches Basil's Today (YUI-183) in the same reply: the breakdown and the board move together.
        const n = (meta.native ?? {}) as Record<string, unknown>;
        if (plansMeals(a) && !n.limit && n.food !== false) {
          body = await withMealScreens(store, a, body, await store.tables(a.id), clock((opts.now ?? Date.now)(), validZone(await store.timezone(a.userId))), ["today"]);
        }
        const id = await g.store.reply(a, body, meta);
        result.replies.push(id);
        return id;
      },
      budget: async (userId) => (own ? true : (await store.takeTurn(userId)).ok),
    });
    await store.finishJob(job.id, "done", done.result);
    result.turns++;
  } catch (e: any) {
    if (e instanceof Stopped || g.signal.aborted) {
      await store.finishJob(job.id, "failed", { stopped: true });
      log(`${agent.profile.name}: meal job ${job.id} stopped by the person, nothing written`);
      return result;
    }
    log(`${agent.profile.name}: meal job ${job.id} failed: ${e?.message ?? e}`);
    // A model that is away gets another go from the tick; the third try tells the person.
    if (e instanceof ModelUnavailable && job.tries < 3) {
      await store.finishJob(job.id, "queued", { error: String(e.message).slice(0, 200) });
      return result;
    }
    await store.finishJob(job.id, "failed", { error: String(e?.message ?? e).slice(0, 200) });
    result.replies.push(await store.reply(agent, `${agent.profile.name} couldn't work out that meal: ${e?.message ?? "something went wrong"}. Send the photo again?`,
                                          { native: { meal: job.id, failed: true } }));
  } finally {
    g.end();
  }
  return result;
}

/** Meal-question taps: each finds its question in the thread and the log is updated, no model turn. */
async function mealFixes(store: Store, agent: NativeAgent, taps: { row: Row; id: string; choice: string }[], before: string, now: number,
                         say: (body: string, meta: Record<string, unknown>) => Promise<string>, log: (m: string) => void): Promise<void> {
  const history = await store.history(agent.id, before, HISTORY_ROWS, null, chatOf(taps[0]?.row));
  const clk = clock(now, validZone(await store.timezone(agent.userId)));
  let tables = await store.tables(agent.id);
  for (const t of taps) {
    const fix: MealFix | undefined = [...history].reverse().find((h) => h.sender === "agent" && h.meta?.native?.mealfix?.id === t.id)?.meta.native.mealfix;
    if (!fix) {
      await say("That question isn't waiting any more. Tell me what to fix and I'll update the log.", { turn: [t.row.id] });
      continue;
    }
    const done = applyFix(tables, fix, t.choice, clk);
    const ch = diff(tables, done.store);
    if (changed(ch)) await store.saveTables(agent, ch, done.store);
    tables = done.store;
    const body = plansMeals(agent) ? await withMealScreens(store, agent, done.body, tables, clk, ["today"]) : done.body;
    await say(body, { ...(t.row.id.startsWith(SYNTHETIC) ? {} : { turn: [t.row.id] }), native: { mealfixed: t.id } });
    log(`${agent.profile.name}: meal ${t.id} fixed: ${t.choice}`);
  }
}

/** Basil's tool tables, made once for a Basil from before YUI-183 (from his starter seeds), and saved. */
async function ensureMealTools(store: Store, agent: NativeAgent, tables: TableStore): Promise<TableStore> {
  const out = ensureTools(tables, crew().basil?.tables);
  const ch = diff(tables, out);
  if (changed(ch)) await store.saveTables(agent, ch, out);
  return out;
}

/** Which of Basil's pages a table change touches. */
function mealPages(ch: { rows: { table: string }[]; dropRows: { table: string }[]; tables: { name: string }[] }): ("today" | "week" | "groceries")[] {
  const names = new Set([...ch.rows.map((r) => r.table), ...ch.dropRows.map((r) => r.table), ...ch.tables.map((t) => t.name)]);
  const out: ("today" | "week" | "groceries")[] = [];
  if (names.has(MEAL_LOG) || names.has(GOAL) || names.has(MEAL_PLAN)) out.push("today");
  if (names.has(MEAL_PLAN)) out.push("week");
  if (names.has(GROCERIES) || names.has(MEAL_PLAN)) out.push("groceries");
  return out;
}

/** A reply with Basil's page lines added: inside its last yui fence, or in a new one. Keeps the shape in his profile. */
async function withMealScreens(store: Store, agent: NativeAgent, body: string, tables: TableStore, clk: Clock,
                               only: ("today" | "week" | "groceries")[]): Promise<string> {
  const { lines, shape } = mealScreenLines(tables, clk, drawnShape(agent.profile), only);
  if (!lines.length) return body;
  if (agent.profile.mealScreens !== shape) {
    agent.profile = { ...agent.profile, mealScreens: shape };
    await store.updateAgent(agent.id, agent.profile);
  }
  const at = body.lastIndexOf("\n```");
  if (/```yui\n/.test(body) && at > body.lastIndexOf("```yui\n")) return `${body.slice(0, at)}\n${lines.join("\n")}${body.slice(at)}`;
  return `${body.trim()}\n\`\`\`yui\n${lines.join("\n")}\n\`\`\``;
}

/** Basil's tools, answered from his tables: the plan, a swap, the grocery list, a meal fixed; his pages patched after. */
async function mealTools(store: Store, agent: NativeAgent, asks: MealAsk[], now: number,
                         say: (body: string, meta: Record<string, unknown>) => Promise<string>, log: (m: string) => void): Promise<void> {
  const p = agent.profile;
  const clk = clock(now, validZone(await store.timezone(agent.userId)));
  const start = await seedOnce(store, agent, await store.tables(agent.id), log);
  let tables = ensureTools(start, crew().basil?.tables);
  for (const a of asks) {
    const turn = a.row.id.startsWith(SYNTHETIC) ? {} : { turn: [a.row.id] };
    // The ones that open a flow or answer in words: nothing written yet.
    const opens: Partial<Record<MealAsk["kind"], () => string>> = {
      plan: () => planBody(tables), add: () => ADD_BODY, share: () => groceryText(tables), logmeal: () => LOG_BODY,
      fix: () => fixBody(tables, (a as Extract<MealAsk, { kind: "fix" }>).choice, clk),
    };
    if (opens[a.kind]) {
      await say(opens[a.kind]!(), turn);
      log(`${p.name}: ${a.kind}`);
      continue;
    }
    if (a.kind === "tick") {
      // A tick says nothing: the phone already shows it, and the item leaves the list the next time it is drawn.
      tables = tickGrocery(tables, a.item, a.got, clk).store;
      log(`${p.name}: ${a.got ? "got" : "unticked"} ${a.item}`);
      continue;
    }
    let text = "";
    let extra: string[] = [];
    let only: ("today" | "week" | "groceries")[] = ["today", "week", "groceries"];
    if (a.kind === "planned") {
      const r = applyPlan(tables, a.answers, clk);
      tables = r.store;
      if (!r.planned.length) {
        await say("Nothing in my recipes fits all of that. Leave out fewer things, or tell me a few meals you like and I'll add them.", turn);
        continue;
      }
      const days = new Set(r.planned.map((x) => x.day)).size;
      text = `Your ${days} ${days === 1 ? "day is" : "days are"} planned. Tap any meal to swap it.${r.missing.length ? ` Nothing fit for ${r.missing.join(" or ").toLowerCase()}, so I left it out.` : ""}`;
      extra = weekDeck(tables, clk, r.prefs);
    } else if (a.kind === "swap") {
      const r = applySwap(tables, a.day, a.choice, clk);
      if (!r.to) {
        await say(r.slot ? `Nothing else fits your ${r.slot.toLowerCase()} that day. Plan again to change what I pick from.` : "That meal isn't on your plan any more.", turn);
        continue;
      }
      tables = r.store;
      text = `${r.slot} is ${r.to.name} now, ${r.to.cal.toLocaleString("en-US")} kcal. Your list follows.`;
      // The deck's page for that day, when it is still in the thread.
      const d = weekDeck(tables, clk, lastPrefs(tables)).find((l) => l.startsWith(`choose@swap-${a.day.replace(/-/g, "")} `));
      if (d) extra = [d.replace(/^choose@/, "~")];
    } else if (a.kind === "added") {
      const r = addGroceries(tables, readItems(a.words), clk);
      tables = r.store;
      text = r.added.length ? `Added ${joinWords(r.added.map((x) => x.toLowerCase()))}.` : "I didn't catch an item. Try: add oat milk to my groceries.";
      only = ["groceries"];
    } else if (a.kind === "ate") {
      const next = nextPlanned(tables, clk);
      const r = next ? logPlanned(tables, next.key, clk) : { store: tables };
      tables = r.store;
      text = "name" in r && r.name ? `Logged ${String(r.slot).toLowerCase()}: ${r.name}, ${(r.cal ?? 0).toLocaleString("en-US")} kcal.` : "Nothing planned is left today. Snap or say anything else you eat.";
      only = ["today"];
    } else if (a.kind === "fixed") {
      const r = applyMealFix(tables, a.day, a.meal, a.answers, clk);
      tables = r.store;
      text = r.text;
      only = ["today"];
    }
    const sl = mealScreenLines(tables, clk, drawnShape(agent.profile), only);
    await say(`${text}\n\`\`\`yui\n${[...extra, ...sl.lines].join("\n")}\n\`\`\``, { ...turn, native: { mealtool: a.kind } });
    agent.profile = { ...agent.profile, mealScreens: sl.shape };
    await store.updateAgent(agent.id, agent.profile);
    log(`${p.name}: ${a.kind}, ${sl.lines.some((l) => /^>\d clear$/.test(l)) ? "a page drawn again" : "pages patched"}`);
  }
  const ch = diff(start, tables);
  if (changed(ch)) await store.saveTables(agent, ch, tables);
}

/** Gouda's tool tables, made once for a Gouda from before YUI-184 (from his starter seeds), and saved. */
async function ensureMusicTools(store: Store, agent: NativeAgent, tables: TableStore): Promise<TableStore> {
  const out = ensureMusic(tables, crew().gouda?.tables);
  const ch = diff(tables, out);
  if (changed(ch)) await store.saveTables(agent, ch, out);
  return out;
}

/** A reply with Gouda's page lines added, inside its last yui fence or in a new one. Keeps the shape in his profile. */
async function withMusicScreens(store: Store, agent: NativeAgent, body: string, tables: TableStore, clk: Clock, only: MusicPage[]): Promise<string> {
  const { lines, shape } = musicScreenLines(tables, clk, musicShape(agent.profile), only);
  if (!lines.length) return body;
  if (agent.profile.musicScreens !== shape) {
    agent.profile = { ...agent.profile, musicScreens: shape };
    await store.updateAgent(agent.id, agent.profile);
  }
  const at = body.lastIndexOf("\n```");
  if (/```yui\n/.test(body) && at > body.lastIndexOf("```yui\n")) return `${body.slice(0, at)}\n${lines.join("\n")}${body.slice(at)}`;
  return `${body.trim()}\n\`\`\`yui\n${lines.join("\n")}\n\`\`\``;
}

/** Gouda's tools, answered from his tables: a song learned, practice logged, a beat saved or opened; his pages patched after. */
async function musicTools(store: Store, agent: NativeAgent, asks: MusicAsk[], now: number,
                          say: (body: string, meta: Record<string, unknown>) => Promise<string>, log: (m: string) => void): Promise<void> {
  const p = agent.profile;
  const clk = clock(now, validZone(await store.timezone(agent.userId)));
  const start = await seedOnce(store, agent, await store.tables(agent.id), log);
  let tables = ensureMusic(start, crew().gouda?.tables);
  for (const a of asks) {
    const turn = a.row.id.startsWith(SYNTHETIC) ? {} : { turn: [a.row.id] };
    // The ones that open a flow: nothing written yet.
    if (a.kind === "learn" || a.kind === "log") {
      await say(a.kind === "learn" ? learnBody(tables, a.song) : practiceBody(tables, clk), turn);
      log(`${p.name}: ${a.kind}`);
      continue;
    }
    if (a.kind === "take") {
      const take = readTake(a.value);
      if (!take) {
        await say("That loop is empty. Tap a few steps on, then Send.", turn);
        continue;
      }
      tables = keepDraft(tables, take, clk);
      await say(saveBody(take), turn);
      log(`${p.name}: a ${take.kind} to name`);
      continue;
    }
    let text = "";
    let only: MusicPage[] = [];
    if (a.kind === "learned") {
      const r = applyLearn(tables, a.answers, clk);
      if (!r.lesson) {
        await say(pasteBody(r.missing ?? "that song"), turn);
        continue;
      }
      tables = r.store;
      const l = r.lesson;
      text = `${l.song} is on your Chords page: ${l.bars.length} bars in ${l.key}, the click at ${playBpm(l)}. Tap Start, count four, play.`;
      only = ["chords", "keys", "practice"];
    } else if (a.kind === "speed" || a.kind === "bar") {
      const r = a.kind === "speed" ? applySpeed(tables, a.choice, clk) : applyBar(tables, a.choice, clk);
      if (!r.lesson) {
        await say("Pick a song to learn first.", turn);
        continue;
      }
      tables = r.store;
      text = a.kind === "speed" ? `${r.lesson.song} at ${playBpm(r.lesson)} now.`
        : r.lesson.bar ? `Looping bar ${r.lesson.bar} of ${r.lesson.song}. Stay on it until it's easy.` : `The whole of ${r.lesson.song} again.`;
      only = ["chords", "practice"];
    } else if (a.kind === "scale") {
      tables = applyScale(tables, a.choice, clk);
      text = `Keys locked to ${a.choice.toLowerCase()}.`;
      only = ["keys"];
    } else if (a.kind === "practiced" || a.kind === "clicked") {
      if (a.kind === "clicked") {
        const l = lesson(tables);
        const minutes = Math.max(1, Math.round(a.seconds / 60));
        const what = a.id === "click" && l ? l.song : `The click at ${a.bpm || "your tempo"}`;
        tables = logPractice(tables, { minutes, what, bpm: a.bpm || undefined }, clk);
        text = `Logged ${minutes} ${minutes === 1 ? "minute" : "minutes"}: ${what}.`;
      } else {
        const r = applyPracticed(tables, a.answers, clk);
        tables = r.store;
        text = `Logged ${r.minutes} minutes: ${r.what}.`;
      }
      const s = streak(tables, clk);
      if (s > 1) text += ` ${s} days in a row.`;
      only = ["practice", "chords"];
    } else if (a.kind === "saved") {
      const r = applySave(tables, a.answers, clk);
      if (!r.session) {
        await say("That beat isn't waiting any more. Tap Send on the looper again.", turn);
        continue;
      }
      tables = r.store;
      text = `Saved ${r.session.name}. ${r.looper ? "It's on your Looper." : "Open it from your Looper any time."}`;
      only = ["looper"];
    } else if (a.kind === "open") {
      const r = applyOpen(tables, a.name, clk);
      if (!r.session) {
        await say(`I can't find ${a.name} any more.`, turn);
        continue;
      }
      tables = r.store;
      text = `${r.session.name} is on your Looper, ${r.session.bpm} bpm.`;
      only = ["looper"];
    }
    const sl = musicScreenLines(tables, clk, musicShape(agent.profile), only);
    await say(`${text}\n\`\`\`yui\n${sl.lines.join("\n")}\n\`\`\``, { ...turn, native: { musictool: a.kind } });
    agent.profile = { ...agent.profile, musicScreens: sl.shape };
    await store.updateAgent(agent.id, agent.profile);
    log(`${p.name}: ${a.kind}, ${sl.lines.some((l) => /^>\d clear$/.test(l)) ? "a page drawn again" : "pages patched"}`);
  }
  const ch = diff(start, tables);
  if (changed(ch)) await store.saveTables(agent, ch, tables);
}

/** A table change that wrote to, or removed rows from, the named table. */
function touches(ch: { rows: { table: string }[]; dropRows: { table: string }[]; tables: { name: string }[] }, name: string): boolean {
  return ch.rows.some((r) => r.table === name) || ch.dropRows.some((r) => r.table === name) || ch.tables.some((t) => t.name === name);
}

/** Penny's tool tables, made once for a Penny from before YUI-185 (from her starter seeds), and saved. */
async function ensurePlannerTools(store: Store, agent: NativeAgent, tables: TableStore): Promise<TableStore> {
  const out = ensurePlanner(tables, crew().penny?.tables);
  const ch = diff(tables, out);
  if (changed(ch)) await store.saveTables(agent, ch, out);
  return out;
}

/** A reply with Penny's page lines added, inside its last yui fence or in a new one. Keeps the shape in her profile. */
async function withPlannerScreens(store: Store, agent: NativeAgent, body: string, tables: TableStore, clk: Clock, only: PlannerPage[]): Promise<string> {
  const { lines, shape } = plannerScreenLines(tables, clk, plannerShape(agent.profile), only);
  if (!lines.length) return body;
  if (agent.profile.plannerScreens !== shape) {
    agent.profile = { ...agent.profile, plannerScreens: shape };
    await store.updateAgent(agent.id, agent.profile);
  }
  const at = body.lastIndexOf("\n```");
  if (/```yui\n/.test(body) && at > body.lastIndexOf("```yui\n")) return `${body.slice(0, at)}\n${lines.join("\n")}${body.slice(at)}`;
  return `${body.trim()}\n\`\`\`yui\n${lines.join("\n")}\n\`\`\``;
}

/** Penny's tools, answered from her tables: the week planned, a task added, ticked or moved, the day reviewed; her pages patched after. */
async function plannerTools(store: Store, agent: NativeAgent, asks: PlanAsk[], now: number,
                            say: (body: string, meta: Record<string, unknown>) => Promise<string>, log: (m: string) => void): Promise<void> {
  const p = agent.profile;
  const clk = clock(now, validZone(await store.timezone(agent.userId)));
  const start = await seedOnce(store, agent, await store.tables(agent.id), log);
  let tables = ensurePlanner(start, crew().penny?.tables, true);
  for (const a of asks) {
    const turn = a.row.id.startsWith(SYNTHETIC) ? {} : { turn: [a.row.id] };
    // The ones that open a flow: nothing written yet.
    const opens: Partial<Record<PlanAsk["kind"], () => string>> = {
      plan: () => weekPlanBody(tables, clk), add: () => TODO_BODY, review: () => reviewBody(tables, clk), move: () => moveBody(tables, clk),
    };
    if (opens[a.kind]) {
      await say(opens[a.kind]!(), turn);
      log(`${p.name}: ${a.kind}`);
      continue;
    }
    const before = JSON.stringify(reminderMeta(tables));
    let text = "";
    let only: PlannerPage[] = ["today", "week"];
    if (a.kind === "planned") {
      const r = applyWeekPlan(tables, a.answers, clk);
      tables = r.store;
      if (!r.added.length && !r.carried) {
        await say("I didn't catch anything to plan. Talk it out again, like: call the dentist Tuesday at 9, groceries, finish the report by Friday.", turn);
        continue;
      }
      const days = new Set(r.added.map((x) => x.due)).size;
      const timed = r.added.filter((x) => x.time).length;
      text = `Your week is planned: ${r.added.length} ${r.added.length === 1 ? "thing" : "things"} over ${days} ${days === 1 ? "day" : "days"}`
        + `${r.carried ? `, plus ${r.carried} brought in` : ""}. Drag to reorder on This week.`
        + `${timed && r.prefs.remind != null ? ` ${timed === 1 ? "The timed one gets" : `The ${timed} timed ones get`} a reminder.` : ""}`;
      const n = nextTask(tables, clk);
      if (n) text += ` First up: ${n.task.toLowerCase()}.`;
    } else if (a.kind === "next") {
      text = nextText(tables, clk);
      only = ["today"];
    } else if (a.kind === "added") {
      const r = addTasks(tables, a.words, clk);
      tables = r.store;
      if (!r.added.length) {
        await say("I didn't catch a to-do. Try: add a to-do: call mom tomorrow at 5.", turn);
        continue;
      }
      const reminds = r.added.some((x) => x.time) && remindLead(tables) != null;
      text = `Added ${joinWords(r.added.map((x) => `${x.task.toLowerCase()} for ${dayWord(x.due, clk)}${x.time ? ` at ${clockText(x.time)}` : ""}`))}.`
        + `${reminds ? " I'll remind you." : ""}`;
    } else if (a.kind === "tick" || a.kind === "donenext") {
      const label = a.kind === "tick" ? a.item : nextTask(tables, clk)?.key ?? "";
      const r = tickTask(tables, label, a.kind === "tick" ? a.done : true, clk);
      tables = r.store;
      if (!r.task) {
        if (a.kind === "tick") continue; // the "Nothing on today" line: nothing to do
        text = "Nothing left today.";
      } else if (a.kind === "donenext") {
        const n = nextTask(tables, clk);
        text = `Done: ${r.task.task.toLowerCase()}.${n ? ` Next: ${n.task.toLowerCase()}.` : " That was the last one today."}`;
      }
      // A tick says nothing: the phone shows it; the pages follow in patches (a quiet reply).
    } else if (a.kind === "order") {
      const r = applyOrder(tables, a.order, clk);
      tables = r.store;
      text = r.moved.length ? `Moved ${joinWords(r.moved.slice(0, 3).map((x) => `${x.task.toLowerCase()} to ${dayWord(x.due, clk)}`))}.` : "";
    } else if (a.kind === "moved") {
      const r = applyMove(tables, a.answers, clk);
      if (!r.task) {
        await say("That task isn't on your week any more.", turn);
        continue;
      }
      tables = r.store;
      text = `${r.task.task} is on ${dayWord(r.day!, clk)} now.`;
    } else if (a.kind === "reviewed") {
      const r = applyReview(tables, a.answers, clk);
      tables = r.store;
      const bits = [r.done && `${r.done} done`, r.moved && `${r.moved} to tomorrow`, r.dropped && `${r.dropped} dropped`].filter(Boolean) as string[];
      const morning = clock(Date.parse(`${clk.today}T12:00:00Z`) + 86400000, "UTC").today;
      const first = nextTask(tables, { today: morning, now: `${morning}T00:00` });
      text = `Day wrapped${bits.length ? `: ${joinWords(bits)}` : ""}.${r.felt === "Rough" ? " Tomorrow's a fresh start." : r.felt === "Great" ? " Good day." : ""}`
        + `${first ? ` First up tomorrow: ${first.task.toLowerCase()}.` : ""}`;
    }
    // A moved task or a saved order changes places in the week: This week is drawn again in the saved order, so
    // another device, or the app after a reinstall, reads the same week (YUI-185b; patches in place kept the order
    // on one phone only).
    const sl = plannerScreenLines(tables, clk, plannerShape(agent.profile), only, a.kind === "moved" || a.kind === "order");
    const after = reminderMeta(tables);
    const native: Record<string, unknown> = { plannertool: a.kind, ...(JSON.stringify(after) !== before ? { reminders: after } : {}) };
    await say(text ? `${text}\n\`\`\`yui\n${sl.lines.join("\n")}\n\`\`\`` : `\`\`\`yui\n${sl.lines.join("\n")}\n\`\`\``, { ...turn, native });
    agent.profile = { ...agent.profile, plannerScreens: sl.shape };
    await store.updateAgent(agent.id, agent.profile);
    log(`${p.name}: ${a.kind}, ${sl.lines.some((l) => /^>\d clear$/.test(l)) ? "a page drawn again" : "pages patched"}`);
  }
  const ch = diff(start, tables);
  if (changed(ch)) await store.saveTables(agent, ch, tables);
}

/** Quill's tool tables, made once for a Quill from before YUI-186 (from his starter seeds), and saved. */
async function ensureStudyTools(store: Store, agent: NativeAgent, tables: TableStore): Promise<TableStore> {
  const out = ensureStudy(tables, crew().quill?.tables);
  const ch = diff(tables, out);
  if (changed(ch)) await store.saveTables(agent, ch, out);
  return out;
}

/** A reply with Quill's page lines added, inside its last yui fence or in a new one. Keeps the shape in his profile. */
async function withStudyScreens(store: Store, agent: NativeAgent, body: string, tables: TableStore, clk: Clock, only: StudyPage[]): Promise<string> {
  const { lines, shape } = studyScreenLines(tables, clk, studyShape(agent.profile), only);
  if (!lines.length) return body;
  if (agent.profile.studyScreens !== shape) {
    agent.profile = { ...agent.profile, studyScreens: shape };
    await store.updateAgent(agent.id, agent.profile);
  }
  const at = body.lastIndexOf("\n```");
  if (/```yui\n/.test(body) && at > body.lastIndexOf("```yui\n")) return `${body.slice(0, at)}\n${lines.join("\n")}${body.slice(at)}`;
  return `${body.trim()}\n\`\`\`yui\n${lines.join("\n")}\n\`\`\``;
}

/**
 * The one model call behind a lesson or a problem: JSON, no thinking budget, one more try when it isn't JSON. Takes a
 * free turn (a person's own key takes none). Null with the words to say when there is no answer to draw.
 */
async function studyModel<T>(store: Store, agent: NativeAgent, opts: TurnOptions, system: string, user: string, read: (text: string) => T | null,
                             log: (m: string) => void): Promise<{ value?: T; model?: string; say?: string }> {
  const p = agent.profile;
  const own = await store.ownKey(agent.userId);
  const provider = own ? ownProvider(own) : opts.provider;
  const budget = own ? { ok: true, limit: 0 } : await store.takeTurn(agent.userId);
  if (!budget.ok) return { say: outOfTurns(budget.limit) };
  const routes = await store.routes();
  const model = provider.model ?? (p.model && p.model !== "default" ? p.model : routes.text);
  let messages: any[] = [{ role: "system", content: system }, { role: "user", content: user }];
  try {
    for (let i = 0; i < 2; i++) {
      const req = { model, messages, max_tokens: 3000 };
      const a = await ask(opts, provider, provider.reasoning ? { ...req, reasoning: { enabled: false } } : req);
      const value = read(a.text);
      if (value) return { value, model };
      log(`${p.name}: the model's answer wasn't the JSON${i ? ", giving up" : ", asking again"}`);
      messages = [...messages, { role: "assistant", content: a.text }, { role: "user", content: "That wasn't the JSON. Answer with the JSON object only." }];
    }
  } catch (e: any) {
    if (e instanceof ModelUnavailable) return { say: `${p.name} can't reach its model right now. Send that again in a minute.` };
    if (!(e instanceof ModelError)) throw e;
    return { say: `${p.name} couldn't answer that: ${own ? `${e.message} (this is your own ${own.provider} key)` : e.message}` };
  }
  return { say: "I couldn't put that together. Try it again, maybe in fewer words?", model };
}

/** Quill's tools: flows opened, a lesson written and kept, cards reviewed, a problem walked step by step; his pages patched after. */
async function studyTools(store: Store, agent: NativeAgent, asks: StudyAsk[], now: number,
                          say: (body: string, meta: Record<string, unknown>) => Promise<string>, log: (m: string) => void, opts: TurnOptions): Promise<void> {
  const p = agent.profile;
  const clk = clock(now, validZone(await store.timezone(agent.userId)));
  const start = await seedOnce(store, agent, await store.tables(agent.id), log);
  let tables = ensureStudy(start, crew().quill?.tables, true);
  const pages = async (text: string, only: StudyPage[], native: Record<string, unknown>, turn: Record<string, unknown>) => {
    const sl = studyScreenLines(tables, clk, studyShape(agent.profile), only);
    const at = text.lastIndexOf("\n```");
    const body = !sl.lines.length ? text
      : /```yui\n/.test(text) && at > text.lastIndexOf("```yui\n") ? `${text.slice(0, at)}\n${sl.lines.join("\n")}${text.slice(at)}`
      : `${text.trim()}\n\`\`\`yui\n${sl.lines.join("\n")}\n\`\`\``;
    await say(body.trim(), { ...turn, native });
    if (agent.profile.studyScreens !== sl.shape) {
      agent.profile = { ...agent.profile, studyScreens: sl.shape };
      await store.updateAgent(agent.id, agent.profile);
    }
  };
  // Saved as it goes: a lesson or a problem is kept before the next ask's model call.
  let saved = start;
  const save = async () => {
    const ch = diff(saved, tables);
    if (changed(ch)) await store.saveTables(agent, ch, tables);
    saved = tables;
  };
  for (const a of asks) {
    const turn = a.row.id.startsWith(SYNTHETIC) ? {} : { turn: [a.row.id] };
    const doing = (w: string) => (a.row.id.startsWith(SYNTHETIC) ? Promise.resolve() : store.doing(a.row.id, w));
    if (a.kind === "quiet") continue;
    if (a.kind === "learn") {
      // A topic they named rides on the reply, so the plan's Send (which then has no topic question) finds it.
      await say(lessonPlanBody(tables, a.topic), { ...turn, ...(a.topic ? { native: { studytool: "learn", topic: a.topic } } : {}) });
      log(`${p.name}: learn${a.topic ? ` (${a.topic})` : ""}`);
      continue;
    }
    if (a.kind === "problem" && !a.words) {
      await say(problemBody(), turn);
      log(`${p.name}: problem`);
      continue;
    }
    if (a.kind === "review" || a.kind === "next") {
      // What's due: the answer in one line, and the review under it when there is one to do.
      const due = dueCards(tables, clk).length;
      await say(a.kind === "review" ? cardReviewBody(tables, clk) : due ? `${dueText(tables, clk)}\n${cardReviewBody(tables, clk)}` : dueText(tables, clk), turn);
      log(`${p.name}: ${a.kind}`);
      continue;
    }
    if (a.kind === "reviewed") {
      const r = applyCardReview(tables, a.answers, clk);
      tables = r.store;
      await save();
      if (!r.rated) {
        await say("Nothing rated, so nothing moved. Open the review again when you're ready.", turn);
        continue;
      }
      const text = `Saved: ${r.rated} ${r.rated === 1 ? "card" : "cards"} reviewed${r.again ? `, ${r.again} to see again today` : ""}.`
        + `${r.left ? ` ${r.left} still due.` : " All caught up."}`;
      await pages(text, ["studying", "review", "progress"], { studytool: a.kind }, turn);
      log(`${p.name}: reviewed ${r.rated}`);
      continue;
    }
    if (a.kind === "quizdone") {
      const r = applyQuiz(tables, a.deck, a.score, a.of, clk);
      tables = r.store;
      await save();
      if (!r.deck) continue;
      const text = `${a.score} of ${a.of}${a.score === a.of ? ". Every one right." : a.score * 2 >= a.of ? ". Nice." : ". The cards will help."}`
        + ` ${r.deck.deck} is in your review, first cards tomorrow.`;
      await pages(text, ["studying", "progress"], { studytool: a.kind }, turn);
      log(`${p.name}: quiz ${a.score}/${a.of}`);
      continue;
    }
    if (a.kind === "step") {
      const r = answerStep(tables, a.problem, a.n, a.choice, clk);
      if (!r.p || !r.step || r.stale) continue; // an answer changed on a step already passed: nothing to do
      tables = r.store;
      await save();
      const said = r.right ? "Right." : `Not quite: it's ${r.step.answer}.${r.step.why ? ` ${r.step.why}` : ""}`;
      if (r.next) {
        await say(`${said}\n\`\`\`yui\n${stepLines(r.p, r.next).join("\n")}\n\`\`\``, { ...turn, native: { studytool: "step", step: r.next.n } });
      } else {
        const text = `${said} Solved${r.p.result ? `: ${r.p.result}` : ""}. You got ${r.p.right} of ${r.p.steps} steps.`;
        await pages(text, ["progress"], { studytool: "solved" }, turn);
      }
      log(`${p.name}: step ${a.n} ${r.right ? "right" : "wrong"}`);
      continue;
    }
    if (a.kind === "learned") {
      let l = readLearn(a.answers);
      if (!l.topic) {
        const hist = await store.history(agent.id, a.row.created_at, 20, null, chatOf(a.row));
        const named = [...hist].reverse().find((h) => h.sender === "agent" && h.meta?.native?.studytool === "learn");
        if (named?.meta?.native?.topic) l = { ...l, topic: String(named.meta.native.topic) };
      }
      if (!l.topic) {
        await say(lessonPlanBody(tables), turn);
        continue;
      }
      await doing(`Writing your lesson on ${l.topic}`);
      const got = await studyModel(store, agent, opts, LESSON_PROMPT, lessonAsk(l), (t) => parseLesson(t, l.time), log);
      if (!got.value) {
        await say(got.say!, turn);
        continue;
      }
      const k = keepLesson(tables, got.value, clk);
      tables = k.store;
      await save();
      await pages(lessonBody(got.value, k.key, k.added, l.time), ["studying", "review"], { studytool: a.kind, model: got.model }, turn);
      log(`${p.name}: lesson "${got.value.title}", ${got.value.pages.length} pages, ${got.value.quiz.length} questions, ${k.added} cards`);
      continue;
    }
    // A problem: from the plan's Send, or said in words.
    const pr = a.kind === "posed" ? readProblem(a.answers) : { problem: a.words, small: true };
    if (!pr.problem) {
      await say(problemBody(), turn);
      continue;
    }
    await doing("Breaking it into steps");
    const got = await studyModel(store, agent, opts, PROBLEM_PROMPT, problemAsk(pr), parseProblem, log);
    if (!got.value) {
      await say(got.say!, turn);
      continue;
    }
    const k = keepProblem(tables, got.value, pr.problem, clk);
    tables = k.store;
    await save();
    const row = problemRows(tables).find((x) => x.key === k.key)!;
    const first = stepsOf(tables, k.key)[0];
    await say(`${got.value.title}, in ${row.steps} ${row.steps === 1 ? "step" : "steps"}. Answer each one and the next shows.\n\`\`\`yui\n${stepLines(row, first).join("\n")}\n\`\`\``,
              { ...turn, native: { studytool: "problem", model: got.model, step: 1 } });
    log(`${p.name}: problem "${got.value.title}", ${row.steps} steps`);
  }
  await save();
}

const joinWords = (xs: string[]) => (xs.length < 2 ? xs.join("") : `${xs.slice(0, -1).join(", ")} and ${xs[xs.length - 1]}`);

/** Arnold's tools, answered from his tables: the runner, the log, a day changed, and the screens patched after. */
async function workoutTools(store: Store, agent: NativeAgent, asks: WorkoutAsk[], before: string, now: number,
                            say: (body: string, meta: Record<string, unknown>) => Promise<string>, log: (m: string) => void): Promise<void> {
  const p = agent.profile;
  const clk = clock(now, validZone(await store.timezone(agent.userId)));
  const start = await seedOnce(store, agent, await store.tables(agent.id), log);
  let tables = start;
  let history: Row[] | null = null;
  for (const a of asks) {
    const turn = a.row.id.startsWith(SYNTHETIC) ? {} : { turn: [a.row.id] };
    if (a.kind === "start") {
      const r = startReply(tables, clk, a.from);
      await say(r.body, { ...turn, native: r.session ? { workout: r.session } : { workout: null } });
      log(`${p.name}: ${r.session ? `runner for ${r.session.focus}` : "no session to run today"}`);
      continue;
    }
    if (a.kind === "rest") {
      await say("Rest it is. See you next session.", turn);
      continue;
    }
    if (a.kind === "log") {
      await say(logBody(tables, clk), turn);
      continue;
    }
    if (a.kind === "edit") {
      await say(editDayBody(tables, a.day), turn);
      continue;
    }
    let text: string;
    if (a.kind === "runner") {
      history ??= await store.history(agent.id, before, HISTORY_ROWS, null, chatOf(a.row));
      let s: Session | undefined = [...history].reverse().find((h) => h.sender === "agent" && h.meta?.native?.workout?.id === a.id)?.meta.native.workout;
      if (!s) {
        // Not in the thread any more: the same session again from the id (wk-<yyyymmdd>-<day>).
        const d = splitDays(tables).find((x) => x.key === a.id.slice(-3));
        const ymd = a.id.slice(3, 11);
        if (d) s = session(tables, d, `${ymd.slice(0, 4)}-${ymd.slice(4, 6)}-${ymd.slice(6, 8)}`);
      }
      if (!s) {
        await say("That workout isn't on your split any more. Tell me what you did and I'll log it.", turn);
        continue;
      }
      const r = applyRunner(tables, s, a.answers, clk);
      tables = r.store;
      text = loggedLine(s.focus, r.items);
      if (r.feel === "Hard") text += " Felt hard? Next time we keep the weight and own the reps.";
      else if (r.feel === "Easy") text += " Felt easy? Add 5 lb next time.";
    } else if (a.kind === "logged") {
      const r = applyLogged(tables, a.answers, clk);
      tables = r.store;
      text = loggedLine(r.name, r.items);
    } else {
      const r = applyDay(tables, a.day, a.answers, clk);
      tables = r.store;
      const name = ({ mon: "Monday", tue: "Tuesday", wed: "Wednesday", thu: "Thursday", fri: "Friday", sat: "Saturday", sun: "Sunday" } as Record<string, string>)[a.day];
      text = r.known ? `${name} is ${r.focus} now.` : `${name} is ${r.focus} now. Tell me what goes in it and I'll fill it in.`;
    }
    // The pages stay current with patches; the first time (or a new lift's chart) they are drawn again.
    const shape = progressShape(tables);
    const first = !p.workoutScreens;
    const lines = screenLines(tables, clk, { week: first, progress: first || p.workoutScreens !== shape });
    await say(`${text}\n\`\`\`yui\n${lines.join("\n")}\n\`\`\``, { ...turn, native: { workoutlog: a.kind } });
    agent.profile = { ...agent.profile, workoutScreens: shape };
    p.workoutScreens = shape;
    await store.updateAgent(agent.id, agent.profile);
    log(`${p.name}: ${a.kind} logged, screens ${first ? "drawn" : "patched"}`);
  }
  const ch = diff(start, tables);
  if (changed(ch)) await store.saveTables(agent, ch, tables);
}

async function applySchedules(store: Store, agent: NativeAgent, lines: string[], current: ScheduleItem[], tz: string, now: number,
                              log: (m: string) => void): Promise<string[]> {
  const problems: string[] = [];
  for (const line of lines.slice(0, 5)) {
    const parsed = parseLine(line, tz, now);
    if (!parsed) {
      problems.push(`I couldn't read the check-in "${line.slice(0, 60)}"`);
      continue;
    }
    if ("cancel" in parsed) {
      const hit = current[Number(parsed.cancel.slice(1)) - 1];
      if (hit) await store.dropSchedule(hit.id);
      continue;
    }
    const at = next(parsed.rule, tz, now);
    if (!at) {
      problems.push(`that check-in time has passed`);
      continue;
    }
    const id = await store.addSchedule({ userId: agent.userId, agentId: agent.id, note: parsed.note.slice(0, 300), rule: parsed.rule, tz,
                                         nextAt: new Date(at).toISOString() });
    if (!id) problems.push("you're at the most check-ins for now");
    else log(`${agent.profile.name}: check-in set for ${new Date(at).toISOString()}`);
  }
  return problems;
}

/** A crew agent as it came off the shelf (same version, not forked, its personality never rewritten) reads the
 *  shelf's soul as it is now, so what a starter learns (Basil's meal logging, YUI-103) reaches the ones already on
 *  people's phones. A soul edited before `soulEdited` existed keeps its own when its first line changed. Never saved. */
export function shelfSoul(agent: NativeAgent): NativeAgent {
  const p = agent.profile;
  const shelf = p.base && p.base !== "custom" ? crew()[p.base] : undefined;
  if (!shelf || p.soulEdited || shelf.version !== p.version || shelf.soul === p.soul) return agent;
  const opener = (s: string) => s.trim().split("\n")[0].trim();
  if (opener(shelf.soul) !== opener(p.soul)) return agent;
  return { ...agent, profile: { ...p, soul: shelf.soul } };
}

/**
 * What didn't work in a turn, as one short plain line: a refused table write reads "Couldn't save that to
 * Groceries.", anything else the first thing that went wrong, as a sentence. Never raw ops, never repeats.
 */
export function slipLine(notes: string[], slipped: string[]): string | null {
  const tables = [...new Set(slipped)];
  if (tables.length) return tables.length === 1 && tables[0] ? `Couldn't save that to ${pretty(tables[0])}.` : "Couldn't save all of that.";
  const first = [...new Set(notes.map((n) => n.trim()).filter(Boolean))][0];
  if (!first) return null;
  const line = first.replace(/\s*\([^)]*\)/g, "").replace(/"/g, "'").replace(/[.;:]+$/, "");
  const short = line.length > 80 ? `${line.slice(0, 77).replace(/\s+\S*$/, "")}...` : line;
  return `${short[0].toUpperCase()}${short.slice(1)}.`;
}

/**
 * Starter tables, once each (YUI-170, YUI-188): an agent whose profile ships a starter table it was never given
 * (made before tables, or before that table joined its tables.yui) gets it now, with its starter rows. A table
 * it already has is never touched, and one it was given and they dropped or gave away never comes back:
 * `seededTables` names every starter table it has been given.
 */
async function seedOnce(store: Store, agent: NativeAgent, tables: TableStore, log: (m: string) => void): Promise<TableStore> {
  const p = agent.profile;
  const seeds = p.base === "custom" ? undefined : crew()[p.base]?.tables;
  if (!seeds?.length) return tables;
  const given = new Set(p.seededTables ?? []);
  const owed = seeds.filter((s) => !given.has(s.name));
  if (!owed.length) return tables;
  // Before YUI-188 a seeded agent kept no list: the starter tables it has now were given; the rest are owed.
  // An agent never seeded that already made tables of its own gets only the ones it is missing, the same way.
  let out = tables;
  const added: string[] = [];
  for (const s of owed) {
    if (out.tables[s.name] || Object.keys(out.tables).length >= LIMITS.tables) continue;
    out = { tables: { ...out.tables, ...fromSeeds([s]).tables } };
    added.push(s.name);
  }
  if (added.length) {
    await store.saveTables(agent, diff(tables, out), out);
    log(`${p.name}: wrote its starter table(s) ${added.join(", ")}`);
  }
  const mark = { seeded: true, seededTables: [...new Set([...given, ...seeds.map((s) => s.name)])] };
  agent.profile = { ...p, ...mark };
  // Onto the saved profile, never this turn's copy: a soul read from the shelf is never saved over theirs.
  const saved = (await store.agent(agent.id))?.profile ?? p;
  await store.updateAgent(agent.id, { ...saved, ...mark });
  return out;
}

const HELD_TAP = /^\[yui\]\s+(del-[A-Za-z0-9]+)\s+choose\b.*?\bchoice=("?)(Delete|Keep)\2/i;

/** Delete or Keep, tapped on deletes an earlier answer held: applied, and the tap's row tells the agent what was done. */
async function heldTaps(store: Store, agent: NativeAgent, rows: Row[], history: Row[], tables: TableStore, clk: Clock,
                        log: (m: string) => void): Promise<{ tables: TableStore; rows: Row[] }> {
  let out = tables;
  const seen = new Set<string>();
  const next = [];
  for (const r of rows) {
    const m = (r.body ?? "").match(HELD_TAP);
    if (!m || seen.has(m[1])) {
      next.push(r);
      continue;
    }
    seen.add(m[1]);
    const held = [...history].reverse().find((h) => h.sender === "agent" && h.meta?.native?.held?.id === m[1])?.meta.native.held;
    let note: string;
    if (!held) note = "[yui] That delete isn't waiting any more; nothing changed.";
    else if (m[3].toLowerCase() === "keep") note = "[yui] They kept it: nothing was deleted.";
    else {
      const done = applyHeld(out, held.lines, clk);
      const ch = diff(out, done.store);
      if (changed(ch)) await store.saveTables(agent, ch, done.store);
      out = done.store;
      note = `[yui] Deleted, as they asked: ${held.lines.join("; ")}. Say so in a few words and show what is left.`;
      log(`${agent.profile.name}: held delete ${m[1]} done (${done.done})`);
    }
    next.push({ ...r, body: `${r.body}\n${note}` });
  }
  return { tables: out, rows: next };
}

/** Reads the agent's tables for it (a ```tables block alone), then asks again, twice a turn at most. */
async function readTables(opts: TurnOptions, provider: Provider, req: { messages: any[] } & Record<string, unknown>, first: Completion,
                          tables: TableStore, clk: Clock, last: string | undefined, store: Store, log: (m: string) => void,
                          name: string): Promise<{ answer: Completion; messages: any[] }> {
  let messages = req.messages;
  let answer = first;
  for (let n = 0; n < 2; n++) {
    const x = extract(answer.text);
    if (!x.tables.length) break;
    if (last) await store.doing(last, "Checking your tables");
    const qs = readQueries(x.tables.join("\n"));
    const found = qs.map((q) => `query ${q.table}${Object.entries(q).filter(([k]) => k !== "table").map(([k, v]) => ` ${k}=${Array.isArray(v) ? v.join("|") : v}`).join("")}\n${asText(tables, q, clk)}`);
    log(`${name}: read ${qs.length} table quer${qs.length === 1 ? "y" : "ies"}`);
    const note = qs.length ? `[yui] Your tables:\n\n${found.join("\n\n")}\n\n[yui] Answer the person now: a line, then a screen. A query line in your yui block draws these rows for them.`
      : "[yui] That tables block had no query lines. Answer the person now.";
    messages = [...messages, { role: "assistant", content: answer.text }, { role: "user", content: note }];
    answer = await ask(opts, provider, { ...req, messages });
  }
  return { answer, messages };
}

/**
 * Cut off at the limit with nothing to say, or with most of the budget spent
 * thinking (GLM takes reasoning.max_tokens as a hint: one run thought 2958 of
 * 3000 and left half a sentence). A long answer that simply ran long is kept.
 */
export function thoughtOut(a: Completion, maxTokens: number): boolean {
  if (a.finish !== "length") return false;
  if (!a.text.trim()) return true;
  const thought = (a.usage as any)?.completion_tokens_details?.reasoning_tokens ?? Math.round(a.reasoning.length / 4);
  return thought > maxTokens / 2;
}

const RETRY_NOTE = "[yui] Your last try ran out of room while thinking. Answer the person now, shorter, with little thinking.";
const SILENT_NOTE = "[yui] Your last try had nothing the person can see. Answer them now: a line of words and a screen.";

/** An answer with no words or screen for the person and no agent change or handoff. Called after the lookups ran,
 *  so a search or fetch block still in it answers nothing. */
export function silent(text: string): boolean {
  const e = extract(text);
  return !e.text.trim() && !e.agents.length && !e.handoff.length && !e.meal.length;
}

interface Looked {
  answer?: Completion;
  messages?: any[]; // the conversation the last answer came from, lookups and all
  sources: Source[];
  capped?: { why: "month" | "day"; limit: number }; // Yui's free lookups ran out this turn
}

function hasLookup(text: string): boolean {
  const x = extract(text);
  return !!(x.search || x.fetch);
}

/**
 * Runs the agent's lookups one at a time, each answered with a new model call,
 * until it answers the person or hits the turn's cap (yui_limits
 * native_searches_per_turn). On Yui's key each lookup comes out of the free
 * month and day; the person's own Firecrawl key only counts them.
 */
async function lookUp(store: Store, agent: NativeAgent, opts: TurnOptions, provider: Provider, req: { messages: any[] } & Record<string, unknown>,
                      first: Completion, last: string | undefined, log: (m: string) => void): Promise<Looked> {
  const p = agent.profile;
  const theirs = await store.searchKey(agent.userId);
  const key = theirs ?? opts.search?.key;
  const fc = key ? new Firecrawl(key, opts.search?.fetch ?? fetch, opts.search?.base) : null;
  const out: Looked = { sources: [] };
  let messages = req.messages;
  let answer = first;
  let perTurn = 1;
  for (let n = 0; ; n++) {
    const x = extract(answer.text);
    const look = x.search ? { kind: "search" as const, q: x.search } : x.fetch ? { kind: "fetch" as const, q: x.fetch } : null;
    if (!look) break;
    let note: string;
    if (n >= perTurn || n >= 4) {
      note = "[yui] That's all the lookups for this turn. Answer the person now with what you have, with no search or fetch block.";
    } else if (!fc) {
      note = "[yui] Search isn't available right now. Answer from what you know, and say briefly that you couldn't look it up.";
    } else {
      const take = await store.takeSearch(agent.userId, !!theirs);
      perTurn = Math.max(1, take.perTurn);
      if (!take.ok) {
        out.capped = { why: take.why ?? "month", limit: take.limit };
        note = `[yui] The free web searches are used up ${take.why === "day" ? "for today" : "for this month"}. Answer from what you know, say in one line that you couldn't look it up, and don't write a search block again this turn.`;
        log(`${p.name}: ${look.kind} "${look.q}" (free lookups used up, ${take.why})`);
      } else {
        if (last) await store.doing(last, look.kind === "search" ? `Looking up ${look.q.slice(0, 40)}` : `Reading ${hostName(look.q)}`);
        try {
          const found = look.kind === "search" ? await fc.search(look.q) : await fc.fetchPage(look.q);
          out.sources.push(...found.sources);
          note = `[yui] ${look.kind === "search" ? `Web results for "${look.q}"` : "The page"}:\n\n${found.text}\n\n`
            + "[yui] Answer the person now from these, and name where it came from. If one page is worth reading in full, "
            + "you may write a fetch block with its link instead.";
          log(`${p.name}: ${look.kind} "${look.q.slice(0, 80)}", ${found.sources.length} source(s), ${take.used}/${take.limit} this month${theirs ? " (their key)" : ""}`);
        } catch (e) {
          if (!(e instanceof LookupError)) throw e;
          const whose = theirs && (e.status === 401 || e.status === 402) ? " (it's their own Firecrawl key, in Settings)" : "";
          note = `[yui] The lookup didn't work: ${e.message}${whose}. Answer from what you know and say so in one line.`;
          log(`${p.name}: ${look.kind} failed: ${e.message}`);
        }
      }
    }
    messages = [...messages, { role: "assistant", content: answer.text }, { role: "user", content: note }];
    answer = await ask(opts, provider, { ...req, messages });
    if (n >= perTurn || out.capped || !fc) {
      // Asked to answer without looking again: whatever block it still wrote is dropped by extract().
      break;
    }
  }
  out.answer = answer;
  out.messages = messages;
  return out;
}

function hostName(u: string): string {
  try {
    return new URL(u).hostname.replace(/^www\./, "");
  } catch {
    return "a page";
  }
}

// The house voice has no em or en dashes (YUI-163). The prompt says so; models
// still write them, so the answer is swept once more before it is written.
const OPENERS = new Set(["i", "i'm", "i'll", "you", "you're", "you'll", "we", "we'll", "let's", "they", "he", "she", "it", "it's",
  "that", "that's", "this", "here", "here's", "there", "there's", "tap", "try", "pick", "send", "tell", "say", "ask", "give",
  "just", "open", "start", "go"]);

/** One piece of prose without dashes: a spaced one becomes a comma, or a period when a new sentence follows. */
function undashProse(t: string): string {
  return t
    .replace(/(\d)\s?[\u2013\u2014]\s?(\d)/g, "$1-$2") // 3–5, 9:00—10:00
    .replace(/^([ \t]*)[\u2013\u2014][ \t]+/gm, "$1- ") // a dash used as a bullet
    .replace(/[ \t]*[\u2013\u2014]+[ \t]*(?=\n|$)/g, ".") // a dash that ends a line
    .replace(/[ \t]*[\u2013\u2014]+[ \t]*(\S+)/g, (_m, word: string, at: number, all: string) => {
      const before = all.slice(0, at).trimEnd();
      if (/[.!?:,;]$/.test(before) || !before) return ` ${word}`;
      const bare = word.replace(/^["'(\u201c\u2018]+/, "").replace(/[^A-Za-z']+$/, "").toLowerCase();
      if (OPENERS.has(bare)) return `. ${word.replace(/[A-Za-z]/, (c) => c.toUpperCase())}`;
      return `, ${word}`;
    })
    .replace(/[\u2013\u2014]/g, ", ");
}

/**
 * The answer without em or en dashes, where the person reads them: the chat text
 * and the quoted strings in a yui block. Everything else in a fence (tokens,
 * links, code) is left as the model wrote it.
 */
export function undash(text: string): string {
  if (!/[\u2013\u2014]/.test(text)) return text;
  const parts = text.split(/(^```[^\n]*\n[\s\S]*?^```[ \t]*$)/m);
  return parts.map((part, i) => {
    if (i % 2 === 0) return undashProse(part);
    if (!/^```yui\b/.test(part)) return part;
    return part.replace(/"((?:[^"\\\n]|\\.)*)"/g, (_m, inner: string) => `"${undashProse(inner)}"`);
  }).join("");
}

// Models write \n inside a quoted YL string to break a line (YUI-161). In YL a
// backslash escapes the next character, so the person would read "nn". The
// answer is swept once more: a `say` becomes one line per break, a run of
// bullets a `list`, and a break in any other quoted string a space.
const QUOTED = /"((?:[^"\\\n]|\\.)*)"/g;
const BULLET = /^\s*(?:[•·*-]|\d{1,2}[.)])\s+/;

/** A quoted string's inside, cut at each \n (\r dropped, \t a space). Other escapes stay as written. */
function breaks(inner: string): string[] {
  const out = [""];
  for (let i = 0; i < inner.length; i++) {
    if (inner[i] !== "\\" || i + 1 >= inner.length) {
      out[out.length - 1] += inner[i];
      continue;
    }
    const next = inner[++i];
    if (next === "n") out.push("");
    else if (next === "t") out[out.length - 1] += " ";
    else if (next !== "r") out[out.length - 1] += `\\${next}`;
  }
  return out;
}

/** One `say` line whose text breaks, as the lines it meant: a `say` per line, a `list` per run of bullets. */
function sayLines(route: string, id: string, segs: string[]): string[] {
  const lines: string[] = [];
  let run: string[] = [];
  let numbered = true;
  const flush = () => {
    if (run.length) lines.push(`${route}list ${run.map((s) => `"${s}"`).join(" ")}${numbered ? " +num" : ""}`);
    run = [];
    numbered = true;
  };
  for (const s of segs.map((x) => x.trim())) {
    if (!s) {
      flush();
      continue;
    }
    if (BULLET.test(s)) {
      numbered &&= /^\s*\d/.test(s);
      run.push(s.replace(BULLET, ""));
      continue;
    }
    flush();
    lines.push(`${route}say${lines.length ? "" : id} "${s}"`);
  }
  flush();
  return lines.length ? lines : [`${route}say${id} ""`];
}

/** One line of a yui block with no \n left in its quoted strings. */
function breakLine(line: string): string[] {
  if (!line.includes("\\")) return [line];
  const say = line.match(/^(\s*(?:>[\w-]+\s+)?)say(@[\w-]+)?\s+(.*?)\s*$/);
  if (say) {
    const [, route, id = "", rest] = say;
    const whole = rest.match(/^"((?:[^"\\]|\\.)*)"$/);
    // Outside quotes a backslash is literal, so an unquoted say is cut at the two characters \n.
    const segs = whole ? breaks(whole[1])
      : rest.includes('"') ? null
      : rest.replace(/\\r/g, "").split("\\n").map((s) => s.replace(/\\/g, "\\\\"));
    if (segs && segs.length > 1) return sayLines(route, id, segs);
  }
  return [line.replace(QUOTED, (m, inner: string) => {
    const segs = breaks(inner);
    if (segs.length < 2) return m;
    const text = segs.map((s) => s.replace(BULLET, "").trim()).filter(Boolean)
      .reduce((all, s) => (!all ? s : /[.!?:;,]$/.test(all) ? `${all} ${s}` : `${all}. ${s}`), "");
    return `"${text}"`;
  })];
}

/** The answer with every \n inside a yui block's quoted strings turned into real lines. */
export function unbreak(text: string): string {
  if (!text.includes("\\")) return text;
  const parts = text.split(/(^```[^\n]*\n[\s\S]*?^```[ \t]*$)/m);
  return parts.map((part, i) => {
    if (i % 2 === 0 || !/^```yui\b/.test(part)) return part;
    return part.split("\n").flatMap(breakLine).join("\n");
  }).join("");
}

// The presets that open a group an `end` closes (yuilines GROUPS) and `flow`.
const GROUPS = /^(?:plan|deck|narrate|timeline|sketch|shapes|map|flow)(?:@[A-Za-z0-9_-]+)?(?:\s|$)/;

/** Two slips in a yui block, mended: a line that starts with a quote or a `+flag` (options wrapped onto their own
 *  line; no YL line can start with either) joins the line above, and a block that opens no group loses its `end` lines. */
export function unend(text: string): string {
  const parts = text.split(/(^```[^\n]*\n[\s\S]*?^```[ \t]*$)/m);
  return parts.map((part, i) => {
    if (i % 2 === 0 || !/^```yui\b/.test(part)) return part;
    const lines: string[] = [];
    for (const l of part.split("\n")) {
      const t = l.trim();
      if (/^(?:"|\+[a-z])/.test(t) && lines.length > 1 && lines[lines.length - 1].trim()) lines[lines.length - 1] += " " + t;
      else lines.push(l);
    }
    if (lines.some((l) => GROUPS.test(l.trim()))) return lines.join("\n");
    return lines.filter((l) => l.trim() !== "end").join("\n");
  }).join("");
}

// A deck or plan holds pages and their pictures (and a quiz or questions); any other line inside one closes it early on
// the phone, and the `end` after it is left with nothing to close, so the answer fails to draw (Gouda put a `list` in
// a deck, Quill `step` lines). Those lines move to just after the group's last `end`.
const IN_DECK = /^(?:page|sketch|row|after|shapes|shape|math|chart|stat|calc|map|area|pin|route|image|choose|pick|ask|slide|form|mic|camera|end)(?:[@\s]|$)/;
const OPENS = /^(?:deck|plan)(?:@[\w-]+)?(?:\s|$)/;

export function undeck(text: string): string {
  const parts = text.split(/(^```[^\n]*\n[\s\S]*?^```[ \t]*$)/m);
  return parts.map((part, i) => {
    if (i % 2 === 0 || !/^```yui\b/.test(part)) return part;
    const lines = part.split("\n");
    const start = lines.findIndex((l) => OPENS.test(l.trim()));
    if (start < 0) return part;
    let last = -1;
    for (let j = lines.length - 1; j > start; j--) if (lines[j].trim() === "end") { last = j; break; }
    if (last < 0) return part;
    const moved: string[] = [];
    const kept = lines.filter((l, j) => {
      if (j <= start || j >= last || !l.trim() || IN_DECK.test(l.trim())) return true;
      moved.push(l);
      return false;
    });
    if (!moved.length) return part;
    const at = kept.lastIndexOf(lines[last]) + 1;
    return [...kept.slice(0, at), ...moved, ...kept.slice(at)].join("\n");
  }).join("");
}

// The phone shows markdown as it is written (t_a88dc3b5, TestFlight build 244: Basil's "what can you do" came back
// as raw **bold** bullets the stage cut into 7 pages). The prompt says no markdown; what a model still writes is
// swept here: chat text with bullets, headings or bold becomes Yui Lines (a `say` per paragraph or heading, a
// `list` per run of bullets) at the top of the answer's yui block, and bold left in a quoted string loses its stars.
const MD_BULLET = /^[ \t]*(?:[-*•+]|\d{1,2}[.)])[ \t]+(?=\S)/;
const MD_HEADING = /^[ \t]{0,3}#{1,6}[ \t]+(?=\S)/;
const MD_BOLD = /\*\*(?=\S)([^*\n]+?)\*\*|__(?=\S)([^_\n]+?)__/;

function plainInline(t: string): string {
  return t
    .replace(/\*\*(?=\S)([^*\n]+?)\*\*/g, "$1").replace(/__(?=\S)([^_\n]+?)__/g, "$1")
    .replace(/(^|[\s(])\*(?=\S)([^*\n]+?)\*(?=[\s).,!?:;]|$)/g, "$1$2")
    .replace(/`([^`\n]+)`/g, "$1")
    .replace(/\[([^\]\n]+)\]\((https?:[^)\s]+)\)/g, "$1 ($2)")
    .replace(/\*\*/g, "")
    .replace(/\s+/g, " ").trim();
}

const quote = (t: string) => `"${t.replace(/\\/g, "\\\\").replace(/"/g, "'")}"`;

/** Prose with markdown in it, as Yui Lines; null when it has none. */
function markdownLines(prose: string): string[] | null {
  const lines = prose.split("\n");
  const bullets = lines.filter((l) => MD_BULLET.test(l));
  // One numbered line ("1) Stretch first.") reads fine as prose; a real list has two or more, or a dash or a star.
  const listy = bullets.length >= 2 || bullets.some((l) => /^[ \t]*[-*•+][ \t]/.test(l));
  if (!listy && !lines.some((l) => MD_HEADING.test(l)) && !MD_BOLD.test(prose)) return null;
  const out: string[] = [];
  let para: string[] = [];
  let run: string[] = [];
  let numbered = true;
  const flushPara = () => {
    const t = plainInline(para.join(" "));
    if (t) out.push(`say ${quote(t)}`);
    para = [];
  };
  const flushRun = () => {
    if (run.length) out.push(`list ${run.map(quote).join(" ")}${numbered ? " +num" : ""}`);
    run = [];
    numbered = true;
  };
  for (const l of lines) {
    if (!l.trim()) {
      flushPara();
      flushRun();
    } else if (MD_HEADING.test(l)) {
      flushPara();
      flushRun();
      out.push(`say ${quote(plainInline(l.replace(MD_HEADING, "")))}`);
    } else if (listy && MD_BULLET.test(l)) {
      flushPara();
      numbered &&= /^[ \t]*\d/.test(l);
      const item = plainInline(l.replace(MD_BULLET, ""));
      if (item) run.push(item);
    } else if (run.length && /^[ \t]+\S/.test(l)) {
      run[run.length - 1] = plainInline(`${run[run.length - 1]} ${l}`); // a bullet wrapped onto the next line
    } else {
      flushRun();
      para.push(l);
    }
  }
  flushPara();
  flushRun();
  return out;
}

/** The answer with no markdown where the person reads it (see above). Code fences other than yui are left alone. */
export function unmark(text: string): string {
  const parts = text.split(/(^```[^\n]*\n[\s\S]*?^```[ \t]*$)/m);
  const isYui = (i: number) => i % 2 === 1 && /^```yui\b/.test(parts[i]);
  // Bold inside a yui block's quoted strings loses its stars; a heading's hashes go too.
  for (let i = 1; i < parts.length; i += 2) {
    if (!isYui(i)) continue;
    parts[i] = parts[i].replace(QUOTED, (m, inner: string) =>
      MD_BOLD.test(inner) || /^#{1,6} /.test(inner) ? `"${inner.replace(/^#{1,6} +/, "").replace(/\*\*|__/g, "")}"` : m);
  }
  const into = (i: number, lines: string[], atTop: boolean) => {
    const head = parts[i].match(/^```[^\n]*\n/)![0];
    const rest = parts[i].slice(head.length);
    parts[i] = atTop ? `${head}${lines.join("\n")}\n${rest}` : parts[i].replace(/\n?```[ \t]*$/, `\n${lines.join("\n")}\n\`\`\``);
  };
  for (let i = 0; i < parts.length; i += 2) {
    const lines = markdownLines(parts[i]);
    if (!lines) continue;
    const lead = parts[i].match(/^\s*/)![0].includes("\n") ? "\n" : "";
    const tail = /\n\s*$/.test(parts[i]) ? "\n" : "";
    if (!lines.length) continue;
    if (isYui(i + 1)) {
      into(i + 1, lines, true);
      parts[i] = lead;
    } else if (isYui(i - 1)) {
      into(i - 1, lines, false);
      parts[i] = tail;
    } else {
      parts[i] = `${lead}\`\`\`yui\n${lines.join("\n")}\n\`\`\`${tail}`;
    }
  }
  return parts.join("");
}

// The stage plays an answer as pages: a paragraph of chat text, a `say` or a deck `page` is one each (the app's
// StageChunks). Past MOST_PAGES, short neighbours are merged so a small answer is never a long swipe.
const MOST_PAGES = 4;
const SHORT_WORDS = 40;
const wordsIn = (t: string) => t.split(/\s+/).filter(Boolean).length;
const SAY = /^say\s+"((?:[^"\\]|\\.)*)"\s*$/;
const PAGE = /^page\s+"((?:[^"\\]|\\.)*)"(?:\s+body="((?:[^"\\]|\\.)*)")?\s*$/;

/** Merges neighbours in `items` (`pair` returns the merge, or null for a pair that can't share a page) while `over()`. */
function squeeze<T>(items: T[], over: () => boolean, pair: (a: T, b: T) => T | null): void {
  for (let i = 0; over() && i < items.length - 1;) {
    const m = pair(items[i], items[i + 1]);
    if (m === null) i++;
    else items.splice(i, 2, m);
  }
}

const withStop = (t: string) => (/[.!?:]$/.test(t) ? t : `${t}.`);

function mergeLines(a: string, b: string): string | null {
  const sa = a.trim().match(SAY), sb = b.trim().match(SAY);
  if (sa && sb && wordsIn(sa[1]) + wordsIn(sb[1]) <= SHORT_WORDS) return `say "${withStop(sa[1])} ${sb[1]}"`;
  const pa = a.trim().match(PAGE), pb = b.trim().match(PAGE);
  if (pa && pb && wordsIn(`${pa[2] ?? ""} ${pb[1]} ${pb[2] ?? ""}`) <= SHORT_WORDS) {
    return `page "${pa[1]}" body="${[pa[2] && withStop(pa[2]), withStop(pb[1]), pb[2]].filter(Boolean).join(" ")}"`;
  }
  return null;
}

// The stage plays every loose `stat` tile as a page of its own (Chris, t_afb1bf90: "a full breakdown of the calories
// and macros, I don't need eight screens for that"). Three or more tiles in a row become one table, one page.
const STAT = /^stat(?:@([\w-]+))?\s+("(?:[^"\\]|\\.)*"|\S+)\s+("(?:[^"\\]|\\.)*"|[^\s=+]+(?:\s+[^\s=+"]+)*?)(?=\s+[\w]+=|\s+\+|\s*$)(.*)$/;
const bare = (t: string) => t.replace(/^"|"$/g, "").replace(/\|/g, "/");

function tilesToTable(lines: string[]): string[] {
  const out: string[] = [];
  for (let i = 0; i < lines.length;) {
    let j = i;
    while (j < lines.length && STAT.test(lines[j].trim())) j++;
    if (j - i < 3) {
      out.push(...lines.slice(i, Math.max(j, i + 1)));
      i = Math.max(j, i + 1);
      continue;
    }
    const rows = lines.slice(i, j).map((l) => {
      const [, , value, label, rest] = l.trim().match(STAT)!;
      const sub = rest.match(/\bsub="((?:[^"\\]|\\.)*)"/)?.[1];
      return `"${bare(label)}|${bare(value)}${sub ? ` (${bare(sub)})` : ""}"`;
    });
    const id = lines[i].trim().match(STAT)![1];
    const title = rows.some((r) => /protein|carb|fat|calorie|kcal/i.test(r)) ? "Macros" : "Numbers";
    out.push(`table${id ? `@${id}` : ""} ${title} Item|Amount ${rows.join(" ")}`);
    i = j;
  }
  return out;
}

// A table's title is a bare word; a quoted one (`table "Two eggs, toast" Item|Kcal ...`) reads as the header, and the
// real header becomes a row. It moves to name=, which the phone shows as the title.
const QUOTED_TITLE = /^(\s*(?:>[\w-]+\s+)?table(?:@[\w-]+)?)\s+"((?:[^"\\]|\\.)*)"(?=\s+[^\s"=]*\|)/;

// A row written `"Eggs (2 large)"|140|12g` (the quote closed before the pipes) draws as its first cell alone on the
// phone: it is rejoined into one quoted row, `"Eggs (2 large)|140|12g"`.
const SPLIT_ROW = /"((?:[^"\\|]|\\.)*)"((?:\|(?:"(?:[^"\\]|\\.)*"|[^\s|"]+))+)/g;

// A header with spaces (`Day|Cal (kcal)|Protein (g)`) splits on the phone and shows as rows (YUI-170 shots): a unit in
// brackets moves to units=, any other space becomes a dash.
const SPACED_HEADER = /^(\s*(?:>[\w-]+\s+)?table(?:@[\w-]+)?\s+(?:name="(?:[^"\\]|\\.)*"\s+)?)([^"=\n]*\|[^"=\n]*?)(\s+")/;

function spacedHeader(l: string): string {
  const m = l.match(SPACED_HEADER);
  if (!m) return l;
  // With no name=, a bare first word is the title (`table Macros Item|Amount`), not part of the header.
  let lead = m[1], head = m[2].trim();
  const title = !/name="/.test(lead) ? head.match(/^([^\s|]+)\s+(?=\S)/) : null;
  if (title) {
    lead += title[0];
    head = head.slice(title[0].length);
  }
  if (!/\S\s+\S/.test(head)) return l;
  const cells = head.split("|").map((c) => c.trim().match(/^(.*?)\s*\(([^()]+)\)$/) ?? [c, c.trim(), ""]);
  const header = cells.map((c) => c[1].replace(/\s+/g, "-")).join("|");
  const units = cells.some((c) => c[2]) && !/\sunits=/.test(l) ? ` units=${cells.map((c) => c[2].replace(/\s+/g, "")).join("|")}` : "";
  return `${lead}${header}${m[3]}${l.slice(m[0].length)}${units}`;
}

function tableLine(l: string): string {
  if (!/^\s*(?:>[\w-]+\s+)?table(?:@[\w-]+)?\s/.test(l) || /^\s*(?:>[\w-]+\s+)?table\s+create\b/.test(l)) return l;
  return spacedHeader(l.replace(QUOTED_TITLE, '$1 name="$2"')
    .replace(SPLIT_ROW, (_m, first: string, rest: string) => `"${first}${rest.replace(/"/g, "")}"`));
}

/** The answer on at most MOST_PAGES stage pages where short ones can share a page. */
export function unsprawl(text: string): string {
  text = text.split(/(^```[^\n]*\n[\s\S]*?^```[ \t]*$)/m)
    .map((p, i) => (i % 2 === 1 && /^```yui\b/.test(p)
      ? tilesToTable(p.split("\n")).map(tableLine).join("\n") : p)).join("");
  const parts = text.split(/(^```[^\n]*\n[\s\S]*?^```[ \t]*$)/m);
  const isYui = (i: number) => i % 2 === 1 && /^```yui\b/.test(parts[i]);
  const paras = (p: string) => p.split(/\n\s*\n/).filter((x) => x.trim());
  const count = (p: string, i: number) =>
    i % 2 === 0 ? paras(p).length : isYui(i) ? p.split("\n").filter((l) => SAY.test(l.trim()) || PAGE.test(l.trim())).length : 0;
  const total = () => parts.reduce((n, p, i) => n + count(p, i), 0);
  if (total() <= MOST_PAGES) return text;
  // Chat paragraphs first, then says and deck pages.
  for (let i = 0; i < parts.length; i++) {
    if (total() <= MOST_PAGES) break;
    if (i % 2 === 0) {
      const ps = paras(parts[i]).map((x) => x.trim());
      if (ps.length < 2) continue;
      const rest = total() - ps.length;
      squeeze(ps, () => rest + ps.length > MOST_PAGES, (a, b) => (wordsIn(a) + wordsIn(b) <= SHORT_WORDS ? `${a} ${b}` : null));
      parts[i] = `${parts[i].match(/^\s*/)![0]}${ps.join("\n\n")}${parts[i].match(/\s*$/)![0]}`;
    } else if (isYui(i)) {
      const lines = parts[i].split("\n");
      const rest = total() - count(parts[i], i);
      squeeze(lines, () => rest + count(lines.join("\n"), i) > MOST_PAGES, mergeLines);
      parts[i] = lines.join("\n");
    }
  }
  return parts.join("");
}

/** Streams when it can; one retry when the model is busy. */
const INLINE_MAX = 8 * 1024 * 1024;

/** The same messages with every photo URL swapped for its bytes (data: URL), or null when none could be fetched. */
export async function inlineImages(messages: any[], fetchImpl: typeof fetch): Promise<any[] | null> {
  let swapped = 0;
  const out = await Promise.all(messages.map(async (m) => {
    if (!Array.isArray(m.content)) return m;
    const content = await Promise.all(m.content.map(async (part: any) => {
      const url = part?.type === "image_url" ? part.image_url?.url : null;
      if (!url || url.startsWith("data:")) return part;
      try {
        const r = await fetchImpl(url);
        const type = (r.headers.get("content-type") ?? "").split(";")[0].trim();
        if (!r.ok || !type.startsWith("image/")) return part;
        const bytes = new Uint8Array(await r.arrayBuffer());
        if (bytes.length > INLINE_MAX) return part;
        let bin = "";
        for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
        swapped++;
        return { type: "image_url", image_url: { url: `data:${type};base64,${btoa(bin)}` } };
      } catch {
        return part;
      }
    }));
    return { ...m, content };
  }));
  return swapped ? out : null;
}

async function ask(opts: TurnOptions, pv: Provider, req: Record<string, unknown>): Promise<Completion> {
  if (opts.signal?.aborted) throw new Stopped();
  const client = new ChatClient(pv.url, { key: pv.key, headers: pv.headers, fetch: opts.fetch, idle: 120 });
  const body = { ...req, ...(pv.extra ?? {}) } as any;
  try {
    return await client.complete(body, { stream: true });
  } catch (e) {
    if (opts.signal?.aborted) throw new Stopped(); // the person's Stop ended the call, not the model
    if (!(e instanceof ModelUnavailable)) throw e;
    await new Promise((r) => setTimeout(r, Math.min((e.retryAfter ?? 2) * 1000, 8000)));
    return await client.complete(body, { stream: true });
  }
}

export function outOfTurns(limit: number): string {
  const next = new Date();
  next.setUTCMonth(next.getUTCMonth() + 1, 1);
  const when = next.toLocaleDateString("en-US", { month: "long", day: "numeric", timeZone: "UTC" });
  return `That's your ${limit} free turns for this month. They come back on ${when}, or add your own model key in Settings to keep going now.\n\`\`\`yui\ncard "Free turns used" body="${limit} a month on Yui. Your own OpenRouter, TrustedRouter or Groq key has no limit."\n\`\`\``;
}

export function uuid(): string {
  return crypto.randomUUID();
}
