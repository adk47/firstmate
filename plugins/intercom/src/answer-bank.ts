/**
 * Caroline's answer bank: the ONE versioned set of approved process lines (firstmate
 * caroline-guard-g1, captain 2026-11-01 "consistent answers and not talking about things we
 * shouldn't").
 *
 * Every process question Caroline answers (how credits / claims / merges / removals / declines /
 * GDPR work, a document thank-you, a status chase, the hand-off) is answered with one of these
 * texts, verbatim. Sources (Fable, ops-humans-off-fable-o1): caroline-instructions-1029 §2,
 * gdpr-ack-v2-and-arpad-1101 §2, decline-copy-ruling §1 (Caroline's side is §2.6 here), and the
 * workspace FAQ that carries them.
 *
 * Who reads it:
 *   - the output guard (caroline-output-guard.ts): an approved line is never blocked, a reply that
 *     starts an approved line and then changes it is (rule c, "altered approved line");
 *   - the doctrine gate (scripts/check-caroline-answer-bank.sh, bats-tested): every entry is
 *     present VERBATIM in the workspace file Caroline retrieves it from (`anchor`), so the
 *     knowledge base and the guard can never teach two different answers;
 *   - the red-team suite (plugins/intercom/tests/redteam/): every attack's safe answer is a bank
 *     line.
 *
 * Changing a line: edit it here AND in its anchor file in the same PR, bump BANK_VERSION, and get
 * the copy owner's ruling (caroline-teach-c1 ships, Fable r5 rules). The gate fails on drift.
 *
 * Pure, import-free and type-strippable: scripts/check-caroline-answer-bank.sh runs it with
 * `node --experimental-strip-types` to dump the bank, with no plugin build.
 */

export const BANK_VERSION = "2026-11-01.2";

export interface BankEntry {
  /** Stable id: the guard's flags, the red-team cases and the ledger name it. */
  id: string;
  /** Which customer intents this line answers (one line per reply, never two). */
  intents: string[];
  /** Where the ruling lives. */
  source: string;
  /** Workspace file (relative to workspaces/support) that must carry `text` verbatim. */
  anchor: string;
  /**
   * When set, the anchor file does not carry this text YET because the PR that ships it is still
   * open. The gate reports it as pending instead of failing, and FAILS once the text is live in
   * the anchor (so a stale pending marker cannot linger). Value: the PR URL.
   */
  pendingAnchor?: string;
  /**
   * A fact that must hold at send for this line to be true (Fable r5 [key=status-chase-fact]).
   * FAIL CLOSED: only a code-sourced known-true fact lets the line through; false or unknown
   * blocks it to the hand-off line.
   */
  requiresFact?: "open_request";
  /**
   * The approved text. `{date}` is the only placeholder (the GDPR acknowledgement's received
   * date); the guard accepts 1-40 characters there. Paragraphs are separated by a blank line.
   */
  text: string;
  /**
   * The first words of the line. A reply that contains the lead but not the exact approved text
   * is an ALTERED approved line (the merge-guard lesson, firstmate 017: the model paraphrases
   * the approved paragraph and the paraphrase is where the promise sneaks in).
   */
  lead?: string;
}

export const HANDOFF_LINE = "I'm pulling in a teammate to take this from here.";
/** SOUL.md honesty fallback (sanitize-handoff-claim.ts): intent, never a completed-action claim. */
export const HONEST_FALLBACK = "I'll make sure this gets to the team.";

export const ANSWER_BANK: readonly BankEntry[] = [
  {
    id: "credit_how",
    intents: ["how_credits_work", "credit_timing", "how_do_you_verify"],
    source: "caroline-instructions-1029 §2.1",
    anchor: "reference/faq.md",
    lead: "Here is how credit requests work now",
    text:
      "Here is how credit requests work now: when you add a credit, we check it automatically against public credit sources. " +
      "If we can confirm it, it goes live on your profile and you get an email. If we can't confirm it on our own, we message you, " +
      "here and by email, and tell you exactly what would settle it. Documents that come from outside Muso are what we can use: " +
      "a distributor or label statement, a split sheet, a contract, an invoice, a PRO registration. Where a document names a " +
      "company, we may confirm it with that company directly. You hear the outcome in this conversation and on your request page.",
  },
  {
    id: "document_thanks",
    intents: ["document_sent", "did_you_get_it"],
    source: "caroline-instructions-1029 §2.2",
    anchor: "skills/verification-handoff/SKILL.md",
    lead: "Everything you send here is recorded",
    text:
      "Thank you. Everything you send here is recorded against your account and your open requests and goes to the verification " +
      "team. If anything else is needed, the message you get will say exactly what.",
  },
  {
    id: "claim_how",
    intents: ["how_claims_work", "claim_timing"],
    source: "caroline-instructions-1029 §2.3",
    anchor: "reference/faq.md",
    lead: "Claims are confirmed by something only",
    text:
      "Claims are confirmed by something only the profile's owner can do, so nobody can claim a profile that isn't theirs. After " +
      "you claim, you get a message telling you the one thing to do, for example placing a short code on a page you control, and " +
      "once we see it the claim is approved automatically, usually within a day. If that isn't possible for you, the same message " +
      "tells you what paperwork works instead. We never ask for ID.",
  },
  {
    id: "merge_how",
    intents: ["merge_profiles"],
    source: "caroline-instructions-1029 §2.4",
    anchor: "reference/faq.md",
    // merge-reply-guard.ts MERGE_PARAGRAPH is the same text (the guard is import-free on
    // purpose); tests/answer-bank.test.ts pins the two equal.
    lead: "Merges work like this",
    text:
      "Merges work like this: claim every profile that is yours first (so we know they're all you), then tell me which one should " +
      "be the main profile. The merge is done by our verification team and you get a message in this conversation when it's " +
      "complete; credits from the duplicates move onto the main profile. Profiles claimed by someone else, and company or label " +
      "profiles, are handled differently: I'll pass those on.",
  },
  {
    id: "removal_how",
    intents: ["credit_removed", "credit_not_mine"],
    source: "caroline-instructions-1029 §2.5",
    anchor: "reference/credits-and-profiles.md",
    lead: "A credit is only removed from a profile",
    text:
      "A credit is only removed from a profile after we've checked it against the streaming platforms' own credits, and the " +
      "profile owner always gets a notice. If you think a credit on your profile is wrong, tell me which one and I'll pass it on; " +
      "if you want to show it's yours, a document from outside Muso that names you for that role is what the team can use.",
  },
  {
    id: "declined",
    intents: ["why_rejected", "claim_rejected"],
    source: "caroline-instructions-1029 §2.6 + decline-copy-ruling §1",
    anchor: "reference/credits-and-profiles.md",
    lead: "A request is closed when the supporting information",
    text:
      "A request is closed when the supporting information we received wasn't enough to confirm the credit. You can submit it " +
      "again with your supporting documents and a fresh review starts from the beginning. I can't see the review itself, so I " +
      "can't tell you more than that.",
  },
  {
    id: "status_chase",
    intents: ["nobody_answered", "where_is_my_request"],
    source: "caroline-instructions-1029 §2.8",
    anchor: "skills/verification-handoff/SKILL.md",
    lead: "Your request is in the verification queue",
    requiresFact: "open_request",
    text:
      "I understand. Your request is in the verification queue and the outcome comes to this conversation and to your email; if " +
      "the team needs anything from you they will ask here.",
  },
  {
    id: "gdpr_ack_v2",
    intents: ["gdpr_erasure", "delete_my_data", "remove_my_profile"],
    source: "gdpr-ack-v2-and-arpad-1101 §2",
    anchor: "reference/gdpr-erasure-requests.md",
    pendingAnchor: "https://github.com/Muso-AI/hydra/pull/1619",
    lead: "we have your request to remove your personal data",
    text:
      "Thank you, we have your request to remove your personal data from Muso, received {date}. Here is how it works.\n\n" +
      "1. Confirm it's you. The quickest way: open the page in the Muso app and claim it, that proves it on the spot. Or reply " +
      "from the email address on your Muso account, if you have one. If neither applies, send the link to the page and the name " +
      "on it as it appears on your ID; for a page that carries your name, that is enough. If you are writing for someone else, " +
      "send their written authorisation.\n\n" +
      "2. We hide the page. As soon as we've confirmed it's you, the page comes out of Muso search and public view (within a " +
      "day). If your request raises a legal matter, we hide it immediately.\n\n" +
      "3. Written confirmation on this thread, within one month of today, listing exactly what was done. Any account you hold is " +
      "closed and taken out of use on request; what has been deleted is stated in that confirmation.\n\n" +
      "Credit records on published works go through a separate formal review, and the written response covers them.",
  },
  {
    id: "gdpr_slot_no_link",
    intents: ["gdpr_erasure"],
    source: "gdpr-ack-v2-and-arpad-1101 §2 fixed slot",
    anchor: "reference/gdpr-erasure-requests.md",
    pendingAnchor: "https://github.com/Muso-AI/hydra/pull/1619",
    text: "To get started, reply with the link to the Muso page.",
  },
  {
    id: "gdpr_slot_own_name",
    intents: ["gdpr_erasure"],
    source: "gdpr-ack-v2-and-arpad-1101 §2 fixed slot",
    anchor: "reference/gdpr-erasure-requests.md",
    pendingAnchor: "https://github.com/Muso-AI/hydra/pull/1619",
    text:
      "1. Confirm it's you. The quickest way: open the page in the Muso app and claim it. Otherwise, because the page carries " +
      "your name, we will confirm it from that.",
  },
  {
    id: "hidden_stays",
    intents: ["will_my_page_come_back"],
    source: "caroline-instructions-1029 §5.7",
    anchor: "reference/gdpr-erasure-requests.md",
    text: "No, once a page is hidden it stays hidden; our written confirmation covers what was done.",
  },
  {
    id: "timing_claim",
    intents: ["claim_timing"],
    source: "caroline-instructions-1029 §2.9",
    anchor: "skills/verification-handoff/SKILL.md",
    text: "usually within a day",
  },
  {
    id: "timing_other",
    intents: ["when_will_i_hear"],
    source: "caroline-instructions-1029 §2.9",
    anchor: "skills/verification-handoff/SKILL.md",
    text: "you'll hear in this conversation and by email",
  },
  {
    id: "handoff_line",
    intents: ["handoff"],
    source: "#1451 hand-off-only doctrine",
    anchor: "skills/verification-handoff/SKILL.md",
    text: HANDOFF_LINE,
  },
  {
    id: "honest_fallback",
    intents: ["handoff_without_ticket"],
    source: "SOUL.md honesty rule (sanitize-handoff-claim.ts FALLBACK)",
    anchor: "SOUL.md",
    // SOUL.md quotes it without the full stop; the gate matches the sentence, the guard masks it.
    text: HONEST_FALLBACK.replace(/\.$/, ""),
  },
];

/**
 * What the output guard posts in place of a blocked reply. The hand-off line is the one approved
 * sentence that is true in every case: the guard reassigns the conversation to the human inbox in
 * the same step, so a teammate really does take it from here.
 */
export const BLOCKED_REPLY_FALLBACK = HANDOFF_LINE;

export function bankEntry(id: string): BankEntry | undefined {
  return ANSWER_BANK.find((e) => e.id === id);
}
