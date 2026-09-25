// Driver for mcp_app_host_e2e.py (INT-7): plays the person in the ext-apps
// reference host (examples/basic-host). Calls yui_show from the host's form,
// waits for the Yui screen to draw in the sandboxed iframe, screenshots it,
// taps an option inside it, and waits for the view to say it was sent.
//
//   PW=<path to playwright> node mcp_app_host.cjs <out dir> <lines> <option to tap> [light]
const { chromium } = require(process.env.PW || "playwright");
const path = require("path");

const [out, lines, option, theme] = process.argv.slice(2);
const HOST = process.env.HOST_URL || "http://localhost:8080";

let page;
const log = [];
(async () => {
  const browser = await chromium.launch();
  page = await browser.newPage({ viewport: { width: 900, height: 1100 }, deviceScaleFactor: 2 });
  page.on("console", async (m) => {
    // The host logs the view's ui/message params as an object: expand it.
    if (m.text().includes("Message from MCP App")) {
      const args = await Promise.all(m.args().map((a) => a.jsonValue().catch(() => null)));
      log.push("Message from MCP App: " + JSON.stringify(args.slice(1)));
    } else log.push(m.text());
  });
  await page.goto(HOST);
  const tool = page.locator("select").nth(1);
  await page.waitForFunction(() => [...document.querySelectorAll("select option")].some((o) => o.value === "yui_show"), null, { timeout: 30000 });
  await tool.selectOption("yui_show");
  await page.locator("textarea").fill(JSON.stringify({ text: "Lunch?", lines }));
  // The reference host starts light; its toggle switches the host context.
  if (theme !== "light") await page.locator("button[title='Switch to dark mode']").click();
  await page.getByRole("button", { name: "Call Tool" }).click();

  // host page > sandbox proxy iframe (other origin) > the view (srcdoc)
  const outer = page.frameLocator("iframe").first();
  const view = outer.frameLocator("iframe").first();
  const btn = view.getByRole("button", { name: option, exact: true });
  await btn.waitFor({ timeout: 45000 });
  await view.getByText("also on your phone").waitFor({ timeout: 45000 });
  await page.waitForTimeout(600);
  await page.screenshot({ path: path.join(out, `host-screen${theme === "light" ? "-light" : ""}.png`), fullPage: true });
  await btn.click();
  const sent = view.getByText(/^Sent: /);
  await sent.waitFor({ timeout: 30000 });
  await page.waitForTimeout(400);
  await page.screenshot({ path: path.join(out, `host-tapped${theme === "light" ? "-light" : ""}.png`), fullPage: true });
  const status = await sent.textContent();
  const message = log.find((l) => l.includes("Message from MCP App")) || null;
  console.log(JSON.stringify({ status, message, log: log.filter((l) => /HOST|MCP App|error/i.test(l)).slice(-15) }));
  await browser.close();
})().catch(async (e) => {
  console.error(String(e?.stack || e));
  console.error(log.slice(-20).join("\n"));
  if (page) await page.screenshot({ path: path.join(out, "host-failed.png"), fullPage: true }).catch(() => {});
  process.exit(1);
});
