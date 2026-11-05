#!/usr/bin/env bats
# Scout company-finder Step 3 must fetch the LinkedIn company page before it may reject
# NO_LINKEDIN; a search miss is not a reject (MUS-29922). On 5 Nov the daily run did two
# `site:linkedin.com/company` searches, never called web_fetch, and dropped every survivor.
bats_require_minimum_version 1.5.0

REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SKILL="$REPO/workspaces/scout/skills/muso-outreach-discovery/SKILL.md"

setup() {
  # Step 3 section: from "### Step 3" up to (not including) the next "### ".
  STEP3="$(awk '/^### Step 3/{f=1;print;next} f&&/^### /{exit} f{print}' "$SKILL")"
  [ -n "$STEP3" ]
}

@test "Step 3 tells Scout to web_fetch the linkedin.com/company URL" {
  grep -qE 'web_fetch[^.]*linkedin\.com/company/<slug>' <<<"$STEP3"
}

@test "Step 3 says a search miss is not NO_LINKEDIN" {
  grep -qE 'never a `?NO_LINKEDIN`? by itself' <<<"$STEP3"
}

@test "Step 3 defines the no-URL branch: one search, at most 2 guessed slug fetches, then NO_LINKEDIN listing the attempts" {
  grep -qE 'at most one search' <<<"$STEP3"
  grep -qE 'at most 2 guessed `https://www\.linkedin\.com/company/<slug>`' <<<"$STEP3"
  grep -qE 'NO_LINKEDIN.*never a silent drop' <<<"$STEP3"
  grep -qE 'lists what was tried' <<<"$STEP3"
  grep -qE 'homepage: no link / search: no company URL / slug fetches' <<<"$STEP3"
}
