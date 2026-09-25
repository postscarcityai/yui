import { createChannelRouter } from '@flue/runtime';
import { Hono } from 'hono';
import { channel as yui, client as yuiClient } from './channels/yui.ts';

const app = new Hono();

app.get('/health', (c) => c.json({ ok: true }));
// POST /channels/yui/webhook, when YUI_WEBHOOK_SECRET is set
if (yui) app.route('/channels/yui', createChannelRouter(yui.routes));

// Node target: dial out to Yui once this machine is paired.
if (yuiClient.paired) {
  yuiClient.start().catch((e) => console.error(`yui-flue: ${e?.message ?? e}`));
  yuiClient.stopOnSignals(); // Yui hears goodbye before the server exits
}

export default app;
