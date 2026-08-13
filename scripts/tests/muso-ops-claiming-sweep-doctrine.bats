#!/usr/bin/env bats
# Mechanical backstop for the claiming queue-sweep doctrine. The August 2026
# backlog accumulated when newest-first, first-page sweeps silently skipped old
# claims and "needs review" had no durable escalation or re-surfacing path.

bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SKILL="$HYDRA_REPO/skills-all/muso-ops-claiming/SKILL.md"
OPS_SOUL="$HYDRA_REPO/workspaces/operations/SOUL.md"

queue_sweep_section() {
  awk '
    /^### Batch Review \(Queue Sweep\)$/ {
      if (found) exit 2
      found = 1
      in_section = 1
      next
    }
    in_section && /^## / { in_section = 0 }
    in_section { print }
    END { if (found != 1) exit 2 }
  ' "$1"
}

escalation_ledger_section() {
  awk '
    /^## Escalation Ledger \(No Silent Abstentions\)$/ {
      if (found) exit 2
      found = 1
      in_section = 1
      next
    }
    in_section && /^## / { in_section = 0 }
    in_section { print }
    END { if (found != 1) exit 2 }
  ' "$1"
}

validate_queue_sweep_contract() {
  local section ledger contract

  section="$(queue_sweep_section "$1")" || return 1
  contract="$(
    printf '%s\n' "$section" | awk '
      /^<!-- queue-sweep-contract:v1 -->$/ {
        if (seen || in_contract) exit 2
        seen = 1
        in_contract = 1
        next
      }
      /^<!-- \/queue-sweep-contract:v1 -->$/ {
        if (!in_contract) exit 2
        in_contract = 0
        closed = 1
        next
      }
      in_contract {
        sub(/[[:space:]]+$/, "")
        if (length) print
      }
      END { if (seen != 1 || !closed || in_contract) exit 2 }
    '
  )" || return 1

  [ "$contract" = $'- pagination: all_pages\n- processing_order: oldest_first\n- stable_snapshot_passes: 2\n- mutation_revalidation: per_claim\n- ledger_lock: memory/claiming-escalations.lock\n- lock_mode: exclusive_fail_closed' ] || return 1

  if printf '%s\n' "$section" \
      | grep -Eiq '(only|just)[[:space:]]+(process[[:space:]]+)?page[[:space:]]*1|stop after (the )?first page|newest[- ]first'; then
    return 1
  fi

  ledger="$(escalation_ledger_section "$1")" || return 1
  if printf '%s\n' "$ledger" \
      | grep -Eo '[[:alnum:]_./${}-]+\.lock' \
      | grep -Fvx 'memory/claiming-escalations.lock' \
      | grep -q .; then
    return 1
  fi
}

@test "queue sweep has one normalized authoritative contract" {
  run validate_queue_sweep_contract "$SKILL"
  [ "$status" -eq 0 ]
}

@test "queue sweep contract rejects a page-one newest-first override" {
  mutated="$BATS_TEST_TMPDIR/muso-ops-claiming-SKILL.md"
  awk '
    { print }
    /^### Batch Review \(Queue Sweep\)$/ {
      print "Process only page 1 newest-first; this overrides pagination below."
    }
  ' "$SKILL" > "$mutated"

  run validate_queue_sweep_contract "$mutated"
  [ "$status" -ne 0 ]
}

@test "queue sweep contract rejects an alternate per-process lock" {
  mutated="$BATS_TEST_TMPDIR/muso-ops-claiming-alt-lock-SKILL.md"
  awk '
    { print }
    /^## Escalation Ledger \(No Silent Abstentions\)$/ {
      print "Use memory/claiming-escalations-${PPID}.lock instead of the canonical sidecar."
    }
  ' "$SKILL" > "$mutated"

  run validate_queue_sweep_contract "$mutated"
  [ "$status" -ne 0 ]
}

@test "queue sweeps enumerate the complete queue oldest-first" {
  run grep -F "page 1, 2, 3" "$SKILL"
  [ "$status" -eq 0 ]

  run grep -F 'API items by `createdAt ASC`' "$SKILL"
  [ "$status" -eq 0 ]

  run grep -F 'require every page' "$SKILL"
  [ "$status" -eq 0 ]

  run grep -F 'page 1 and require every page' "$SKILL"
  [ "$status" -eq 0 ]

  run grep -F 'exact claim ID appears twice' "$SKILL"
  [ "$status" -eq 0 ]

  run grep -F 'unique accumulated count does not equal' "$SKILL"
  [ "$status" -eq 0 ]

  run grep -F 'exact claim-ID set twice in a row' "$SKILL"
  [ "$status" -eq 0 ]

  run grep -F 'Immediately before each claim mutation' "$SKILL"
  [ "$status" -eq 0 ]

  run grep -F 'fully paginated' "$SKILL"
  [ "$status" -eq 0 ]

  run grep -F 'muso claiming list --profile-id <profileId> --json' "$SKILL"
  [ "$status" -eq 0 ]

  run grep -F 'unique `count == total`' "$SKILL"
  [ "$status" -eq 0 ]

  run grep -F 'different-team claim with `pending` or `processed` status' "$SKILL"
  [ "$status" -eq 0 ]

  run grep -F 'rejected, reverted, or closed history as risk evidence' "$SKILL"
  [ "$status" -eq 0 ]
}

@test "aged claims cannot leave a sweep as silent needs-review abstentions" {
  run grep -F "Every pending claim older than 72h" "$SKILL"
  [ "$status" -eq 0 ]

  run grep -F "approve**, **reject**, or **ESCALATED" "$SKILL"
  [ "$status" -eq 0 ]
}

@test "escalations are durable and re-surfaced on the next sweep" {
  run grep -F 'memory/claiming-escalations.json' "$SKILL"
  [ "$status" -eq 0 ]

  run grep -F "Every sweep starts by re-surfacing" "$SKILL"
  [ "$status" -eq 0 ]

  run grep -F 'initialize it once as `{"escalations": []}`' "$SKILL"
  [ "$status" -eq 0 ]

  run grep -F 'memory/claiming-escalations.lock' "$SKILL"
  [ "$status" -eq 0 ]

  run grep -F 'flock -x -w 30 "$claiming_lock_fd"' "$SKILL"
  [ "$status" -eq 0 ]

  run grep -F 'never use the ledger file, a temporary file, or another path as the lock target' "$SKILL"
  [ "$status" -eq 0 ]

  run grep -F '`ESCALATION LOCK FAILED`' "$SKILL"
  [ "$status" -eq 0 ]

  run grep -F 'exactly one ledger record per `claimId`' "$SKILL"
  [ "$status" -eq 0 ]

  run grep -F 'api-logs/admin/YYYY-MM-DD.jsonl' "$SKILL"
  [ "$status" -eq 0 ]

  run grep -F 'relative to the active agent workspace' "$SKILL"
  [ "$status" -eq 0 ]

  run grep -F 're-read the file and verify the record' "$SKILL"
  [ "$status" -eq 0 ]

  run grep -F 'An open record without `slack_ts` is incomplete delivery' "$SKILL"
  [ "$status" -eq 0 ]
}

@test "same-team duplicates and contested claims have explicit dispositions" {
  run grep -F "already claimed by your workspace" "$SKILL"
  [ "$status" -eq 0 ]

  run grep -F "two DIFFERENT teams, same profile" "$SKILL"
  [ "$status" -eq 0 ]

  run grep -F 'Never use it for `profileType == organization`' "$SKILL"
  [ "$status" -eq 0 ]

  run grep -F 'rejection can remove the workspace company seat' "$SKILL"
  [ "$status" -eq 0 ]
}

@test "read-only listing cannot trigger sweep writes" {
  run grep -F '"Show me today' "$SKILL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"is read-only"* ]]

  run grep -F 'create ledger entries, send Slack posts, or change claim state' "$SKILL"
  [ "$status" -eq 0 ]

  run grep -F 'During a read-only review, return an' "$SKILL"
  [ "$status" -eq 0 ]

  run grep -F 'Tier 4 is always read-only and never triggers those writes' "$SKILL"
  [ "$status" -eq 0 ]
}

@test "escalation ownership resolves through current Operations doctrine" {
  run grep -F 'Operations SOUL `## Escalation`' "$SKILL"
  [ "$status" -eq 0 ]

  run grep -F 'Default escalation target:' "$OPS_SOUL"
  [ "$status" -eq 0 ]
}

@test "failed escalation writes are read back before any retry" {
  run grep -F 'A failed or timed-out Slack write has unknown outcome' "$SKILL"
  [ "$status" -eq 0 ]

  run grep -F 'never blind-retry it' "$SKILL"
  [ "$status" -eq 0 ]
}

@test "legacy repo and API instructions cannot return" {
  run grep -E 'Muso-AI/muso-skills|/w/admin|offset=|Athena|\.openclaw/skills/skills' "$SKILL"
  [ "$status" -eq 1 ]
}
