// The Mini App end to end (INT-4), in a real browser against yuigui.com/tg or a
// local build. Telegram is stood in for by a window.Telegram.WebApp with
// Telegram's own light and dark theme colors and initData signed with a
// made-up bot token; telegram.org's script is not loaded. No bot, no chat.
//
//   node tests/miniapp_e2e.mjs [--base https://www.yuigui.com] [--shots DIR] [--only <sample slug>]
//
// Checks: every playground sample draws in dark and light with no page error
// (a screenshot each), the adapter's own "Open in Yui" link opens the same
// screen, a tap goes back through sendData and through the bridge as the
// phone's exact line with initData the bot verifies, and outside Telegram a
// tap says where to send it. Needs Playwright (PLAYWRIGHT=path to its package,
// default ~/src/ext-apps/node_modules/playwright).
import { mkdirSync } from "node:fs";
import { createRequire } from "node:module";
import { homedir } from "node:os";
import { join } from "node:path";
import { MemoryStore, render } from "../src/render.ts";
import { encodeYL } from "../src/share.ts";
import { signInitData, readBridgePost } from "../src/webapp.ts";

const arg = (k, d) => { const i = process.argv.indexOf(k); return i > 0 ? process.argv[i + 1] : d; };
const BASE = arg("--base", "http://127.0.0.1:3417").replace(/\/$/, "");
const SHOTS = arg("--shots", null);
const ONLY = arg("--only", null);
const HUB = process.env.YUIGUI || join(homedir(), "dev/yuigui");
const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT || join(homedir(), "src/ext-apps/node_modules/playwright"));
const { SCREENS, DEMOS, MEDIA, SCIENCE, FLOWS } = await import(join(HUB, "site/lib/yl/samples.mjs"));
const { slug } = await import(join(HUB, "site/lib/slug.mjs"));
const SAMPLES = [...SCREENS, ...DEMOS, ...MEDIA, ...SCIENCE, ...FLOWS].map((s) => ({ ...s, slug: s.slug || slug(s.name.replace(/^demo:\s*/i, "")) }));

const TOKEN = "123456:TEST-e2e-not-a-real-token";
// Telegram's default themes (iOS client), as the WebApp hands them over.
const THEME = {
  dark: { bg_color: "#000000", secondary_bg_color: "#1c1c1d", text_color: "#ffffff", hint_color: "#98989e", link_color: "#3e88f7", button_color: "#3e88f7", button_text_color: "#ffffff", section_separator_color: "#38383a" },
  light: { bg_color: "#ffffff", secondary_bg_color: "#f0f0f0", text_color: "#000000", hint_color: "#999999", link_color: "#2481cc", button_color: "#2481cc", button_text_color: "#ffffff", section_separator_color: "#e7e7e7" },
};

let pass = 0, fail = 0;
const ok = (c, name, extra = "") => { if (c) pass++; else fail++; console.log(`${c ? "ok  " : "FAIL"} ${name}${extra ? `  ${extra}` : ""}`); };

const initData = await signInitData({ auth_date: String(Math.floor(Date.now() / 1000)), query_id: "AAE-e2e", user: JSON.stringify({ id: 4242, first_name: "E2E" }) }, TOKEN);

function fakeTelegram(scheme, init) {
  return `(() => {
    const sent = [];
    window.__sent = sent;
    window.Telegram = { WebApp: {
      initData: ${JSON.stringify(init)}, initDataUnsafe: { user: { id: 4242 } }, colorScheme: ${JSON.stringify(scheme)},
      themeParams: ${JSON.stringify(THEME[scheme])}, platform: "ios", version: "8.0",
      ready() {}, expand() {}, onEvent() {}, offEvent() {}, setHeaderColor() {}, setBackgroundColor() {},
      sendData(d) { sent.push(d); }, HapticFeedback: { impactOccurred() {} },
    } };
  })();`;
}

const browser = await chromium.launch();
async function open(url, { scheme = "dark", telegram = true } = {}) {
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, colorScheme: scheme });
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.route("https://telegram.org/**", (r) => r.fulfill({ status: 200, contentType: "text/javascript", body: "" }));
  await page.route("https://www.googletagmanager.com/**", (r) => r.fulfill({ status: 200, contentType: "text/javascript", body: "" }));
  if (telegram) await page.addInitScript(fakeTelegram(scheme, initData));
  await page.goto(url, { waitUntil: "networkidle" });
  await page.waitForSelector(".tg-root .pg-node, .tg-note", { timeout: 15000 });
  await page.waitForTimeout(400);
  return { page, ctx, errors };
}

// 1. Every playground sample, dark and light.
if (SHOTS) mkdirSync(SHOTS, { recursive: true });
for (const s of SAMPLES.filter((x) => !ONLY || x.slug === ONLY)) {
  for (const scheme of ["dark", "light"]) {
    const { page, ctx, errors } = await open(`${BASE}/tg?demo=${encodeURIComponent(s.slug)}`, { scheme });
    const nodes = await page.locator(".tg-root .pg-node, .tg-root .stage-pill, .tg-root .yl-stagepill").count();
    const bg = await page.evaluate(() => getComputedStyle(document.querySelector(".tg-root")).backgroundColor);
    const want = scheme === "dark" ? "rgb(0, 0, 0)" : "rgb(255, 255, 255)";
    if (SHOTS) await page.screenshot({ path: join(SHOTS, `${s.slug}-${scheme}.png`), fullPage: false });
    ok(nodes > 0 && !errors.length && bg === want, `${s.slug} ${scheme}`, `${nodes} parts${errors.length ? `, errors: ${errors.join("; ")}` : ""}${bg !== want ? `, bg ${bg}` : ""}`);
    await ctx.close();
  }
}

// 2. The adapter's own link opens the same screen.
{
  const r = await render("Two things.\n```yui\nchoose \"What today?\" Push|Pull|Legs\ntimer 40/20x8 Tabata\n```", { store: new MemoryStore(), agent: "Coach" });
  const b = r.messages.flatMap((m) => m.reply_markup?.inline_keyboard.flat() ?? []).find((x) => x.text === "Open in Yui");
  const url = new URL(b.web_app.url);
  const { page, ctx, errors } = await open(`${BASE}/tg${url.search}`);
  const who = await page.locator(".tg-who").textContent();
  const chips = await page.locator(".tg-root .chip").allTextContents();
  ok(who === "Coach" && ["Push", "Pull", "Legs"].every((c) => chips.includes(c)) && !errors.length, "adapter link opens the screen", `agent ${who}, chips ${chips.join("|")}`);
  if (SHOTS) await page.screenshot({ path: join(SHOTS, "adapter-link-dark.png") });
  await ctx.close();
}

// 3. A tap through sendData is the phone's exact line.
{
  const code = await encodeYL('choose "What today?" Push|Pull|Legs\npick "Gear?" Bench|Bands');
  const { page, ctx } = await open(`${BASE}/tg?yl=${code}`);
  await page.locator(".tg-root .chip", { hasText: "Legs" }).click();
  await page.locator(".tg-root .chip", { hasText: "Bands" }).click();
  await page.locator(".tg-root .chip", { hasText: "Bench" }).click();
  await page.locator(".tg-root button", { hasText: /^Done/ }).click();
  const sent = await page.evaluate(() => window.__sent);
  ok(JSON.stringify(sent) === JSON.stringify(["[yui] n1 choose choice=Legs", "[yui] n2 pick picked=Bands|Bench"]), "sendData carries the event lines", JSON.stringify(sent));
  await ctx.close();
}

// 4. A tap through the bridge: POSTed with initData the bot verifies.
{
  const code = await encodeYL('ask "Send the invite now?" "Yes, send"|"Not yet"');
  const bridge = "https://bot.example.test/yui";
  const { page, ctx } = await open(`${BASE}/tg?yl=${code}&bridge=${encodeURIComponent(bridge)}`, { scheme: "light" });
  const posts = [];
  await page.route(bridge, async (r) => { posts.push(JSON.parse(r.request().postData())); await r.fulfill({ status: 200, body: "{}" }); });
  await page.locator(".tg-root button", { hasText: "Yes, send" }).click();
  await page.waitForSelector(".tg-note.ok");
  const note = await page.locator(".tg-note").textContent();
  const v = posts[0] ? await readBridgePost(posts[0], TOKEN) : null;
  ok(v?.ok && v.line === '[yui] n1 ask answer="Yes, send"' && v.user.id === 4242 && note === 'Sent "Yes, send".', "bridge POST verifies with the bot token", JSON.stringify(v));
  const sent = await page.evaluate(() => window.__sent);
  ok(sent.length === 0, "no sendData when there is a bridge");
  if (SHOTS) await page.screenshot({ path: join(SHOTS, "bridge-sent-light.png") });
  await ctx.close();
}

// 5. Outside Telegram: it draws, and a tap says where to send it.
{
  const code = await encodeYL('choose "What today?" Push|Pull|Legs');
  const { page, ctx, errors } = await open(`${BASE}/tg?yl=${code}`, { telegram: false });
  await page.locator(".tg-root .chip", { hasText: "Pull" }).click();
  const note = await page.locator(".tg-note").textContent();
  ok(note === 'Open this in Telegram to send "Pull".' && !errors.length, "outside Telegram a tap explains itself", note);
  await ctx.close();
}

// 6. No screen: a friendly note, not a crash.
{
  const { page, ctx, errors } = await open(`${BASE}/tg`);
  const note = await page.locator(".tg-note").textContent();
  ok(/Nothing to show here yet/.test(note) && !errors.length, "empty /tg says what it is for");
  await ctx.close();
}

await browser.close();
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
