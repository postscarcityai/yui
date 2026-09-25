// flue-blueprint: channel/yui@1
import { AgentRunError, init } from '@flue/runtime';
import { createYuiChannel, createYuiConnector, type YuiTurn } from 'yui-flue';
import { Assistant } from '../agents/assistant.ts';

// One Flue conversation per Yui thread. The instance id is the Yui agent's
// id, which only this connector's Yui account can reach.
async function answer(turn: YuiTurn): Promise<string | null> {
  const agent = init(Assistant, { id: `yui:${turn.agent.id}` });
  const receipt = await agent.dispatch({
    // A Yui thread is one person and their agent, so a user message. A tap
    // arrives as its `[yui] <id> <preset> key=value` line in the text.
    message: { kind: 'user', body: turn.text },
    // Stable for these rows: a turn replayed after a restart converges on
    // the first submission instead of running twice.
    idempotencyKey: turn.key,
    initialData: { yuiAgentId: turn.agent.id, name: turn.agent.name },
  });
  try {
    return (await agent.read(receipt)).text;
  } catch (e) {
    // A settled failure would fail the same way on a retry: tell the person once.
    if (e instanceof AgentRunError) return `${turn.agent.name} couldn't finish that (${e.outcome}).`;
    throw e; // anything else: the connector tries the same turn again later
  }
}

// Dial out to Yui (Node). Paired with `node yui-flue.ts pair <code>`.
export const client = createYuiConnector({ answer });

// Verified ingress for pushed turns: the webhook bridge's signed POSTs
// (`yui-webhook run --webhook <app>/channels/yui/webhook --secret ...`), and
// later Yui's hosted connector. Only when a secret is set: unsigned, anyone
// could talk as the person.
export const channel = process.env.YUI_WEBHOOK_SECRET
  ? createYuiChannel({ secret: process.env.YUI_WEBHOOK_SECRET, answer })
  : null;
