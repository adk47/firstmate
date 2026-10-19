import { Type, type Static } from "@sinclair/typebox";
import { textResult, type AgentTool, type AgentToolResult } from "../types.js";

const IntentSchema = Type.Union([
  Type.Literal("analytics_data_complaint"),
  Type.Literal("credit_verification"),
  Type.Literal("profile_claim"),
  Type.Literal("profile_duplicates"),
  Type.Literal("remove_wrong_credits"),
  Type.Literal("order_fulfillment"),
  Type.Literal("founding_member"),
  Type.Literal("billing_cancel_refund"),
  Type.Literal("catalog_metadata_repair"),
  Type.Literal("login_email_verification"),
  Type.Literal("account_profile_change"),
]);

const StateSchema = Type.Optional(Type.Union([
  Type.Literal("new_request"),
  Type.Literal("read_ok"),
  Type.Literal("missing_info"),
  Type.Literal("preview_ok"),
  Type.Literal("customer_confirmed"),
  Type.Literal("applied_ok"),
  Type.Literal("tool_refused"),
  Type.Literal("tool_disabled"),
  Type.Literal("loop_detected"),
]));

const Parameters = Type.Object({
  intent: IntentSchema,
  state: StateSchema,
});

type Params = Static<typeof Parameters>;
type RouterState = NonNullable<Params["state"]>;

type Availability = "live" | "partial" | "planned";
type Outcome = "call_tool" | "run_skill" | "ask_missing_info" | "ask_confirmation" | "apply_tool" | "close" | "handoff";

interface NextStep {
  outcome: Outcome;
  instruction: string;
  tool?: string;
  skill?: string;
  action_type?: string;
}

interface RouteDefinition {
  label: string;
  availability: Availability;
  goal: string;
  live_read_tools: string[];
  live_write_tools: string[];
  live_handoff_tools: string[];
  planned_tools: string[];
  human_gated_writes: string[];
  sequence: string[];
  close_when: string[];
  handoff_when: string[];
  missing_info: string[];
  tags: string[];
  steps: Record<RouterState, NextStep>;
}

const handoffStep = (actionType: string, instruction = "Create a structured handoff packet with the tool evidence and the exact customer ask."): NextStep => ({
  outcome: "handoff",
  tool: "create_ticket",
  action_type: actionType,
  instruction,
});

const closeStep = (instruction = "Reply with the result and close the loop. Do not create a ticket after a clean successful action."): NextStep => ({
  outcome: "close",
  instruction,
});

const creditProofStep: NextStep = {
  outcome: "run_skill",
  skill: "customer-credit-verification",
  instruction: "Ask for proof ONLY if none was given before (customer-credit-verification skill Step 2 no-re-ask rule), once, in one message covering all pending credits. Otherwise do not ask: still run the skill's Step 3 contradiction and catalog-corroboration checks on what is visible or stated, and if they do not resolve it, file the needs-human credit-verify ticket and tell the customer it is with the team. Never approve from prose alone.",
};

// remove_wrong_credits never applies a removal: core-backend refuses agent-token
// removals, so every post-preview state files the packet; the in-app instruction is additive.
const removalRouteStep = (): NextStep => handoffStep(
  "credit-correction",
  "Show the resolved (track, roles) list. File the credit-correction packet first (every route, including self-service), then tell an owner how to remove the credits themselves in the app. Do not tell the customer any removal happened.",
);

// Billing-route failure handoff: intentionally NO action_type. The route
// serves both refund and charge/billing-issue complaints and cannot see
// customer_request, so the agent must file with the request-appropriate type —
// billing-issue (Tier 2) for a charge/duplicate-charge complaint or any
// non-refund billing problem, subscription-refund (Tier 3) only for an explicit
// refund request — matching billing_status's own handoff_packet.action_type.
const billingFailureHandoff = (extra = ""): NextStep => ({
  outcome: "handoff",
  tool: "create_ticket",
  instruction:
    "File create_ticket with the request-appropriate action_type: billing-issue (Tier 2) for a charge/duplicate-charge complaint or any non-refund billing problem, subscription-refund (Tier 3) only for an explicit refund request. Include whatever billing_status facts you obtained." +
    (extra ? " " + extra : ""),
});

export const SUPPORT_ACTION_ROUTES: Record<string, RouteDefinition> = {
  analytics_data_complaint: {
    label: "Analytics or data freshness complaint",
    availability: "live",
    goal: "Ground the answer in profile, subscription, and analytics-status data; explain current state; file a follow-up only when evidence shows an account-specific issue.",
    live_read_tools: ["profile_status", "subscription_status", "profile_analytics_status"],
    live_write_tools: [],
    live_handoff_tools: ["create_ticket"],
    planned_tools: ["track_analytics_status", "analytics_refresh_request", "analytics_recheck"],
    human_gated_writes: [],
    sequence: [
      "Use profile_status first when the customer mentions analytics, streams, stale numbers, or whether their account is working.",
      "Use subscription_status when plan or seat entitlement could explain missing analytics.",
      "Use profile_analytics_status to read the profile's current analytics state before deciding close vs follow-up.",
      "If the live data explains the issue, answer directly and close.",
      "If the data genuinely looks wrong or stale, file analytics-followup with the observed evidence.",
    ],
    close_when: ["Profile/subscription/analytics evidence explains the state", "Customer only needed current plan or data visibility explained"],
    handoff_when: ["profile_status, subscription_status, or profile_analytics_status fails closed", "profile_analytics_status reports missing, stale, or inconsistent analytics", "Customer is stuck after one grounded explanation"],
    missing_info: ["Profile URL or name when profile_status cannot resolve the target", "Which track/profile/date range is stale"],
    tags: ["intent:analytics", "bundle:analytics", "outcome:close-or-handoff"],
    steps: {
      new_request: { outcome: "call_tool", tool: "profile_status", instruction: "Resolve the mentioned profile and inspect the latest visible state before answering." },
      read_ok: { outcome: "call_tool", tool: "profile_analytics_status", instruction: "Read the resolved profile's analytics status before deciding close vs follow-up; use subscription_status first only when entitlement is still unclear." },
      missing_info: { outcome: "ask_missing_info", instruction: "Ask for the profile or track needed to run the status check." },
      preview_ok: closeStep(),
      customer_confirmed: handoffStep("analytics-followup"),
      applied_ok: closeStep(),
      tool_refused: handoffStep("analytics-followup"),
      tool_disabled: handoffStep("analytics-followup"),
      loop_detected: handoffStep("analytics-followup", "Stop repeating generic analytics copy; file a follow-up with the exact observed evidence and conversation summary."),
    },
  },
  credit_verification: {
    label: "Pending credit verification",
    availability: "live",
    goal: "Inspect pending UVN credits, ask for proof at most once and only if none was given before, approve only catalog-corroborated owned requests, otherwise hand off cleanly.",
    live_read_tools: ["credit_verification_check", "profile_credits_status"],
    live_write_tools: ["credits_verify"],
    live_handoff_tools: ["create_ticket"],
    planned_tools: [],
    human_gated_writes: ["reject credit requests", "approve non-corroborated requests"],
    sequence: [
      "Use profile_credits_status first when it is unclear whether the credit already exists or is merely pending.",
      "Run credit_verification_check.",
      "Ask for proof once, in one message covering all pending credits, ONLY if none was given before (customer-credit-verification skill Step 2 no-re-ask rule); otherwise do not ask and continue with the skill's Step 3 checks and the steps below.",
      "For catalog-corroborated owned requests, preview credits_verify with apply:false.",
      "After customer confirmation, apply credits_verify with apply:true.",
      "For every other case, create a credit-verify handoff packet.",
    ],
    close_when: ["credits_verify apply:true returns ok", "No pending UVN credits exist and the answer is explained"],
    handoff_when: ["owner_undetermined, impersonation, shared profile, disabled, no approver, non-corroborated proof, or wrapper refusal"],
    missing_info: ["Profile URL/name", "Track title and role", "Proof screenshot/link or catalog corroboration"],
    tags: ["intent:credits", "bundle:credit-verification", "outcome:self-serve-or-handoff"],
    steps: {
      new_request: { outcome: "run_skill", skill: "customer-credit-verification", tool: "credit_verification_check", instruction: "Enter the credit verification skill and start with the read-only pending-credit check." },
      read_ok: creditProofStep,
      missing_info: creditProofStep,
      preview_ok: { outcome: "ask_confirmation", tool: "credits_verify", instruction: "Tell the customer which credit would be verified and wait for explicit confirmation before apply:true." },
      customer_confirmed: { outcome: "apply_tool", tool: "credits_verify", instruction: "Apply the already-previewed owned, catalog-corroborated credit verification." },
      applied_ok: closeStep("Tell the customer the credit has been verified. Do not also create a ticket."),
      tool_refused: handoffStep("credit-verify"),
      tool_disabled: handoffStep("credit-verify"),
      loop_detected: handoffStep("credit-verify"),
    },
  },
  profile_claim: {
    label: "Profile claim approval",
    availability: "live",
    goal: "Approve the customer's own pending profile claim when the muso gate says it is safe.",
    live_read_tools: ["profile_status", "profile_credits_status", "profile_claim_status"],
    live_write_tools: ["profiles_claim_self"],
    live_handoff_tools: ["create_ticket"],
    planned_tools: [],
    human_gated_writes: ["cross-owner claim approval", "manual ownership override"],
    sequence: ["Run profile_claim_status to discover the claim id, its state, and any competing claim.", "Self-serve only when it returns route_selfserve_claim with a claim id; any conflict or suspicion flag becomes a profile-claim packet.", "Preview profiles_claim_self with that claim id.", "Apply only after explicit confirmation.", "Hand off every refusal."],
    close_when: ["profiles_claim_self apply:true returns ok or noop for an already-applied own claim"],
    handoff_when: ["disabled, owner mismatch, ambiguous profile, shared ownership, competing claim, suspicion flags, or any route_to_human result"],
    missing_info: ["Profile URL"],
    tags: ["intent:profile-claim", "bundle:profile", "outcome:self-serve-or-handoff"],
    steps: {
      new_request: { outcome: "run_skill", skill: "customer-profile-claim", tool: "profile_claim_status", instruction: "Use the profile claim skill; read the claim state first with profile_claim_status." },
      read_ok: { outcome: "call_tool", tool: "profiles_claim_self", instruction: "Preview the customer's own pending claim using the claim id profile_claim_status returned; only when it routed self-serve." },
      missing_info: { outcome: "ask_missing_info", instruction: "Ask for the profile URL needed to read the claim state." },
      preview_ok: { outcome: "ask_confirmation", tool: "profiles_claim_self", instruction: "Confirm the exact profile that will be claimed before apply:true." },
      customer_confirmed: { outcome: "apply_tool", tool: "profiles_claim_self", instruction: "Apply the already-previewed own claim." },
      applied_ok: closeStep("Tell the customer the claim is sorted. Do not create a duplicate handoff."),
      tool_refused: handoffStep("profile-claim"),
      tool_disabled: handoffStep("profile-claim"),
      loop_detected: handoffStep("profile-claim"),
    },
  },
  profile_duplicates: {
    label: "Duplicate profile consolidation",
    availability: "live",
    goal: "Self-serve only same-owner unclaimed duplicate consolidation; everything destructive or cross-owner goes to a packet.",
    live_read_tools: ["dedupe_check", "profile_status", "profile_credits_status"],
    live_write_tools: ["profiles_consolidate"],
    live_handoff_tools: ["create_ticket"],
    planned_tools: [],
    human_gated_writes: ["claimed duplicate merge", "cross-owner merge", "unmerge", "delete profile"],
    sequence: ["Use profile_credits_status to surface same-name duplicate candidates when the customer cannot name the duplicate URLs yet.", "Run dedupe_check once the survivor and duplicate URLs are known.", "Preview profiles_consolidate only for owned survivor plus unclaimed same-name duplicates.", "Apply after confirmation.", "Hand off all other merges."],
    close_when: ["profiles_consolidate apply:true returns ok"],
    handoff_when: ["claimed duplicate, cross-owner signal, unmerge-shaped request, disabled, no approver, or ambiguity"],
    missing_info: ["Survivor profile URL", "Duplicate profile URLs"],
    tags: ["intent:profile-duplicates", "bundle:profile", "outcome:self-serve-or-handoff"],
    steps: {
      new_request: { outcome: "call_tool", tool: "dedupe_check", instruction: "Verify survivor ownership and duplicate claim state before any merge path." },
      read_ok: { outcome: "call_tool", tool: "profiles_consolidate", instruction: "Preview only if the check shows an owned survivor and unclaimed same-name duplicates." },
      missing_info: { outcome: "ask_missing_info", instruction: "Ask for the main profile URL plus duplicate profile URLs." },
      preview_ok: { outcome: "ask_confirmation", tool: "profiles_consolidate", instruction: "Confirm the survivor and duplicate ids before apply:true." },
      customer_confirmed: { outcome: "apply_tool", tool: "profiles_consolidate", instruction: "Apply the already-previewed same-owner consolidation." },
      applied_ok: closeStep("Tell the customer the duplicate profiles were consolidated. Do not also file a merge ticket."),
      tool_refused: handoffStep("profile-merge"),
      tool_disabled: handoffStep("profile-merge"),
      loop_detected: handoffStep("profile-merge"),
    },
  },
  remove_wrong_credits: {
    label: "Remove wrong credits from owned profile (preview and route only)",
    availability: "live",
    goal: "Resolve which mechanical wrong credits a customer owns on their profile, then route: file the staff packet and additionally point an owner to the in-app removal. The agent never removes a credit itself.",
    live_read_tools: ["profile_status", "credits_search", "profile_credits_status", "remove_credits"],
    live_write_tools: [],
    live_handoff_tools: ["create_ticket"],
    planned_tools: [],
    human_gated_writes: ["credit removal", "unmerge", "role-based bulk removals", "production-side credit removals"],
    sequence: ["Run the customer-credit-removal skill.", "Resolve ownership with profile_status.", "Dry-run remove_credits (apply:false only) to resolve the exact tracks.", "Show the resolved (track, roles) list.", "File the credit-correction packet (mandatory on every route).", "Then tell an owner how to remove the credits in the app."],
    close_when: ["the customer has the resolved list and a filed packet (plus the in-app removal steps for an owner)"],
    handoff_when: ["staff removal requested, unmerge-shaped cluster, owner mismatch, unclaimed/multi-owner profile, production-side role refusal, or repeated ambiguity"],
    missing_info: ["Profile URL", "Specific track titles to remove"],
    tags: ["intent:credit-removal", "bundle:credits", "outcome:self-serve-or-handoff"],
    steps: {
      new_request: { outcome: "run_skill", skill: "customer-credit-removal", tool: "profile_status", instruction: "Use the credit-removal skill; do the ownership pre-check first." },
      read_ok: { outcome: "call_tool", tool: "remove_credits", instruction: "Run remove_credits apply:false to resolve the exact tracks. Preview only; the apply mode is not available to the agent." },
      missing_info: { outcome: "ask_missing_info", instruction: "Ask for the profile URL and the exact track titles." },
      preview_ok: removalRouteStep(),
      customer_confirmed: removalRouteStep(),
      applied_ok: removalRouteStep(),
      tool_refused: handoffStep("credit-correction"),
      tool_disabled: handoffStep("credit-correction"),
      loop_detected: handoffStep("credit-correction"),
    },
  },
  order_fulfillment: {
    label: "Plaque or poster order fulfillment",
    availability: "live",
    goal: "Answer order status and correct the verified customer's own shipping address when the order is still editable.",
    live_read_tools: ["order_lookup"],
    live_write_tools: ["order_address_update"],
    live_handoff_tools: ["create_ticket"],
    planned_tools: [],
    human_gated_writes: ["vendor-requested address changes", "non-owner order edits", "refunds or replacements"],
    sequence: ["Run order_lookup.", "For address changes, dry-run order_address_update.", "Apply after customer confirmation.", "Hand off every owner/editability refusal."],
    close_when: ["Order status answers the question", "order_address_update apply:true returns ok"],
    handoff_when: ["Order not found, owner mismatch, vendor-only request, shipped/non-editable order, or apply failure"],
    missing_info: ["Order number or order id", "Correct recipient/address fields from the customer"],
    tags: ["intent:order", "bundle:fulfillment", "outcome:self-serve-or-handoff"],
    steps: {
      new_request: { outcome: "run_skill", skill: "order-fulfillment", tool: "order_lookup", instruction: "Use the order-fulfillment skill and look up the order first." },
      read_ok: { outcome: "call_tool", tool: "order_address_update", instruction: "For address edits, run apply:false with the proposed recipient." },
      missing_info: { outcome: "ask_missing_info", instruction: "Ask for the order reference and any missing address fields." },
      preview_ok: { outcome: "ask_confirmation", tool: "order_address_update", instruction: "Confirm the exact recipient/address before apply:true." },
      customer_confirmed: { outcome: "apply_tool", tool: "order_address_update", instruction: "Apply the already-previewed address update." },
      applied_ok: closeStep("Tell the customer the order address was updated. Do not create a ticket."),
      tool_refused: handoffStep("order-fulfillment"),
      tool_disabled: handoffStep("order-fulfillment"),
      loop_detected: handoffStep("order-fulfillment"),
    },
  },
  founding_member: {
    label: "Founding member status or buy-back",
    availability: "live",
    goal: "Read founder status and mint only the customer-requested paid buy-back checkout link.",
    live_read_tools: ["founding_status"],
    live_write_tools: ["founding_buyback_link"],
    live_handoff_tools: ["create_ticket"],
    planned_tools: [],
    human_gated_writes: ["free founder reinstatement", "manual comp", "price override"],
    sequence: ["Run founding_status before discussing perks.", "If lapsed and the customer explicitly asks to rejoin, run founding_buyback_link.", "Hand off comp/free reinstatement."],
    close_when: ["founding_status answers active/never/lapsed state", "founding_buyback_link returns a checkout URL"],
    handoff_when: ["Customer asks for free/comp reinstatement, status is ambiguous, link mint disabled/refused, or workspace cannot be verified"],
    missing_info: ["Clarify whether they want to rejoin when they are lapsed"],
    tags: ["intent:founding", "bundle:founding", "outcome:self-serve-or-handoff"],
    steps: {
      new_request: { outcome: "call_tool", tool: "founding_status", instruction: "Read the customer's verified founder state before answering." },
      read_ok: { outcome: "call_tool", tool: "founding_buyback_link", instruction: "Only mint when the status is lapsed and the customer explicitly asked to join or rejoin." },
      missing_info: { outcome: "ask_missing_info", instruction: "Ask whether they want the paid buy-back link before minting it." },
      preview_ok: closeStep(),
      customer_confirmed: { outcome: "apply_tool", tool: "founding_buyback_link", instruction: "Mint the checkout link only for the verified customer's workspace." },
      applied_ok: closeStep("Share the returned checkout link and returned figures only. Do not invent pricing."),
      tool_refused: handoffStep("founding-member"),
      tool_disabled: handoffStep("founding-member"),
      loop_detected: handoffStep("founding-member"),
    },
  },
  billing_cancel_refund: {
    label: "Subscription cancel or refund",
    availability: "partial",
    goal: "Read subscription state, run the retention save hierarchy (50% offer, then free plan), cancel at period end when the customer insists; refunds stay a handoff packet.",
    live_read_tools: ["subscription_status", "retention_offer_check", "billing_status"],
    live_write_tools: ["retention_offer_apply", "cancel_subscription"],
    live_handoff_tools: ["create_ticket"],
    planned_tools: ["refund_create"],
    human_gated_writes: ["refunds today", "manual discounts", "B2B invoice changes", "chargeback/legal threats"],
    sequence: [
      "Run the refund-retention skill for every cancel/refund request.",
      "Run subscription_status before quoting plan or renewal state.",
      "Run billing_status before filing any refund packet or diagnosing a charge/duplicate-charge/past-due complaint. Pass customer_request: charge_issue for a duplicate/unexpected charge; it returns a create_handoff_ticket packet whose action_type is billing-issue (a Tier-2 billing ticket, NOT the refund queue). Always file create_ticket with the packet's OWN action_type (subscription-refund for a refund request, billing-issue for a charge complaint).",
      "Read retention_offer_check before offering the 50% save; quote the returned offer wording verbatim.",
      "Apply retention_offer_apply only after the customer explicitly accepts; offer the free-plan save as the fallback.",
      "Cancel via cancel_subscription (period end) only after the customer declines the saves and explicitly confirms.",
      "Any refund request becomes a subscription-refund handoff packet carrying the billing_status packet — never cancel on the refund branch; Operations handles cancel+refund together.",
    ],
    close_when: ["Customer only needed current subscription state or self-service billing guidance", "retention_offer_apply returns ok for an accepted save", "cancel_subscription confirm:true returns ok (quote the returned access_until)"],
    handoff_when: ["Any refund request today", "billing_status reports past_due, a prior refund, or fails with vip_manual / not_stripe / ambiguous_workspace / not_found", "retention_offer_check/apply or cancel_subscription refuses or routes to human (past_due billing, VIP, non-Stripe, ambiguous workspace)", "Duplicate charge, B2B/manual invoice, chargeback/legal threat, or discount request"],
    missing_info: ["Account email if the verified conversation has no owner", "Charge date/amount when filing a refund handoff and billing_status could not resolve them"],
    tags: ["intent:billing", "bundle:billing", "outcome:self-serve-or-handoff"],
    steps: {
      new_request: { outcome: "run_skill", skill: "refund-retention", tool: "subscription_status", instruction: "Run the refund-retention skill and read subscription_status before deciding." },
      read_ok: { outcome: "call_tool", tool: "retention_offer_check", instruction: "Read the live retention offer before offering the 50% save. Refund requests run billing_status (customer_request: refund) and file the subscription-refund packet; charge/duplicate-charge complaints run it (customer_request: charge_issue) and file the billing-issue packet it returns. File create_ticket with the handoff_packet's own action_type." },
      missing_info: { outcome: "ask_missing_info", instruction: "Ask only for missing charge/account facts billing_status could not resolve." },
      preview_ok: { outcome: "ask_confirmation", tool: "cancel_subscription", instruction: "For an accepted 50% save confirm retention_offer_apply instead. For cancellation, confirm explicit cancel intent and declined saves before confirm:true (period-end cancel)." },
      customer_confirmed: { outcome: "apply_tool", tool: "cancel_subscription", instruction: "Apply the confirmed action: retention_offer_apply for an accepted save, cancel_subscription for a declined-saves cancel. Never call cancel on the refund branch." },
      applied_ok: closeStep("Quote the applied offer or access_until verbatim from the tool result. Do not create a ticket after a clean successful action."),
      // Failure states carry NO fixed action_type: this route serves both a
      // refund sub-flow and a charge/billing-issue sub-flow and cannot see
      // customer_request, so hardcoding subscription-refund would send a
      // charge/duplicate-charge complaint to the Tier-3 refund queue. The agent
      // files with the request-appropriate type, matching billing_status's own
      // handoff_packet.action_type.
      tool_refused: billingFailureHandoff(),
      tool_disabled: billingFailureHandoff("If billing_status is disabled for this account, still file the packet for the billing team."),
      loop_detected: billingFailureHandoff("Stop retrying; file with the exact charge/account facts gathered so far."),
    },
  },
  catalog_metadata_repair: {
    label: "Missing tracks, artwork, or metadata repair",
    availability: "partial",
    goal: "Use available profile/credit visibility and file a repair packet until catalog capture tools exist.",
    live_read_tools: ["profile_status", "credits_search", "profile_credits_status"],
    live_write_tools: [],
    live_handoff_tools: ["create_ticket"],
    planned_tools: ["catalog_status", "track_lookup", "metadata_capture_request", "artwork_refresh_request", "catalog_recheck"],
    human_gated_writes: ["manual catalog edits", "artist/label ownership disputes"],
    sequence: ["Resolve the profile/track with profile_status or credits_search.", "When a specific credit is referenced, run profile_credits_status to check whether it already exists, sits on another profile, or is pending verification before filing.", "If the data is missing or wrong, file catalog/metadata repair with exact identifiers.", "Close when the current data answers the question."],
    close_when: ["The requested track/artwork/metadata is already visible or the customer only needed where to submit it"],
    handoff_when: ["Track/artwork/metadata is missing after lookup", "Ownership/dispute ambiguity", "Customer supplied enough identifiers for repair"],
    missing_info: ["Track URL/title", "Artist/profile URL", "ISRC/UPC when available", "Artwork screenshot/link when relevant"],
    tags: ["intent:catalog", "bundle:metadata", "outcome:handoff-until-tools-ship"],
    steps: {
      new_request: { outcome: "call_tool", tool: "profile_status", instruction: "Resolve the profile first; use credits_search when a specific track is involved." },
      read_ok: { outcome: "call_tool", tool: "profile_credits_status", instruction: "When a specific credit/track is referenced, diagnose it before filing; on not_found or on_other_profile file the repair packet the tool suggests. Without a specific credit, file catalog-metadata directly." },
      missing_info: { outcome: "ask_missing_info", instruction: "Ask for the exact track/profile identifier needed for a repair packet." },
      preview_ok: handoffStep("catalog-metadata"),
      customer_confirmed: handoffStep("catalog-metadata"),
      applied_ok: closeStep(),
      tool_refused: handoffStep("catalog-metadata"),
      tool_disabled: handoffStep("catalog-metadata"),
      loop_detected: handoffStep("catalog-metadata"),
    },
  },
  login_email_verification: {
    label: "Login or email verification",
    availability: "planned",
    goal: "Collect exact account-state facts and hand off until login/email tools are exposed.",
    live_read_tools: [],
    live_write_tools: [],
    live_handoff_tools: ["create_ticket"],
    planned_tools: ["user_status", "resend_verification", "email_delivery_status", "login_recovery_packet"],
    human_gated_writes: ["manual email change", "account takeover risk decisions"],
    sequence: ["Ask for the account email if not available in the conversation.", "Never ask for password or codes.", "File login-recovery with the exact symptom and screenshots/errors."],
    close_when: ["Reference docs answer a generic login question without account action"],
    handoff_when: ["Customer cannot access account, verification email missing, bounce/suppression suspected, account email change needed"],
    missing_info: ["Account email", "Exact error text", "Whether they still control the email inbox"],
    tags: ["intent:login", "bundle:login", "outcome:handoff-until-tools-ship"],
    steps: {
      new_request: { outcome: "ask_missing_info", instruction: "Ask for the account email and exact error; do not request passwords or codes." },
      read_ok: handoffStep("login-recovery"),
      missing_info: { outcome: "ask_missing_info", instruction: "Ask for the single missing login fact needed for handoff." },
      preview_ok: handoffStep("login-recovery"),
      customer_confirmed: handoffStep("login-recovery"),
      applied_ok: closeStep(),
      tool_refused: handoffStep("login-recovery"),
      tool_disabled: handoffStep("login-recovery"),
      loop_detected: handoffStep("login-recovery"),
    },
  },
  account_profile_change: {
    label: "Profile or account change intake",
    availability: "partial",
    goal: "Gather proof and run safe prechecks; destructive account/profile changes stay human-gated.",
    live_read_tools: ["profile_lookup", "profile_status", "dedupe_check", "profile_claim_status"],
    live_write_tools: ["profiles_consolidate"],
    live_handoff_tools: ["create_ticket"],
    planned_tools: ["profile_change_packet", "profile_merge_check", "account_merge_preflight", "email_change_preflight", "profile_removal_preflight"],
    human_gated_writes: ["account merge", "email change", "profile removal", "claimed-profile merge", "identity override"],
    sequence: ["Use read/precheck tools to gather ownership evidence.", "Use profiles_consolidate only for the narrow own-unclaimed duplicate case.", "Hand off destructive or identity-sensitive changes with a complete packet."],
    close_when: ["profiles_consolidate succeeds for the narrow duplicate-profile case", "The customer only needed public profile guidance"],
    handoff_when: ["Email change, account merge, profile deletion/removal, identity proof mismatch, claimed duplicate, or any destructive request"],
    missing_info: ["Profile URLs", "Target email/name", "Proof of ownership", "Specific change requested"],
    tags: ["intent:account-profile-change", "bundle:profile", "outcome:packet-or-narrow-self-serve"],
    steps: {
      new_request: { outcome: "call_tool", tool: "profile_status", instruction: "Resolve the relevant profile and gather ownership signals before deciding if this is a narrow self-serve duplicate case." },
      read_ok: handoffStep("profile-change"),
      missing_info: { outcome: "ask_missing_info", instruction: "Ask for the exact profile/account details and proof needed for a complete packet." },
      preview_ok: { outcome: "ask_confirmation", tool: "profiles_consolidate", instruction: "Only for narrow same-owner unclaimed duplicates; otherwise hand off." },
      customer_confirmed: { outcome: "apply_tool", tool: "profiles_consolidate", instruction: "Apply only an already-previewed same-owner unclaimed duplicate consolidation." },
      applied_ok: closeStep(),
      tool_refused: handoffStep("profile-change"),
      tool_disabled: handoffStep("profile-change"),
      loop_detected: handoffStep("profile-change"),
    },
  },
};

const DENIED_TOOLS = ["exec", "muso api", "muso query", "raw_http", "db_write"];

export function createSupportActionRouterTool(): AgentTool<typeof Parameters, unknown> {
  return {
    name: "support_action_router",
    label: "Support Action Router",
    description:
      "Read-only router for Caroline support intents. Returns the router-suggested next step, live tools, planned tools, close conditions, and handoff conditions for a customer request. " +
      "Use it before choosing a tool for multi-step support cases. It never performs a customer-data read or write.",
    parameters: Parameters,
    async execute(_toolCallId: string, params: Params): Promise<AgentToolResult<unknown>> {
      const state = params.state ?? "new_request";
      const route = SUPPORT_ACTION_ROUTES[String(params.intent)];
      if (!route) {
        return textResult(JSON.stringify({
          ok: false,
          reason: "unknown_intent",
          route_to_human: true,
          allowed_intents: Object.keys(SUPPORT_ACTION_ROUTES),
        }));
      }

      const next = route.steps[state] ?? route.steps.new_request;
      return textResult(JSON.stringify({
        ok: true,
        intent: params.intent,
        state,
        label: route.label,
        availability: route.availability,
        goal: route.goal,
        next,
        live_tools: {
          read: route.live_read_tools,
          write: route.live_write_tools,
          handoff: route.live_handoff_tools,
        },
        planned_tools: route.planned_tools,
        human_gated_writes: route.human_gated_writes,
        denied_tools: DENIED_TOOLS,
        sequence: route.sequence,
        close_when: route.close_when,
        handoff_when: route.handoff_when,
        missing_info: route.missing_info,
        tags: route.tags,
        guardrails: [
          "Use the verified Intercom identity supplied by the tool boundary; never trust an email typed by the customer as authorization.",
          "Preview before apply for every gated write that supports dry-run.",
          "A clean successful write resolves the request; do not also create a handoff ticket.",
          "Any disabled, refused, ambiguous, cross-owner, or route_to_human result becomes a structured handoff packet.",
        ],
      }));
    },
  };
}
