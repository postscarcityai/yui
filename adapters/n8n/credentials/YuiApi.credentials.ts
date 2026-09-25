import type { IAuthenticateGeneric, ICredentialTestRequest, ICredentialType, INodeProperties } from 'n8n-workflow';

// A connection token (yui_ct_...) from pairing a code made in the Yui app
// (Agents > Add agent), kind "mcp". See spec/MCP.md "Pair with a code".
export class YuiApi implements ICredentialType {
	name = 'yuiApi';

	displayName = 'Yui API';

	documentationUrl = 'https://www.yuigui.com/developers/mcp#pair-with-a-code-three-steps';

	icon = 'file:../nodes/Yui/yui.svg' as const;

	properties: INodeProperties[] = [
		{
			displayName: 'Connection Token',
			name: 'token',
			type: 'string',
			typeOptions: { password: true },
			default: '',
			placeholder: 'yui_ct_...',
			description:
				'In Yui: Agents > Add agent, then trade its 6-digit code for a token (yui-connect pair, kind "mcp"). Removing the computer in the app revokes it.',
		},
		{
			displayName: 'Endpoint',
			name: 'endpoint',
			type: 'string',
			default: 'https://ewzzaoperdpxqxkshynx.supabase.co/functions/v1/yui-mcp',
			description: "Yui's MCP server. Leave as is.",
		},
	];

	authenticate: IAuthenticateGeneric = {
		type: 'generic',
		properties: { headers: { Authorization: '=Bearer {{$credentials.token}}' } },
	};

	test: ICredentialTestRequest = {
		request: {
			method: 'POST',
			url: '={{$credentials.endpoint}}',
			headers: { accept: 'application/json, text/event-stream', 'content-type': 'application/json' },
			body: { jsonrpc: '2.0', id: 1, method: 'ping' },
		},
	};
}
