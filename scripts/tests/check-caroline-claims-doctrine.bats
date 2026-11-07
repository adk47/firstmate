#!/usr/bin/env bats
# Negative and positive cases for scripts/check-caroline-claims-doctrine.sh.
# Every case runs against a COPY of the files the gate reads (REPO_ROOT override), so a
# test can plant a violation without touching the real doctrine.

setup() {
  REAL_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  GATE="$REAL_ROOT/scripts/check-caroline-claims-doctrine.sh"
  FAKE="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$FAKE/workspaces" "$FAKE/plugins/support-tools/src/tools" "$FAKE/plugins/intercom/src"
  cp -R "$REAL_ROOT/workspaces/support" "$FAKE/workspaces/support"
  cp "$REAL_ROOT/plugins/support-tools/src/tools/ticket-format.ts" "$FAKE/plugins/support-tools/src/tools/"
  cp "$REAL_ROOT/plugins/intercom/src/ticket-format.ts" "$FAKE/plugins/intercom/src/"
  CI_MD="$FAKE/workspaces/support/reference/common-issues.md"
}

run_gate() { run env REPO_ROOT="$FAKE" bash "$GATE"; }

# Pad a file well past the 64 KiB pipe buffer so a `producer | grep -q` matcher would see
# the producer die of SIGPIPE after an early match (the false-green QA found).
pad_large() { python3 -c "import sys; open(sys.argv[1],'a').write(('filler line about subscriptions\n')*8000)" "$1"; }

@test "clean copy of the real doctrine passes" {
  run_gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK: Caroline claims/credits/merges doctrine"* ]]
}

@test "CAN FAIL: a forbidden merge date in a small file is caught" {
  printf '\nOur team will review and merge typically within 5 business days.\n' >> "$CI_MD"
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"merge typically within 5 business days"* ]]
}

@test "CAN FAIL: a forbidden phrase near the top of a LARGE file is caught (no SIGPIPE false-green)" {
  { printf 'They will follow up. You'"'"'ll hear back within 5 business days.\n'; cat "$CI_MD"; } > "$CI_MD.new"
  mv "$CI_MD.new" "$CI_MD"
  pad_large "$CI_MD"
  [ "$(wc -c < "$CI_MD")" -gt 200000 ]
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"hear back within 5 business days"* ]]
}

@test "CAN FAIL: forbid is case- and wrap-insensitive" {
  printf '\nThis needs a MANUAL REVIEW\nBY OUR TEAM, sorry.\n' >> "$CI_MD"
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"manual review by our team"* ]]
}

@test "CAN FAIL: a removed required anchor is caught" {
  python3 - "$CI_MD" <<'EOF'
import sys; p=sys.argv[1]; s=open(p).read()
s=s.replace("**Hand off only**: run no check on their profiles.", "Run dedupe_check first.")
open(p,'w').write(s)
EOF
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"Q5 merge: hand off only, no check"* ]]
}

@test "a large file with every anchor present still passes (require is not false-red on SIGPIPE)" {
  pad_large "$CI_MD"
  run_gate
  [ "$status" -eq 0 ]
}

@test "CAN FAIL: bulk-credit-change dropped from the null-SLA set is caught" {
  sed -i.bak 's/"credit-verify", "bulk-credit-change", "profile-claim",/"credit-verify", "profile-claim",/' \
    "$FAKE/plugins/support-tools/src/tools/ticket-format.ts"
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"AGENT_LANE_ACTIONS covers claims + credits"* ]]
}

@test "CAN FAIL: a conversation-reply promise for claims is caught" {
  python3 - "$CI_MD" <<'EOF'
import sys; p=sys.argv[1]; s=open(p).read()
s += "\n`create_ticket` returns no timeframe for claims. The outcome is posted in this conversation.\n"
open(p,'w').write(s)
EOF
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"no conversation-reply promise for claims"* ]]
}

@test "a missing input file exits 2, never passes" {
  rm "$FAKE/workspaces/support/reference/faq.md"
  run_gate
  [ "$status" -eq 2 ]
}

@test "CAN FAIL: a captain-barred phrase in a credit reply is caught (02:51Z: 'passed to our team')" {
  printf '\nThanks! I have passed your screenshots to our team.\n' >> "$CI_MD"
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"captain 02:51Z barred phrase"* ]]
}

@test "CAN FAIL: 'nothing else is needed' and 'review already underway' are caught, case-insensitive" {
  printf '\nNothing else is needed from you.\nI added it to the review ALREADY UNDERWAY.\n' >> "$CI_MD"
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"nothing else is needed"* ]]
  [[ "$output" == *"review already underway"* ]]
}

@test "CAN FAIL: a second barred-phrases marker line cannot smuggle a violation past the forbid list" {
  printf '\n<!-- barred-phrases --> No need to resend, it is with our team.\n<!-- barred-phrases --> again\n' >> "$CI_MD"
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"more than one barred-phrases marker line"* ]]
}

@test "CAN FAIL: a scripted claim of an action is caught (captain 2026-10-28: 'raised the priority', 'I've checked')" {
  AR_MD="$FAKE/workspaces/support/skills/action-request/SKILL.md"
  printf '\n"I have raised the priority on your request."\n' >> "$AR_MD"
  printf "\n\"I've checked quite a lot for you today already.\"\n" >> "$CI_MD"
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"raised the priority"* ]]
  [[ "$output" == *"I've checked quite a lot"* ]]
}

@test "CAN FAIL: dropping 'I've verified' / 'I can merge' from the never-say line is caught" {
  CV_MD="$FAKE/workspaces/support/skills/verification-handoff/SKILL.md"
  python3 - "$CV_MD" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
s=s.replace('"I\'ve verified", "I verified", ', '', 1)
open(p,'w').write(s)
PY
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"Q12 the never-say-checked/filed/verified/merged phrases"* ]]
}

@test "CAN FAIL: a removed verification/merge skill coming back is caught (dir or routing reference)" {
  mkdir -p "$FAKE/workspaces/support/skills/customer-profile-consolidate"
  printf -- '---\nname: customer-profile-consolidate\n---\nMerge their profiles.\n' > "$FAKE/workspaces/support/skills/customer-profile-consolidate/SKILL.md"
  printf '\n- Duplicates -> `customer-profile-dedupe`.\n' >> "$CI_MD"
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"removed verification/merge skill is back"* ]]
  [[ "$output" == *"routes to a removed verification/merge skill"* ]]
}

@test "CAN FAIL: a ticket kind losing its handoff tag is caught" {
  sed -i.bak 's/"profile-merge": { default: "merge", allowed: \["merge"\] },//' \
    "$FAKE/plugins/support-tools/src/tools/ticket-format.ts"
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"Q12 merge kinds tag merge"* ]]
}

@test "CAN FAIL: a hand-off line that is not the approved one is caught" {
  CV_MD="$FAKE/workspaces/support/skills/verification-handoff/SKILL.md"
  sed -i.bak "s/I'm pulling in a teammate to take this from here./I've passed this to our team and checked it./" "$CV_MD"
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"hand-off line is the approved one"* ]]
}

@test "CAN FAIL: Jaxsta coming back into any support doctrine file is caught (captain 2026-10-29)" {
  printf '\n- A public link where the credit is listed: Tidal, Genius, JAXSTA, Discogs\n' >> "$FAKE/workspaces/support/reference/faq.md"
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"Jaxsta is not named to users"* ]]
}

# --- caroline-instructions-1029 evals (captain 2026-10-29) ----------------------------

@test "CAN FAIL: 'why was my credit rejected?' answered with a reason is caught (§2.6)" {
  CAP_MD="$FAKE/workspaces/support/reference/credits-and-profiles.md"
  python3 - "$CAP_MD" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
s=s.replace("A request is closed when the supporting information we received wasn't enough to confirm the credit.",
            "Your request was declined because the document doesn't name you.")
open(p,'w').write(s)
PY
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"Q3 declined: the approved decline paragraph"* ]]
}

# QA #1718 round 8 (2026-11-06): the gate listed four of the five internal review codes, so a
# doctrine edit saying a decline was for an unreadable document passed. One case per code, and
# one per phrasing, so a future edit that drops a code from either list fails here.
@test "CAN FAIL: every one of the five internal review codes is caught in the decline doctrine" {
  CAP_MD="$FAKE/workspaces/support/reference/credits-and-profiles.md"
  CV_MD="$FAKE/workspaces/support/skills/verification-handoff/SKILL.md"
  for code in doesnt_name_you other_track other_role unreadable not_a_document; do
    for f in "$CAP_MD" "$CV_MD"; do
      cp "$f" "$f.orig"
      printf '\nIf the review code was %s, tell them so.\n' "$code" >> "$f"
      run_gate
      [ "$status" -eq 1 ] || { echo "gate passed a doctrine file naming the code '$code' in ${f##*/}"; false; }
      [[ "$output" == *"Q3 declined: the internal review codes stay internal"* ]]
      mv "$f.orig" "$f"
    done
  done
}

@test "CAN FAIL: the way an unreadable or non-document decline SOUNDS is caught, not just the code" {
  CAP_MD="$FAKE/workspaces/support/reference/credits-and-profiles.md"
  for phrase in "the document was unreadable" "we couldn't read the file" "that wasn't a document"; do
    cp "$CAP_MD" "$CAP_MD.orig"
    printf '\nYour request was declined because %s.\n' "$phrase" >> "$CAP_MD"
    run_gate
    [ "$status" -eq 1 ] || { echo "gate passed the decline phrasing '$phrase'"; false; }
    [[ "$output" == *"Q3 declined: never a reason"* ]]
    mv "$CAP_MD.orig" "$CAP_MD"
  done
}

@test "the unreadable guard does not reach SOUL.md's legitimate attachment-block use" {
  # The bare word is scoped to the two decline-doctrine files on purpose: SOUL.md says
  # "don't call it corrupt or unreadable" about the attachment block, which is a different
  # subject. If the guard ever widens to the whole workspace, this case fails.
  grep -qi "unreadable" "$FAKE/workspaces/support/SOUL.md"
  run_gate
  [ "$status" -eq 0 ]
}

@test "CAN FAIL: 'how do you verify credits?' naming our sources or a score is caught (§3)" {
  printf '\nWe compare every credit against Spotify and Tidal and MusicBrainz, then a risk score decides.\n' >> "$FAKE/workspaces/support/reference/faq.md"
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"Spotify and Tidal"* ]]
  [[ "$output" == *"MusicBrainz"* ]]
  [[ "$output" == *"risk score"* ]]
}

@test "CAN FAIL: a GDPR reply with a business-day number or the old SLA step is caught (§2.7)" {
  GDPR_MD="$FAKE/workspaces/support/reference/gdpr-erasure-requests.md"
  printf '\n3. Reply with the Tier 3 template from the skill and quote the returned SLA once (5-10 business days).\n' >> "$GDPR_MD"
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"Q14 no tier-3 SLA quote"* ]]
  [[ "$output" == *"5-10 business days"* ]]
}

@test "CAN FAIL: a promise of inaction ('nothing is needed from you') is caught (captain 2026-10-29)" {
  printf '\nThanks, nothing is needed from you right now.\n' >> "$CI_MD"
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"nothing is needed from you"* ]]
}

@test "CAN FAIL: an internal or vendor name in the reference library is caught (§3)" {
  printf '\nFable and DeepSeek review every document.\n' >> "$FAKE/workspaces/support/reference/faq.md"
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"Fable"* ]]
  [[ "$output" == *"DeepSeek"* ]]
}

@test "CAN FAIL: a second never-reveal marker line cannot smuggle signal words past the forbid list" {
  printf '\n<!-- never-reveal --> your risk score was high\n<!-- never-reveal --> again\n' >> "$CI_MD"
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"more than one never-reveal marker line"* ]]
}

@test "CAN FAIL: the approved GDPR acknowledgement removed is caught (§2.7)" {
  GDPR_MD="$FAKE/workspaces/support/reference/gdpr-erasure-requests.md"
  sed -i.bak 's/within one month of today,/soon,/' "$GDPR_MD"
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"Q14 ack sentence 9 verbatim"* ]]
  [[ "$output" == *"Q14 the full approved acknowledgement block verbatim"* ]]
}

@test "CAN FAIL: an always-loaded template quoting the SLA is caught (QA on #1451)" {
  printf '\n- `create_ticket {submitted:true, sla}` -- "You will hear back within `<sla>`."\n' >> "$FAKE/workspaces/support/SOUL.md"
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"no reply template quotes an SLA"* ]]
}

@test "CAN FAIL: GDPR v2 - 'deleted on request' anywhere in the support workspace is caught (legal hold 1350)" {
  printf '\nAccount data, your login, email and personal details, is deleted on request.\n' >> "$CI_MD"
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"GDPR v2: never promise deletion"* ]]
}

@test "CAN FAIL: GDPR v2 - the identity step without 'claim it' first, or the retired v1 text, is caught" {
  GDPR_MD="$FAKE/workspaces/support/reference/gdpr-erasure-requests.md"
  sed -i.bak 's/The quickest way: open the page in the Muso app and claim it, that proves it on the spot\. //' "$GDPR_MD"
  printf '\n> Here is how it works: we confirm that the page is about you, we take the page out.\n' >> "$GDPR_MD"
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"Q14 ack sentence 3 verbatim"* ]]
  [[ "$output" == *"Q14 v1 acknowledgement retired"* ]]
}

@test "CAN FAIL: GDPR v2 - dropping 'a claim is not required' or the legal_threat slot is caught" {
  GDPR_MD="$FAKE/workspaces/support/reference/gdpr-erasure-requests.md"
  sed -i.bak -e 's/A claim is NOT required for GDPR\.//' -e 's/put `legal_threat` first/put the trigger first/' "$GDPR_MD"
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"Q14 a claim is not required for GDPR"* ]]
  [[ "$output" == *"Q14 legal words carry legal_threat"* ]]
}

@test "CAN FAIL: GDPR v2 own-name slot - the r5-barred inaction or name-match promise is caught" {
  GDPR_MD="$FAKE/workspaces/support/reference/gdpr-erasure-requests.md"
  sed -i.bak "s/Otherwise, reply with your name as it appears on your ID; if the page is unclaimed and carries that name, the team can confirm it from that\./Otherwise nothing more is needed from you for this step: the page carries your name and we will confirm it from that./" "$GDPR_MD"
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"Q14 slot own-name verbatim"* ]]
  [[ "$output" == *"Q14 own-name slot carries no inaction promise"* ]]
  [[ "$output" == *"Q14 no name-match sufficiency promise"* ]]
}

@test "CAN FAIL: GDPR v2 (QA on #1619) - replacing the formal-review sentence with an erasure promise is caught" {
  GDPR_MD="$FAKE/workspaces/support/reference/gdpr-erasure-requests.md"
  sed -i.bak 's/Credit records on published works go through a separate formal review, and the written response covers them\./All credit records on published works are erased immediately./' "$GDPR_MD"
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"Q14 ack sentence 11 verbatim"* ]]
  [[ "$output" == *"Q14 the full approved acknowledgement block verbatim"* ]]
}

@test "CAN FAIL: GDPR v2 - every acknowledgement sentence and fixed slot is pinned on its own (one mutation each)" {
  GDPR_MD="$FAKE/workspaces/support/reference/gdpr-erasure-requests.md"
  cp "$GDPR_MD" "$GDPR_MD.orig"
  # one distinctive phrase per sentence (1..11), then the two slots
  phrases=("received {date}." "Here is how it works." "that proves it on the spot." "if you have one." "your name as it appears on your ID." "send their written authorisation." "public view." "we hide it immediately." "listing exactly what was done." "stated in that confirmation." "the written response covers them.")
  n=0
  for ph in "${phrases[@]}"; do
    n=$((n + 1))
    python3 - "$GDPR_MD.orig" "$GDPR_MD" "$ph" <<'PY'
import sys; src, dst, ph = sys.argv[1:4]; s = open(src).read()
# insert one word inside the phrase's first occurrence after the approval marker
j = s.index(ph, s.index("<!-- approved: gdpr-ack-v2-1101 -->"))
mutated = ph.replace(" ", " X ", 1) if " " in ph else "X" + ph
open(dst, "w").write(s[:j] + mutated + s[j + len(ph):])
PY
    run_gate
    [ "$status" -eq 1 ] || { echo "sentence $n mutation passed"; return 1; }
    [[ "$output" == *"Q14 ack sentence $n verbatim"* ]] || { echo "sentence $n not named: $output"; return 1; }
  done
  cp "$GDPR_MD.orig" "$GDPR_MD"
  sed -i.bak 's/To get started, reply with the link to the Muso page\./To get started, send us the page./' "$GDPR_MD"
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"Q14 slot no-link verbatim"* ]]
}

@test "CAN FAIL: GDPR v2 - a day count on the hide, or a name-match sufficiency promise, is caught (r5 on #1619)" {
  GDPR_MD="$FAKE/workspaces/support/reference/gdpr-erasure-requests.md"
  printf '\n> the page comes out of Muso search and public view (within a day).\n> for a page that carries your name, that is enough.\n' >> "$GDPR_MD"
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"Q14 the hide carries no day count"* ]]
  [[ "$output" == *"Q14 no name-match sufficiency promise"* ]]
}

@test "CAN FAIL: cs-health 2026-11-01 - dropping the no-profile line or the one-page claim-code line is caught" {
  FAQ_MD="$FAKE/workspaces/support/reference/faq.md"
  sed -i.bak -e 's/claim or create your profile first, then add the credit\./add the credit./' \
             -e 's/Yes, the code on one page you control is enough\./Yes./' "$FAQ_MD"
  run_gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"no-profile users get claim/create first"* ]]
  [[ "$output" == *"claim-code: the code on one page is enough"* ]]
}
