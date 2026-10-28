import type { IntercomReader } from "./intercom-client.js";
import { deriveConvId } from "./tools/dedupe-check.js";

// Owner anchor for tools that would otherwise hand one person's data to whoever asks
// (caroline-redteam-r1 EX-1/EX-2). The requester is the conversation's ONE Intercom contact,
// read from the contact record, never from message text or a model argument.
//
// Intercom Identity Verification is OFF (web boots the Messenger without user_hash / JWT), so a
// contact's email and external_id are browser-assertable. Until it is on, the anchor also applies
// security-arch-fable-s1's fail-closed screen: role=user (never a lead), a non-empty external_id,
// and a contact created more than 24 h ago. There is NO "the conversation is older" exception: a
// fresh contact attached to an older conversation is exactly what a re-boot as someone else looks like
// while Identity Verification is off (r5 on #1437). Slack and any other non-Intercom session has no conversation id and anchors nothing.

export const MIN_CONTACT_AGE_S = 24 * 3600;

export type OwnerAnchor =
  | { ok: true; email: string }
  | {
      ok: false;
      reason:
        | "no_conversation"
        | "no_intercom_token"
        | "contact_unreadable"
        | "contact_not_user"
        | "contact_no_external_id"
        | "contact_age_unknown"
        | "contact_too_new";
    };

export interface OwnerAnchorDeps {
  sessionKey?: string;
  intercomReader?: IntercomReader;
  intercomToken?: string;
  nowSeconds?: () => number;
}

export async function resolveOwnerAnchor(deps: OwnerAnchorDeps): Promise<OwnerAnchor> {
  const convId = deriveConvId(deps.sessionKey);
  if (!convId) return { ok: false, reason: "no_conversation" };
  if (!deps.intercomToken) return { ok: false, reason: "no_intercom_token" };
  if (!deps.intercomReader?.getContactIdentity) return { ok: false, reason: "contact_unreadable" };
  let who;
  try {
    who = await deps.intercomReader.getContactIdentity(convId, deps.intercomToken);
  } catch {
    who = null;
  }
  if (!who || !who.email) return { ok: false, reason: "contact_unreadable" };
  if (who.role !== "user") return { ok: false, reason: "contact_not_user" };
  if (!who.externalId) return { ok: false, reason: "contact_no_external_id" };
  if (who.contactCreatedAt === null) return { ok: false, reason: "contact_age_unknown" };
  const now = (deps.nowSeconds ?? (() => Math.floor(Date.now() / 1000)))();
  if (now - who.contactCreatedAt <= MIN_CONTACT_AGE_S) return { ok: false, reason: "contact_too_new" };
  return { ok: true, email: who.email };
}
