/**
 * The ACTIVE-seat decision for whether a stream figure may leave this process.
 *
 * THE INVARIANT THIS FILE EXISTS TO HOLD: a stream figure leaves this process
 * only for a verified account holding an ACTIVE seat on that exact profile.
 *
 * On 2026-09-30, Caroline handed an unsubscribed contact, Tobi Wikström,
 * another customer's lifetime stream breakdown. `profile-analytics-status.ts`
 * resolved the profile from whatever the customer typed (`profile_id` /
 * `profile_url` / `email` / `name` — all model tool-args) and serialized
 * `lifetime.totals` / `platformTotals` straight to the model with no identity
 * anchor and no entitlement check at all.
 *
 * This module is the fix. It mirrors core-backend's own
 * `verifyUserAnalyticsAccess.js` active_seat rule: entitled iff a workspace
 * the VERIFIED Intercom contact belongs to holds a roster seat for the
 * requested profileId with status ACTIVE — anchored the same way
 * `subscription_status` anchors its lookup (`deriveConvId` -> the trusted
 * Intercom author email, never a model arg). Every unverifiable step fails
 * closed. Gate on the seat, never on a plan-name string — `past_due` tears
 * the seat down, so it falls out of this rule for free.
 *
 * This module makes the decision only — it never calls the analytics
 * endpoint itself. `profile-analytics-status.ts` wires it in before the
 * endpoint read and returns on deny without going further.
 */
import { execFile } from "node:child_process";
import type { IntercomReader } from "./intercom-client.js";
import { deriveConvId } from "./tools/dedupe-check.js";

export type AnalyticsEntitlement =
  | { entitled: true; grant: "active_seat"; workspaceId: string }
  | { entitled: false; reason: AnalyticsDenyReason; routeToHuman: boolean };

export type AnalyticsDenyReason =
  | "owner_undetermined" // no conv id / no intercom token / unreadable author email
  | "account_not_resolved" // email resolved to zero or >1 user, or too many workspaces
  | "profile_not_in_workspace" // no workspace of this user holds a seat for this profile
  | "no_active_seat" // seat exists but status !== ACTIVE (covers past_due)
  | "check_unavailable"; // a CLI/admin read failed

const MAX_CANDIDATE_WORKSPACES = 5;

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

export interface AnalyticsEntitlementDeps {
  profileId: string;
  // Trusted gateway session key (carries the convId); NOT ctx.sessionId.
  sessionKey: string;
  intercomReader: IntercomReader;
  intercomToken: string;
  // muso CLI binary + target env. The gateway PATH does not always include
  // /usr/local/bin, so default to the absolute path; prod is the live env.
  musoBin?: string;
  env?: string;
  execFileImpl?: ExecFileLike;
}

interface UserRow {
  id?: unknown;
  email?: unknown;
}
interface TeamRow {
  id?: unknown;
}
// Shape of `muso teams seats get --json` (teamSeatItem, muso-cli/internal/cli/teams.go:662-672):
// the admin HTTP/CLI projection renames the ORM's seatId/status to id/seatStatus.
// Do NOT mirror verifyUserAnalyticsAccess.js's in-process Sequelize field names here.
interface SeatRow {
  id?: unknown;
  seatStatus?: unknown;
}

function extractRows<T>(parsed: unknown): T[] {
  const p = parsed as Record<string, unknown>;
  if (p && Array.isArray(p.items)) return p.items as T[];
  if (p && Array.isArray(p.data)) return p.data as T[];
  if (Array.isArray(parsed)) return parsed as T[];
  return [];
}

function deny(reason: AnalyticsDenyReason, routeToHuman: boolean, workspaceIds?: string[]): AnalyticsEntitlement {
  // Attribution signal for D2: no email, no customer numbers — reason + the
  // candidate workspace(s), if any were reached before the deny. D2's
  // widening evidence comes from core-backend's own analytics_access_attribution
  // log, not from this deny log (see the CTO's D2 correction on MUS-1469).
  console.warn(
    JSON.stringify({
      event: "analytics_entitlement_denied",
      reason,
      workspaceId: workspaceIds && workspaceIds.length > 0 ? workspaceIds : null,
    }),
  );
  return { entitled: false, reason, routeToHuman };
}

export async function resolveAnalyticsEntitlement(deps: AnalyticsEntitlementDeps): Promise<AnalyticsEntitlement> {
  const { profileId, sessionKey, intercomReader, intercomToken } = deps;
  const musoBin = deps.musoBin ?? process.env.MUSO_CLI_BIN ?? "/usr/local/bin/muso";
  const env = deps.env ?? process.env.MUSO_CLI_ENV ?? "prod";
  const exec = execFileToPromise(deps.execFileImpl ?? (execFile as ExecFileLike));

  // Step 1 — anti-spoof anchor. Never a model tool-arg.
  const convId = deriveConvId(sessionKey);
  if (!convId) return deny("owner_undetermined", true);
  if (!intercomToken) return deny("owner_undetermined", true);

  let verifiedEmail: string | null;
  try {
    verifiedEmail = await intercomReader.getAuthorEmail(convId, intercomToken);
  } catch {
    return deny("check_unavailable", true);
  }
  if (!verifiedEmail) return deny("owner_undetermined", true);

  const runMuso = async (args: readonly string[]): Promise<unknown> => {
    const res = await exec(musoBin, args, { timeout: 30 * 1000, maxBuffer: 4 * 1024 * 1024 });
    if (res.stderr && res.stderr.trim()) {
      console.warn(`[analytics-entitlement] muso stderr: ${res.stderr.trim()}`);
    }
    return JSON.parse(res.stdout.trim());
  };

  // Step 2 — resolve the verified email to exactly one user. `users search`
  // is a server-side SUBSTRING filter, so re-filter to an EXACT
  // case-insensitive match before trusting it.
  let userRows: UserRow[];
  try {
    const parsed = await runMuso(["users", "search", verifiedEmail, "--env", env, "--json"]);
    userRows = extractRows<UserRow>(parsed);
  } catch {
    return deny("check_unavailable", true);
  }
  const want = verifiedEmail.toLowerCase();
  const exactUsers = userRows.filter((r) => typeof r.email === "string" && (r.email as string).toLowerCase() === want);
  if (exactUsers.length !== 1) return deny("account_not_resolved", true);
  const rawUserId = exactUsers[0].id;
  // A row with a matching email but no id is a data anomaly, not a resolved
  // account (D6) — String(undefined) === "undefined" would otherwise sail
  // into --user-id and come back profile_not_in_workspace with no human route.
  if (rawUserId === undefined || rawUserId === null || String(rawUserId).trim() === "") {
    return deny("account_not_resolved", true);
  }
  const userId = String(rawUserId);

  // Step 3 — candidate workspaces: ones the user belongs to AND that hold a
  // roster seat for this exact profile.
  let teamRows: TeamRow[];
  try {
    const parsed = await runMuso(["teams", "list", "--user-id", userId, "--seat-id", profileId, "--env", env, "--json"]);
    teamRows = extractRows<TeamRow>(parsed);
  } catch {
    return deny("check_unavailable", true);
  }
  if (teamRows.length === 0) return deny("profile_not_in_workspace", false);
  if (teamRows.length > MAX_CANDIDATE_WORKSPACES) return deny("account_not_resolved", true);

  // Step 4 — `teams list` proves the seat EXISTS, not its status (the list
  // response omits seats). Fetch seats per candidate and grant on the first
  // ACTIVE match for this profile.
  for (const row of teamRows) {
    const teamId = String(row.id);
    let seatRows: SeatRow[];
    try {
      const parsed = await runMuso(["teams", "seats", "get", teamId, "--env", env, "--json"]);
      seatRows = extractRows<SeatRow>(parsed);
    } catch {
      return deny("check_unavailable", true);
    }
    const activeSeat = seatRows.find(
      (s) => String(s.id) === profileId && String(s.seatStatus ?? "").toUpperCase() === "ACTIVE",
    );
    if (activeSeat) {
      return { entitled: true, grant: "active_seat", workspaceId: teamId };
    }
  }

  // Every candidate workspace holds a seat for this profile, but none is
  // ACTIVE.
  return deny(
    "no_active_seat",
    false,
    teamRows.map((row) => String(row.id)),
  );
}
