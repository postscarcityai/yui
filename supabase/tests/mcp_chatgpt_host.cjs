// Driver for mcp_chatgpt_e2e.py (INT-8): plays the person in the Apps SDK
// test host (mcp_chatgpt_host.html). Waits for the Yui screen to draw in the
// sandboxed frame, screenshots it, taps an option, waits for the view to say
// it was sent, and prints the host's state as one JSON line.
//
//   PW=<path to playwright> node mcp_chatgpt_host.cjs <out dir> <host url> <bridge|openai> <dark|light> <lines> <option>
const { chromium } = require(process.env.PW || "playwright");
const path = require("path");

const [out, base, mode, theme, lines, option] = process.argv.slice(2);
const name = `chatgpt-${mode}-${theme}`;

let page;
const log = [];
(async () => {
  const browser = await chromium.launch();
  page = await browser.newPage({ viewport: { width: 760, height: 900 }, deviceScaleFactor: 2 });
  page.on("console", (m) => log.push(m.text()));
  await page.goto(`${base}/?${new URLSearchParams({ mode, theme, lines })}`);
  const view = page.frameLocator("#widget");
  const btn = view.getByRole("button", { name: option, exact: true });
  await btn.waitFor({ timeout: 45000 });
  await view.getByText("also on your phone").waitFor({ timeout: 45000 });
  await page.waitForTimeout(700);
  await page.screenshot({ path: path.join(out, `${name}.png`), fullPage: true });
  await btn.click();
  const sent = view.getByText(/^(Sent|Not sent): /);
  await sent.waitFor({ timeout: 30000 });
  await page.waitForTimeout(500);
  await page.screenshot({ path: path.join(out, `${name}-tapped.png`), fullPage: true });
  const status = await sent.textContent();
  const state = await page.evaluate(() => window.__state);
  // Chromium logs a CSP block on the console too.
  const cspConsole = log.filter((l) => /Content Security Policy/i.test(l));
  console.log(JSON.stringify({ status, ...state, cspErrors: [...state.cspErrors, ...cspConsole] }));
  await browser.close();
})().catch(async (e) => {
  console.error(String(e?.stack || e));
  console.error(log.slice(-20).join("\n"));
  if (page) {
    console.error(JSON.stringify(await page.evaluate(() => window.__state).catch(() => null)));
    await page.screenshot({ path: path.join(out, `${name}-failed.png`), fullPage: true }).catch(() => {});
  }
  process.exit(1);
});
