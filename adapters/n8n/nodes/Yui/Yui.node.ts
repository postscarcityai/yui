import {
	NodeConnectionTypes,
	NodeOperationError,
	type IDataObject,
	type IExecuteFunctions,
	type INodeExecutionData,
	type INodeType,
	type INodeTypeDescription,
} from 'n8n-workflow';

import { flatten, say, show, waitForAnswer, YuiError, type Post } from './mcp';

// "Yui: send screen / wait for answer" (INT-17). Every operation is one or
// more calls to Yui's MCP server, the same tools Claude and ChatGPT use.
export class Yui implements INodeType {
	description: INodeTypeDescription = {
		displayName: 'Yui',
		name: 'yui',
		icon: 'file:yui.svg',
		group: ['output'],
		version: 1,
		subtitle: '={{$parameter["operation"]}}',
		description: "Put a screen on the person's phone in Yui and wait for their tap",
		defaults: { name: 'Yui' },
		usableAsTool: true,
		inputs: [NodeConnectionTypes.Main],
		outputs: [NodeConnectionTypes.Main],
		credentials: [{ name: 'yuiApi', required: true }],
		properties: [
			{
				displayName: 'Operation',
				name: 'operation',
				type: 'options',
				noDataExpression: true,
				default: 'ask',
				options: [
					{
						name: 'Ask and Wait',
						value: 'ask',
						action: 'Show a screen and wait for the tap',
						description: 'Show a screen, then wait until the person answers it',
					},
					{
						name: 'Send Screen',
						value: 'show',
						action: 'Send a screen',
						description: 'Show a screen and go on at once; returns the screen ID',
					},
					{
						name: 'Wait for Answer',
						value: 'wait',
						action: 'Wait for an answer',
						description: 'Wait for the tap on a screen sent earlier',
					},
					{
						name: 'Send Message',
						value: 'say',
						action: 'Send a message',
						description: 'A plain chat message in the thread',
					},
				],
			},
			{
				displayName: 'Screen (Yui Lines)',
				name: 'lines',
				type: 'string',
				typeOptions: { rows: 4 },
				default: 'choose "Lunch?" Salad|Soup|Tacos',
				required: true,
				displayOptions: { show: { operation: ['ask', 'show'] } },
				description:
					'One component per line, no fence. Options are split with |. Full grammar: https://www.yuigui.com/yl.',
			},
			{
				displayName: 'Chat Text',
				name: 'text',
				type: 'string',
				default: '',
				displayOptions: { show: { operation: ['ask', 'show'] } },
				description: 'Optional line shown above the screen',
			},
			{
				displayName: 'Message',
				name: 'message',
				type: 'string',
				typeOptions: { rows: 2 },
				default: '',
				required: true,
				displayOptions: { show: { operation: ['say'] } },
			},
			{
				displayName: 'Screen ID',
				name: 'screenId',
				type: 'string',
				default: '={{ $json.screen_id }}',
				displayOptions: { show: { operation: ['wait'] } },
				description: 'The ID a Send Screen step returned. Empty waits for anything new in the thread.',
			},
			{
				displayName: 'Timeout (Seconds)',
				name: 'timeout',
				type: 'number',
				typeOptions: { minValue: 0 },
				default: 300,
				displayOptions: { show: { operation: ['ask', 'wait'] } },
				description: 'How long to wait for a tap. 0 checks once.',
			},
			{
				displayName: 'On Timeout',
				name: 'onTimeout',
				type: 'options',
				default: 'error',
				displayOptions: { show: { operation: ['ask', 'wait'] } },
				options: [
					{ name: 'Fail', value: 'error' },
					{ name: 'Output an Empty Answer', value: 'empty', description: 'One item with timed_out: true' },
				],
			},
			{
				displayName: 'Additional Fields',
				name: 'additional',
				type: 'collection',
				placeholder: 'Add Field',
				default: {},
				options: [
					{
						displayName: 'Agent',
						name: 'agent',
						type: 'string',
						default: '',
						description: 'The agent to post as, when the token serves several (its ref or name). Empty uses the first.',
					},
					{
						displayName: 'Taps Only',
						name: 'tapsOnly',
						type: 'boolean',
						default: true,
						description: 'Whether to keep waiting past text the person types. Off: typed text also ends the wait.',
					},
				],
			},
		],
	};

	async execute(this: IExecuteFunctions): Promise<INodeExecutionData[][]> {
		const items = this.getInputData();
		const out: INodeExecutionData[] = [];
		const creds = await this.getCredentials('yuiApi');
		const endpoint = String(creds.endpoint || '').trim();

		const post: Post = (body) =>
			this.helpers.httpRequestWithAuthentication.call(this, 'yuiApi', {
				method: 'POST',
				url: endpoint,
				headers: { accept: 'application/json, text/event-stream', 'content-type': 'application/json' },
				body,
				json: true,
			});

		for (let i = 0; i < items.length; i++) {
			try {
				const op = this.getNodeParameter('operation', i) as string;
				const extra = this.getNodeParameter('additional', i, {}) as { agent?: string; tapsOnly?: boolean };
				const agent = extra.agent?.trim() || undefined;
				const tapsOnly = extra.tapsOnly !== false;

				if (op === 'say') {
					const r = await say(post, this.getNodeParameter('message', i) as string, agent);
					out.push({ json: r as IDataObject, pairedItem: { item: i } });
					continue;
				}

				let screenId: string | undefined;
				if (op === 'ask' || op === 'show') {
					const lines = this.getNodeParameter('lines', i) as string;
					const text = this.getNodeParameter('text', i, '') as string;
					const screen = await show(post, lines, text, agent);
					if (op === 'show') {
						out.push({ json: screen as unknown as IDataObject, pairedItem: { item: i } });
						continue;
					}
					screenId = screen.screen_id;
				} else {
					screenId = (this.getNodeParameter('screenId', i, '') as string).trim() || undefined;
				}

				const timeout = this.getNodeParameter('timeout', i, 300) as number;
				const r = await waitForAnswer(post, { screenId, agent, timeout, tapsOnly });
				if (r.timedOut) {
					if (this.getNodeParameter('onTimeout', i, 'error') === 'error') {
						throw new NodeOperationError(this.getNode(), `No answer in Yui after ${timeout} s`, { itemIndex: i });
					}
					out.push({ json: { screen_id: screenId ?? null, timed_out: true }, pairedItem: { item: i } });
					continue;
				}
				const also = r.other.map((a) => a.text);
				for (const a of r.answers) {
					const json = flatten(a, screenId) as IDataObject;
					if (also.length) json.also_wrote = also;
					out.push({ json, pairedItem: { item: i } });
				}
			} catch (e) {
				const err = e instanceof YuiError ? new NodeOperationError(this.getNode(), e.message, { itemIndex: i }) : e;
				if (this.continueOnFail()) {
					out.push({ json: { error: (err as Error).message }, pairedItem: { item: i } });
					continue;
				}
				throw err;
			}
		}
		return [out];
	}
}
