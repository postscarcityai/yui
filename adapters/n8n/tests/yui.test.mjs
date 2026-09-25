// Unit tests for the Yui n8n node (INT-17), against the built dist/ and a fake
// yui-mcp that answers the way the real one does (ok(): text, then the data as
// JSON on the last line; bad(): isError). Run: npm test
import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { Yui } = require('../dist/nodes/Yui/Yui.node.js');
const { YuiApi } = require('../dist/credentials/YuiApi.credentials.js');
const { unfence, flatten, waitForAnswer } = require('../dist/nodes/Yui/mcp.js');
const { NodeOperationError } = require('n8n-workflow');

const TOKEN = 'yui_ct_test';
const SCREEN = '11111111-2222-3333-4444-555555555555';

// -- a fake yui-mcp ------------------------------------------------------------
function fakeServer(script) {
	const calls = [];
	const srv = http.createServer((req, res) => {
		let raw = '';
		req.on('data', (c) => (raw += c));
		req.on('end', async () => {
			const body = JSON.parse(raw);
			calls.push({ auth: req.headers.authorization, accept: req.headers.accept, body });
			const reply = await script(body.params?.name, body.params?.arguments ?? {}, calls.length);
			res.writeHead(200, { 'content-type': 'application/json' });
			res.end(JSON.stringify({ jsonrpc: '2.0', id: body.id, result: reply }));
		});
	});
	return new Promise((ok) => srv.listen(0, '127.0.0.1', () => ok({ srv, calls, url: `http://127.0.0.1:${srv.address().port}/yui-mcp` })));
}
const ok = (text, data) => ({ content: [{ type: 'text', text: `${text}\n${JSON.stringify(data)}` }] });
const bad = (text) => ({ content: [{ type: 'text', text }], isError: true });
const tap = (choice, id = 'n1') => ({
	id: 'row-' + choice, at: '2026-09-25T12:00:00Z', kind: 'event', text: `[yui] ${id} choose choice=${choice}`,
	event: { id, preset: 'choose', value: { choice }, echo: choice },
});

// -- a fake n8n execute context, auth applied the way n8n applies the credential
function ctx(url, params, { items = [{ json: {} }], continueOnFail = false } = {}) {
	const creds = { token: TOKEN, endpoint: url };
	const cred = new YuiApi();
	return {
		getInputData: () => items,
		getCredentials: async (name) => (assert.equal(name, 'yuiApi'), creds),
		getNode: () => ({ name: 'Yui', type: 'n8n-nodes-yui.yui' }),
		continueOnFail: () => continueOnFail,
		getNodeParameter: (name, i, fallback) => {
			const p = typeof params === 'function' ? params(i) : params;
			return name in p ? p[name] : fallback;
		},
		helpers: {
			async httpRequestWithAuthentication(name, opts) {
				assert.equal(name, 'yuiApi');
				const auth = cred.authenticate.properties.headers.Authorization.replace('{{$credentials.token}}', creds.token).replace(/^=/, '');
				const r = await fetch(opts.url, { method: opts.method, headers: { ...opts.headers, Authorization: auth }, body: JSON.stringify(opts.body) });
				return r.json();
			},
		},
	};
}
const run = (c) => new Yui().execute.call(c);

test('Ask and Wait: shows the screen, waits through an empty answer, returns the tap flat', async () => {
	const { srv, calls, url } = await fakeServer((tool, args, n) => {
		if (tool === 'yui_show') return ok('On it.', { screen_id: SCREEN, agent: 'n8n', ids: [{ id: 'n1', preset: 'choose' }] });
		if (tool === 'yui_answers') return n < 3 ? ok('Nothing yet', { agent: 'n8n', answers: [] }) : ok('[yui] n1 choose choice=Soup', { agent: 'n8n', answers: [tap('Soup')] });
	});
	try {
		const [[item]] = await run(ctx(url, { operation: 'ask', lines: '```yui\nchoose "Lunch?" Salad|Soup|Tacos\n```', text: 'Hi', timeout: 60, additional: {} }));
		assert.equal(item.json.choice, 'Soup');
		assert.equal(item.json.echo, 'Soup');
		assert.equal(item.json.line, '[yui] n1 choose choice=Soup');
		assert.equal(item.json.screen_id, SCREEN);
		assert.deepEqual(item.pairedItem, { item: 0 });
		assert.equal(calls[0].body.params.arguments.lines, 'choose "Lunch?" Salad|Soup|Tacos', 'the fence comes off');
		assert.equal(calls[0].body.params.arguments.text, 'Hi');
		assert.equal(calls[1].body.params.arguments.screen_id, SCREEN);
		assert.equal(calls[1].body.params.arguments.wait, 25, 'waits the most the server allows');
		assert.ok(calls.every((c) => c.auth === `Bearer ${TOKEN}` && c.accept.includes('application/json')));
		assert.ok(calls.every((c) => c.body.jsonrpc === '2.0' && c.body.method === 'tools/call'));
	} finally { srv.close(); }
});

test('Send Screen returns the screen id and tap ids, then Wait for Answer reads it by id', async () => {
	const { srv, calls, url } = await fakeServer((tool) =>
		tool === 'yui_show' ? ok('On it.', { screen_id: SCREEN, agent: 'n8n', ids: [{ id: 'q', preset: 'ask' }] })
			: ok('x', { agent: 'n8n', answers: [{ ...tap('Yes', 'q'), event: { id: 'q', preset: 'ask', value: { answer: 'Yes' }, echo: 'Yes' } }] }));
	try {
		const [[shown]] = await run(ctx(url, { operation: 'show', lines: 'ask@q "Ready?" Yes|No', additional: {} }));
		assert.deepEqual(shown.json, { screen_id: SCREEN, agent: 'n8n', ids: [{ id: 'q', preset: 'ask' }] });
		const [[got]] = await run(ctx(url, { operation: 'wait', screenId: shown.json.screen_id, timeout: 30, additional: {} }));
		assert.deepEqual(got.json.value, { answer: 'Yes' });
		assert.equal(got.json.id, 'q');
		assert.equal(got.json.choice, undefined);
		assert.equal(calls[1].body.params.arguments.screen_id, SCREEN);
	} finally { srv.close(); }
});

test('Send Message and the agent field', async () => {
	const { srv, calls, url } = await fakeServer(() => ok('Sent.', { message_id: 'm1', agent: 'Kitchen' }));
	try {
		const [[r]] = await run(ctx(url, { operation: 'say', message: 'Tea is ready', additional: { agent: 'kitchen' } }));
		assert.deepEqual(r.json, { message_id: 'm1', agent: 'Kitchen' });
		assert.deepEqual(calls[0].body.params, { name: 'yui_say', arguments: { text: 'Tea is ready', agent: 'kitchen' } });
	} finally { srv.close(); }
});

test("bad lines fail with the server's own message, and nothing waits", async () => {
	const msg = 'Nothing was sent. Fix these lines and call yui_show again:\n- chose x\n  unknown component';
	const { srv, calls, url } = await fakeServer(() => bad(msg));
	try {
		await assert.rejects(run(ctx(url, { operation: 'ask', lines: 'chose x', timeout: 5, additional: {} })),
			(e) => e instanceof NodeOperationError && e.message === msg);
		assert.equal(calls.length, 1);
		const [[r]] = await run(ctx(url, { operation: 'ask', lines: 'chose x', timeout: 5, additional: {} }, { continueOnFail: true }));
		assert.equal(r.json.error, msg);
	} finally { srv.close(); }
});

test('timeout: fails by default, or outputs timed_out', async () => {
	const { srv, url } = await fakeServer((tool) => tool === 'yui_show' ? ok('.', { screen_id: SCREEN, agent: 'n8n', ids: [] }) : ok('Nothing', { agent: 'n8n', answers: [] }));
	try {
		await assert.rejects(run(ctx(url, { operation: 'ask', lines: 'say hi', timeout: 0, additional: {} })), /No answer in Yui after 0 s/);
		const [[r]] = await run(ctx(url, { operation: 'ask', lines: 'say hi', timeout: 0, onTimeout: 'empty', additional: {} }));
		assert.deepEqual(r.json, { screen_id: SCREEN, timed_out: true });
	} finally { srv.close(); }
});

test('typed text: skipped (and kept) while waiting for a tap, or ends the wait with Taps Only off', async () => {
	const typed = { id: 'r2', at: 't', kind: 'text', text: 'make it tea' };
	const script = (tool, args, n) => tool === 'yui_show' ? ok('.', { screen_id: SCREEN, agent: 'n8n', ids: [] })
		: n === 2 ? ok('x', { agent: 'n8n', answers: [typed] }) : ok('x', { agent: 'n8n', answers: [tap('Tacos')] });
	let s = await fakeServer(script);
	try {
		const [[r]] = await run(ctx(s.url, { operation: 'ask', lines: 'choose "?" Soup|Tacos', timeout: 60, additional: {} }));
		assert.equal(r.json.choice, 'Tacos');
		assert.deepEqual(r.json.also_wrote, ['make it tea']);
	} finally { s.srv.close(); }
	s = await fakeServer(script);
	try {
		const [[r]] = await run(ctx(s.url, { operation: 'ask', lines: 'choose "?" Soup|Tacos', timeout: 60, additional: { tapsOnly: false } }));
		assert.equal(r.json.kind, 'text');
		assert.equal(r.json.echo, 'make it tea');
		assert.equal(r.json.id, null);
	} finally { s.srv.close(); }
});

test('several input items each get their own screen', async () => {
	let k = 0;
	const { srv, calls, url } = await fakeServer((tool) => tool === 'yui_show'
		? ok('.', { screen_id: `${SCREEN.slice(0, -1)}${++k}`, agent: 'n8n', ids: [] })
		: ok('x', { agent: 'n8n', answers: [tap(k === 1 ? 'A' : 'B')] }));
	try {
		const out = await run(ctx(url, (i) => ({ operation: 'ask', lines: `choose "Q${i}" A|B`, timeout: 30, additional: {} }), { items: [{ json: {} }, { json: {} }] }));
		assert.deepEqual(out[0].map((x) => [x.json.choice, x.pairedItem.item]), [['A', 0], ['B', 1]]);
		assert.equal(calls.filter((c) => c.body.params.name === 'yui_show').length, 2);
	} finally { srv.close(); }
});

test('waitForAnswer never asks the server to wait past the timeout', async () => {
	let t = 0;
	const waits = [];
	const post = async (b) => { waits.push(b.params.arguments.wait); t += b.params.arguments.wait * 1000; return { result: ok('', { answers: [] }) }; };
	const r = await waitForAnswer(post, { screenId: SCREEN, timeout: 60, tapsOnly: true, now: () => t });
	assert.equal(r.timedOut, true);
	assert.deepEqual(waits, [25, 25, 10]);
});

test('helpers: unfence, flatten', () => {
	assert.equal(unfence('```yui\ntimer 5m Focus\n```'), 'timer 5m Focus');
	assert.equal(unfence('  timer 5m Focus \n'), 'timer 5m Focus');
	assert.equal(flatten(tap('Walk'), SCREEN).choice, 'Walk');
	assert.equal(flatten({ id: 'x', at: 't', kind: 'text', text: 'hi' }).echo, 'hi');
});

test('package: n8n finds the node and credential, no runtime dependencies', async () => {
	const pkg = require('../package.json');
	assert.ok(pkg.keywords.includes('n8n-community-node-package'));
	assert.equal(pkg.dependencies, undefined);
	for (const f of [...pkg.n8n.nodes, ...pkg.n8n.credentials]) require(`../${f}`);
	const d = new Yui().description;
	assert.equal(d.name, 'yui');
	assert.equal(d.usableAsTool, true);
	assert.equal(d.credentials[0].name, new YuiApi().name);
	assert.ok(new YuiApi().properties.find((p) => p.name === 'token').typeOptions.password);
});
