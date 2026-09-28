// YUI-103: log a meal without weighing. A photo is answered at once, the macros are worked out as a job behind it,
// the breakdown is one reply, each food is remembered, and the one question is a tap the runtime applies itself.
import { test } from "node:test";
import assert from "node:assert/strict";
import { runAgent, runJob } from "../src/turn.ts";
import { ACK, breakdown, clip, honour, saidNo, mealName, mealTurn, parseEstimate, plainPortion, spoken } from "../src/meals.ts";
import { extract } from "../src/directives.ts";
import { fakeModel, freshYui, provider, type Call } from "./helpers.ts";

const SALMON = {
  food: true, title: "Salmon bowl", sure: "Sure on the salmon and rice. Less sure on the dressing.",
  items: [
    { food: "Salmon, grilled", portion: "1 fillet", cal: 310, protein: 33, carbs: 0, fat: 19, memory: null, servings: 1 },
    { food: "White rice", portion: "about a cup", cal: 205, protein: 4, carbs: 45, fat: 0, memory: "white-rice", servings: 1 },
    { food: "Avocado", portion: "half", cal: 120, protein: 2, carbs: 6, fat: 11, memory: null, servings: 1 },
  ],
  question: null,
};
const isJob = (c: Call) => String(c.messages[0].content).startsWith("You work out the calories");
const bodies = (store: any, agentId: string) => store.data.rows.filter((r: any) => r.agent_id === agentId && r.sender === "agent").map((r: any) => r.body);

test("a meal photo to Basil is answered at once, with no model call; the macros come after as one breakdown", async () => {
  const { store, byHandle } = await freshYui();
  const basil = await byHandle("basil");
  const m = fakeModel(() => JSON.stringify(SALMON));
  const photo = store.say(basil.id, "[yui] c1 camera photo=https://img.test/bowl.jpg", "event");
  const r = await runAgent(store, basil.id, { provider, fetch: m.fetch, now: () => Date.parse("2026-09-27T13:30:00Z") });
  assert.equal(m.calls.length, 0, "the answer waits on no model");
  assert.equal(r.jobs.length, 1);
  const ack = store.data.rows.at(-1)!;
  assert.equal(ack.body, ACK);
  assert.deepEqual(ack.meta.turn, [photo]);
  assert.ok(store.data.rows.find((x) => x.id === photo)!.handled_at, "the photo is handled with the answer");

  const done = await runJob(store, r.jobs[0], { provider, fetch: m.fetch, now: () => Date.parse("2026-09-27T13:30:00Z") });
  assert.equal(done.replies.length, 1);
  assert.equal(m.calls.length, 1);
  assert.equal(m.calls[0].model, "z-ai/glm-5v-turbo", "the photo goes to the model that sees");
  assert.deepEqual(m.calls[0].messages[1].content[1], { type: "image_url", image_url: { url: "https://img.test/bowl.jpg" } });
  assert.match(m.calls[0].messages[0].content, /white-rice: White rice, cooked \(1 cup\) 205 kcal/, "the job sees the foods it can reuse");
  assert.equal(m.calls[0].body.max_tokens, 1200);

  const body = store.data.rows.at(-1)!.body as string;
  assert.match(body, /say "Salmon bowl, about 635 kcal\. Sure on the salmon and rice\. Less sure on the dressing\."/);
  assert.match(body, /table@meal-\w+ name="Lunch: Salmon bowl" Item\|Kcal\|Protein\|Carbs\|Fat "Salmon, grilled, 1 fillet\|310\|33\|0\|19"/);
  assert.match(body, /"Total\|635\|39\|51\|30" units=\|kcal\|g\|g\|g/);
  assert.match(body, /chart donut "Today's macros, grams" x=Protein\|Carbs\|Fat y=39\|51\|30/);
  assert.doesNotMatch(body, /^stat/m, "no page per number");
  assert.equal(body.match(/^say /gm)!.length, 2, "two pages at most: the meal, then today");
  assert.doesNotMatch(body, /choose/, "no question when nothing big is unsure");

  const t = store.data.tables![basil.id];
  assert.equal(t.tables.meals.order.length, 3);
  const first = t.tables.meals.rows[t.tables.meals.order[0]];
  assert.deepEqual(first, { Day: "2026-09-27", Meal: "Lunch", Food: "Salmon, grilled", Portion: "1 fillet", Cal: 310, Protein: 33, Carbs: 0, Fat: 19 });
  // The rice matched a starter food: its numbers win; the new foods join the person's memory.
  assert.equal(t.tables.meals.rows[t.tables.meals.order[1]].Cal, 205);
  assert.deepEqual(Object.keys(t.tables.myfoods.rows).sort(), ["avocado", "salmon-grilled", "white-rice"]);
  assert.equal(store.data.jobs![0].status, "done");
  // A second run of the same job finds it taken.
  assert.equal((await runJob(store, r.jobs[0], { provider, fetch: m.fetch })).replies.length, 0);
});

test("the food memory: a usual food is reused with its own numbers and counted again", async () => {
  const { store, byHandle } = await freshYui();
  const basil = await byHandle("basil");
  const now = () => Date.parse("2026-09-27T12:00:00Z");
  store.say(basil.id, "[yui] c1 camera photo=https://img.test/oats.jpg", "event");
  const first = fakeModel(() => JSON.stringify({ food: true, title: "Usual oatmeal", sure: "Clear photo.", question: null,
    items: [{ food: "Oatmeal with whey", portion: "1 bowl", cal: 400, protein: 30, carbs: 50, fat: 8 }] }));
  const r1 = await runAgent(store, basil.id, { provider, fetch: first.fetch, now });
  await runJob(store, r1.jobs[0], { provider, fetch: first.fetch, now });
  const mem = store.data.tables![basil.id].tables.myfoods;
  assert.deepEqual(mem.rows["oatmeal-with-whey"], { Food: "Oatmeal with whey", Portion: "1 bowl", Cal: 400, Protein: 30, Carbs: 50, Fat: 8, Times: 1, Last: "2026-09-27" });

  // Next time, with their words: the model names the remembered food, and its numbers (not a new guess) are used.
  const again = fakeModel((c) => {
    assert.match(String(c.messages[0].content), /Their own foods:\n- oatmeal-with-whey: Oatmeal with whey \(1 bowl\) 400 kcal/);
    assert.match(JSON.stringify(c.messages[1].content), /my usual oatmeal, a big one/);
    return "```json\n" + JSON.stringify({ food: true, title: "Usual oatmeal", sure: "Your usual.", question: null,
      items: [{ food: "Oatmeal with whey", portion: "1 big bowl", cal: 999, protein: 1, carbs: 1, fat: 1, memory: "oatmeal-with-whey", servings: 1.5 }] }) + "\n```";
  });
  store.say(basil.id, "my usual oatmeal, a big one");
  store.data.rows.at(-1)!.meta = { photos: ["https://img.test/oats2.jpg"] };
  const r2 = await runAgent(store, basil.id, { provider, fetch: again.fetch, now });
  await runJob(store, r2.jobs[0], { provider, fetch: again.fetch, now });
  const meals = store.data.tables![basil.id].tables.meals;
  const row = meals.rows[meals.order.at(-1)!];
  assert.equal(row.Cal, 600, "1.5 of the remembered 400");
  assert.equal(row.Protein, 45);
  assert.equal(store.data.tables![basil.id].tables.myfoods.rows["oatmeal-with-whey"].Times, 2);
  assert.match(store.data.rows.at(-1)!.body, /Today so far: 1,000 kcal/);
});

test("one short question when it matters, answered by a tap with no model turn", async () => {
  const { store, byHandle } = await freshYui();
  const basil = await byHandle("basil");
  const now = () => Date.parse("2026-09-27T19:00:00Z");
  const est = { food: true, title: "Eggs and toast", sure: "Sure on the eggs. The pan fat is a guess.",
    items: [{ food: "Eggs, fried", portion: "2 eggs", cal: 180, protein: 12, carbs: 1, fat: 14 },
            { food: "Toast", portion: "2 slices", cal: 160, protein: 8, carbs: 28, fat: 2 }],
    question: { text: "Cooked in butter or oil?", options: [{ label: "None", cal: 0 }, { label: "A little", cal: 100, fat: 11 }, { label: "A lot", cal: 200, fat: 22 }] } };
  const m = fakeModel(() => JSON.stringify(est));
  store.say(basil.id, "[yui] c1 camera photo=https://img.test/eggs.jpg", "event");
  const r = await runAgent(store, basil.id, { provider, fetch: m.fetch, now });
  await runJob(store, r.jobs[0], { provider, fetch: m.fetch, now });
  const reply = store.data.rows.at(-1)!;
  const id = reply.meta.native.mealfix.id;
  assert.match(reply.body, new RegExp(`choose@fix-${id} "Cooked in butter or oil\\?" "None"\\|"A little"\\|"A lot"`));
  assert.match(reply.body, /name="Dinner: Eggs and toast"/);

  const calls = m.calls.length;
  const tap = store.say(basil.id, `[yui] fix-${id} choose choice="A little"`, "event");
  await runAgent(store, basil.id, { provider, fetch: m.fetch, now });
  assert.equal(m.calls.length, calls, "the tap needs no model");
  const fixed = store.data.rows.at(-1)!;
  assert.deepEqual(fixed.meta.turn, [tap]);
  assert.match(fixed.body, /say "A little: \+100 kcal\. Eggs and toast is 440 kcal\."/);
  assert.match(fixed.body, /"Meal\|440\|20\|29\|27"/);
  assert.doesNotMatch(fixed.body, /~choose/, "a patch plays as an empty page on the stage; the newest tap wins anyway");
  const meals = store.data.tables![basil.id].tables.meals;
  assert.equal(meals.rows[`${id}-fix`].Cal, 100);
  // Changing the answer replaces the fix, never adds a second one; None takes it away.
  store.say(basil.id, `[yui] fix-${id} choose choice=None changed=true`, "event");
  await runAgent(store, basil.id, { provider, fetch: m.fetch, now });
  assert.equal(store.data.tables![basil.id].tables.meals.rows[`${id}-fix`], undefined);
  assert.match(store.data.rows.at(-1)!.body, /None\. Nothing to add\. Eggs and toast is 340 kcal\./);
});

test("a photo with a question in the words is a normal turn with the model that sees", async () => {
  const { store, byHandle } = await freshYui();
  const basil = await byHandle("basil");
  const m = fakeModel(() => "Eggs, spinach and feta: a frittata.");
  store.say(basil.id, "what can I cook with this");
  store.data.rows.at(-1)!.meta = { photos: ["https://img.test/fridge.jpg"] };
  const r = await runAgent(store, basil.id, { provider, fetch: m.fetch });
  assert.equal(r.jobs.length, 0);
  assert.equal(m.calls[0].model, "z-ai/glm-5v-turbo");
  assert.match(store.data.rows.at(-1)!.body, /frittata/);
});

test("not a meal: says so and offers the camera, nothing logged", async () => {
  const { store, byHandle } = await freshYui();
  const basil = await byHandle("basil");
  const m = fakeModel(() => JSON.stringify({ food: false, title: "", sure: "It's a screenshot of a menu", items: [], question: null }));
  store.say(basil.id, "[yui] c1 camera photo=https://img.test/menu.jpg", "event");
  const r = await runAgent(store, basil.id, { provider, fetch: m.fetch });
  await runJob(store, r.jobs[0], { provider, fetch: m.fetch });
  const body = store.data.rows.at(-1)!.body;
  assert.match(body, /That doesn't look like a meal to log\. It's a screenshot of a menu\./);
  assert.match(body, /camera@plate "Snap your meal" \+inline/);
  assert.equal(store.data.tables![basil.id].tables.meals.order.length, 0);
});

test("a meal said in words: Basil's answer queues it with a meal block, the job reads the words on the text model", async () => {
  const { store, byHandle } = await freshYui();
  const basil = await byHandle("basil");
  const m = fakeModel((c) => (isJob(c)
    ? JSON.stringify({ food: true, title: "Eggs and toast", sure: "From your words.", question: null,
        items: [{ food: "Egg", portion: "2 large", cal: 999, protein: 0, carbs: 0, fat: 0, memory: "egg", servings: 2 },
                { food: "Butter", portion: "1 tbsp", cal: 102, protein: 0, carbs: 0, fat: 12, memory: "butter" }] })
    : "On it.\n```meal\nlog \"two eggs and toast with butter\"\n```"));
  store.say(basil.id, "had two eggs and toast with butter");
  const r = await runAgent(store, basil.id, { provider, fetch: m.fetch });
  assert.equal(store.data.rows.at(-1)!.body, "On it.");
  assert.equal(r.jobs.length, 1);
  await runJob(store, r.jobs[0], { provider, fetch: m.fetch });
  const job = m.calls.find(isJob)!;
  assert.equal(job.model, "z-ai/glm-5.2", "no photo: the text model");
  assert.match(job.messages[1].content, /No photo: the meal is in their words\. They said: "two eggs and toast with butter"/);
  const meals = store.data.tables![basil.id].tables.meals;
  assert.equal(meals.rows[meals.order[0]].Cal, 144, "2 of the starter egg (72)");
  // A meal block alone still says something.
  assert.equal(extract("```meal\nlog \"a banana\"\n```").meal[0], "a banana");
  // GLM writes it inside its yui fence too (live eval): taken the same way, and the fence goes when nothing is left.
  const inYui = extract("Let me log that.\n```yui\nmeal\nlog \"two eggs and toast\"\n```");
  assert.deepEqual(inYui.meal, ["two eggs and toast"]);
  assert.equal(inYui.text, "Let me log that.");
  const mixed = extract("Logged.\n```yui\nlog \"a banana\"\ncamera@plate \"Snap your meal\" +inline\n```");
  assert.deepEqual(mixed.meal, ["a banana"]);
  assert.match(mixed.text, /```yui\ncamera@plate/);
});

test("a job whose model is away goes back in the queue; a broken answer is asked for once more", async () => {
  const { store, byHandle } = await freshYui();
  const basil = await byHandle("basil");
  store.say(basil.id, "[yui] c1 camera photo=https://img.test/x.jpg", "event");
  const r = await runAgent(store, basil.id, { provider, fetch: fakeModel(() => "unused").fetch });
  const away = fakeModel(() => 503);
  await runJob(store, r.jobs[0], { provider, fetch: away.fetch });
  assert.equal(store.data.jobs![0].status, "queued");
  let n = 0;
  const flaky = fakeModel(() => (n++ === 0 ? "Looks like salmon!" : JSON.stringify(SALMON)));
  const done = await runJob(store, r.jobs[0], { provider, fetch: flaky.fetch });
  assert.equal(done.replies.length, 1);
  assert.match(flaky.calls[1].messages.at(-1).content, /JSON object only/);
  assert.equal(store.data.jobs![0].status, "done");
});

test("a Basil added before this reads the shelf's soul as it is now; a fork keeps its own", async () => {
  const { store, byHandle } = await freshYui();
  const basil = await byHandle("basil");
  const shelf = store.data.agents[basil.id].profile.soul.split("\n")[0];
  store.data.agents[basil.id].profile.soul = `${shelf}\n- An old soul.`;
  const m = fakeModel(() => "Hi.");
  store.say(basil.id, "hi");
  await runAgent(store, basil.id, { provider, fetch: m.fetch });
  assert.match(String(m.calls[0].messages[0].content), /Logging food never means weighing it/);
  assert.equal(store.data.agents[basil.id].profile.soul, `${shelf}\n- An old soul.`, "never saved over");
  for (const [i, change] of [{ version: 2 }, { soulEdited: true }, { soul: "You are Basil, but grumpy." }].entries()) {
    const p = store.data.agents[basil.id].profile;
    Object.assign(p, { version: 1, soulEdited: false, soul: `${shelf}\n- An old soul.` }, change);
    store.say(basil.id, "hi");
    await runAgent(store, basil.id, { provider, fetch: m.fetch });
    assert.doesNotMatch(String(m.calls[i + 1].messages[0].content), /Logging food never means weighing it/, JSON.stringify(change));
  }
});

test("pieces: spoken words, meal names, the estimate read loosely, and the breakdown's shape", () => {
  assert.equal(spoken([{ id: "1", sender: "user", kind: "event", body: '[yui] c1 camera photo=/p.jpg note="with butter"', created_at: "" }]), "with butter");
  assert.equal(spoken([{ id: "1", sender: "user", kind: "text", body: "lunch, half the rice", created_at: "" }]), "lunch, half the rice");
  const agent: any = { profile: { base: "basil" } };
  const row = (body: string): any => ({ id: "r", sender: "user", kind: "text", body, created_at: "" });
  assert.ok(mealTurn(agent, [row("lunch")], ["p.jpg"]));
  assert.equal(mealTurn(agent, [row("is this healthy?")], ["p.jpg"]), null);
  assert.equal(mealTurn(agent, [row("lunch")], []), null);
  assert.equal(mealTurn({ profile: { base: "arnold" } } as any, [row("lunch")], ["p.jpg"]), null);
  assert.equal(mealName("2026-09-27T08:10"), "Breakfast");
  assert.equal(mealName("2026-09-27T12:30"), "Lunch");
  assert.equal(mealName("2026-09-27T19:00"), "Dinner");
  assert.equal(mealName("2026-09-27T23:40"), "Snack");
  assert.equal(mealName("2026-09-27T21:40", "two eggs for breakfast"), "Breakfast", "the meal they named wins");
  assert.equal(plainPortion("about 3 oz / small fillet"), "small fillet");
  assert.equal(plainPortion("1 large fillet (about 170g)"), "1 large fillet");
  assert.equal(plainPortion("Shrimp, about 2 oz / a few pieces"), "Shrimp, a few pieces");
  assert.equal(plainPortion("150 g"), "1 portion");
  assert.equal(plainPortion("2 slices"), "2 slices");
  assert.equal(clip("A little drizzle of sauce", 20), "A little drizzle of");
  assert.deepEqual(saidNo("no mayo on mine, and without the dressing. I skipped the rice"), ["mayo", "dressing", "rice"]);
  assert.deepEqual(saidNo("no more, thanks"), []);
  const bowl = { food: true, title: "Poke", sure: "", items: [{ food: "Rice", portion: "1 cup", cal: 200, protein: 4, carbs: 45, fat: 0 },
    { food: "Spicy mayo or dressing", portion: "2 tbsp", cal: 120, protein: 0, carbs: 1, fat: 13 }],
    question: { text: "Spicy mayo or peanut sauce?", options: [{ label: "Mayo", cal: 0, protein: 0, carbs: 0, fat: 0 }, { label: "Peanut", cal: 0, protein: 0, carbs: 0, fat: 0 }] } };
  const kept = honour(bowl, "no mayo on mine");
  assert.deepEqual(kept.items.map((i) => i.food), ["Rice"]);
  assert.equal(kept.question, null);
  assert.equal(parseEstimate(JSON.stringify({ food: true, title: "Bowl", sure: "ok", items: [{ food: "Rice", portion: "1 cup", cal: 200 }],
    question: { text: "Is the sauce spicy mayo? (You said no mayo on yours)", options: [{ label: "None" }, { label: "A little" }] } }))!.question!.text,
    "Is the sauce spicy mayo?", "an aside after the question comes off");
  const est = parseEstimate('Here: {"food":true,"title":"Toast","sure":"ok","items":[{"food":"Toast","portion":"1 slice","cal":80.4,"protein":"3","carbs":14,"fat":1}]}');
  assert.equal(est!.items[0].cal, 80);
  assert.equal(est!.items[0].protein, 3);
  assert.equal(parseEstimate("no json here"), null);
  assert.equal(parseEstimate('{"food":true,"items":[]}')!.food, false, "no items is not a meal");
  const b = breakdown({ ...est!, title: 'Toast "plain" | jam', question: null }, "abc", "Breakfast", { cal: 80, protein: 3, carbs: 14, fat: 1, meals: 1 });
  assert.match(b, /^```yui\n/);
  assert.match(b, /name="Breakfast: Toast 'plain' \/ jam"/, "quotes and pipes can't break a line");
  assert.equal(b.split("\n").length, 6);
});
