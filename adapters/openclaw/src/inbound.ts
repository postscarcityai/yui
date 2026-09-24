// One Yui turn through the OpenClaw agent: the person's rows in, one reply out.
//
// The rows become one inbound message on a direct session per Yui agent
// (peer yui:<agent id>). The OpenClaw agent is the Yui agent's remote_ref, set
// at pairing (`openclaw yui pair <code> --agent main`). Replies are collected
// from the dispatcher and handed back to the connector, which writes them to
// the thread exactly once (outbox, meta.turn). Only the paired Yui account can
// write these rows, so the sender is the owner and commands are authorized.
import type { ResolvedYuiAccount } from "./accounts.js";
import type { YuiAgent, YuiRow } from "./client.js";
import { guidePrompt } from "./prompt.js";
import { getYuiRuntime } from "./runtime.js";

const CHANNEL_ID = "yui";

function agentIds(cfg: any): string[] {
  const list = cfg?.agents?.list;
  return Array.isArray(list) ? list.map((a: any) => String(a?.id ?? "")).filter(Boolean) : [];
}

function route(cfg: any, account: ResolvedYuiAccount, agent: YuiAgent, target: string, log: (m: string) => void) {
  const runtime = getYuiRuntime();
  const peer = { kind: "direct" as const, id: target };
  const base = runtime.channel.routing.resolveAgentRoute({ cfg, channel: CHANNEL_ID, accountId: account.accountId, peer });
  const known = agentIds(cfg);
  const want = [agent.remote_ref, account.agent].find((id) => id && (known.includes(id) || id === base.agentId));
  if (agent.remote_ref && !want) log(`no OpenClaw agent "${agent.remote_ref}" for ${agent.name}; using ${base.agentId}`);
  const agentId = want ?? base.agentId;
  if (agentId === base.agentId) return base;
  return {
    ...base,
    agentId,
    sessionKey: runtime.channel.routing.buildAgentSessionKey({ agentId, channel: CHANNEL_ID, accountId: account.accountId, peer }),
  };
}

let attempt = 0;

export async function runYuiTurn(params: {
  cfg: any;
  account: ResolvedYuiAccount;
  agent: YuiAgent;
  rows: YuiRow[];
  guide: { version: string; body: string };
  log: (m: string) => void;
}): Promise<string[]> {
  const { cfg, account, agent, rows } = params;
  const runtime = getYuiRuntime();
  const target = `yui:${agent.id}`;
  const r = route(cfg, account, agent, target, params.log);
  const text = rows.map((row) => row.body).join("\n");
  const last = rows[rows.length - 1];
  const storePath = runtime.channel.session.resolveStorePath(cfg.session?.store, { agentId: r.agentId });
  const previousTimestamp = runtime.channel.session.readSessionUpdatedAt({ storePath, sessionKey: r.sessionKey });
  const body = runtime.channel.reply.formatAgentEnvelope({
    channel: "Yui",
    from: "Yui",
    timestamp: new Date(last.created_at),
    previousTimestamp,
    envelope: runtime.channel.reply.resolveEnvelopeFormatOptions(cfg),
    body: text,
  });
  // A turn tried again in the same process gets a fresh id, so OpenClaw's
  // inbound dedupe never swallows the retry. Restarts are deduped by meta.turn.
  const sid = `${last.id}:${++attempt}`;
  const ctxPayload = runtime.channel.reply.finalizeInboundContext({
    Body: body,
    BodyForAgent: text,
    RawBody: text,
    CommandBody: text,
    From: target,
    To: target,
    SessionKey: r.sessionKey,
    AccountId: r.accountId ?? account.accountId,
    ChatType: "direct",
    ConversationLabel: agent.name,
    NativeChannelId: agent.id,
    SenderName: "Yui",
    SenderId: target,
    Provider: CHANNEL_ID,
    Surface: CHANNEL_ID,
    MessageSid: sid,
    MessageSidFull: rows.map((row) => row.id).join(","),
    Timestamp: last.created_at,
    OriginatingChannel: CHANNEL_ID,
    OriginatingTo: target,
    CommandAuthorized: true,
    // Trusted system prompt: the Yui channel guide, and Yui Lines not A2UI.
    GroupSystemPrompt: guidePrompt(params.guide),
  });
  const out: string[] = [];
  let failed: unknown = null;
  await runtime.channel.inbound.dispatchReply({
    cfg,
    channel: CHANNEL_ID,
    accountId: account.accountId,
    agentId: r.agentId,
    routeSessionKey: r.sessionKey,
    storePath,
    ctxPayload,
    recordInboundSession: runtime.channel.session.recordInboundSession,
    dispatchReplyWithBufferedBlockDispatcher: runtime.channel.reply.dispatchReplyWithBufferedBlockDispatcher,
    delivery: {
      deliver: async (payload: any, info?: { kind?: string }) => {
        if (info?.kind === "tool") return; // tool progress stays on the host
        const parts = [typeof payload?.text === "string" ? payload.text : ""];
        const media = [payload?.mediaUrl, ...(payload?.mediaUrls ?? [])].filter((u) => typeof u === "string" && u);
        parts.push(...new Set(media as string[]));
        const t = parts.filter((p) => p.trim()).join("\n");
        if (t.trim()) out.push(t);
      },
      onError: (error: unknown) => {
        failed = error;
      },
    },
    replyPipeline: {},
    record: {
      onRecordError: (error: unknown) => params.log(`session record failed: ${String(error)}`),
    },
  } as any);
  if (failed) throw failed instanceof Error ? failed : new Error(String(failed));
  // One turn, one row: the phone shows the agent's answer as a single message.
  return out.length ? [out.join("\n\n")] : [];
}
