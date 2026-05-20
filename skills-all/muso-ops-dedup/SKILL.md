---
name: muso-ops-dedup
description: |
  Profile-duplicate detection and dedup-sweep operations for Muso ops. Wraps
  the read-only detector CLI (`scripts/dedup/find-dupes.sh`) plus three
  read-only-by-default sweeps (close stale ClickUp tickets, notify untold
  customers, scan catalog for proactive same-name clusters).

  Use when: someone asks "find duplicates", "is this a dupe", "are these
  two the same", "check ClickUp for already-merged tickets", "notify the
  customers we merged", "scan the catalog for dupes", "any new dupes
  today?", or when a profile-merge action-request lands in the queue.

  Triggers: "find duplicates", "find dupes", "dedup", "duplicate profiles",
  "is X the same as Y", "merge-request tickets", "stale merge tickets",
  "already merged", "untold customers", "scan dupes", "name clusters".

  Does NOT execute the merge itself — hands off to muso-ops-profiles once
  a hard_dupe candidate is confirmed.
depends-on:
  - muso-ops-profiles
  - muso-ops-admin
compatibility: |
  Requires: muso-ops-admin (for the post-detect merge handoff), Trino access
  via /opt/hydra/scripts/trino-query.sh, ClickUp + Intercom tokens in
  gateway env (CLICKUP_API_KEY, MUSOAI_INTERCOM_TOKEN).
metadata:
  version: "0.1"
  source-repo: "Muso-AI/hydra"
  verified-against: "scripts/dedup/ (PR #297, 2026-05-20)"
  backtest: "20.2% hard_dupe+candidate_dupe + 17.8% soft_partial recall over 258 real merges (90d)"
---

# Muso Ops — Profile Dedup

Detection + sweep workflow. **Read-only by default.** Any `--apply` call goes
through the standard ops-admin audit log; Jan is on the
`tier2-godmode-allowlist`, so no separate Aaron approval is required for
the sweeps below.

## Access Control

- Tier 1-2: All detection + all sweeps (`--apply` included).
- Tier 3: Detection only. No `--apply` writes.
- Tier 4: Read-only (detection dry-runs and `--catalog` scans).

## Mode selector

Pick the right CLI for the user's intent before running anything:

| User says… | Use mode | Cost |
|---|---|---|
| "find duplicates for [email]" / "this customer says they have dupes" | `--email <addr>` | seconds |
| "is [uuid] a dupe of anything?" / "find dupes for this profile" | `--profile <uuid>` | seconds |
| "find dupes by name" / "the ticket only mentions a name, no UUIDs" | `--name "<name>"` | seconds |
| "are [a] and [b] the same?" / "score this pair" | `--pair <a> <b>` | seconds |
| "scan the catalog for new dupes" / "any new same-name clusters?" | `sweeps/scan-name-clusters.sh` | minutes |
| "check ClickUp for already-merged tickets" / "close stale merge tickets" | `sweeps/close-merged-tickets.sh` | minutes |
| "notify the customers we merged" / "any untold customers?" | `sweeps/notify-merged-customers.py` | seconds-per-ticket |

All commands assume `cd /opt/hydra` on the gateway host. See PR #297 README
(`scripts/dedup/README.md`) for the full algorithm spec and the 2026-05-20
verification findings.

## Workflows

### Find dupes for a customer (by email)

Use when a customer reports "I have duplicate profiles" or filed a
profile-merge ticket. Returns hard/candidate-dupe pairs across all profiles
they've claimed.

```bash
bash /opt/hydra/scripts/dedup/find-dupes.sh --email <customer@example.com>
```

**Output:** JSONL on stdout, one detected pair per line. Each line is the
verdict object (`profile_a`, `profile_b`, `verdict`, `hard_signals`,
`soft_signals`) plus `detected_via: "email"`.

**Common results:**
- `no claimed profiles for <addr>` on stderr → the customer's email isn't
  attached to any profile claim. Ask the customer to confirm the email
  matches their Muso login.
- `profile <uuid> has no profile-level external identifiers; no hard match
  possible` → the customer has profiles but they share no Spotify/Tidal/
  Apple IDs across the catalog. **This is the Ali Zain pattern** — likely
  ID-less dupe; fall through to `--name` mode.

### Find dupes for a specific profile (by UUID)

Use when investigating a single Muso profile UUID — usually because a
ticket or admin-UI screen mentions one specifically.

```bash
bash /opt/hydra/scripts/dedup/find-dupes.sh --profile <uuid>
```

Walks the profile's external `raw_profile_ids` to find sibling profiles
sharing any of them, then pair-scores each sibling against the target.

### Find dupes by name (prose-only ticket pattern)

Use when the ticket says "merge profiles for John Smith" but no UUIDs
extracted. Resolves the name to candidate UUIDs via
`matvw_catalog_profile`, then pair-scores against the highest-credit
anchor (or against an explicit `--anchor <uuid>` if you know which one is
correct).

```bash
bash /opt/hydra/scripts/dedup/find-dupes.sh --name "John Smith" --limit 20
# or with an explicit anchor:
bash /opt/hydra/scripts/dedup/find-dupes.sh --name "John Smith" --anchor <uuid> --limit 20
```

**Empire-style caveat:** if the name resolves to many profiles (common
names like "Jay", "Alex", "Empire"), the output may include legitimate
different humans sharing a name. Eyeball the cluster size before trusting
verdicts; cross-reference with `sweeps/scan-name-clusters.sh --max-cluster-size 50`.

### Compare two specific profiles

Use when someone hands you two UUIDs ("are these two the same?") or when
a structured ticket lists `customer_profile_id` + `duplicate_profile_urls`.

```bash
bash /opt/hydra/scripts/dedup/find-dupes.sh --pair <uuid_a> <uuid_b>
```

Emits a single verdict line. Read it back to the requester before
proposing a merge.

### Scan the catalog for proactive same-name dupes

Use when there's no specific ticket — Jan wants to "find new dupes
nobody has filed yet". Walks the top-N name buckets (cluster size DESC)
and scores within each.

```bash
bash /opt/hydra/scripts/dedup/sweeps/scan-name-clusters.sh \
  --top-n 200 --max-cluster-size 50 --limit-per-cluster 50
```

**Pre-checklist:**

1. Start with `--max-cluster-size 50` to skip Empire-style mass-pseudonym
   buckets (e.g. "Jay" has 2512 profiles — pair-explosion + mostly distinct
   humans).
2. Walk output by `verdict: hard_dupe` first; those are the safe
   cluster-size-2 candidates.
3. For `candidate_dupe`, eyeball the name + credit counts before
   escalating to merge.

### Close stale ClickUp profile-merge tickets

Use when Jan says "check ClickUp for tickets that are already merged"
or "clean up the merge-request queue". Finds open ClickUp profile-merge
tickets whose merge already executed (per `action_log`) and closes them.

**Dry-run first** (always):
```bash
bash /opt/hydra/scripts/dedup/sweeps/close-merged-tickets.sh
```

Reports each match with `customer_profile_id`, `merge_at`, and the
customer-reply audit result (`safe_to_close` vs `needs_human_reply`).

**Apply** (Jan godmode, no separate approval gate needed):
```bash
bash /opt/hydra/scripts/dedup/sweeps/close-merged-tickets.sh --apply
```

Each `safe_to_close` ticket gets a closure comment + `status="resolved"`,
and Nick is auto-assigned for audit traceability. Each `needs_human_reply`
ticket is LEFT OPEN — see next workflow for how to handle.

**Tune look-back window** (default 90 days):
```bash
bash /opt/hydra/scripts/dedup/sweeps/close-merged-tickets.sh --days 30 --apply
```

### Notify customers whose merges were never told

After `close-merged-tickets.sh` flags tickets as `needs_human_reply`, this
sweep posts a templated reply in Intercom and closes the ticket. Pipe
ticket IDs from the previous sweep, or pass them by hand.

**Dry-run first** (proposes messages as JSONL on stdout, no writes):
```bash
printf "869dadcrq\n869daak39\n" \
  | python3 /opt/hydra/scripts/dedup/sweeps/notify-merged-customers.py
```

**Apply** (writes to Intercom + closes the ClickUp ticket):
```bash
printf "869dadcrq\n" \
  | python3 /opt/hydra/scripts/dedup/sweeps/notify-merged-customers.py --apply
```

**Pre-checklist:**

1. `INTERCOM_ADMIN_ID` must be set in env — there's no default. Pick the
   admin you want the customer to see (founder voice = aaron's admin id).
2. Per-conv dedup is automatic: if two tickets resolve to the same
   Intercom conversation, only the first triggers a reply.
3. Customers whose email isn't in Intercom get a `skip: no Intercom conv`
   in dry-run output — those need manual ops, not this sweep.

## Verdict interpretation

Detector output verdicts and what each means in practice (calibrated by
the 2026-05-20 backtest over 258 real human merges):

| Verdict | What it means | Action |
|---|---|---|
| `hard_dupe` | Shared `raw_profile_id` (non-Muso) or shared IPI. ~20% of confirmed dupes hit this in the backtest, but Empire-style false positives exist when one external ID points at many real humans. | Eyeball the cluster size + claim state. If cluster-size==2, no claim conflict → propose merge via muso-ops-profiles. |
| `candidate_dupe` | `name_lev ≤ 2` AND `claim_state != both_claimed_different_users` AND `(shared_tracks ≥ 3 OR (min_cc ≤ 2 AND max_cc ≥ 5))`. This is the thin-stub-against-anchor pattern. The claim-state filter prevents proposing merges across two different users' claimed profiles. | Show side-by-side to requester; usually safe to merge after confirming. |
| `soft_partial` (backtest-only) | `name_lev ≤ 2` but no credit asymmetry and no shared-tracks signal. ~18% of real merges sit here — would catch if `shared_tracks ≥ 3` becomes a hard signal upgrade. | The CLI does NOT emit this label today; backtest only. Customers in this bucket → ask for evidence (specific shared track titles, e.g.). |
| `no_match` | Different names entirely. ~62% of real merges (stage-name ↔ legal-name, e.g. AJJ2Clip ↔ Joseph Turner). | Detector is structurally blind here. Need customer testimony or cross-name fuzzy. Fall through to `--name` mode or ask the customer to confirm. |

## Escalating to muso-ops-profiles for the actual merge

Once detection confirms a `hard_dupe` and the safety checks pass, hand off
to the merge primitive in `muso-ops-profiles`. **This skill does not
implement merge itself.**

Pre-handoff checks (refuse to escalate if ANY fail):

1. **Cluster size == 2.** Multi-profile clusters (Empire) require human
   triage per Spec §11.
2. **Claim state is NOT `both_claimed_different_users`.** The merge endpoint
   has a known bug that silently transfers a claim when exactly one side
   is claimed (incident 2026-04-29). Refuse the merge regardless of
   verdict if both sides are claimed by different users.
3. **Cross-language / cross-Jaxsta-ID gotcha checked.** The 2026-05-20
   precision audit found one HIGH-FP `hard_dupe` where two real artists
   shared a Jaxsta ID across language editions (Maui ES vs PT-BR). If the
   two profiles have detectably different track sets / countries / labels,
   escalate to human, not to merge.

If checks pass, point the operator at `muso-ops-profiles.### Merge Profiles`
with the survivor/loser pair already chosen.

## Safety guardrails

- **All detection modes are read-only** — they query Trino + the admin
  GET endpoints. No writes happen during detection.
- **Sweeps are dry-run by default.** `--apply` is the explicit trigger.
- **Empire-style clusters (size > 50) are skipped server-side** by
  `scan-name-clusters.sh` (commit `7df6444`). Do not lower
  `--max-cluster-size` above 50 without manually eyeballing the cluster.
- **`notify-merged-customers.py` is the only customer-facing write in
  this skill.** Three guardrails: dry-run default, `INTERCOM_ADMIN_ID`
  required, per-conv dedup.
- **Catalog mode (`--catalog`) emits `hard_dupe` rows only.** Use it for
  bulk scans; do not auto-merge from its output without per-cluster
  human triage.

## Shadow log (precision data collection)

Every detection run appends a one-line JSON record to
`/var/log/dedup-shadow.jsonl` (path overridable via `DEDUP_SHADOW_LOG`).
Fields: `ts, profile_a, profile_b, verdict, hard_signals, soft_signals`.
The record is written next to the JSONL stdout emit, with no observable
change in CLI behaviour. Mode (the `--profile`/`--catalog`/etc. entry
point) is intentionally NOT in the shadow record — the post-hoc precision
analysis treats every verdict the detector produced as one observation
regardless of how it was surfaced.

This data is the precision-on-live-queue signal the `recall.py` backtest
structurally can't measure: every verdict the agent surfaces, alongside
whether Jan ultimately approved a merge for it or not. After ~2 weeks
of real traffic, the log feeds a confusion-matrix analysis (separate
PR).

If `$DEDUP_SHADOW_LOG` is unwritable, the shim silently no-ops — never
breaks the CLI.
