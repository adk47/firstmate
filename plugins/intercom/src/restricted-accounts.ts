// Restricted accounts: Intercom contacts that Caroline must never handle herself.
//
// WHY THIS EXISTS (2026-10-12): 15 accounts were banned after a fraud review (captain-approved
// "PULL", Fable item 1), their Stripe subscriptions were set to end at period end, and the captain
// ruled "no refunds on fraud cases". The first one to write in (17:56Z) got three replies from
// Caroline, who could not know the account was banned: she confirmed how long their access lasts and
// escalated the "unexpected cancellation" as a billing issue for Ops to fix. That is the wrong outcome
// in both directions: a promise to a banned account, and a ticket inviting a teammate to reverse a
// captain decision.
//
// So the check is deterministic and runs BEFORE the agent is dispatched: a message from one of these
// contacts is never answered by the agent and never acknowledged by the generic fallback. It goes to
// the human inbox with an Intercom internal note and a Slack alert saying what it is. A prompt rule could not guarantee that.
//
// Keys are Intercom CONTACT ids (opaque; no email or name in this repo). They are every contact found
// for the 12 still-listed accounts (of the 15 searched on 2026-10-12), by the account email and by
// the Muso profile external id (mapping re-derived from Intercom contact records + core users/claims on 2026-10-13).
// Limitation, stated plainly: a banned person who writes in from a NEW address creates a new contact
// that is not in this list. The human who picks up any conversation should still check the account.
//
// TWO TIERS (2026-10-13, after the fraud re-review; captain + firstmate 576):
//   banned        - the 3 accounts that stay banned (fraud confirmed). Hard hold: no reversal, no refund.
//   proof_review  - 9 accounts restored on 2026-10-13 whose disputed credits are under proof review.
//                   Same routing (human, silent, internal note), neutral note text.
// No expiry: these sets are maintained by hand, and an account leaves its set when the captain
// decides it. The note carries no date, because a date there would go stale.
// Three accounts the re-review cleared are NOT listed at all: Caroline handles them normally.
// Both tiers get the same treatment from the plugin; only the note the human sees differs.
//
// To add or remove an account, edit the matching set. The ledger of the underlying decisions lives
// with the firstmate CS lane (data/cs-systemic-issues-lane-c1/fraud-pull-stripe-cancel-2026-10-12.md).

export const RESTRICTED_CATEGORY = "restricted_account";
export const PROOF_REVIEW_CATEGORY = "proof_review_account";

// What the human sees (Intercom internal note + Slack alert). Never customer-facing.
export const RESTRICTED_NOTE =
  "banned fraud account - no reversal, no refund, escalate to Aaron";
export const PROOF_REVIEW_NOTE =
  "account restored, credits under proof review - escalate, no promises on credits";

// banned: 3 accounts, 4 contacts.
const BANNED_CONTACT_IDS: ReadonlySet<string> = new Set([
  "63bf0173c00101f1a4a458ec",
  "6660ab93f1ae3f2f322e805a",
  "68b5a3b2156f3730cab748bd", "6ab6b93dd1112bb52a968a18",
]);

// proof_review: 9 accounts, 14 contacts.
const PROOF_REVIEW_CONTACT_IDS: ReadonlySet<string> = new Set([
  "6207d785a391b23adf9309eb", "6207d7fe2dac44e627bbdfc6",
  "62e5a1f0367ae1371aab242b", "62e5a2005f115759da6e4070", "62e5a244d0830e30f9ff69f3",
  "63a756033095c208f361c19d",
  "651d64867692574a9d4363fc",
  "653d6188543386a913cae31e", "6aa6ae8e7f04185096f05f01",
  "65fa53898900641a7bcb0109",
  "670a0cf8e0acc1cdc8aa38bb",
  "676301708af8013e6b78fe14",
  "68d33fa3cabb46db0db9f59d", "6ab8c058917251cd4df9cacc",
]);

export interface Restriction {
  category: string;
  note: string;
}

const BANNED: Restriction = { category: RESTRICTED_CATEGORY, note: RESTRICTED_NOTE };
const PROOF_REVIEW: Restriction = { category: PROOF_REVIEW_CATEGORY, note: PROOF_REVIEW_NOTE };

// The restriction for a contact, or null when Caroline may handle it normally.
export function restrictionFor(contactId: string | null | undefined): Restriction | null {
  if (typeof contactId !== "string" || contactId.length === 0) return null;
  if (BANNED_CONTACT_IDS.has(contactId)) return BANNED;
  if (PROOF_REVIEW_CONTACT_IDS.has(contactId)) return PROOF_REVIEW;
  return null;
}

export function isRestrictedContact(contactId: string | null | undefined): boolean {
  return restrictionFor(contactId) !== null;
}
