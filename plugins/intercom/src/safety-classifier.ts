/**
 * Optional second-layer classifier for the Caroline safety layer: Meta PromptGuard 2 served by
 * promptguard/server.py on node-8 loopback (SAFETY_CLASSIFIER_URL, a constant).
 *
 * Its place in the order (caroline-guard-g1 spec: "deterministic rules first, optional classifier
 * second"):
 *   - INBOUND: the label + score are recorded on the injection ledger row and in the log. They
 *     never change what is dispatched (detection only). A non-benign label with no rule hit is
 *     itself a ledger row, so the classifier extends the watch.
 *   - OUTBOUND: a reply the deterministic guard passed is blocked only when the classifier says
 *     injection/jailbreak at >= OUTBOUND_BLOCK_SCORE. It can ADD a block, never remove one.
 *
 * Fail-soft by design: if the sidecar is down, slow or answers garbage, the result is
 * `{label: "unavailable"}` and the deterministic layer is the whole decision (it is the
 * guarantee; the classifier is extra). Every unavailable result is counted in the ledger row so a
 * dead sidecar is visible in the daily digest, never silent.
 */

export const SAFETY_CLASSIFIER_URL = "http://127.0.0.1:18793/v1/classify";
export const SAFETY_CLASSIFIER_TIMEOUT_MS = 800;
export const OUTBOUND_BLOCK_SCORE = 0.98;
const MAX_CHARS = 10_000; // promptguard/server.py ClassifyRequest max_length

export interface ClassifierResult {
  label: "benign" | "injection" | "jailbreak" | "unavailable";
  score: number | null;
}

export type FetchLike = (url: string, init: { method: string; headers: Record<string, string>; body: string; signal: AbortSignal }) => Promise<{
  ok: boolean;
  json(): Promise<unknown>;
}>;

export async function classifyText(text: string, fetchImpl: FetchLike = fetch as unknown as FetchLike): Promise<ClassifierResult> {
  const t = (text || "").trim().slice(0, MAX_CHARS);
  if (!t) return { label: "benign", score: 0 };
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), SAFETY_CLASSIFIER_TIMEOUT_MS);
  try {
    const res = await fetchImpl(SAFETY_CLASSIFIER_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text: t }),
      signal: ctl.signal,
    });
    if (!res.ok) return { label: "unavailable", score: null };
    const body = (await res.json()) as { label?: unknown; score?: unknown };
    const label = body?.label;
    const score = typeof body?.score === "number" && body.score >= 0 && body.score <= 1 ? body.score : null;
    if ((label === "benign" || label === "injection" || label === "jailbreak") && score !== null) return { label, score };
    return { label: "unavailable", score: null };
  } catch {
    return { label: "unavailable", score: null };
  } finally {
    clearTimeout(timer);
  }
}

export function classifierBlocksOutbound(r: ClassifierResult): boolean {
  return (r.label === "injection" || r.label === "jailbreak") && (r.score ?? 0) >= OUTBOUND_BLOCK_SCORE;
}
