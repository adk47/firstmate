import { Type, type Static } from "@sinclair/typebox";
import { execFile } from "node:child_process";
import { textResult, type AgentTool, type AgentToolResult } from "../types.js";
import type { RateLimiter } from "../rate-limiter.js";
import type { IntercomReader } from "../intercom-client.js";
import { deriveConvId } from "./dedupe-check.js";

// Caroline's real, safe actions (caroline-operator-c1, captain 2026-10-27 ~16:00Z).
//
//   credit_status_lookup   core truth -> ONE approved status line, or a refusal
//   document_intake        the customer's cached attachments -> the document reader's intake
//   merge_request_intake   a merge request -> the merge queue (a profile-merge ticket); never executes
//   credit_trust_handoff   a case she cannot decide -> the credit-trust board queue
//
// Every decision lives in scripts/caroline-actions.py (docs/credit-verification/caroline-actions.md);
// these tools only dispatch. The identity is the conversation's CUSTOMER email, derived in-plugin from
// the trusted session key (deriveConvId -> getCustomerEmail), never a model argument and never
// getAuthorEmail (which returns the teammate on threads our own outbound note opened).
//
// None of them approves, rejects, deletes or hides. Nothing is sent: an approved line comes back as
// `reply_line` only while node-8's lines switch is on, and Caroline then uses it VERBATIM; with
// `reply_line: null` she gives no status sentence of her own.
//
// Dark-shipped: `carolineActionsEnabled` (default OFF) -> {disabled:true}, no exec, no network.

export const DEFAULT_CAROLINE_ACTIONS_SCRIPT =
  process.env.CAROLINE_ACTIONS_SCRIPT ?? "/opt/hydra/scripts/caroline-actions.py";

const UUID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i;
const HANDOFF_REASONS = [
  "owes_proof", "dispute", "decided_not_closed", "account_hold", "facts_unknown", "no_approved_line",
  "customer_asked_for_person", "claim_proof", "merge_contested", "other",
] as const;

type ExecFileLike = (
  file: string,
  args: readonly string[],
  options: { timeout?: number; maxBuffer?: number },
  callback: (err: unknown, stdout: string, stderr: string) => void,
) => unknown;

export interface CreateTicketLike {
  execute: (toolCallId: string, params: any) => Promise<AgentToolResult<unknown>>;
}

export interface CarolineActionsDeps {
  scriptPath: string;
  rateLimiter: RateLimiter;
  sessionKey: string;
  intercomReader: IntercomReader;
  intercomToken: string;
  enabled: boolean;
  execFileImpl?: ExecFileLike;
  // merge_request_intake files through the ordinary create_ticket (which stamps merge_intake).
  createTicket?: () => CreateTicketLike;
}

type Json = Record<string, unknown>;

function run(fn: ExecFileLike, file: string, args: string[]): Promise<Json> {
  return new Promise((resolve) => {
    fn(file, args, { timeout: 120 * 1000, maxBuffer: 2 * 1024 * 1024 }, (err, stdout, stderr) => {
      if (stderr && stderr.trim()) console.warn(`[caroline_actions] stderr: ${stderr.trim().slice(0, 500)}`);
      const text = (stdout ?? "").trim().split("\n").pop() ?? "";
      if (err && !text) {
        resolve({ ok: false, error: "actions_exec_failed", reply_line: null });
        return;
      }
      try {
        const parsed = JSON.parse(text);
        resolve(parsed && typeof parsed === "object" ? (parsed as Json) : { ok: false, error: "actions_invalid_output", reply_line: null });
      } catch {
        resolve({ ok: false, error: "actions_invalid_output", reply_line: null });
      }
    });
  });
}

const out = (o: Json) => textResult(JSON.stringify(o));

export function createCarolineActionTools(deps: CarolineActionsDeps): AgentTool[] {
  const exec = deps.execFileImpl ?? (execFile as ExecFileLike);

  // Shared front door: flag, rate limit, conversation, verified customer email. Fails closed.
  async function anchor(tool: string, max: number): Promise<{ conv: string; email: string } | Json> {
    if (!deps.enabled) return { ok: false, disabled: true, note: "Caroline's status/document/merge actions are not enabled; file a ticket instead", reply_line: null };
    if (!deps.rateLimiter.check(deps.sessionKey, tool, 60, max).allowed) return { ok: false, error: "rate_limited", reply_line: null };
    const conv = deriveConvId(deps.sessionKey);
    if (!conv) return { ok: false, error: "identity_unverified", detail: "conversation id unavailable", reply_line: null };
    if (!deps.intercomToken || !deps.intercomReader.getCustomerEmail) {
      return { ok: false, error: "identity_unverified", detail: "cannot read the conversation's customer", reply_line: null };
    }
    const email = await deps.intercomReader.getCustomerEmail(conv, deps.intercomToken);
    if (!email) return { ok: false, error: "identity_unverified", detail: "no single customer contact with an email on this conversation", reply_line: null };
    return { conv, email };
  }
  const isAnchor = (a: unknown): a is { conv: string; email: string } =>
    !!a && typeof (a as any).conv === "string" && typeof (a as any).email === "string";

  const status: AgentTool = {
    name: "credit_status_lookup",
    label: "Look up the customer's credit or claim status (approved wording only)",
    description:
      "Read core truth for the VERIFIED customer (request status, core notice markers, IDP and account holds, claim state, merge ledger, hydra notes) " +
      "and get back ONE approved status line in `reply_line`, or `reply_line: null` with `refusals`. Use `reply_line` VERBATIM. When it is null, give no status sentence, " +
      "never say nothing else is needed, and use credit_trust_handoff if a person must decide. Read-only: changes nothing. Rate limit: 6 / 60 min.",
    parameters: Type.Object({ topic: Type.Union([Type.Literal("credit"), Type.Literal("claim")], { default: "credit" }) }),
    async execute(_id: string, params: { topic?: "credit" | "claim" }) {
      const a = await anchor("credit_status_lookup", 6);
      if (!isAnchor(a)) return out(a);
      return out(await run(exec, "python3", [deps.scriptPath, "status", "--email", a.email, "--conv", a.conv, "--topic", params?.topic === "claim" ? "claim" : "credit"]));
    },
  };

  const intake: AgentTool = {
    name: "document_intake",
    label: "File the customer's attached documents for the document reader",
    description:
      "When the customer sent a file (proof for a credit, or paperwork for their profile claim), call this ONCE. It files every attachment of THIS conversation " +
      "into the document reader's intake with their account and their open request (or claim) ids. It decides nothing about the document. " +
      "`reply_line` is the approved 'we have your document' line when nothing else is owed, else null: then say only that you have the file. Rate limit: 4 / 60 min.",
    parameters: Type.Object({ subject: Type.Union([Type.Literal("credit"), Type.Literal("claim")]) }),
    async execute(_id: string, params: { subject: "credit" | "claim" }) {
      const a = await anchor("document_intake", 4);
      if (!isAnchor(a)) return out(a);
      const subject = params?.subject === "claim" ? "claim" : "credit";
      return out(await run(exec, "python3", [deps.scriptPath, "doc-intake", "--email", a.email, "--conv", a.conv, "--subject", subject]));
    },
  };

  const MergeParams = Type.Object({
    keepProfile: Type.String({ description: "The profile the customer wants to KEEP: its credits.muso.ai URL or UUID." }),
    otherProfiles: Type.Array(Type.String(), { minItems: 1, maxItems: 5, description: "Each duplicate to fold into it: URL or UUID." }),
    summary: Type.String({ description: "One plain sentence: what the customer asked." }),
  });
  const merge: AgentTool = {
    name: "merge_request_intake",
    label: "File a profile-merge request to the merge queue (never executes)",
    description:
      "File the customer's profile-merge request to the merge queue (a profile-merge ticket with the merge intake block), once per request per 7 days. " +
      "It NEVER merges anything and promises no date; there is no approved merge wording, so `reply_line` is always null. Rate limit: 3 / 60 min.",
    parameters: MergeParams,
    async execute(_id: string, params: Static<typeof MergeParams>) {
      const a = await anchor("merge_request_intake", 3);
      if (!isAnchor(a)) return out(a);
      const id = (s: string) => (s ?? "").match(UUID)?.[0]?.toLowerCase() ?? "";
      const keep = id(params?.keepProfile);
      const others = (params?.otherProfiles ?? []).map(id);
      if (!keep || others.length === 0 || others.some((o) => !o)) {
        return out({ ok: false, refusals: ["not_profile_ids"], reply_line: null, hint: "Ask for each profile's credits.muso.ai link." });
      }
      const argv = [deps.scriptPath, "merge-intake", "--email", a.email, "--conv", a.conv, "--kind", "profile-merge", "--keep", keep];
      for (const o of others) argv.push("--other", o);
      const check = await run(exec, "python3", argv);
      const refusals = Array.isArray(check.refusals) ? (check.refusals as unknown[]) : ["actions_unavailable"];
      if (refusals.length > 0 || typeof check.merge_row !== "number") return out({ ...check, reply_line: null });
      if (!deps.createTicket) {
        await run(exec, "python3", [deps.scriptPath, "merge-record", "--email", a.email, "--conv", a.conv, "--row", String(check.merge_row), "--failed"]);
        return out({ ok: false, refusals: ["merge_queue_unavailable"], reply_line: null });
      }
      // The to_file row is already committed. If the ticket call THROWS (a ClickUp timeout, a crash),
      // we cannot know whether a ticket exists: the row stays to_file (it blocks a second filing for 7
      // days, so there is never a duplicate) and the answer says so explicitly, with the next step.
      let ticket: Awaited<ReturnType<CreateTicketLike["execute"]>>;
      try {
        ticket = await deps.createTicket().execute("merge_request_intake", {
          actionType: "profile-merge",
          customerEmail: a.email,
          customerProfileId: keep,
          summary: (params.summary ?? "").slice(0, 300) || "Customer asked to merge duplicate profiles",
          conversationSummary: "Filed by merge_request_intake (Caroline). No merge was executed and no date was promised.",
          details: {
            main_profile_url: `https://credits.muso.ai/profile/${keep}`,
            duplicate_profile_urls: others.map((o) => `https://credits.muso.ai/profile/${o}`),
          },
        });
      } catch (err) {
        console.warn(`[caroline_actions] merge ticket call threw: ${(err as Error)?.message ?? err}`);
        return out({
          ok: false,
          filed: "unknown",
          ticket_id: null,
          executed: false,
          merge_row: check.merge_row,
          refusals: ["merge_filing_outcome_unknown"],
          next: "credit_trust_handoff",
          note: "the merge ticket call failed mid-flight; it may or may not exist. Do not file again (the request is held for 7 days). Hand it off with credit_trust_handoff reason other, and promise nothing.",
          reply_line: null,
        });
      }
      let parsed: Json = {};
      try {
        const text = ticket.content.find((c): c is { type: "text"; text: string } => c.type === "text")?.text ?? "{}";
        parsed = JSON.parse(text);
      } catch {
        parsed = {};
      }
      const ok = parsed.submitted === true && typeof parsed.ticket_id === "string";
      // A refusal that names an EXISTING ticket (merge_intake_not_updated: ticket_id; keep_conflict_unflagged:
      // ticket_ids) means a merge request is already on file. Record that id so the row stays held for
      // 7 days: clearing it (--failed) would let a repeat file a duplicate (QA on #1402).
      const existingIds: string[] = !ok
        ? [parsed.ticket_id, ...(Array.isArray(parsed.ticket_ids) ? parsed.ticket_ids : [])]
            .filter((x: unknown): x is string => typeof x === "string" && x.trim() !== "")
        : [];
      const holdId = ok ? String(parsed.ticket_id) : existingIds[0];
      const rec = [deps.scriptPath, "merge-record", "--email", a.email, "--conv", a.conv, "--row", String(check.merge_row)];
      rec.push(...(holdId ? ["--ticket-id", holdId] : ["--failed"]));
      // The record step is retry-safe (the same ticket id on a filed row is a success), so a lost answer
      // is retried once. If it still fails, the row stays to_file, which blocks a second filing for 7 days:
      // the ticket is never filed twice, and the failure is SURFACED, never reported as a clean filing.
      let recorded = (await run(exec, "python3", rec)).recorded === true;
      if (!recorded) recorded = (await run(exec, "python3", rec)).recorded === true;
      if (!ok && holdId) {
        return out({
          ok: false,
          filed: false,
          ticket_id: holdId,
          existing_ticket_ids: existingIds,
          executed: false,
          refusals: [String(parsed.reason ?? "merge_ticket_exists")],
          held: recorded,
          note: "a merge request is already on file for this (ticket id above); it was not updated. Do not file again (held for 7 days). Hand off if the customer needs more, and promise nothing.",
          reply_line: null,
        });
      }
      if (ok && !recorded) {
        return out({
          ok: false,
          filed: true,
          ticket_id: parsed.ticket_id,
          executed: false,
          refusals: ["merge_record_failed"],
          note: "the merge ticket exists; its ledger record failed, so this request stays blocked from a second filing. Hand off, do not file again.",
          reply_line: null,
        });
      }
      return out({
        ok,
        filed: ok,
        ticket_id: ok ? parsed.ticket_id : null,
        ticket_result: ok ? undefined : parsed,
        executed: false,
        refusals: ok ? [] : ["merge_ticket_not_filed"],
        reply_line: null,
      });
    },
  };

  const HandoffParams = Type.Object({
    reason: Type.Union(HANDOFF_REASONS.map((r) => Type.Literal(r))),
    summary: Type.String({ description: "One or two plain sentences for the reviewer. No promises." }),
  });
  const handoff: AgentTool = {
    name: "credit_trust_handoff",
    label: "Hand a credit/claim case to the credit-trust board",
    description:
      "Hand a credit, claim or merge case you cannot decide (a dispute, a user who owes proof while asks are off, a refusal from credit_status_lookup) " +
      "to the credit-trust board queue, once per conversation and reason per 7 days. It decides nothing and promises nothing: `reply_line` is null. Rate limit: 3 / 60 min.",
    parameters: HandoffParams,
    async execute(_id: string, params: Static<typeof HandoffParams>) {
      const a = await anchor("credit_trust_handoff", 3);
      if (!isAnchor(a)) return out(a);
      const reason = (HANDOFF_REASONS as readonly string[]).includes(params?.reason) ? params.reason : "other";
      return out(await run(exec, "python3", [deps.scriptPath, "handoff", "--email", a.email, "--conv", a.conv, "--reason", reason,
        "--summary", String(params?.summary ?? "").slice(0, 500)]));
    },
  };

  return [status, intake, merge, handoff];
}
