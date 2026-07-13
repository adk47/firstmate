/**
 * Mechanical outbound tool-leak guardrail for the Intercom CS agent.
 *
 * Customer-facing replies must not contain internal tool names, architecture
 * terms, or "the system says..." phrasing. This sanitizer is the deterministic
 * enforcement layer -- SOUL.md prose is paired instruction-layer defense, not
 * the guarantee. Mirrors the shape of sanitize-email.ts so the wrapper in
 * outbound.ts can compose both predictably.
 */

export interface ToolLeakSanitizeResult {
  body: string;
  redactions: string[];
}

const REDACTED = "[REDACTED]";
const MAX_BODY_LENGTH = 16_000;

const PATTERNS: RegExp[] = [
  // tool tokens
  /\bprofile_status\b/g,
  /\bprofile_lookup\b/g,
  /\bcredits_search\b/g,
  /\bcreate_ticket\b/g,
  /\bsubscription_status\b/g,
  /\bremove_credits\b/g,
  /\bdedupe_check\b/g,
  /\bcredit_verification_check\b/g,
  /\bprofiles_claim_self\b/g,
  /\bcredits_verify\b/g,
  /\bprofiles_consolidate\b/g,
  /\border_lookup\b/g,
  /\border_address_update\b/g,
  /\bfounding_status\b/g,
  /\bfounding_buyback_link\b/g,
  /\bsupport_action_router\b/g,
  /\bmemory_search\b/g,
  /\bmemory_get\b/g,
  /\bprofile_analytics_status\b/g,
  /\bprofile_credits_status\b/g,
  /\bretention_offer_check\b/g,
  /\bretention_offer_apply\b/g,
  /\bcancel_subscription\b/g,
  /\btrack_analytics_status\b/g,
  /\banalytics_refresh_request\b/g,
  /\banalytics_recheck\b/g,
  /\bsubscription_cancel\b/g,
  /\brefund_policy_check\b/g,
  /\brefund_create\b/g,
  /\bcatalog_status\b/g,
  /\btrack_lookup\b/g,
  /\bmetadata_capture_request\b/g,
  /\bartwork_refresh_request\b/g,
  /\bcatalog_recheck\b/g,
  /\buser_status\b/g,
  /\bresend_verification\b/g,
  /\bemail_delivery_status\b/g,
  /\blogin_recovery_packet\b/g,
  /\bprofile_change_packet\b/g,
  /\bprofile_merge_check\b/g,
  /\baccount_merge_preflight\b/g,
  /\bemail_change_preflight\b/g,
  /\bprofile_removal_preflight\b/g,
  // defense-in-depth: scrub the bare word "ticket". Low false-positive
  // risk in Caroline's domain (music credits / profiles / subscriptions /
  // refunds). SOUL.md tells the model not to say "ticket" — this is
  // the mechanical backstop.
  /\bticket\b/gi,
  // internal phrases (case-insensitive)
  /\btool failed\b/gi,
  /\berror fetching\b/gi,
  /\bunable to look up\b/gi,
  /\bthe system says\b/gi,
  /\bmy system\b/gi,
  /\bthere was an issue with\b/gi,
  // architecture words
  /\bClickUp\b/gi,
  /\bopenclaw\b/gi,
  /\bHYDRA\b/g, // case-sensitive: only the all-caps internal moniker
];

export function sanitizeToolLeak(body: string): ToolLeakSanitizeResult {
  if (typeof body !== "string") {
    return { body: REDACTED, redactions: [`<non-string body: ${typeof body}>`] };
  }
  const truncated = body.length > MAX_BODY_LENGTH;
  let input = truncated ? body.slice(0, MAX_BODY_LENGTH) : body;
  const redactions: string[] = [];
  for (const pat of PATTERNS) {
    input = input.replace(pat, (match) => {
      redactions.push(match);
      return REDACTED;
    });
  }
  if (truncated) redactions.push(`<truncated: ${body.length} -> ${MAX_BODY_LENGTH} bytes>`);
  // A replacement string ("[REDACTED]") can be longer than the matched token,
  // so the post-replacement body may still exceed MAX_BODY_LENGTH even after
  // the pre-truncation above. Hard-cap the output to stay within the limit.
  const finalBody = input.length > MAX_BODY_LENGTH ? input.slice(0, MAX_BODY_LENGTH) : input;
  return { body: finalBody, redactions };
}
