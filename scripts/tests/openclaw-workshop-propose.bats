#!/usr/bin/env bats
# MUS-3105: autonomous skill captures must stay proposals on node-8. openclaw's default
# is skills.workshop.autonomous.mode="auto", which applies a capture to the live SKILL.md
# in the same call (no reviewer, re-drifts the deploy baseline: #1047, #1057, MUS-3099).
# The key is global in openclaw's schema; there is no per-agent form.
# MUS-4094: but there is one config file per profile, each loaded by its own gateway
# (--profile edge gateway --port 18810). #1068 pinned openclaw-main.json only, so the
# support agent (Caroline, on edge) kept applying autonomously. Every openclaw-*.json at
# the repo root must carry the pin; the glob means a new profile (e.g. openclaw-qa.json,
# MUS-2687) cannot ship without it.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

@test "at least one openclaw-*.json profile is found (an empty glob must not pass vacuously)" {
  shopt -s nullglob
  files=("$REPO_ROOT"/openclaw-*.json)
  [ "${#files[@]}" -gt 0 ]
}

@test "every openclaw-*.json pins skills.workshop.autonomous.mode to propose" {
  shopt -s nullglob
  files=("$REPO_ROOT"/openclaw-*.json)
  [ "${#files[@]}" -gt 0 ]
  bad=""
  for f in "${files[@]}"; do
    mode="$(jq -r '.skills.workshop.autonomous.mode // "unset"' "$f")" || mode="jq-failed"
    [ "$mode" = "propose" ] || bad="$bad $(basename "$f")=$mode"
  done
  if [ -n "$bad" ]; then
    echo "profiles without the propose pin:$bad" >&2
    return 1
  fi
}
