// The Yui channel for OpenClaw: config, gateway loop, outbound sends, prompt hints.
import { buildChannelOutboundSessionRoute, createChatChannelPlugin } from "openclaw/plugin-sdk/channel-core";
import type { ChannelPlugin } from "openclaw/plugin-sdk/channel-core";
import type { ChannelGatewayContext } from "openclaw/plugin-sdk/channel-contract";
import { createMessageReceiptFromOutboundResults, defineChannelMessageAdapter } from "openclaw/plugin-sdk/channel-outbound";
import { DEFAULT_ACCOUNT_ID, resolveYuiAccount, type ResolvedYuiAccount } from "./accounts.js";
import { Connector, pickAgent, Refused, State } from "./client.js";
import { runYuiTurn } from "./inbound.js";
import { FORMATTING_HINTS } from "./prompt.js";

const CHANNEL_ID = "yui" as const;

/** The running connector, so outbound sends reuse its session and outbox. */
let active: Connector | null = null;

async function sendYuiText(params: { cfg: any; to?: string | null; text: string }) {
  const account = resolveYuiAccount(params.cfg);
  const c = active ?? new Connector(new State(account.stateFile));
  await c.ensureSession();
  const agent = pickAgent(c.agents, params.to);
  if (!agent) throw new Refused(`no Yui agent ${JSON.stringify(params.to)} on this connector`);
  const messageId = await c.send(agent.id, params.text);
  return { channel: CHANNEL_ID, to: `yui:${agent.id}`, messageId };
}

async function startYuiGatewayAccount(ctx: ChannelGatewayContext<ResolvedYuiAccount>) {
  const account = resolveYuiAccount(ctx.cfg, ctx.accountId);
  if (!account.configured) {
    throw new Error("Yui is not paired: add an agent in the Yui app, then run `openclaw yui pair <code>`");
  }
  const log = (m: string) => ctx.log?.info?.(m);
  const connector = new Connector(new State(account.stateFile), log);
  active = connector;
  ctx.setStatus({ accountId: account.accountId, running: true, configured: true, enabled: account.enabled } as any);
  try {
    await connector.run(
      (agent, rows) => runYuiTurn({ cfg: ctx.cfg, account, agent, rows, guide: connector.guide, log }),
      ctx.abortSignal,
      account.interval,
    );
  } finally {
    if (active === connector) active = null;
    ctx.setStatus({ accountId: account.accountId, running: false } as any);
  }
}

const yuiMessageAdapter = defineChannelMessageAdapter({
  id: CHANNEL_ID,
  durableFinal: { capabilities: { text: true } },
  send: {
    text: async (ctx: any) => {
      const sent = await sendYuiText({ cfg: ctx.cfg, to: ctx.to, text: ctx.text });
      return {
        messageId: sent.messageId,
        receipt: createMessageReceiptFromOutboundResults({
          results: [{ channel: CHANNEL_ID, messageId: sent.messageId, conversationId: sent.to }],
          kind: "text",
        }),
      };
    },
  },
} as any);

export const yuiPlugin: ChannelPlugin<ResolvedYuiAccount> = createChatChannelPlugin({
  base: {
    id: CHANNEL_ID,
    meta: {
      id: CHANNEL_ID,
      label: "Yui",
      selectionLabel: "Yui (iPhone)",
      detailLabel: "Yui",
      docsPath: "/channels/yui",
      docsLabel: "yui",
      blurb: "your agent on your phone, with real screens: buttons, pickers, forms, timers.",
      markdownCapable: true,
      order: 90,
    },
    capabilities: { chatTypes: ["direct"] },
    reload: { configPrefixes: ["channels.yui"] },
    config: {
      listAccountIds: () => [DEFAULT_ACCOUNT_ID],
      resolveAccount: (cfg: any, accountId?: string | null) => resolveYuiAccount(cfg, accountId),
      defaultAccountId: () => DEFAULT_ACCOUNT_ID,
      isConfigured: (account: ResolvedYuiAccount) => account.configured,
      isEnabled: (account: ResolvedYuiAccount) => account.enabled,
    },
    messaging: {
      targetPrefixes: ["yui"],
      normalizeTarget: (raw: string) => raw.trim(),
      inferTargetChatType: () => "direct",
      targetResolver: {
        looksLikeId: (raw: string) => /^yui:/i.test(raw.trim()),
        hint: "<yui:agent-id|handle>",
      },
      resolveOutboundSessionRoute: ({ cfg, agentId, accountId, target }: any) =>
        buildChannelOutboundSessionRoute({
          cfg,
          agentId,
          channel: CHANNEL_ID,
          accountId,
          peer: { kind: "direct", id: target },
          chatType: "direct",
          from: `yui:${accountId ?? DEFAULT_ACCOUNT_ID}`,
          to: target,
        }),
    },
    agentPrompt: {
      inboundFormattingHints: () => FORMATTING_HINTS,
    },
    gateway: { startAccount: startYuiGatewayAccount },
    message: yuiMessageAdapter,
  },
  outbound: {
    base: { deliveryMode: "direct" },
    attachedResults: {
      channel: CHANNEL_ID,
      sendText: async ({ cfg, to, text }: any) => await sendYuiText({ cfg, to, text }),
    },
  },
} as any);
