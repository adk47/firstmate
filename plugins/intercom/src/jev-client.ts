/**
 * One-shot HTTP client for TypeSafe's System One ("Jev") typed-judgment model,
 * called via OpenRouter's decisions endpoint. Mirrors scripts/lib/jev.sh's wire
 * contract exactly (same URL, same {state, model, questions} body, same
 * "answers" extraction), but as a TypeScript function so it can be called
 * in-process from the plugin's hot dispatch path instead of shelling out.
 *
 * Never throws — every failure mode (timeout, non-2xx, missing/malformed
 * `.answers`, network error) resolves to a `{ok: false, reason, ...}` result
 * (never null — the caller needs `reason`/`httpStatus` to log a failure
 * shadow row, jev.sh-shape) and logs exactly one
 * `[intercom:jev] rc=fail reason=<token>` warn line, per
 * docs/designs/2026-09-22-jev-caroline-router.md §B.
 */

const JEV_API_URL = "https://openrouter.ai/api/alpha/decisions";

// Matches docs/plans/jev-adoption.md's default; overridable per-account via
// config.ts's `jev.model`.
export const DEFAULT_JEV_MODEL = "typesafe/jev-1.13";
export const DEFAULT_JEV_TIMEOUT_MS = 1500;

export interface CallJevInput {
  apiKey: string;
  model?: string;
  timeoutMs?: number;
  state: Record<string, unknown>;
  questions: Record<string, unknown>;
  fetchImpl?: typeof fetch;
  log?: { warn: (msg: string) => void };
}

export interface CallJevSuccess {
  ok: true;
  answers: Record<string, unknown>;
  usage: unknown;
  model: string;
  latencyMs: number;
  httpStatus: number;
}

export interface CallJevFailure {
  ok: false;
  // "timeout" | "network" | `http_${status}` | "shape"
  reason: string;
  httpStatus: number | null;
  latencyMs: number;
}

export type CallJevResult = CallJevSuccess | CallJevFailure;

// --- nested answer-shape validation (QA finding 2, 2026-09-22 PR #999) ---
//
// The endpoint is alpha: a 200 response can carry a well-formed top-level
// `{answers: {...}}` envelope (the only thing validated below, historically)
// while a NESTED field inside one answer is malformed — e.g. `confidence` as
// a string, `probabilities` as a non-object, or a missing `choice`. Those
// values used to reach jev-router.ts's render/log path unchecked and THROW
// there (`.toFixed` on a non-number, `in` on a non-object), aborting a real
// customer's turn instead of taking the documented fail-soft path. Every
// answer is validated per its declared `type` before `callJev` ever returns
// `ok: true`; any mismatch returns the same `{ok: false, reason: "shape"}`
// shape the top-level check already used, so the turn takes the unchanged
// dispatch path and a failure shadow row (rc 3) is written — no new failure
// mode for callers to handle.
//
// `probabilities`/`confidence`/`legend` are optional on every answer type
// (mirrors JevAnswerChoice/JevAnswerScore in jev-router.ts, and the existing
// "choice with no probabilities" fixture in jev-client.test.ts) — validated
// for shape only WHEN present, never required.
function isPlainObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function isUnitProb(v: unknown): v is number {
  return typeof v === "number" && Number.isFinite(v) && v >= 0 && v <= 1;
}

function isValidProbabilities(v: unknown): v is Record<string, number> {
  return isPlainObject(v) && Object.values(v).every(isUnitProb);
}

// --- question-driven SET validation (QA finding 3, 2026-09-22 PR #999) ---
//
// Validating each answer in isolation left the SET of answers unchecked:
// `Object.values({}).every(...)` is vacuously true and the prior top-level
// check didn't reject arrays, so `answers: {}`/`answers: []` returned
// `ok: true` and the handler stored a route block with no real decision. A
// partial map (some questions unanswered) and an answer whose `type` doesn't
// match its question's declared `type` also incorrectly passed. `questions`
// is already part of `CallJevInput`, so validation is driven off it: every
// question key must be present in `answers`, and each answer is checked
// against its OWN question's declared `type`/`criteria` rather than in a
// vacuum. Extra `answers` keys not present in `questions` are ignored, not
// rejected — jev-router.ts's `decide()`/renderers only ever read the small
// fixed set of keys the question set defines, so rejecting unconsumed extras
// would add fragility without protecting anything actually read.
function choiceCriteriaKeys(question: Record<string, unknown>): Set<string> | null {
  const criteria = question.criteria;
  if (Array.isArray(criteria)) return null; // score-shaped criteria; not a choice question
  if (isPlainObject(criteria)) return new Set(Object.keys(criteria));
  return null; // no declared criteria — nothing to validate `choice` against
}

// Score questions declare their range either as an array of labels
// (`criteria: ["Calm", "Concerned", ...]`, index-keyed) or as an object
// legend (`criteria: {"0": "low", ...}`, key-keyed). Returns the set of
// valid string keys for `legend`/`probabilities` entries, or null when the
// question declares no range to check against.
function scoreCriteriaKeys(question: Record<string, unknown>): Set<string> | null {
  const criteria = question.criteria;
  if (Array.isArray(criteria)) {
    return new Set(criteria.map((_, i) => String(i)));
  }
  if (isPlainObject(criteria)) return new Set(Object.keys(criteria));
  return null;
}

function isValidJevAnswer(a: unknown, question: Record<string, unknown>): boolean {
  if (!isPlainObject(a)) return false;
  if (a.type !== question.type) return false;
  switch (a.type) {
    case "noul":
      return isUnitProb(a.noul);
    case "choice": {
      if (typeof a.choice !== "string" || a.choice.length === 0) return false;
      const validKeys = choiceCriteriaKeys(question);
      if (validKeys && !validKeys.has(a.choice)) return false;
      if (a.probabilities !== undefined) {
        if (!isValidProbabilities(a.probabilities)) return false;
        if (!(a.choice in a.probabilities)) return false;
        if (validKeys && !Object.keys(a.probabilities).every((k) => validKeys.has(k))) return false;
      }
      if (a.confidence !== undefined && !isUnitProb(a.confidence)) return false;
      return true;
    }
    case "score": {
      if (typeof a.score !== "number" || !Number.isFinite(a.score)) return false;
      const validKeys = scoreCriteriaKeys(question);
      // A Score is a probability-weighted POSITION across the ordered levels
      // (TypeSafe docs), so it is continuous: 0.04 for a mildly uncertain
      // "Calm", 2.12 for "mostly Frustrated, some Angry". It is NOT a level
      // key. Requiring String(score) to be a key rejected every answer that
      // was not perfectly certain -- in production, 106 of 125 Caroline turns
      // on 2026-09-23 (reason=shape), disproportionately the frustrated
      // customers, which silently dropped their routing block. Validate the
      // RANGE instead: within [0, highest level index].
      if (validKeys) {
        const levels = [...validKeys].map(Number).filter((n) => Number.isFinite(n));
        if (levels.length > 0) {
          const min = Math.min(...levels), max = Math.max(...levels);
          if (a.score < min || a.score > max) return false;
        }
      }
      if (a.legend !== undefined) {
        if (!isPlainObject(a.legend)) return false;
        if (validKeys && !Object.keys(a.legend).every((k) => validKeys.has(k))) return false;
      }
      if (a.probabilities !== undefined) {
        if (!isValidProbabilities(a.probabilities)) return false;
        if (validKeys && !Object.keys(a.probabilities).every((k) => validKeys.has(k))) return false;
      }
      if (a.confidence !== undefined && !isUnitProb(a.confidence)) return false;
      return true;
    }
    default:
      // Unknown/missing `type` — reject rather than guess.
      return false;
  }
}

function isValidAnswers(answers: unknown, questions: Record<string, unknown>): answers is Record<string, unknown> {
  if (!isPlainObject(answers)) return false; // rejects arrays too (isPlainObject excludes them)
  return Object.entries(questions).every(([key, question]) => {
    if (!isPlainObject(question)) return false;
    // A missing key reads as `undefined`, which isValidJevAnswer already
    // rejects via isPlainObject — no separate `key in answers` check needed;
    // every asked question is answered as a side effect of that same guard.
    return isValidJevAnswer(answers[key], question);
  });
}

export async function callJev(input: CallJevInput): Promise<CallJevResult> {
  const model = input.model ?? DEFAULT_JEV_MODEL;
  const timeoutMs = input.timeoutMs ?? DEFAULT_JEV_TIMEOUT_MS;
  const fetchFn = input.fetchImpl ?? fetch;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  const start = Date.now();
  // Set exactly once, on the branch that decided to bail; logged in `finally`
  // so every early return (including the try/catch's own) still warns once.
  let reason: string | null = null;
  let failureHttpStatus: number | null = null;

  try {
    const resp = await fetchFn(JEV_API_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${input.apiKey}`,
      },
      body: JSON.stringify({ model, state: input.state, questions: input.questions }),
      signal: controller.signal,
    });

    if (!resp.ok) {
      reason = `http_${resp.status}`;
      failureHttpStatus = resp.status;
      return { ok: false, reason, httpStatus: failureHttpStatus, latencyMs: Date.now() - start };
    }

    const body: unknown = await resp.json().catch(() => null);
    const answers = (body as { answers?: unknown } | null)?.answers;
    if (
      typeof body !== "object" ||
      body === null ||
      !isValidAnswers(answers, input.questions)
    ) {
      reason = "shape";
      failureHttpStatus = resp.status;
      return { ok: false, reason, httpStatus: failureHttpStatus, latencyMs: Date.now() - start };
    }

    const b = body as { answers: Record<string, unknown>; usage?: unknown; model?: string };
    return {
      ok: true,
      answers: b.answers,
      usage: b.usage ?? null,
      model: typeof b.model === "string" ? b.model : model,
      latencyMs: Date.now() - start,
      httpStatus: resp.status,
    };
  } catch {
    // AbortController.abort() from the timeout is the only source of an
    // aborted signal here — any other throw (DNS, connection refused, etc.)
    // is a plain network failure.
    reason = controller.signal.aborted ? "timeout" : "network";
    return { ok: false, reason, httpStatus: null, latencyMs: Date.now() - start };
  } finally {
    clearTimeout(timer);
    if (reason) {
      input.log?.warn(`[intercom:jev] rc=fail reason=${reason}`);
    }
  }
}
