// Web search (YUI-142): Firecrawl search and fetch, the free monthly cap, the
// per-turn and per-day caps, the invite to add a Firecrawl key, and the key itself.
import { test } from "node:test";
import assert from "node:assert/strict";
import { runAgent } from "../src/turn.ts";
import { extract } from "../src/directives.ts";
import { Firecrawl, safeUrl, sourceCards, searchInvite } from "../src/search.ts";
// The Yui Lines parser yui-mcp ships (a copy of yuigui's), to prove the cards parse clean.
import { parse as ylParse } from "../../supabase/functions/yui-mcp/yl.mjs";
import { fakeModel, freshYui, lastUser, provider, USER } from "./helpers.ts";

/** A scripted Firecrawl: records each call with the key it came with. */
function fakeFirecrawl(opts: { status?: number } = {}) {
  const calls: { path: string; auth: string; body: any }[] = [];
  const f = (async (url: string, init: any) => {
    const path = new URL(url).pathname;
    calls.push({ path, auth: init?.headers?.authorization ?? "", body: init?.body ? JSON.parse(init.body) : null });
    if (opts.status) return new Response(JSON.stringify({ success: false, error: "no" }), { status: opts.status });
    if (path.endsWith("/search")) {
      return Response.json({ success: true, data: { web: [
        { url: "https://www.espn.com/nba/scores", title: "NBA Scores - ESPN", description: "Knicks 112, Celtics 108 (final)." },
        { url: "https://www.nba.com/games", title: "NBA Games", description: "Tonight's games and results." },
        { url: "javascript:alert(1)", title: "bad", description: "dropped" },
      ] } });
    }
    if (path.endsWith("/scrape")) {
      return Response.json({ success: true, data: { markdown: "# Knicks beat Celtics\nBrunson scored 38.", metadata: { title: "Recap" } } });
    }
    if (path.endsWith("/team/credit-usage")) return Response.json({ success: true, data: { remaining_credits: 500 } });
    return new Response("?", { status: 404 });
  }) as unknown as typeof fetch;
  return { calls, fetch: f };
}

/** Every ```yui fence in a reply, parsed: the cards and any errors. */
function parse(body: string) {
  const ops = [...body.matchAll(/```yui\n([\s\S]*?)\n```/g)].flatMap((m) => ylParse(m[1]));
  return { errors: ops.filter((o: any) => o.op === "error"), components: ops.filter((o: any) => o.op === "add").map((o: any) => ({ type: o.preset, props: o.props })) };
}

const last = (store: any, agentId: string) => store.data.rows.filter((r: any) => r.agent_id === agentId && r.sender === "agent").pop()!;

test("a question that needs today's facts: one search, then the answer with its sources", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const fc = fakeFirecrawl();
  const m = fakeModel((c) => /Web results for/.test(String(lastUser(c).content))
    ? "The Knicks beat the Celtics 112 to 108 last night."
    : "```search\nknicks score last night\n```");
  store.say(yui.id, "did the knicks win last night?");
  await runAgent(store, yui.id, { provider, fetch: m.fetch, search: { key: "fc-yui", fetch: fc.fetch } });

  assert.equal(m.calls.length, 2);
  assert.deepEqual(fc.calls.map((c) => `${c.path} ${c.auth}`), ["/v2/search Bearer fc-yui"]);
  assert.equal(fc.calls[0].body.query, "knicks score last night");
  const second = m.calls[1].messages;
  assert.equal(second[second.length - 2].role, "assistant", "the agent's search block stays in the conversation");
  const results = String(lastUser(m.calls[1]).content);
  assert.match(results, /1\. NBA Scores - ESPN\n\s+https:\/\/www\.espn\.com\/nba\/scores\n\s+Knicks 112, Celtics 108/);
  assert.doesNotMatch(results, /javascript:/);

  const reply = last(store, yui.id);
  assert.match(reply.body, /^The Knicks beat the Celtics 112 to 108 last night\.\n```yui\n/);
  const screen = parse(reply.body);
  assert.equal(screen.errors.length, 0, JSON.stringify(screen.errors));
  const cards = screen.components.filter((c: any) => c.type === "card");
  assert.deepEqual(cards.map((c: any) => [c.props.title, c.props.url, c.props.cta]), [
    ["NBA Scores - ESPN", "https://www.espn.com/nba/scores", "Read"],
    ["NBA Games", "https://www.nba.com/games", "Read"],
  ]);
  assert.deepEqual(reply.meta.native.sources.map((s: any) => s.url), ["https://www.espn.com/nba/scores", "https://www.nba.com/games"]);
  assert.equal(store.data.searches![`${USER}:${new Date().toISOString().slice(0, 7)}`], 1);
});

test("search then fetch in one turn; the per-turn cap stops a third lookup", async () => {
  const { store, byHandle } = await freshYui();
  store.searchesPerTurn = 2;
  const gouda = await byHandle("gouda");
  const fc = fakeFirecrawl();
  let n = 0;
  const m = fakeModel(() => {
    n++;
    if (n === 1) return "```search\nboom bap history\n```";
    if (n === 2) return "```fetch\nhttps://en.wikipedia.org/wiki/Boom_bap\n```";
    if (n === 3) return "```search\nmore\n```";
    return "Boom bap came up in 90s New York.";
  });
  store.say(gouda.id, "where does boom bap come from?");
  await runAgent(store, gouda.id, { provider, fetch: m.fetch, search: { key: "fc-yui", fetch: fc.fetch } });
  assert.deepEqual(fc.calls.map((c) => c.path), ["/v2/search", "/v2/scrape"]);
  assert.equal(fc.calls[1].body.url, "https://en.wikipedia.org/wiki/Boom_bap");
  assert.match(String(lastUser(m.calls[2]).content), /^\[yui\] The page:\n\nRecap\nhttps:\/\/en\.wikipedia\.org\/wiki\/Boom_bap\n\n# Knicks beat Celtics/);
  assert.match(String(lastUser(m.calls[3]).content), /That's all the lookups for this turn/);
  assert.equal(m.calls.length, 4);
  assert.match(last(store, gouda.id).body, /^Boom bap came up in 90s New York\./);
  assert.equal(store.data.searches![`${USER}:${new Date().toISOString().slice(0, 7)}`], 2);
});

test("free lookups used up this month: answers from what it knows, with the invite to add a Firecrawl key", async () => {
  const { store, byHandle } = await freshYui();
  store.freeSearches = 1;
  const basil = await byHandle("basil");
  const fc = fakeFirecrawl();
  const answer = (c: any) => /used up for this month/.test(String(lastUser(c).content)) ? "From what I know: oats are a good start."
    : /Web results/.test(String(lastUser(c).content)) ? "Here's what I found." : "```search\nbest breakfast for energy\n```";
  store.say(basil.id, "what's a good breakfast?");
  await runAgent(store, basil.id, { provider, fetch: fakeModel(answer).fetch, search: { key: "fc-yui", fetch: fc.fetch } });
  store.say(basil.id, "and lunch?");
  const m = fakeModel(answer);
  await runAgent(store, basil.id, { provider, fetch: m.fetch, search: { key: "fc-yui", fetch: fc.fetch } });

  assert.equal(fc.calls.length, 1, "no Firecrawl call past the cap");
  const reply = last(store, basil.id);
  assert.match(reply.body, /^From what I know: oats are a good start\./);
  const invite = parse(reply.body).components.find((c: any) => c.type === "card")!;
  assert.equal(invite.props.title, "Free web searches used");
  assert.equal(invite.props.url, "yui://settings/search");
  assert.equal(invite.props.cta, "Open Settings");
  assert.match(invite.props.body, /1 things a month|own Firecrawl key in Settings/);
  assert.doesNotMatch(reply.body, /fc-|api key:/i, "never asks for the key in chat");
  assert.equal(reply.meta.native.search_capped, "month");
});

test("the daily cap says so, and says tomorrow", async () => {
  const { store, byHandle } = await freshYui();
  store.maxSearches = 0;
  const penny = await byHandle("penny");
  const m = fakeModel((c) => /for today/.test(String(lastUser(c).content)) ? "I'll go from memory." : "```search\nholidays this week\n```");
  store.say(penny.id, "any holidays this week?");
  await runAgent(store, penny.id, { provider, fetch: m.fetch, search: { key: "fc-yui", fetch: fakeFirecrawl().fetch } });
  const reply = last(store, penny.id);
  assert.match(reply.body, /come back tomorrow/);
  assert.equal(reply.meta.native.search_capped, "day");
});

test("their own Firecrawl key: used for the lookup, and the monthly cap is lifted", async () => {
  const { store, byHandle } = await freshYui();
  store.freeSearches = 0;
  store.maxSearches = 0;
  store.data.searchKeys = { [USER]: "fc-theirs-1234" };
  const quill = await byHandle("quill");
  const fc = fakeFirecrawl();
  const m = fakeModel((c) => /Web results/.test(String(lastUser(c).content)) ? "Found it." : "```search\nphotosynthesis steps\n```");
  store.say(quill.id, "explain photosynthesis");
  await runAgent(store, quill.id, { provider, fetch: m.fetch, search: { key: "fc-yui", fetch: fc.fetch } });
  assert.deepEqual(fc.calls.map((c) => c.auth), ["Bearer fc-theirs-1234"]);
  const reply = last(store, quill.id);
  assert.match(reply.body, /^Found it\./);
  assert.equal(reply.meta.native.search_capped, undefined);
  assert.doesNotMatch(reply.body, /Free web searches used/);
});

test("their key turned down: the agent says so, no invite, nothing thrown", async () => {
  const { store, byHandle } = await freshYui();
  store.data.searchKeys = { [USER]: "fc-dead" };
  const arnold = await byHandle("arnold");
  const m = fakeModel((c) => /didn't work/.test(String(lastUser(c).content)) ? "Couldn't look that up; your Firecrawl key needs a look." : "```search\nbest squat shoes\n```");
  store.say(arnold.id, "best squat shoes?");
  await runAgent(store, arnold.id, { provider, fetch: m.fetch, search: { fetch: fakeFirecrawl({ status: 401 }).fetch } });
  assert.match(String(lastUser(m.calls[1]).content), /the Firecrawl key was turned down \(it's their own Firecrawl key, in Settings\)/);
  assert.match(last(store, arnold.id).body, /^Couldn't look that up/);
});

test("no search configured: answers from what it knows", async () => {
  const { store, byHandle } = await freshYui();
  const yui = await byHandle("yui");
  const m = fakeModel((c) => /isn't available/.test(String(lastUser(c).content)) ? "From memory." : "```search\nweather\n```");
  store.say(yui.id, "weather?");
  await runAgent(store, yui.id, { provider, fetch: m.fetch });
  assert.equal(m.calls.length, 2);
  assert.equal(last(store, yui.id).body, "From memory.");
  assert.equal(store.data.searches, undefined, "nothing counted");
});

test("fetch blocks, safe links, source cards, the key check", async () => {
  assert.deepEqual(extract("```fetch\nhttps://a.com/x\n```").fetch, "https://a.com/x");
  assert.equal(safeUrl("https://example.com/a"), true);
  for (const bad of ["http://localhost:3000", "http://192.168.1.2/", "file:///etc/passwd", "https://printer.local/", "http://10.0.0.1", "nope"]) {
    assert.equal(safeUrl(bad), false, bad);
  }
  const fc = fakeFirecrawl();
  await assert.rejects(new Firecrawl("k", fc.fetch).fetchPage("http://127.0.0.1/admin"), /isn't a web address/);
  assert.equal(fc.calls.length, 0);
  // Linked in the answer already: no card for it.
  assert.deepEqual(sourceCards("See https://a.com/1", [{ title: "A", url: "https://a.com/1" }, { title: 'B "quoted"', url: "https://b.com/2" }]),
    [`card "B 'quoted'" sub="b.com" cta=Read url="https://b.com/2"`]);
  assert.equal(parse("```yui\n" + searchInvite("month", 50) + "\n```").errors.length, 0);
  assert.equal(await new Firecrawl("fc-ok", fc.fetch).check(), null);
  assert.equal(await new Firecrawl("fc-bad", fakeFirecrawl({ status: 401 }).fetch).check(), "Firecrawl turned this key down");
});
