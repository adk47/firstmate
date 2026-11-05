/**
 * ops-intake — the `operations` Slack account's ask router.
 *
 * WHAT THIS PLUGIN IS NOT: an agent. It never composes a answer with a model, it
 * never judges a credit, it never hides a profile. It is the transport that gets
 * a Slack message and its ENVELOPE identity to
 * `scripts/ops_intake/router.py`, and it decides - synchronously, in
 * microseconds, from classification alone - whether the agent turn should see
 * the message at all.
 *
 * WHY A PLUGIN HOOK AND NOT A PROMPT (firstmate spec j2 item 1): before this
 * existed, every Jan ask was a free-form agent turn with root exec. The 14-day
 * census found 301 such asks, >= 24 replies claiming "queued for FirstMate"
 * behind no queue, 15 profile hides through `DELETE /admin/profile`, and verdicts
 * attributed to Firstmate that the Ops/QA agent's own model had produced. A
 * instruction in SOUL.md cannot fix that: the model is the thing being
 * constrained. `inbound_claim` runs BEFORE dispatch, so a claimed message never
 * becomes an agent turn.
 *
 * TWO PHASES, deliberately:
 *
 *   1. `router.py claim` (spawnSync, 8s budget) - classify + write the ask row.
 *      No network, no model. Returns whether this message is ours.
 *   2. `router.py intake` (detached child, `unref`'d) - the coded answerer, the
 *      fraud lens, the W1 ledger plan and the thread reply. Runs off the hook, so
 *      a slow Trino read cannot stall the gateway's inbound path.
 *
 * A row exists after phase 1 even if phase 2 dies, which is what makes the
 * watcher able to chase it. That is the whole difference from "queued".
 *
 * FAIL CLOSED: if the router cannot be reached, times out, or returns garbage,
 * the plugin CLAIMS the message and posts `routerUnavailableReply` - nothing
 * done, human path named - rather than letting an agent turn take it. Silence
 * would let the agent judge a credit, which is the exact failure this replaces.
 * The same holds for a message the router refuses to key (`no-ts`): it cannot
 * become an ask row, so the plugin claims it and posts `unkeyableReply`.
 *
 * Identity is `ctx.senderId` only (see envelope.ts).
 */
import { spawn, spawnSync } from "node:child_process";
import path from "node:path";

import { definePluginEntry, type OpenClawPluginApi } from "openclaw/plugin-sdk/plugin-entry";

import {
  DEFAULT_CONFIG,
  buildPayload,
  channelAllowed,
  routerUnavailableReply,
  unkeyableReply,
  type InboundClaimContext,
  type InboundClaimEvent,
  type PluginConfig,
  type RouterPayload,
} from "./envelope.js";

const DEFAULT_ROUTER = "/opt/hydra/scripts/ops_intake/router.py";
const CLAIM_TIMEOUT_MS = 8_000;
const SLACK_API = "https://slack.com/api/chat.postMessage";
const OPERATIONS_TOKEN_ENV = "MUSO_SLACK_BOT_TOKEN_OPERATIONS";

export interface ResolvedConfig extends PluginConfig {
  routerScript: string;
  pythonBin: string;
  /** Slack channel allowlist mirrored from policies/ops-intake-actions.json.
   *  The Python side enforces the policy file; this copy only decides whether the
   *  claim fast-path is worth a subprocess. */
  channels: string[];
}

export function resolveConfig(raw: Record<string, unknown> = {}): ResolvedConfig {
  const channels = Array.isArray(raw.channels)
    ? (raw.channels as unknown[]).filter((c): c is string => typeof c === "string")
    : ["C0APB2CMM7C"];
  return {
    ...DEFAULT_CONFIG,
    account: typeof raw.account === "string" ? raw.account : DEFAULT_CONFIG.account,
    allowDirectMessages:
      typeof raw.allowDirectMessages === "boolean"
        ? raw.allowDirectMessages
        : DEFAULT_CONFIG.allowDirectMessages,
    routerScript:
      typeof raw.routerScript === "string"
        ? raw.routerScript
        : process.env.OPS_INTAKE_ROUTER || DEFAULT_ROUTER,
    pythonBin: typeof raw.pythonBin === "string" ? raw.pythonBin : "python3",
    channels,
  };
}

export interface ClaimResult {
  claimed: boolean;
  ask_id?: string | null;
  state?: string;
  class?: string | null;
  /** Why the router declined to claim it (e.g. "no-ts"). */
  skip_reason?: string | null;
  /** A page the router could not send from the claim fast path (network). */
  page?: string | null;
}

/** Parse the router's stdout. Anything unexpected is a claim failure, never a
 *  silent "not ours". */
export function parseClaim(stdout: string): ClaimResult | null {
  const line = stdout.trim().split("\n").filter(Boolean).pop();
  if (!line) return null;
  try {
    const parsed = JSON.parse(line) as Record<string, unknown>;
    if (typeof parsed.claimed !== "boolean") return null;
    return {
      claimed: parsed.claimed,
      ask_id: typeof parsed.ask_id === "string" ? parsed.ask_id : null,
      state: typeof parsed.state === "string" ? parsed.state : undefined,
      class: typeof parsed.class === "string" ? parsed.class : null,
      skip_reason: typeof parsed.skip_reason === "string" ? parsed.skip_reason : null,
      page: typeof parsed.page === "string" ? parsed.page : null,
    };
  } catch {
    return null;
  }
}

function routerEnv(config: ResolvedConfig): NodeJS.ProcessEnv {
  return {
    ...process.env,
    OPS_INTAKE_ROUTER: config.routerScript,
    PATH: process.env.PATH || "/usr/local/bin:/usr/bin:/bin",
  };
}

export function runClaim(
  payload: RouterPayload,
  config: ResolvedConfig,
  spawnSyncImpl: typeof spawnSync = spawnSync,
): ClaimResult | null {
  const result = spawnSyncImpl(config.pythonBin, [config.routerScript, "claim"], {
    input: JSON.stringify(payload),
    encoding: "utf8",
    timeout: CLAIM_TIMEOUT_MS,
    env: routerEnv(config),
    maxBuffer: 1024 * 1024,
  });
  if (result.error || result.status !== 0) {
    console.error(
      `[ops-intake] claim failed (status=${String(result.status)} error=${String(
        result.error ?? "",
      )}): ${String(result.stderr ?? "").slice(0, 400)}`,
    );
    return null;
  }
  return parseClaim(String(result.stdout ?? ""));
}

export function startIntake(
  payload: RouterPayload,
  config: ResolvedConfig,
  spawnImpl: typeof spawn = spawn,
): void {
  try {
    const child = spawnImpl(config.pythonBin, [config.routerScript, "intake"], {
      detached: true,
      stdio: ["pipe", "ignore", "ignore"],
      env: routerEnv(config),
    });
    child.on?.("error", (err: Error) => {
      console.error(`[ops-intake] intake spawn error: ${String(err)}`);
    });
    child.stdin?.end(JSON.stringify(payload));
    child.unref?.();
  } catch (err) {
    console.error(`[ops-intake] intake spawn threw: ${String(err)}`);
  }
}

/** Page #clio_devops about a router outage, detached (the router owns the devops
 *  bot; the plugin only holds the operations token). Deduped by the router. */
export function startUnavailablePage(
  payload: RouterPayload,
  config: ResolvedConfig,
  spawnImpl: typeof spawn = spawn,
): void {
  try {
    const child = spawnImpl(config.pythonBin, [config.routerScript, "page-unavailable"], {
      detached: true,
      stdio: ["pipe", "ignore", "ignore"],
      env: routerEnv(config),
    });
    child.on?.("error", (err: Error) => {
      console.error(`[ops-intake] unavailable-page spawn error: ${String(err)}`);
    });
    child.stdin?.end(JSON.stringify(payload));
    child.unref?.();
  } catch (err) {
    console.error(`[ops-intake] unavailable-page spawn threw: ${String(err)}`);
  }
}

/** Post a fail-closed line into the ask's thread. Best effort: a failed post
 *  must not throw into the hook (the message is already claimed, so nothing else
 *  will answer it). */
export async function postThreadReply(
  payload: RouterPayload,
  text: string,
  fetchImpl: typeof fetch = fetch,
): Promise<boolean> {
  const token = process.env[OPERATIONS_TOKEN_ENV];
  if (!token) {
    console.error("[ops-intake] no operations token; cannot post fail-closed reply");
    return false;
  }
  // Slack rejects `thread_ts: ""` (a supplied parent must be a real message ts),
  // and a message that could not be keyed has neither a thread nor a ts. Omit
  // the field entirely in that case so the refusal is still posted, at the
  // channel root, where a human will see it.
  const threadTs = (payload.thread_ts ?? payload.ts)?.trim();
  const body: Record<string, unknown> = {
    channel: payload.channel,
    text,
    unfurl_links: false,
  };
  if (threadTs) body.thread_ts = threadTs;
  try {
    const res = await fetchImpl(SLACK_API, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json; charset=utf-8",
      },
      body: JSON.stringify(body),
    });
    const result = (await res.json()) as { ok?: boolean; error?: string };
    if (!result.ok) {
      console.error(`[ops-intake] fail-closed post rejected: ${String(result.error)}`);
      return false;
    }
    return true;
  } catch (err) {
    console.error(`[ops-intake] fail-closed post failed: ${String(err)}`);
    return false;
  }
}

export function postRouterUnavailable(
  payload: RouterPayload,
  detail: string,
  fetchImpl: typeof fetch = fetch,
): Promise<boolean> {
  return postThreadReply(payload, routerUnavailableReply(detail), fetchImpl);
}

/** The no-ts fail-closed line: the message cannot be keyed, so no ask row exists
 *  and nothing was done. */
export function postUnkeyable(
  payload: RouterPayload,
  fetchImpl: typeof fetch = fetch,
): Promise<boolean> {
  return postThreadReply(payload, unkeyableReply(), fetchImpl);
}

export type HookResult = { handled: boolean } | undefined;

export function startPage(
  payload: RouterPayload,
  config: ResolvedConfig,
  spawnImpl: typeof spawn = spawn,
): void {
  try {
    const child = spawnImpl(config.pythonBin, [config.routerScript, "page"], {
      detached: true,
      stdio: ["pipe", "ignore", "ignore"],
      env: routerEnv(config),
    });
    child.on?.("error", (err: Error) => {
      console.error(`[ops-intake] page spawn error: ${String(err)}`);
    });
    child.stdin?.end(JSON.stringify(payload));
    child.unref?.();
  } catch (err) {
    console.error(`[ops-intake] page spawn threw: ${String(err)}`);
  }
}

export function handleInbound(
  event: InboundClaimEvent,
  ctx: InboundClaimContext,
  config: ResolvedConfig,
  deps: {
    claim?: typeof runClaim;
    intake?: typeof startIntake;
    page?: typeof startPage;
    pageUnavailable?: typeof startUnavailablePage;
    postUnavailable?: typeof postRouterUnavailable;
    postUnkeyable?: typeof postUnkeyable;
  } = {},
): HookResult {
  const { payload } = buildPayload(event, ctx, config);
  if (!payload) return undefined;
  // ONE definition of the allowlist rule, the same one the tests exercise.
  if (!channelAllowed(payload, config.channels, config.allowDirectMessages)) return undefined;

  const claim = (deps.claim ?? runClaim)(payload, config);
  if (claim === null) {
    // Router down: claim it so no agent turn can judge a credit, say so in the
    // thread, and page the on-call (the router dedupes the page per window).
    void (deps.postUnavailable ?? postRouterUnavailable)(
      payload,
      "router did not answer claim",
    );
    (deps.pageUnavailable ?? startUnavailablePage)(payload, config);
    return { handled: true };
  }
  if (!claim.claimed) {
    // The claim path is network-free, so a page it owes is spawned detached here.
    if (claim.page) (deps.page ?? startPage)(payload, config);
    if (claim.skip_reason === "no-ts") {
      // No stable ts means no ask row, so the coded router cannot answer it - but
      // it must not fall through to an agent turn either. Claim it, say nothing
      // was done, and page (the page child above).
      void (deps.postUnkeyable ?? postUnkeyable)(payload);
      return { handled: true };
    }
    // `other` class: the agent turn gets it, but the ask row already exists.
    return undefined;
  }
  (deps.intake ?? startIntake)(payload, config);
  return { handled: true };
}

export default definePluginEntry({
  id: "ops-intake",
  name: "Ops Intake Router",
  description:
    "Routes asks on the operations Slack account to coded answerers in scripts/ops_intake before any agent turn sees them.",
  register(api: OpenClawPluginApi) {
    const config = resolveConfig(api.pluginConfig ?? {});
    api.on(
      "inbound_claim",
      (event, ctx) => {
        try {
          return handleInbound(event, ctx, config);
        } catch (err) {
          // Never throw into the hook: an exception here would be an unclaimed
          // message, i.e. an agent turn. Claim + fail-closed instead.
          console.error(`[ops-intake] hook error: ${String(err)}`);
          const built = buildPayload(event, ctx, config);
          if (built.payload) {
            void postRouterUnavailable(built.payload, String(err));
            return { handled: true };
          }
          return undefined;
        }
      },
      { priority: 90 },
    );
  },
});

export { buildPayload, routerUnavailableReply };
export const ROUTER_DEFAULT_SCRIPT = path.resolve(DEFAULT_ROUTER);
