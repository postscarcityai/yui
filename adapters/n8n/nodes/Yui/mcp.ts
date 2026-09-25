// Talks to Yui's MCP server (yui-mcp) with plain JSON-RPC over HTTP. The
// server is stateless: every call is one POST, no session, no SSE. The node
// passes `post`, which n8n signs with the Yui credential.

export type Post = (body: object) => Promise<unknown>;

export interface Screen {
	screen_id: string;
	agent: string;
	ids: Array<{ id: string; preset: string }>;
}

export interface Answer {
	id: string;
	at: string;
	kind: string;
	text: string;
	event?: { id: string; preset: string; value?: Record<string, unknown>; echo?: string; [k: string]: unknown };
	photos?: string[];
}

// A problem the workflow author can fix (bad lines, an unknown agent). The
// message is the server's own, word for word.
export class YuiError extends Error {}

let seq = 0;

export async function callTool(post: Post, name: string, args: Record<string, unknown>): Promise<{ text: string; data: any }> {
	const res = (await post({ jsonrpc: '2.0', id: ++seq, method: 'tools/call', params: { name, arguments: args } })) as any;
	const r = typeof res === 'string' ? JSON.parse(res) : res;
	if (r?.error) throw new YuiError(`Yui refused ${name}: ${r.error.message ?? JSON.stringify(r.error)}`);
	const result = r?.result;
	const text: string = result?.content?.[0]?.text ?? '';
	if (!result || result.isError) throw new YuiError(text || `Yui refused ${name}.`);
	// ok() in yui-mcp puts the data as JSON on the last line of the text.
	const nl = text.lastIndexOf('\n');
	let data: any = null;
	try {
		data = JSON.parse(text.slice(nl + 1));
	} catch {
		data = null;
	}
	return { text: nl >= 0 ? text.slice(0, nl) : text, data };
}

// Drop a ```yui fence if the author pasted one; the server takes bare lines.
export function unfence(lines: string): string {
	const m = lines.trim().match(/^```yui\s*\n([\s\S]*?)\n?```$/);
	return (m ? m[1] : lines).trim();
}

export async function show(post: Post, lines: string, text?: string, agent?: string): Promise<Screen> {
	const args: Record<string, unknown> = { lines: unfence(lines) };
	if (text) args.text = text;
	if (agent) args.agent = agent;
	const { data } = await callTool(post, 'yui_show', args);
	return data as Screen;
}

export async function say(post: Post, text: string, agent?: string): Promise<{ message_id: string; agent: string }> {
	const args: Record<string, unknown> = { text };
	if (agent) args.agent = agent;
	return (await callTool(post, 'yui_say', args)).data;
}

// Wait for what the person sends back to a screen. yui_answers holds each call
// open up to 25 s, so this loops until an answer comes or `timeout` runs out.
// `taps` keeps only taps (typed text in the thread is still marked read by the
// server, and returned in `other`).
export async function waitForAnswer(
	post: Post,
	opts: { screenId?: string; agent?: string; timeout: number; tapsOnly: boolean; now?: () => number },
): Promise<{ answers: Answer[]; other: Answer[]; timedOut: boolean }> {
	const now = opts.now ?? Date.now;
	const end = now() + opts.timeout * 1000;
	const other: Answer[] = [];
	for (;;) {
		const left = Math.max(0, Math.ceil((end - now()) / 1000));
		const args: Record<string, unknown> = { wait: Math.min(25, left) };
		if (opts.screenId) args.screen_id = opts.screenId;
		else if (opts.agent) args.agent = opts.agent;
		const { data } = await callTool(post, 'yui_answers', args);
		const got: Answer[] = data?.answers ?? [];
		const taps = opts.tapsOnly ? got.filter((a) => a.kind === 'event') : got;
		if (opts.tapsOnly) other.push(...got.filter((a) => a.kind !== 'event'));
		if (taps.length) return { answers: taps, other, timedOut: false };
		if (now() >= end) return { answers: [], other, timedOut: true };
	}
}

// One flat item per answer, easy to use in the next node: `choice`, `value`,
// `echo` (what the person saw as their reply) and the `[yui]` line.
export function flatten(a: Answer, screenId?: string): Record<string, unknown> {
	const ev = a.event;
	const out: Record<string, unknown> = {
		screen_id: screenId ?? null,
		kind: a.kind,
		line: a.text,
		id: ev?.id ?? null,
		preset: ev?.preset ?? null,
		echo: ev?.echo ?? (a.kind === 'event' ? null : a.text),
		value: ev?.value ?? null,
		message_id: a.id,
		at: a.at,
	};
	const v = ev?.value as Record<string, unknown> | undefined;
	if (v && 'choice' in v) out.choice = v.choice;
	if (a.photos) out.photos = a.photos;
	return out;
}
