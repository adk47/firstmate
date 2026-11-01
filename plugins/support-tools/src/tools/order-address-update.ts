import { Type, type Static } from "@sinclair/typebox";
import { execFile } from "node:child_process";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { textResult, type AgentTool, type AgentToolResult } from "../types.js";
import type { RateLimiter } from "../rate-limiter.js";
import { deriveConvId } from "./dedupe-check.js";
import { resolveOwnerAnchor, type OwnerAnchorDeps } from "../owner-anchor.js";
import { validateProdigiAddress, toStripeAddress, normalizeTaxId, type ProdigiAddressInput } from "../order-address.js";

// Hand-rolled promisifier (mirrors remove-credits.ts) so a test mock can use the
// plain (file, args, options, callback) shape.
type ExecFileLike = (
  file: string,
  args: readonly string[],
  options: { timeout?: number; maxBuffer?: number },
  callback: (err: unknown, stdout: string, stderr: string) => void,
) => unknown;

function execFileToPromise(fn: ExecFileLike) {
  return (file: string, args: readonly string[], options: { timeout?: number; maxBuffer?: number }) =>
    new Promise<{ stdout: string; stderr: string }>((resolve, reject) => {
      fn(file, args, options, (err, stdout, stderr) => {
        if (err) {
          const e = err as Error & { stdout?: string; stderr?: string };
          e.stdout = stdout;
          e.stderr = stderr;
          reject(e);
        } else {
          resolve({ stdout, stderr });
        }
      });
    });
}

const EMAIL_PATTERN = "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$";
const LINE = "^[^\\n\\r]{0,300}$";

const Recipient = Type.Object({
  name: Type.String({ minLength: 1, pattern: LINE, description: "Recipient full name (NOT a street)" }),
  phone: Type.String({ minLength: 1, pattern: LINE, description: "Phone number (Prodigi requires it)" }),
  line1: Type.String({ minLength: 1, pattern: LINE, description: "Address line 1 (street & house number)" }),
  line2: Type.Optional(Type.String({ pattern: LINE })),
  city: Type.String({ minLength: 1, pattern: LINE }),
  state: Type.Optional(Type.String({ pattern: LINE })),
  postcode: Type.String({ minLength: 1, pattern: LINE }),
  country: Type.String({ minLength: 1, pattern: LINE, description: "2-letter ISO country code (e.g. DO, US) — NOT the full country name" }),
  email: Type.Optional(Type.String({ pattern: EMAIL_PATTERN })),
  tax_id: Type.Optional(Type.String({ pattern: LINE, description: "Recipient tax ID, required by customs in MX (RFC/CURP), BR (CPF/CNPJ), CL (RUT), AR (CUIT), PE (RUC), CO (NIT), EC (RUC) and DO (RNC) — without it the parcel is held and returned. Validated against the destination country, so ask for it by its local name. Omit for every other country." })),
  tax_id_type: Type.Optional(Type.String({ pattern: LINE, description: "Optional: the id's type, lower-cased ('rfc', 'curp', 'cpf', 'cnpj', 'rut', 'cuit', 'ruc', 'nit', 'rcn'). Inferred from the value's shape if omitted; a type the destination doesn't use is rejected." })),
});

const Parameters = Type.Object({
  order_ref: Type.String({ minLength: 1, pattern: "^[A-Za-z0-9_-]+$", description: "Order UUID, order number, or Prodigi order id" }),
  customer_email: Type.String({ pattern: EMAIL_PATTERN, description: "The order owner's verified Intercom email. The wrapper re-verifies ownership against this." }),
  recipient: Recipient,
  apply: Type.Optional(Type.Boolean({ default: false, description: "false = dry-run preview (default), true = apply. Always dry-run first, show the customer, get explicit confirmation, then apply." })),
});

type Params = Static<typeof Parameters>;

interface ToolDeps extends OwnerAnchorDeps {
  // Same gate as order_lookup (ORDER_DETAILS_REQUIRE_IV, default TRUE): while Intercom Identity Verification is
  // not enforced, a contact's email / external_id is browser-assertable, so NO caller may preview (the dry run
  // returns the order's current address) or change an order. Only an explicit false opens the anchored path.
  orderDetailsRequireIv?: boolean;
  scriptPath: string;
  rateLimiter: RateLimiter;
  sessionId: string;
  // Trusted gateway session KEY (carries the Intercom conv id). The conv id is derived
  // from it, never taken from a model argument.
  sessionKey: string;
  execFileImpl?: ExecFileLike;
}

export const DEFAULT_UPDATE_ORDER_ADDRESS_SCRIPT =
  process.env.UPDATE_ORDER_ADDRESS_SCRIPT ??
  "/opt/hydra/workspaces/support/skills/order-fulfillment/scripts/update-order-address.sh";

export function createOrderAddressUpdateTool(deps: ToolDeps): AgentTool<typeof Parameters, unknown> {
  const { scriptPath, rateLimiter, sessionId, sessionKey, execFileImpl } = deps;
  const refuse = (error: string, extra: Record<string, unknown> = {}) =>
    textResult(JSON.stringify({ ok: false, error, ...extra,
      note: "No order detail is shown and nothing is changed. Hand the address change to the team (order-fulfillment request)." }));
  const exec = execFileToPromise(execFileImpl ?? (execFile as ExecFileLike));

  return {
    name: "order_address_update",
    label: "Update Order Shipping Recipient",
    description:
      "Correct a plaque/poster order's shipping recipient (name, phone, address, and tax id) and push it to the print vendor. " +
      "ONLY for the verified order owner — the wrapper refuses if the requester isn't the owner. " +
      "For a customs-gated destination (MX, BR, CL, AR, PE, CO, EC, DO), also collect the recipient's tax id via tax_id — customs holds and returns the parcel without it, and supplying it releases a NEEDS_TAX_ID hold. " +
      "Always call apply=false first to preview, get explicit customer confirmation, then call apply=true. The Intercom conversation is bound automatically; do not supply it. " +
      "Rejects addresses with lines over 40 chars or missing required fields. Rate limit: 5 calls per 60 minutes per session.",
    parameters: Parameters,
    async execute(_toolCallId: string, params: Params): Promise<AgentToolResult<unknown>> {
      // The wrapper's ownership re-check anchors on the Intercom conversation id. Derive
      // it from the trusted session key (never a model arg) and fail closed without it.
      const convId = deriveConvId(sessionKey);
      if (!convId) {
        return textResult(JSON.stringify({
          ok: false,
          error: "conv_id_unavailable",
          detail: "no Intercom conversation is bound to this session, so the customer cannot be verified",
        }));
      }

      // Ownership BEFORE the wrapper (s1 guardrails-1101 gap 6): the wrapper's dry run returns the order's current
      // address, so an unverified or non-owning contact must never reach it. A refusal code, never a redaction.
      if (deps.orderDetailsRequireIv !== false) {
        return refuse("owner_undetermined", { owner_check: "identity_verification_off" });
      }
      const anchor = await resolveOwnerAnchor(deps);
      if (!anchor.ok) return refuse("owner_undetermined", { owner_check: anchor.reason });
      if ((params.customer_email ?? "").trim().toLowerCase() !== anchor.email) {
        return refuse("owner_mismatch", { owner_check: "customer_email_is_not_the_verified_contact" });
      }

      if (!rateLimiter.check(sessionId, "order_address_update", 60, 5).allowed) {
        return textResult(JSON.stringify({ ok: false, error: "rate_limited" }));
      }

      // Authoritative address validation (single source of truth). Refuse before
      // touching the wrapper so Caroline gets the specific fix-it feedback.
      const input: ProdigiAddressInput = params.recipient;
      const validation = validateProdigiAddress(input);
      if (!validation.ok) {
        return textResult(JSON.stringify({ ok: false, error: "address_invalid", validation }));
      }

      // Optional recipient tax id for a customs-gated destination. Shape-check before
      // exec so a malformed id gets specific fix-it feedback, mirroring the address
      // gate. A bad id is no better than none — it still bounces at customs.
      //
      // The DESTINATION country scopes which shapes are valid, and must be passed:
      // the backend validates against `effectiveAddress.country` and 400s on a
      // mismatch, so validating without it here would disagree with the authority.
      let taxId: { taxId: string; taxIdType?: string } | null = null;
      if (params.recipient.tax_id && params.recipient.tax_id.trim()) {
        const t = normalizeTaxId(params.recipient.tax_id, params.recipient.tax_id_type, input.country);
        if (!t.ok) {
          return textResult(JSON.stringify({ ok: false, error: "tax_id_invalid", detail: t.reason }));
        }
        taxId = { taxId: t.value, ...(t.type ? { taxIdType: t.type } : {}) };
      }

      // Build the PUT body the backend expects: top-level name/phoneNumber/email
      // (+ taxId/taxIdType for tax-id-required destinations), address in
      // Stripe-shape (the backend re-derives the Prodigi shape). taxId is omitted
      // entirely when not supplied, so address-only corrections are unchanged.
      const body = {
        name: input.name?.trim(),
        phoneNumber: input.phone?.trim(),
        ...(params.recipient.email && params.recipient.email.trim() ? { email: params.recipient.email.trim() } : {}),
        address: toStripeAddress(input),
        ...(taxId ?? {}),
      };

      let tmpDir: string | null = null;
      try {
        tmpDir = await mkdtemp(path.join(tmpdir(), "oua-tool-"));
        const bodyFile = path.join(tmpDir, "body.json");
        await writeFile(bodyFile, JSON.stringify(body), "utf8");

        const argv = [
          scriptPath,
          "--order-ref", params.order_ref,
          "--customer-email", params.customer_email,
          "--body-file", bodyFile,
          "--intercom-conv-id", convId,
        ];
        if (params.apply === true) argv.push("--apply");

        const { stdout, stderr } = await exec("bash", argv, {
          timeout: 60 * 1000,
          maxBuffer: 2 * 1024 * 1024,
        });
        if (stderr && stderr.trim()) {
          console.warn(`[order_address_update] wrapper stderr: ${stderr.trim()}`);
        }
        const trimmed = stdout.trim();
        if (!trimmed) {
          return textResult(JSON.stringify({ ok: false, error: "wrapper_empty_output" }));
        }
        try {
          JSON.parse(trimmed);
        } catch {
          return textResult(JSON.stringify({ ok: false, error: "wrapper_invalid_output", detail: trimmed.slice(0, 200) }));
        }
        return textResult(trimmed);
      } catch (err) {
        const e = err as NodeJS.ErrnoException & { stderr?: string };
        const stderrSnippet = (e.stderr ?? "").trim().slice(0, 500);
        if (stderrSnippet) console.warn(`[order_address_update] wrapper exec failed; stderr: ${stderrSnippet}`);
        return textResult(JSON.stringify({
          ok: false,
          error: "wrapper_exec_failed",
          detail: e.message || "unknown",
          stderr: stderrSnippet || undefined,
          code: e.code ?? null,
        }));
      } finally {
        if (tmpDir) {
          await rm(tmpDir, { recursive: true, force: true }).catch(() => undefined);
        }
      }
    },
  };
}
