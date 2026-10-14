#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

# check-blast-radius.sh — advisory impact analyzer for a PR diff
# =============================================================================
# Answers the question diff size cannot: if this change is wrong, WHAT BREAKS?
# Companion to check-rebase-integrity.sh — same hand-off contract, same failure
# posture, same consumers. It exists because the reviewing agent has NO CLONE
# (skills-all/muso-github-code-review/SKILL.md: the qa workspace is not a git
# repo), so it cannot grep for the callers of a changed script. CI can: this
# runs in pr-validate.yml on the self-hosted node-8 runner at fetch-depth 0,
# and hands the result to the agent through the filesystem — the same host.
#
# Signals (each carries its EVIDENCE — the matching files — never a bare count):
#   gate-edit           an enforcement gate changed (check-/ensure-/validate-,
#                       a Guard block, a CI gate step). Weakening a gate is the
#                       highest-consequence class of change in this repo.
#   credential-surface  secrets/, *.env, codex/oauth/auth-profile paths
#   fleet-config        openclaw-*.json, shared env, cron-jobs.json, policies/
#   cron-reach          the file is invoked by a cron job or a systemd unit
#   state-mutation      the diff ADDS destructive ops against /var/lib or
#                       /opt/hydra (rm/mv/truncate/install) — reversibility risk
#   reverse-callers     other files in the repo reference this script
#   skill-reach         skills-all/ content — propagates to every bound agent
#   test-gap            a changed script has no scripts/tests/<name>.bats
#   deploy-path (info)  which changed files rsync to /opt/hydra. INFORMATIONAL
#                       ONLY — see "why deploy-path never lowers the tier".
#
# TIER = the highest severity that fired. No weighted score: a score invites
# the reader to trust a number, and every signal here is a boolean with
# evidence attached. critical ⇒ CRITICAL, high ⇒ HIGH, medium ⇒ MEDIUM,
# else LOW. gate-edit / credential-surface / fleet-config are critical on their
# own REGARDLESS of diff size — that is the entire point of the exercise.
#
# WHY deploy-path NEVER LOWERS THE TIER: "this file isn't deployed, so it's
# harmless" is the one inference here that fails OPEN, and deriving rsync reach
# from deploy.sh's include/exclude globs is exactly the kind of static
# approximation that misses a path. A wrong downgrade silently suppresses a
# real finding, so the signal is reported as context and never subtracts.
#
# ADVISORY BY DESIGN: signals NEVER exit non-zero — humans (and the QA agent)
# decide. Only an internal analyzer error exits non-zero, and even then the
# state file is written with status=ERROR so a fail-closed consumer can act on
# "blast radius unverified". Run inside a full (non-shallow) clone.
#
# Usage: check-blast-radius.sh <pr-number> <head-sha>
#
# Env:
#   BASE_REF (default main)          REPO (default Muso-AI/hydra, owner/name)
#   BR_SKIP_FETCH=1 (tests: no network)
#   BR_STATE_DIR (default /var/lib/hydra-qa/blast-radius; empty ⇒ no state file
#                 — the machine-readable hand-off to the QA agent)
#   BR_MAX_FILES=400                 degrade cap: skip per-file scans above this
#   BR_CALLERS_HIGH=5                distinct callers at/above which the
#                                    reverse-callers signal is `high`
#
# Exit codes: 0 analysis ran (read the report for the tier)
#             2 usage | 3 internal error (state file has status=ERROR)

BASE_REF="${BASE_REF:-main}"
REPO="${REPO:-Muso-AI/hydra}"
BR_STATE_DIR="${BR_STATE_DIR-/var/lib/hydra-qa/blast-radius}"
BR_MAX_FILES="${BR_MAX_FILES:-400}"
BR_CALLERS_HIGH="${BR_CALLERS_HIGH:-5}"

[ "$#" -eq 2 ] || { echo "usage: check-blast-radius.sh <pr-number> <head-sha>" >&2; exit 2; }
PR="$1"
head_sha="$2"
[[ "$PR" =~ ^[0-9]+$ ]] || { echo "check-blast-radius: pr-number must be numeric, got '$PR'" >&2; exit 2; }
# Full 40-hex only: the state file is KEYED by this value and the consumer looks
# it up by headRefOid. A short sha or a ref name would "succeed" into a file
# nobody ever reads (and a name with '/' would break the path). Same rule, and
# the same reason, as check-rebase-integrity.sh.
[[ "$head_sha" =~ ^[0-9a-f]{40}$ ]] || { echo "check-blast-radius: head-sha must be a full 40-hex oid, got '$head_sha'" >&2; exit 2; }
[[ "$BR_MAX_FILES" =~ ^[0-9]+$ ]] || { echo "check-blast-radius: BR_MAX_FILES must be numeric, got '$BR_MAX_FILES'" >&2; exit 2; }
[[ "$BR_CALLERS_HIGH" =~ ^[0-9]+$ ]] || { echo "check-blast-radius: BR_CALLERS_HIGH must be numeric, got '$BR_CALLERS_HIGH'" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/check-blast-radius.XXXXXX")"
: > "$WORK/signals.ndjson"
: > "$WORK/skipped"
: > "$WORK/severities"

# Generated/vendored paths drown the real signals (a plugin rebuild or lockfile
# churn is legitimate mass change). Same definition of "the code" that
# check-rebase-integrity.sh uses, so the two reports agree on the file set.
EXCLUDES=(
  ':(glob,exclude)**/pnpm-lock.yaml'
  ':(glob,exclude)**/package-lock.json'
  ':(glob,exclude)**/node_modules/**'
  ':(glob,exclude)**/dist/**'
)

note_skip() {
  printf '%s\n' "$1" >> "$WORK/skipped"
  echo "note: skipped — $1"
}

# add_signal <id> <severity> <summary> <evidence-newline-list>
# Built with jq --arg ONLY: paths and match text are PR-author-controlled.
add_signal() {
  jq -cn --arg id "$1" --arg severity "$2" --arg summary "$3" --arg evidence "$4" \
    '{id:$id, severity:$severity, summary:$summary,
      evidence: ($evidence | split("\n") | map(select(length>0)))}' \
    >> "$WORK/signals.ndjson"
  printf '%s\n' "$2" >> "$WORK/severities"
}

# Highest severity wins. Kept as an explicit ladder rather than a numeric score
# so the tier is always traceable to one named signal a reviewer can go read.
compute_tier() {
  if grep -qx 'critical' "$WORK/severities" 2>/dev/null; then echo CRITICAL
  elif grep -qx 'high' "$WORK/severities" 2>/dev/null; then echo HIGH
  elif grep -qx 'medium' "$WORK/severities" 2>/dev/null; then echo MEDIUM
  else echo LOW
  fi
}

# --- state file (the machine hand-off the QA skill / Guard 9 consume) --------
write_state() { # <status>
  [ -n "$BR_STATE_DIR" ] || return 0
  mkdir -p "$BR_STATE_DIR" || return 1
  local out tmp signals_json skipped_json tier
  out="$BR_STATE_DIR/${REPO//\//__}-pr-${PR}-${head_sha}.json"
  tmp="$(mktemp "$BR_STATE_DIR/.br-tmp.XXXXXX")" || return 1
  signals_json="$(jq -cs '.' "$WORK/signals.ndjson" 2>/dev/null || echo '[]')"
  skipped_json="$(jq -cRs 'split("\n") | map(select(length>0))' "$WORK/skipped" 2>/dev/null || echo '[]')"
  tier="$(compute_tier)"
  [ "$1" = "ERROR" ] && tier="UNKNOWN"
  jq -n \
    --arg repo "$REPO" --argjson pr "$PR" --arg head_sha "$head_sha" \
    --arg base_ref "$BASE_REF" --arg merge_base "${merge_base:-}" \
    --arg generated_at "$(date -u +%FT%TZ)" \
    --arg status "$1" --arg tier "$tier" \
    --argjson signals "$signals_json" --argjson skipped "$skipped_json" \
    '{version: 1, repo: $repo, pr: $pr, head_sha: $head_sha, base_ref: $base_ref,
      merge_base: $merge_base, generated_at: $generated_at,
      status: $status, tier: $tier, skipped: $skipped, signals: $signals,
      limitations: [
        "grep cannot prove a negative: a caller reached through a variable, eval, or a built-up path is invisible here.",
        "A reference found is not proof the path executes — dead code appears in the radius.",
        "No runtime side effects, concurrency hazards, or service-to-service contracts are modelled.",
        "deploy-path is informational and never lowers the tier; treat an undeployed file as unproven, not safe."
      ]}' > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$out" || { rm -f "$tmp"; return 1; }
  # keep the state dir bounded — reports are per-head and go stale fast
  find "$BR_STATE_DIR" -maxdepth 1 -name '*.json' -mtime +30 -delete 2>/dev/null || true
}

# Fail-loud reporting: any unexpected failure still writes status=ERROR and
# exits 3. Usage errors exit 2 BEFORE this trap is installed, so no rc is
# exempted here — exempting one would skip the ERROR write exactly when it
# matters most.
ANALYSIS_DONE=0
STAGE="init"
on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "$ANALYSIS_DONE" -ne 1 ]; then
    note_skip "internal error at stage: $STAGE" || true
    write_state ERROR || true
    rm -rf "$WORK"
    exit 3
  fi
  rm -rf "$WORK"
}
trap on_exit EXIT

# --- prologue: refs ----------------------------------------------------------
STAGE="fetch"
if [ "${BR_SKIP_FETCH:-0}" != 1 ]; then
  # The staleness step's `--depth=200` fetch can leave the PERSISTENT runner
  # clone shallow; a shallow repo silently truncates the merge-base walk.
  if [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
    git fetch --unshallow origin --quiet || git fetch origin --quiet || true
  fi
  git fetch origin "$BASE_REF" --quiet
fi

STAGE="resolve-refs"
git rev-parse -q --verify "${head_sha}^{commit}" >/dev/null \
  || { echo "check-blast-radius: cannot resolve head sha '$head_sha'" >&2; exit 3; }
base_tip="$(git rev-parse "origin/${BASE_REF}")"
merge_base="$(git merge-base "$head_sha" "$base_tip")"

# Early fail-closed sentinel: if this process dies in a way the EXIT trap cannot
# catch (SIGKILL/OOM/runner cancel), a status=ERROR file must ALREADY exist —
# otherwise a missing file reads as "no data" and the death looks clean.
# Overwritten with the real status at the end.
write_state ERROR

STAGE="pr-files"
# core.quotepath=false wherever paths are consumed programmatically: the default
# quotes/escapes non-ASCII names, which would make every later match miss them.
git -c core.quotepath=false diff --name-only "$merge_base" "$head_sha" -- "${EXCLUDES[@]}" | sort -u > "$WORK/pr_files"
pr_file_count="$(grep -c . "$WORK/pr_files" || true)"

if [ "$pr_file_count" -eq 0 ]; then
  write_state CLEAN || { note_skip "clean state write failed"; write_state ERROR || true; exit 3; }
  ANALYSIS_DONE=1
  echo "blast-radius: no reviewable files changed → tier LOW"
  exit 0
fi

# Added lines only, and ONLY from executable content. A destructive command
# REMOVED by this PR shrinks the radius, so removals are ignored; and prose is
# excluded because content checks on markdown fire on descriptions of code
# rather than code. That is not hypothetical — the first run of this analyzer
# tiered a docs-only PR CRITICAL because a new review-rubric paragraph
# *mentioned* "Guard 7".
STAGE="added-lines"
CODE_PATHSPECS=(
  ':(glob)**/*.sh' ':(glob)**/*.bash' ':(glob)**/*.bats'
  ':(glob)**/*.yml' ':(glob)**/*.yaml' ':(glob)**/*.json'
  ':(glob)**/*.ts' ':(glob)**/*.js' ':(glob)**/*.py'
  ':(glob).githooks/*'
)
# added_code_lines [extra-pathspecs...] — added (+) body lines from code files.
# One awk program, two callers. The header-skip anchor is subtle enough that
# check-rebase-integrity.sh's diff_side() spends three comment lines on why it
# must match `a/ b/ /dev/null` — duplicating it invites fixing one copy only.
added_code_lines() {
  git -c core.quotepath=false diff "$merge_base" "$head_sha" \
    -- "${CODE_PATHSPECS[@]}" "${EXCLUDES[@]}" "$@" \
    | awk '/^\+\+\+ (a\/|b\/|\/dev\/null)/ { next } substr($0,1,1) == "+" { print substr($0,2) }'
}
added_code_lines > "$WORK/added_lines"

# A stricter view for signals that claim "this OPERATION now runs": test
# fixtures and comments are excluded, because neither executes in production.
# Without this the analyzer flags its OWN detector — the comment describing
# `rm -rf /var/lib`, the regex that matches it, and the bats fixtures asserting
# it — which is the false-positive class that teaches reviewers to ignore a
# signal. gate-edit deliberately does NOT use this view: `# --- Guard 4: ---`
# is a comment, and it is exactly the thing worth matching.
added_code_lines ':(glob,exclude)scripts/tests/**' \
                 ':(glob,exclude)scripts/check-blast-radius.sh' \
  | grep -vE '^[[:space:]]*#' > "$WORK/added_exec_lines" || true

# --- identity tokens ----------------------------------------------------------
# What to search for when asking "who references this?". A BASENAME is the wrong
# key: skills-all/<name>/SKILL.md and workspaces/<a>/SOUL.md have basenames
# shared by every skill and every agent in the repo, so a basename grep reported
# 123 "callers" for a file with none. The distinctive identity is the script
# filename for scripts, and the SKILL/PLUGIN DIRECTORY NAME for bundles.
# Anything without a distinctive identity gets no reference analysis at all —
# a missing signal is honest, an invented one is not.
STAGE="identities"
: > "$WORK/identities"
while IFS= read -r F; do
  [ -n "$F" ] || continue
  case "$F" in
    scripts/tests/*) continue ;;
    scripts/*.sh)      printf '%s\t%s\n' "$(basename -- "$F")" "$F" ;;
    skills-all/*/*)    printf '%s\t%s\n' "$(echo "$F" | cut -d/ -f2)" "skills-all/$(echo "$F" | cut -d/ -f2)" ;;
    plugins/*/*)       printf '%s\t%s\n' "$(echo "$F" | cut -d/ -f2)" "plugins/$(echo "$F" | cut -d/ -f2)" ;;
    *) continue ;;
  esac
done < "$WORK/pr_files" | sort -u > "$WORK/identities"

# --- match helper -------------------------------------------------------------
# match_files <extended-regex> → matching changed paths on stdout (never fails
# the script when nothing matches).
match_files() { grep -E "$1" "$WORK/pr_files" || true; }

# --- S1 gate-edit (critical) --------------------------------------------------
STAGE="gate-edit"
gate_files="$(match_files '(^|/)(check|ensure|validate)-[^/]*\.sh$|^scripts/qa-pr-approve\.sh$|^\.github/workflows/.*\.ya?ml$')"
# A Guard block touched inside any other file counts too — Guard N lives in
# qa-pr-approve.sh today, but the pattern is what matters, not the filename.
if grep -qE '(^|[^[:alnum:]])Guard [0-9]+' "$WORK/added_lines" 2>/dev/null; then
  gate_files="$(printf '%s\n%s\n' "$gate_files" "(diff adds or edits a 'Guard N' block)" | grep -v '^$' || true)"
fi
if [ -n "$gate_files" ]; then
  add_signal gate-edit critical \
    "An enforcement gate changed. Read the REFUSAL branch, not the success branch: grep-vs-parse divergence, fail-open on missing input, enforcement that is tested but unwired, concurrency/clock hazards, and discrimination-without-stability are all documented regressions in this repo." \
    "$gate_files"
fi

# --- S2 credential-surface (critical) ----------------------------------------
STAGE="credential-surface"
cred_files="$(match_files '^secrets/|(^|/)[^/]*\.env$|(^|/)\.env\.|auth-profiles|codex-auth|codex-oauth|codex-reauth|(^|/)[^/]*\.(pem|key)$')"
if [ -n "$cred_files" ]; then
  add_signal credential-surface critical \
    "Touches a credential surface. A credential's blast radius is everything it can reach; codex/OAuth stores in this repo are fleet-wide and single-refresher by design." \
    "$cred_files"
fi

# --- S3 fleet-config (critical) ----------------------------------------------
STAGE="fleet-config"
fleet_files="$(match_files '^openclaw-[^/]*\.json$|^openclaw\.json$|^cron-jobs\.json$|^policies/|(^|/)shared\.env$')"
if [ -n "$fleet_files" ]; then
  add_signal fleet-config critical \
    "Changes shared gateway/agent configuration. These files are loaded fleet-wide, so an error here degrades every agent at once rather than one code path." \
    "$fleet_files"
fi

# --- S4 cron-reach (high) -----------------------------------------------------
STAGE="cron-reach"
: > "$WORK/cron_hits"
if [ "$pr_file_count" -le "$BR_MAX_FILES" ]; then
  while IFS=$'\t' read -r ident src; do
    [ -n "$ident" ] || continue
    # Only scheduler surfaces — a hit here means the change runs unattended.
    # THREE targets, and all three are load-bearing:
    #   cron-jobs.json              openclaw cron entries
    #   scripts/install-aux-units.sh  where the systemd unit bodies are actually
    #                               heredoc'd (36 ExecStart lines live here)
    #   scripts/aux-units/          the few standalone unit/override files
    # There is no top-level systemd/ directory in this repo; naming one (and
    # later naming only aux-units/) meant no timer-driven script could ever fire
    # this signal — verified against all 7 timer scripts.
    hits="$(grep -rlF -- "$ident" \
              cron-jobs.json scripts/install-aux-units.sh scripts/aux-units/ \
              2>/dev/null || true)"
    if [ -n "$hits" ]; then
      while IFS= read -r H; do
        [ -n "$H" ] && printf '%s → %s\n' "$src" "$H" >> "$WORK/cron_hits"
      done <<< "$hits"
    fi
  done < "$WORK/identities"
else
  note_skip "cron-reach: PR touches $pr_file_count files (> BR_MAX_FILES=$BR_MAX_FILES)"
fi
if [ -s "$WORK/cron_hits" ]; then
  add_signal cron-reach high \
    "Invoked by a scheduled job. Failures here are unattended: nobody is watching when it fires, so a silent break persists until a watchdog or a human notices." \
    "$(cat "$WORK/cron_hits")"
fi

# --- S5 state-mutation (high) -------------------------------------------------
STAGE="state-mutation"
# `mv` is in BOTH alternations on purpose: it can appear before the path
# (`mv "$tmp" /var/lib/x`) or after it (`mv /opt/hydra/x /tmp`), and the header
# above has always promised rm/mv/truncate/install. It was missing entirely, so
# an overwrite of persistent state via mv reported LOW instead of HIGH.
destructive="$(grep -E '(rm[[:space:]]+-[rf]|mv[[:space:]]|truncate|install[[:space:]]+-m|[[:space:]]>[[:space:]]*"?)(.*)(/var/lib|/opt/hydra)|(/var/lib|/opt/hydra)[^[:space:]]*.*(rm[[:space:]]+-[rf]|mv[[:space:]]|truncate)' "$WORK/added_exec_lines" || true)"
if [ -n "$destructive" ]; then
  add_signal state-mutation high \
    "The diff introduces a destructive or overwriting operation against persistent state (/var/lib or /opt/hydra). Ask explicitly how this is reverted, and whether re-running it twice is safe." \
    "$destructive"
fi

# --- S6 reverse-callers (high / medium) ---------------------------------------
STAGE="reverse-callers"
: > "$WORK/caller_hits"
callers_total=0
if [ "$pr_file_count" -le "$BR_MAX_FILES" ]; then
  while IFS=$'\t' read -r ident src; do
    [ -n "$ident" ] || continue
    # docs/ is excluded deliberately: prose mentioning a script is not a caller,
    # and counting it inflates the tier until reviewers learn to ignore it.
    # Files belonging to the changed bundle itself are not its callers either.
    hits="$(grep -rlF --exclude-dir=.git --exclude-dir=node_modules \
              --exclude-dir=dist --exclude-dir=docs -- "$ident" . 2>/dev/null \
            | sed 's|^\./||' \
            | awk -v p="${src%/}/" 'index($0, p) != 1' \
            | grep -vxF "$src" | sort -u || true)"
    n="$(printf '%s' "$hits" | grep -c . || true)"
    if [ "$n" -gt 0 ]; then
      callers_total=$((callers_total + n))
      printf '%s ← referenced by %s file(s):\n' "$src" "$n" >> "$WORK/caller_hits"
      printf '%s\n' "$hits" | sed 's/^/    /' >> "$WORK/caller_hits"
    fi
  done < "$WORK/identities"
else
  note_skip "reverse-callers: PR touches $pr_file_count files (> BR_MAX_FILES=$BR_MAX_FILES)"
fi
if [ -s "$WORK/caller_hits" ]; then
  if [ "$callers_total" -ge "$BR_CALLERS_HIGH" ]; then
    sev=high
  else
    sev=medium
  fi
  add_signal reverse-callers "$sev" \
    "Other files in the repo reference the changed script(s). For each caller listed, check whether this diff changed the contract that caller depends on: output format, exit codes, or side effects." \
    "$(cat "$WORK/caller_hits")"
fi

# --- S7 skill-reach (medium) --------------------------------------------------
STAGE="skill-reach"
skill_files="$(match_files '^skills-all/|^workspaces/[^/]+/SOUL\.md$')"
if [ -n "$skill_files" ]; then
  add_signal skill-reach medium \
    "Changes agent-facing doctrine. Skill and SOUL content is injected into every agent bound to it, so an error propagates to all of them at once and is invisible in any single code path." \
    "$skill_files"
fi

# --- S8 test-gap (medium) -----------------------------------------------------
STAGE="test-gap"
: > "$WORK/test_gaps"
while IFS= read -r F; do
  case "$F" in scripts/*.sh) ;; *) continue ;; esac
  case "$F" in scripts/tests/*) continue ;; esac
  base="$(basename -- "$F" .sh)"
  [ -f "scripts/tests/${base}.bats" ] || printf '%s (no scripts/tests/%s.bats)\n' "$F" "$base" >> "$WORK/test_gaps"
done < "$WORK/pr_files"
if [ -s "$WORK/test_gaps" ]; then
  add_signal test-gap medium \
    "A changed script has no bats suite. Absent coverage does not make the change risky on its own, but it removes the mechanism that would catch a regression in everything else flagged here." \
    "$(cat "$WORK/test_gaps")"
fi

# --- S9 deploy-path (info — never changes the tier) ---------------------------
STAGE="deploy-path"
undeployed="$(match_files '^docs/|^\.github/|^scripts/tests/|(^|/)README\.md$|^\.claude/')"
if [ -n "$undeployed" ]; then
  add_signal deploy-path info \
    "These changed paths are repo-side only (docs, CI definitions, tests, editor config) — they do not rsync to /opt/hydra. Context for judging runtime impact; this signal NEVER lowers the tier, because an unproven deploy path is not a safe one." \
    "$undeployed"
fi

# --- report -------------------------------------------------------------------
STAGE="report"
tier="$(compute_tier)"
# ANALYSIS_DONE is set only AFTER the final write succeeds, matching
# check-rebase-integrity.sh:462. Setting it first meant a failed final write fell
# out of the EXIT trap's ERROR path and exited 1 — a code this script's header
# does not document and the workflow swallows. Consumers stayed fail-closed via
# the early ERROR sentinel, but the run reported the wrong thing.
write_state OK || { note_skip "final state write failed"; write_state ERROR || true; exit 3; }
ANALYSIS_DONE=1

signal_count="$(grep -c . "$WORK/signals.ndjson" || true)"
echo "blast-radius: tier=${tier} signals=${signal_count} files=${pr_file_count}"
if [ -s "$WORK/signals.ndjson" ]; then
  jq -r '"  [\(.severity)] \(.id): \(.evidence | length) evidence line(s)"' "$WORK/signals.ndjson"
fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    printf '### Blast radius: **%s**\n\n' "$tier"
    if [ -s "$WORK/signals.ndjson" ]; then
      printf '| Severity | Signal | Evidence |\n|---|---|---|\n'
      jq -r '"| \(.severity) | \(.id) | \(.evidence | length) |"' "$WORK/signals.ndjson"
    else
      printf 'No signals fired.\n'
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi
exit 0
