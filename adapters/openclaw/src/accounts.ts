// One Yui connector per OpenClaw install: the account is always "default".
// Its token lives in the state file written by `openclaw yui pair`, never in
// openclaw.json, so config dumps and backups don't carry it.
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { resolveStateDir } from "openclaw/plugin-sdk/state-paths";
import { State } from "./client.js";

export const DEFAULT_ACCOUNT_ID = "default";

export type YuiChannelConfig = { enabled?: boolean; stateFile?: string; interval?: number; agent?: string };
export type ResolvedYuiAccount = {
  accountId: string;
  enabled: boolean;
  configured: boolean;
  stateFile: string;
  interval: number;
  agent?: string; // the OpenClaw agent for Yui agents whose ref names none
};

export function channelSection(cfg: any): YuiChannelConfig {
  return (cfg?.channels?.yui ?? {}) as YuiChannelConfig;
}

export function stateFilePath(cfg?: any): string {
  const custom = channelSection(cfg).stateFile ?? process.env.YUI_OPENCLAW_STATE;
  if (custom) return custom.replace(/^~(?=\/)/, homedir());
  return join(resolveStateDir(), "yui", "connector.json");
}

export function resolveYuiAccount(cfg: any, accountId?: string | null): ResolvedYuiAccount {
  const section = channelSection(cfg);
  const stateFile = stateFilePath(cfg);
  const configured = existsSync(stateFile) && Boolean(new State(stateFile).data.token);
  return {
    accountId: accountId || DEFAULT_ACCOUNT_ID,
    enabled: section.enabled !== false,
    configured,
    stateFile,
    interval: Number(section.interval ?? 2),
    agent: section.agent,
  };
}
