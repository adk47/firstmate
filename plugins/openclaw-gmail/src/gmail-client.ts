import type { ResolvedGmailAccount } from "./accounts.js";
import type { ThreadResponse } from "./quoting.js";
import type { GogSearchMessage } from "./inbound.js";
import { GogGmailClient } from "./gog-client.js";
import { ApiGmailClient } from "./api-client.js";
import { resolveOAuthCredentials, createOAuth2Client, createServiceAccountClient } from "./auth.js";
import type { OpenClawConfig } from "openclaw/plugin-sdk";

export interface GmailClient {
  send(opts: {
    account?: string;
    to?: string;
    subject: string;
    textBody: string;
    htmlBody?: string;
    threadId?: string;
    replyToMessageId?: string;
    replyAll?: boolean;
  }): Promise<void>;

  getThread(threadId: string, opts?: { full?: boolean }): Promise<ThreadResponse | null>;
  getMessage(messageId: string): Promise<Record<string, unknown> | null>;
  searchMessages(query: string, opts?: { maxResults?: number; includeBody?: boolean }): Promise<GogSearchMessage[]>;
  searchThreads(query: string, opts?: { maxResults?: number }): Promise<Record<string, unknown> | null>;
  modifyLabels(id: string, opts: { add?: string[]; remove?: string[] }): Promise<void>;
  modifyThreadLabels(threadId: string, opts: { add?: string[]; remove?: string[] }): Promise<void>;
  listLabels(): Promise<{ id: string; name: string }[]>;
  createLabel(name: string): Promise<void>;
  downloadAttachment(messageId: string, attachmentId: string, outPath: string): Promise<void>;
  getSendAs(): Promise<{ displayName?: string; email: string; isPrimary?: boolean }[]>;
}

export function createGmailClient(account: ResolvedGmailAccount, cfg?: OpenClawConfig): GmailClient {
  if (account.backend === "api") {
    // Try service account first (never expires) — see auth.ts SA_KEY_PATH
    const saClient = createServiceAccountClient(account.email);
    if (saClient) {
      console.error("[openclaw-gmail] createGmailClient: using service account for", account.email);
      return new ApiGmailClient(saClient);
    }

    // Fall back to OAuth refresh token
    if (!cfg) {
      throw new Error(`API backend requires config to resolve OAuth credentials for ${account.email}`);
    }
    const creds = resolveOAuthCredentials(account.email, cfg);
    if (!creds) {
      throw new Error(
        `No OAuth credentials found for ${account.email}. ` +
        `Run onboarding or set oauth.clientId, oauth.clientSecret, and oauth.refreshToken in config.`,
      );
    }
    const auth = createOAuth2Client(creds, account.email);
    return new ApiGmailClient(auth);
  }

  return new GogGmailClient(account.email);
}
