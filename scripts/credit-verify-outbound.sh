#!/usr/bin/env bash
# credit-verify-outbound.sh: the ONE server-side outbound tick for credit verification (captain 2026-10-30 14:4xZ
# "durable, on servers, bi-directional"; plan: firstmate data/proof-loop-lead-fable-p1/unattended-1030.md). Every
# hand-run batch becomes this tick, hourly on node-8 since 2026-11-13 (cron from install-aux-units.sh; every 2 h
# before that). It never decides anything itself: per campaign family it runs the DEPLOYED audience builder and the
# DEPLOYED runner, whose gates are code
# (copy-ref locks, comm_state, R8/account gate, identity G1-G5, email reachability, C11 dry-run == send, refusals
# recorded with reasons). Per family and segment:
#
#   build the audience -> --check-recipients --outcomes-json (what the send would do, read-only)
#   -> 5 rendered bodies for the after-the-fact sample -> apply up to the per-run cap (LIVE only)
#   -> health read -> auto-kill on a threshold
#
# Modes (files, never hand steps):
#   /etc/hydra/credit-verify-outbound.disabled      kill switch: the whole tick does nothing (written by auto-kill too)
#   policies/credit-verify-outbound.json armed_families  [key=arm-per-family] {family: {live, paid}} - a family is
#                                                       armed ONLY by its own row; a family with no row is not armed,
#                                                       and a malformed/unreadable block arms NOTHING (fail closed).
#   /etc/hydra/credit-verify-outbound.live          LEGACY (used only while armed_families is absent): absent = DRY-RUN
#   /etc/hydra/credit-verify-outbound.paid-enabled  LEGACY: absent = paid segments are dry-run even on a live tick
#                                                   (p1: paid joins after one clean free day)
#   /etc/hydra/credit-verify-outbound.exclude       user ids held out of every family (one per line; the
#                                                   transitional hand-exclusions of the pending rule PRs)
# Caps are CAPACITY caps (Fable 10-30 23:4xZ, m2's shared per-day send cap: credit 2,500 / claim 500 inside notify):
# per tick a family sends at most CAP users; per UTC day a campaign+segment at most its policy row, and ALL credit
# families together at most shared_daily_cap.credit, all claim families at most shared_daily_cap.claim (counted from the
# shared verify ledger, sent + attempted). The safety is the auto-kill, not a small fixed number.
# Auto-kill (writes the kill file and pages) after any apply:
#   - health_check.py non-zero: hard bounce > 2 %, unsubscribe > 2 %, spam > 2 % or any complaint above baseline,
#     or unreadable;
#   - a FRAUD HIT: any account this apply sent to is held by the fraud lens when re-checked right after the send
#     (credit_review.fraud_lens; the lens refusing held users BEFORE a send is normal and never kills), or the lens
#     could not be read;
#   - a refusal spike: refused / attempted > REFUSAL_SPIKE in one apply;
#   - n1's zero-read (#1545): a STOP is an unexplained credit-class message, and it kills the WHOLE run. An UNMEASURED
#     is a source we could not read: it stops only that batch's segment, writes a zero_read_unmeasured outcome row per
#     affected user, pages #clio_devops the same minute, and every other family continues on its own read (ruling B).
# The 2 h after-the-fact sample: every apply's ledger id range is appended to $STATE/samples.jsonl (family, segment,
# ledger ids, 5 rendered bodies dir) for flows-verify v1's 2-hourly read of 10 sends per family; v1 stops the tick by
# writing the same kill file.
# Claim families (claim-status, claim-proof-ask; Fable 10-30): the list is the claim lane's (c2) latest
# $CLAIM_LIST (the claim runners refuse a list older than 30 h and keep every claim gate). The claim families run
# FIRST on every day, inside their own CLAIM_GROUP_BUDGET_S slice ([key=claims-never-starved]).
# Outputs per tick: $OUT_ROOT/<UTC stamp>/ (outcomes JSON, check output, 5 bodies per family+segment, the log).
# Exit: 0 ran (or killed/disabled cleanly), 1 a step failed (the OTHER family groups still ran; the tick fails at the end),
# 2 bad config. A family failure ends the tick at once only for the UNMEASURED bar (the gate is slow, every family behind
# it would stall the same way), the TICK_HARD_S deadline, a failed or partial apply (rows may already be sent - the
# post-send rails own it) and an auto-kill. A census read that fails (owing/receipts) is UNMEASURED, logged, and never
# cancels the tick.
set -uo pipefail

# r5 NO-GO @184803d6 / captain [key=unattended]: every GATE input of this unattended timer is a CONSTANT - the kill-file
# and state locations, the ledger (sent counts, budgets), the policy (caps), the fraud lens, the spike threshold, the
# per-tick caps, the day-of-week, the interpreter and every gate script (runner, builders, health, zero-read). The ONE
# seam is the bats harness: with BATS_TEST_TMPDIR set to a directory (bats sets it for every test) the CVO_* test values
# are read; anywhere else no CVO_* / HYDRA_ROOT / PY_BIN environment variable moves anything. Only where the reports land
# (CVO_OUT_ROOT) may move. `--print-config` prints what this run would read, then exits (the test hook).
if [ -n "${BATS_TEST_TMPDIR:-}" ] && [ -d "${BATS_TEST_TMPDIR}" ]; then CVO_HARNESS=1; else CVO_HARNESS=0; fi
cfg() { # <env name> <constant>: the constant - or, under the bats harness only, the test value
  if [ "$CVO_HARNESS" = 1 ]; then local n="$1"; printf '%s' "${!n:-$2}"; else printf '%s' "$2"; fi
}
HYDRA_ROOT="$(cfg HYDRA_ROOT /opt/hydra)"
ETC="$(cfg CVO_ETC /etc/hydra)"
KILL="$ETC/credit-verify-outbound.disabled"
LIVE_FLAG="$ETC/credit-verify-outbound.live"
PAID_FLAG="$ETC/credit-verify-outbound.paid-enabled"
EXCLUDE="$ETC/credit-verify-outbound.exclude"
STATE="$(cfg CVO_STATE /var/lib/hydra/credit-verify-outbound)"
# QA #1541: a durable fallback kill file - if /etc/hydra cannot take the kill file (read-only, full), the auto-kill
# writes here, and every check honours both
KILL2="$STATE/credit-verify-outbound.disabled"
OUT_ROOT="${CVO_OUT_ROOT:-/root/h2-runs/sched}"   # reports only: never a gate input
PY="$(cfg PY_BIN python3)"
RUNNER="$(cfg CVO_RUNNER "$HYDRA_ROOT/scripts/credit-review.py")"
NEED_RUNNER="$(cfg CVO_NEED_RUNNER "$HYDRA_ROOT/scripts/credit_review/need_asks.py")"   # proof-need-ask (E): build + send
OWING="$(cfg CVO_OWING "$HYDRA_ROOT/scripts/credit_review/owing_proof.py")"
RECEIPTS="$(cfg CVO_RECEIPTS "$HYDRA_ROOT/scripts/credit_review/receipts.py")"
HEALTH="$(cfg CVO_HEALTH "$HYDRA_ROOT/scripts/paid-status/health_check.py")"
ZERO_READ="$(cfg CVO_ZERO_READ "$HYDRA_ROOT/scripts/credit_verify/zero_read.py")"   # n1's durable zero-read (#1545)
DEPLOYED_SHA_FILE="$(cfg CVO_DEPLOYED_SHA "$HYDRA_ROOT/.deployed-sha")"   # p1 579: named in every tick artefact
JUDGE="$(cfg CVO_JUDGE "$HYDRA_ROOT/scripts/credit-batch-judge.py")"   # b1 / t01b's batch judge (#1591): SHADOW only here
FRAUD="$(cfg CVO_FRAUD "")"   # a fraud re-check stub <ledger> <lo> <hi> (tests only); otherwise the lens inline below
MAIN_ENV="$(cfg CVO_MAIN_ENV /etc/openclaw/main.env)"
LEDGER="$(cfg CVO_LEDGER /var/lib/hydra/credit-review/ledger.sqlite3)"
SCRIPTS_DIR="$(cfg CVO_SCRIPTS "$HYDRA_ROOT/scripts")"   # credit_review.uvn_status: the runner's own segment record
RD_SCAN="$(cfg CVO_RD_SCAN "$SCRIPTS_DIR/credit_review/reply_due_scan.py")"   # h2's reply_due audience builder
RD_CAP="$(cfg CVO_RD_CAP 100)"
# QA #1574 (Important): the reply_due scan's send-time check is ~35 s per user and it ran UNBOUNDED from this timer -
# the measured 379 due users under a mostly-HELD audience is ~3.7 h against the tick's 6,900 s. The scan takes a
# per-run check budget and a wall clock, and walks ONE page of its audience; the cursor in $STATE starts the next
# tick where this one stopped, so a head of persistently held users is walked PAST, never re-checked for ever.
RD_CHECKS="$(cfg CVO_RD_CHECKS 400)"; RD_BUDGET="$(cfg CVO_RD_BUDGET 900)"
POLICY="$(cfg CVO_POLICY "$HYDRA_ROOT/policies/credit-verify-outbound.json")"
CLAIM_LIST="$(cfg CVO_CLAIM_LIST "$STATE/claim-list.json")"
CAP="$(cfg CVO_CAP 250)"                 # users per family+segment per tick (l1: 250/run)
R1_CAP="$(cfg CVO_R1_CAP 250)"
# uvn-reminder-14 (captain 2026-11-13 15:08Z): the one reminder of a sent uvn-status ask. R14_CAP is the family's cap
# per TICK across paid + free together (SHARED_TICK_CAP below), paid first; R14_ENTRIES is the page it walks per
# segment (its list is already cut to the people the ledger says are due, so a short page fills the cap).
# The cap rises only by PR, on evidence (three clean ticks): constants, never env or a state file.
R14_CAP="$(cfg CVO_R14_CAP 50)"
R14_ENTRIES="$(cfg CVO_R14_ENTRIES 100)"
# uvn-new-rows (ask-never-asked-r1, firstmate 2026-11-14 22:48Z): the follow-up ask to a user we already asked, about
# owed requests no ask named (the owing builder's uvn_new_rows class). NR_CAP is the family's cap per TICK across paid
# + free together (SHARED_TICK_CAP below), paid first. It is LOW on purpose: the family has never sent, and the first
# runs must be small enough to read and judge before it scales. NR_ENTRIES is the page it walks per segment.
# The cap rises only by PR, on the evidence of those runs: constants, never env or a state file.
NR_CAP="$(cfg CVO_NR_CAP 5)"
NR_ENTRIES="$(cfg CVO_NR_ENTRIES 100)"
# proof-refusal (captain 2026-11-15): the note that tells a person why the document they sent did not verify a credit
# and what would. PR_RUNNER builds its list from the proof reviewer's rejected rows and sends through the gate.
# PR_CAP is the family's cap per TICK across paid + free together (SHARED_TICK_CAP below), paid first: one run sends at
# most 100, and the next run starts only after the read-back of every note sent so far (refusal_families).
# PR_ENTRIES is the page it walks per segment. The cap rises only by PR: constants, never env or a state file.
PR_RUNNER="$(cfg CVO_PR_RUNNER "$HYDRA_ROOT/scripts/credit_review/proof_refusal.py")"
PR_CAP="$(cfg CVO_PR_CAP 100)"
PR_ENTRIES="$(cfg CVO_PR_ENTRIES 100)"
CLAIM_CAP="$(cfg CVO_CLAIM_CAP 250)"
REFUSAL_SPIKE="$(cfg CVO_REFUSAL_SPIKE 0.20)"
FIRST_CAP=100                          # [key=scale-now]: a family's first unsigned ticks, until v1's 10-sample line
# p1 22:0xZ / 519, b1 518, QA #1587: a live-gate check costs ~6-15 s a user (10-31), and the 20:00Z dry tick ran past
# 22:00Z holding the lock, so the 22:00Z tick exited. A tick had to end inside its 2 h cadence.
# Since 2026-11-13 the cron is HOURLY and the two deadlines below were NOT shortened with it (cutting them is how
# nothing was sent on 2026-11-11, see [key=tick-deadline-fits-the-send]): a tick may run up to TICK_HARD_S, past the
# next fire, which then meets the held lock and exits in one line. A tick longer than an hour costs that one fire,
# never an overlap, and the fire after it runs - so a day never holds fewer ticks than the 2-hourly cron gave it.
# The per-family SIZE is the family cap (FIRST_CAP before v1's date, the full cap after - #1596 runs read-only checks
# on 4 workers); the TIME is bounded at every step by a hard deadline:
#  - no NEW family after TICK_BUDGET_S, and none whose worst case (check + bodies = 2 x cap x CHECK_S_PER_USER, plus
#    RESERVE_PAD_S) does not fit before TICK_HARD_S;
#  - the bodies are skipped once TICK_HARD_S is passed; the apply is cut to what fits before it at APPLY_S_PER_USER.
TICK_BUDGET_S="$(cfg CVO_TICK_BUDGET_S 6000)"
TICK_HARD_S="$(cfg CVO_TICK_HARD_S 6900)"
# [key=claims-never-starved] (2026-11-12): the group that runs LAST only runs if the groups before it leave time. From
# 2026-11-07 04:25Z to 2026-11-12 17:22Z the ledger holds no claim row at all, for THREE reasons in turn (tick.log):
# through 11-12 04:35Z every tick skipped the group at `list_signed_on_stale` (nothing rebuilt the list on the deployed
# head until #1903's timer); at 06:00Z the group was reached and not armed; and at 08:00Z, armed, it was never reached -
# the weekday order ran the credit families first, they used the whole TICK_BUDGET_S (18 uvn-status sends in 5,400 s)
# and all four claim segments logged "tick budget 6000s reached". Only the last is this script's own doing, and it is
# the one that recurs on every slow credit tick. The claim families are the CHEAP group - measured 11 min for all four
# with a 19-send apply (16:33Z tick), 15 min check-only (06:00Z) - so they run first on every day and are held to their
# own slice: once the claim group has used CLAIM_GROUP_BUDGET_S it starts no new claim family, and the family IN
# FLIGHT is bounded by it too (QA on #1919: a slice only checked before a family starts can be overrun by one slow
# check or apply) - its read-only steps stop at the slice's end, and its apply is handed the seconds left and starts
# no user past them (see step_end / py_ro). So it can never do to the credit families what the credit families did to
# it. What may still run past the slice is never a new send: a user whose send outruns its own worst case (the loop
# starts only one whose worst case fits), and that apply's own post-send read-backs. This is ORDER and TIME only - the caps, the arming rows, the
# one-message-per-stage ledger rule and the gate are untouched.
CLAIM_GROUP_BUDGET_S="$(cfg CVO_CLAIM_GROUP_BUDGET_S 1500)"
# A family that is not reached is counted per family in $STATE/starved-<family>-<segment> and, when ARMED, paged on its
# STARVED_PAGE_AT-th consecutive unreached tick and again every STARVED_REPAGE_EVERY ticks: "armed" must never again be
# indistinguishable from "running". Both count TICKS, so on the hourly cron (2026-11-13) they are 2 h and 12 h of wall
# clock, where they were 4 h and 24 h; the numbers were not changed with the schedule.
STARVED_PAGE_AT="$(cfg CVO_STARVED_PAGE_AT 2)"
STARVED_REPAGE_EVERY="$(cfg CVO_STARVED_REPAGE_EVERY 12)"
# spec-deploy-lock-deferral-m1 (Fable 2026-11-05 12:4xZ + addenda 14:3xZ/14:4xZ): a TRANSIENT condition is not a
# terminal failure of the run. Three ticks in one day lost the claim families (the only family with a real send queue)
# because an earlier family's failure ended the tick before claim_families() ran. The two transient classes are:
#   - a deploy holds /var/lib/hydra/credit-review/apply.lock EXCLUSIVE for its whole sync -> the runner exits 3 with
#     NOTHING attempted (the ledger's max(id) is unchanged);
#   - Trino answers "under too much load ... please retry" -> the runner exits 4 (verify_notify.TrinoTransientError).
# Both are retried bounded and then DEFERRED: no kill file, no refusal-ratio operand, no cursor move. A family that
# defers returns 2, the group stops there, the tick CONTINUES to the next group and exits 2 at the end.
APPLY_LOCK_RC=3
# QA #1799 r11: the marker credit-review.py prints on stderr ONLY when the apply lock is genuinely held/unopenable.
# Kept in step with verify_notify.APPLY_LOCK_MARKER by scripts/tests/credit-verify-outbound.bats.
APPLY_LOCK_MARKER="APPLY_LOCK_HELD"
# QA #1799 r12: a lock that could not be OPENED is a permissions/I-O fault, never contention - its own marker, so the
# tick can stop hard instead of retrying and deferring a broken lock as if a deploy held it.
APPLY_LOCK_UNOPENABLE_MARKER="APPLY_LOCK_UNOPENABLE"                        # credit-review.py: ApplyLockError (nothing sent)
TRANSIENT_RC=4                         # credit-review.py: TrinoTransientError (nothing sent)
# The schedules are constants; the bats harness may shrink them (cfg is harness-only) so the arms run in seconds.
read -r -a APPLY_RETRY_SLEEPS <<<"$(cfg CVO_APPLY_RETRY_SLEEPS '15 30 60 60 120')"   # 6 apply attempts, ~4.75 min
APPLY_RETRY_CAP_S="$(cfg CVO_APPLY_RETRY_CAP_S 600)"   # hard cap from the first transient rc, whatever the budget
read -r -a TRANSIENT_RETRY_SLEEPS <<<"$(cfg CVO_TRANSIENT_RETRY_SLEEPS '30 60 120')"  # 4 read-only attempts
DEFERRED=0                             # 1 once any family deferred: the tick then exits 2, never 0
# [key=walk-size] (2026-11-13): the page a PAGED family (uvn-status, reply-due, r1, wait-apology, proof-need-ask,
# uvn-reminder-14) walks
# per tick, in LIST ENTRIES that still need a live-gate check (p1 599 / r5 598). The page is what sets how many notes a
# tick sends, and CVO_CAP is not: the cap bounds ACCEPTS (250, and the policy tick_cap holds uvn-status free at 60),
# but a tick can only accept from the entries it walked. Reported from run.log 2026-11-13 01:10:23Z: 200 walked, 15
# sendable, 15 notes sent, 2,319 not walked - about 7.5% of a page is sendable, so "15-17 a run" was the page size,
# never a ceiling.
# THREE knobs, because the families are not alike ([key=send-page-per-family], 2026-11-13, corrects #1928):
#   CHECK_ENTRIES      (200) - every paged family.
#   CHECK_ENTRIES_SEND (600) - the ONE family that sends the notes: uvn-status free (see page_entries()).
#   NR_ENTRIES         (100) - uvn-new-rows paid and free (ask-never-asked-r1): two more 100-entry families ahead of
#                              the sending family, each 1,100 s at its worst; they start no family when nobody is listed.
#   R14_ENTRIES        (100) - uvn-reminder-14 paid and free (verif-reask-14d-r1): its list is already cut to the
#                              people the ledger says are due, so a short page fills its 50-a-tick cap. It runs
#                              BEFORE the sending family, i.e. ahead of it, like the four below.
# #1928 raised the one global knob 200 -> 600. Four paged families run AHEAD of uvn-status free (reply-due paid and
# free, uvn-status paid, r1 paid), so each of them walked up to three times as far, and each second they spent started
# the sending family later - where [key=tick-budget-page-fit] cuts its page. The larger page made the family it was
# for start later on a smaller page. It belongs to that family and to nothing else.
#   Deadline, per family: worst = 2 x max(page, cap) x CHECK_S_PER_USER + RESERVE_PAD_S.
#     the sending family: 2 x 600 x 4 + 300 = 5,100 s against TICK_HARD_S 6,900 s (SEND_WORST_S below): 1,800 s to
#       spare. The largest send page that fits a tick ALONE is 825 (2 x 825 x 4 + 300 = 6,900).
#     a 200-entry family: 2 x 200 x 4 + 300 = 1,900 s (2,300 s where its cap is the full 250, since the walk is
#       max(page, cap)); a 100-entry one (the reminder): 2 x 100 x 4 + 300 = 1,100 s.
#   Deadline, the mixed case: the families that ALWAYS run ahead (reply-due paid and free, uvn-status paid, r1 paid at
#   200; uvn-reminder-14 paid and free at 100, and it starts no family at all when nobody is due) at their worst cost
#   4 x (2 x 200 x 4) + 2 x (2 x 100 x 4) = 8,000 s, and the sending family's own check + bodies
#   2 x 600 x 4 = 4,800 s: 12,800 s against 6,900 s. wait-apology paid and free
#   run ahead too whenever a paid-status plan exists for the day, so it is UP TO EIGHT: 11,200 s ahead and 16,000 s
#   mixed - worse, never better.
#   THAT DOES NOT FIT, and it did not fit at 200 either (5 x 1,600 = 8,000 s). With those always-present families ahead
#   (6,900 - 8,000 - 300) is already negative, so the send page cuts to PAGE_FLOOR and the family waits; it was 25
#   entries while the four 200-entry families were the only ones ahead. So 600 is the most the sending family walks,
#   never what it is promised:
#   family() CUTS its page to (TICK_HARD_S - elapsed - RESERVE_PAD_S) / (2 x CHECK_S_PER_USER) whenever it starts
#   more than 1,800 s into the tick. What this knob changes is that the families ahead no longer start it later than
#   they did at 200. How many notes a tick sends is read from run.log after deploy, not derived from a ratio.
#   Cost, on the sending family only: the check and the bodies each walk the page, so its read-only gate calls go from
#   at most 400 to at most 1,200 a tick; and the runner's unmeasured stop is a SHARE of the page (max(5, 10%)), so a
#   full page stops at 60 unmeasured users where it stopped at 20 - a slow gate is noticed three times later there.
#   No deadline, budget, cap or stop RULE moves with any of the three numbers.
#   Revert: set CHECK_ENTRIES_SEND to 200 here, and in the bats cases that name 600 as the shipped send page.
CHECK_ENTRIES="$(cfg CVO_CHECK_ENTRIES 200)"
CHECK_ENTRIES_SEND="$(cfg CVO_CHECK_ENTRIES_SEND 600)"
# page_entries <family> <segment> <subcommand>: the page this paged family walks. Decided from the family's OWN
# arguments - the same name and segment that key its cursor, its arming row and its policy tick_cap - never from where
# the call sits in credit_families(), so reordering the families cannot move the larger page onto another one.
# reply-due also runs the uvn-status subcommand on the free segment; it is not the sending family, so the NAME decides.
page_entries() {
  if [ "$1" = uvn-status ] && [ "$2" = free ] && [ "$3" = uvn-status ]; then echo "$CHECK_ENTRIES_SEND"
  elif [ "$1" = uvn-reminder-14 ]; then echo "$R14_ENTRIES"
  elif [ "$1" = uvn-new-rows ]; then echo "$NR_ENTRIES"
  elif [ "$1" = proof-refusal ]; then echo "$PR_ENTRIES"
  else echo "$CHECK_ENTRIES"; fi
}
# [key=tick-budget-page-fit] (2026-11-11): the smallest page a paged family will still run with. A page that does not
# fit before TICK_HARD_S is CUT to what fits (see family()); below this floor the setup cost is not worth the walk, so
# the family waits for the next tick instead. This is a floor, never a target - it does not raise a page.
PAGE_FLOOR="$(cfg CVO_PAGE_FLOOR 20)"
CHECK_S_PER_USER="$(cfg CVO_CHECK_S_PER_USER 4)"   # ~10-15 s a live-gate check on 4 read-only workers (#1596)
RESERVE_PAD_S="$(cfg CVO_RESERVE_PAD_S 300)"      # + the replica read (~86 s) and the health / zero-read rails
# [key=note-step-timeout] / [key=note-step-budget] (d2 r5 750, amended by Fable 753): TWO numbers, not one.
#   APPLY_S_PER_USER  - the EXPECTED cost of one user (a note step measured at ~40 s). It sizes the apply:
#                       fit = remaining x APPLY_WORKERS / 40, i.e. ~990 users a tick for a 6,600 s remainder at 6.
#   APPLY_USER_WORST_S - the WORST case one user can cost: the note step's retry budget in
#                       scripts/credit_review/verify_notify.py, NOTE_ATTEMPTS x NOTE_TIMEOUT_S + sum(NOTE_BACKOFF_S)
#                       = 3 x 55 + 35 = 200 s. It is NOT the sizing number (fit = remaining / 200 cut throughput 3x to
#                       budget a 1-in-80 event); instead the runner's send loop refuses to START a user whose worst case
#                       would not fit the share we hand it (--apply-budget-s), so one slow user overruns by at most one
#                       retry budget. Change a number here, change the other side's.
#   APPLY_WORKERS     - how many note steps run at once (verify_notify.APPLY_WORKERS, bounded at 6). The workers run
#                       concurrently, so the WALL-CLOCK worst case is still one retry budget, not APPLY_WORKERS of them;
#                       that is why the budget guard stays `spent + 200 > share` and only the SIZING multiplies by it.
#                       Raise it only after measuring what the admin API sustains.
APPLY_S_PER_USER="$(cfg CVO_APPLY_S_PER_USER 40)"
APPLY_USER_WORST_S="$(cfg CVO_APPLY_USER_WORST_S 200)"
APPLY_WORKERS="$(cfg CVO_APPLY_WORKERS 6)"
TICK_ELAPSED0="$(cfg CVO_TICK_ELAPSED0 0)"     # bats only: the tick started this many seconds ago
# How long a lock holder may have run before a fire that meets it calls it STALE: longer than TICK_HARD_S allows any
# tick. It was named for the cadence while the cron was 2-hourly; the cron is hourly now and this is not the cadence.
TICK_STALE_S=7200
TIMEOUT_BIN="$(cfg CVO_TIMEOUT_BIN /usr/bin/timeout)"   # QA #1587: every stage of a started family runs under the deadline
# The READER alarm for the armed claim-proof-ask family (p1 rule 8 / QA #1758 Important 1 / driver 17:5xZ). The 30h
# freshness gate refuses NEW asks when the daily code check is stale; it says nothing about the asks already out, whose
# replies then go unread with no page. These are the alarm's own knobs, never a send's: the limit matches
# claim_proof_ask.DAILY_CHECK_MAX_AGE_H, the unread window is a day (the class's own dwell), and the repeat is 6h so a
# reader that stays down is not a page every tick (24 a day on the hourly cron) but is never silent (model-chain's
# watchdog precedent).
CLAIM_PROOF_STATE="$(cfg CVO_CLAIM_PROOF_STATE /var/lib/claim-proof-check)"
CLAIM_PROOF_LIMIT_H="$(cfg CVO_CLAIM_PROOF_LIMIT_H 30)"
CLAIM_PROOF_UNREAD_H="$(cfg CVO_CLAIM_PROOF_UNREAD_H 24)"
CLAIM_PROOF_REPEAT_MIN="$(cfg CVO_CLAIM_PROOF_REPEAT_MIN 360)"
# [key=scale-now] FINAL (Fable + p1 + r5, 10-31 17:5xZ): a family APPLIES on this unattended timer only from the date
# p1's read-back line set for it HERE - its first batch read back clean (ledger sent set == the check-recipients
# would-send set, health + zero-read clean). Unset = SIGNED-only: the tick still checks it and writes its bodies,
# but never applies it (a signed batch goes by hand). FULL_CAP_FROM = v1's 10-sample line: before it the family runs
# at FIRST_CAP, after it at its normal cap. Constants only - a date moves by PR, never by env or a state file.
declare -A UNSIGNED_FROM=(
  # wait-apology (fable d2 2026-11-05 / firstmate 772): a NEW customer-facing family. It stays SIGNED-only (checked,
  # never applied) until fable d2's GO is stamped here as the read-back date - the same ladder every family walked.
  [wait-apology]=""
  # uvn-reminder-14: the one reminder of a sent uvn-status ask, 14 days on, to a user who neither replied nor sent a
  # document. Dated by the captain's order itself (2026-11-13 15:08Z, "urgent!!! fix it scale it now" / "see it
  # through": yes on re-asking verification non-responders after 14 days), NOT by a read-back batch: that is the one
  # way this family differs from the ladder above, and it is why the three rails below are code rather than a date -
  #   1. no body of this campaign is sent without a SIGNED approve of its exact bytes (intercom-verify-request.sh
  #      holds an `observed` pass for this campaign; policies/outbound-copy-enforce.json lists it under `enforce`);
  #   2. R14_CAP (50) is ONE budget per tick across paid + free (SHARED_TICK_CAP), and policy tick_cap can only lower it;
  #   3. the audience is the ledger's rule (verify_ledger.reminder14_user_done), re-read at the peek and in the claim.
  # On node-8 the policy's armed_families row is what arms it (a row with no date clears this one).
  [uvn-reminder-14]="2026-11-13T15:08Z"
  # uvn-new-rows: dated by firstmate's instruction (2026-11-14 22:48Z, ask-never-asked-r1), after the outbound copy
  # gate approved all six bodies of the family's first dry run on the deployed head (the sign-off its sender lock
  # waited on). Not a read-back batch either, so the same three rails are code:
  #   1. no body is sent without a SIGNED approve of its exact bytes (the sender holds an `observed` pass for this
  #      campaign too; policies/outbound-copy-enforce.json lists it under `enforce`);
  #   2. NR_CAP (5) is ONE budget per tick across paid + free (SHARED_TICK_CAP), and policy tick_cap can only lower it;
  #   3. the audience is the ledger's rule (verify_ledger.new_rows_user_done): only a user with a SENT uvn-status ask.
  # On node-8 the policy's armed_families row is what arms it (a row with no date clears this one).
  [uvn-new-rows]="2026-11-14T22:48Z"
  # proof-refusal: dated by the reviewer's GO on its three rendered bodies (corr=208a8463f735ff45, 2026-11-15T13:41Z)
  # and the captain's instruction of the same day. Not a read-back batch, so the rails are code:
  #   1. no body is sent without a SIGNED approve of its exact bytes (the sender holds an `observed` pass for this
  #      campaign too; policies/outbound-copy-enforce.json lists it under `enforce`), judged as a class 2 message of
  #      policies/outbound-copy-rubric.md;
  #   2. PR_CAP (100) is ONE budget per tick across paid + free (SHARED_TICK_CAP), and policy tick_cap only lowers it;
  #   3. no run starts until every note the campaign has sent reads back: sent = claimed, 0 hard bounces, 0 spam
  #      complaints (refusal_families; a read that cannot be made sends nothing either).
  # On node-8 the policy's armed_families row is what arms it (a row with no date clears this one).
  [proof-refusal]="2026-11-15T13:41Z"
  [uvn-status]="2026-10-31T18:02Z"     # AE-send-3: 3/3 = would-send 3, health + zero-read clean (h2 18:05Z, n1 465)
  [status-team-review]="2026-10-31T08:20Z"   # /k-ap 7: 7/7 = the signed set, health + zero-read clean (not a timer family yet)
  [claim-status]="2026-10-31T17:55Z"   # c2 batch 5 FREE 250: ledger 5763-6052 == the checked/signed 250, health + zero-read clean (p1 488)
  # status-doc-received (r1): the receipts class - "we have the document, it is in the queue", which claims nothing
  # about the credit, approves nothing and asks for nothing. Armed here on p1's measured read-back (r1-readback-1103.md
  # §6, re-measured by p1 at 13:00Z, not taken from the sending lane's report): 2 sends on the deployed head a1e93182,
  # ledger 7073 (marlondisal02@gmail.com) + 7074 (bruehwilermarc@gmail.com), status=sent with NO reason, no user with
  # two rows that day, zero-read verdict OK (stops/reported/unmeasured all empty), and +60 health api x6 / worker x3 at
  # 1/1 with 0 restarts. The date is the FIRST send of that batch, so the class is live from the moment the deploy
  # carries this line. It is paced by the SHARED first-batch budget below (r5 19:06Z): at most FIRST_CAP=100 people
  # per tick ACROSS paid + free, paid first - so arming it makes the 443 free rows sendable AT ALL (before this line
  # the free segment was SIGNED-only and every one of them needed a hand-sent batch), never 200 in one tick.
  [status-doc-received]="2026-11-03T12:56Z"
  # claim-proof-ask: the ask that carries the claimant's own MUSO code. Armed on p1's measured read-back (p1 262),
  # not on the sending lane's report: b19 free-ask 17/17 rc=0 against the b19 list signed 6b643ed7, on the script
  # deployed at that moment - the SAME sha, because the guard below refuses a list whose signed_on is not the deployed
  # head (:955-958), so "the list signed 6b643ed7" and "the deployed tree then" are one statement, not two.
  # ledger 7105-7121 = exactly
  # 17 rows, campaign claim-proof-ask, every one status=sent with NO reason, first 18:58:17Z and last 19:02:36Z - so the
  # date is the FIRST SEND of that batch (18:58Z), the same convention as claim-status (ledger 5763-6052) and
  # status-doc-received. The b20 dry run of 2026-11-04 (42 would-send: 41 free + 1 paid) is NOT the evidence and is not
  # dated here: it never sent, and a date must be the first send of a batch that actually went out.
  # KNOWN EXCEPTION, CLOSED BY THIS PR: the alarm spec's item 8 says no date is written on a class whose reader has
  # no alarm. When this date was written (2026-11-03) no alarm existed on this class's reader - the daily code check,
  # where nothing paged on a stale daily_check - and it was armed anyway because that reader is coupled STRUCTURALLY,
  # not by monitoring: claim_proof_ask.py:70 DAILY_CHECK_MAX_AGE_H = 30 and load_list(require_daily_check=True)
  # refuses the WHOLE list when the check is stale or unnamed, so the asks stop within 30h of the check stopping.
  # THE ALARM NOW EXISTS: claim_proof_check_alarm() above (scripts/claim-proof-check-watchdog.py) pages when that
  # reader's heartbeat or its newest digest goes stale, when a digest names no asks, and when an ask goes unread past
  # its window - and it runs ABOVE the kill gate, so the tick that stops the sender still pages about the reader. The
  # residual harm this exception stated ("an ask sent while the check is fresh, the check then dies, that claimant
  # reaches their close day with the code never read, and nobody is paged") is now paged instead of owed.
  # THE COUPLING IS THIS FAMILY'S ONLY - do not reuse the exception: claim-STATUS calls load_list with
  # require_daily_check=False (claim_proof_ask.py:455), so the status family is NOT tied to the daily check and this
  # rule-8 exception says nothing about it.
  # WHAT THE VALUE DOES: `unsigned` holds this date string and is read only for PRESENCE (`[ -z "$unsigned" ]`), and
  # reached() has already parsed it as %Y-%m-%dT%H:%MZ - so any past stamp arms the family identically, and the stamp's
  # only further job is to tell the next reader which batch justified the arming.
  # PULL-CONDITIONS, in advance: if DAILY_CHECK_MAX_AGE_H is ever raised above 30, or if the close path can close a
  # claim without a code read, this date comes off and the family returns to SIGNED-only (fail-closed, not fail-silent).
  [claim-proof-ask]="2026-11-03T18:58Z"
  # proof-need-ask (E): UNSET (p1 555). First clean coded batch 2026-11-01T03:19:09Z (c2 E batch 1: 3 sent == signed,
  # +60 health + zero-read clean), but it needed two hand-applied /l2 rules (180-d filing, roles) not yet in the
  # renderer - it is dated only from a clean batch on the deployed /l2 renderer
)
# a SUB-class inside a family: uvn-status:c2 = the asks that carry the /c2 correction (class C). Until it is armed the
# uvn-status family passes --no-correction and the gate defers them (check == send).
# [key=class-c-is-a-row] It has no date in this file and is armed ONLY by its own armed_families row
# ("uvn-status:c2": {live, paid, unsigned_from}), per segment: see c2_args. Why a row and not a constant: on
# 2026-11-13 the gate's first answer for 949 of the 3,251 users on the uvn-status list was DEFERRED c2_signed_only,
# and no row could say otherwise (read_arming refused the key as malformed), so sending them took a code change and
# a deploy. "never sent yet" was also no longer true: 390 /c2 asks went on 2026-11-01 (ledger 6338-6994) and 50 of
# them carry a returned document. data/rapid-verif-final-h3/report.md has both measurements.
declare -A FULL_CAP_FROM=()
# bats only (cfg reads env only under the harness): one dated full-cap entry "family=ISO" to test a REACHED date
FULL_CAP_FROM_TEST="$(cfg CVO_FULL_CAP_FROM_TEST "")"
[ -z "$FULL_CAP_FROM_TEST" ] || FULL_CAP_FROM["${FULL_CAP_FROM_TEST%%=*}"]="${FULL_CAP_FROM_TEST#*=}"
# FirstMate ruling 2 (3 Nov, AMENDED 2026-11-11 by the captain - [key=paid-need-ask-no-barrier]): the missing-document
# ask (proof-need-ask) goes to FREE users first. Its PAID segment runs when this date is UNSET (no barrier) or ALREADY
# REACHED; a FUTURE date here holds it until that date. Independent of .paid-enabled. The row is still the sequencing
# lever and the file is still the only place it moves: constants only, never env or a state file.
# [key=family]=ISO, same format as above. (Before the amendment an unset row meant "never", because reached("") is false,
# so the paid family could never run and paid users were never asked.)
declare -A PAID_FROM=()
# bats only (same seam as FULL_CAP_FROM_TEST): one dated entry "family=ISO" to test a REACHED / future paid date
PAID_FROM_TEST="$(cfg CVO_PAID_FROM_TEST "")"
[ -z "$PAID_FROM_TEST" ] || PAID_FROM["${PAID_FROM_TEST%%=*}"]="${PAID_FROM_TEST#*=}"
# r5 19:06Z ruling on #1671 (relayed by p1 718): a newly armed family's first batch is ONE budget for the whole tick,
# not one per segment. Paid and free share the template, the wording, the judge, the row-scoped gate and the ledger
# semantics, so a copy defect hits whichever people received it - a second hundred buys no new information about the
# render, it only doubles the number of people who experience a defect the first hundred would have shown.
# A family LISTED here with an EMPTY date runs every tick on ONE shared FIRST_CAP across all of its segments, charged
# by the ledger's own count of each apply's sends (FIRST_SPENT), in the order credit_families() calls them - PAID FIRST,
# free takes the remainder, and a future third segment can only take what is left (never a fresh 100). The ramp, each
# step a dated line written here by PR after its evidence, never a silent step:
#   1. listed, no date        -> SHARED FIRST_CAP (100) per tick across all segments
#   2. PER_SEGMENT_FROM dated -> FIRST_CAP (100) PER SEGMENT per tick (after the first clean monitored tick)
#   3. FULL_CAP_FROM dated    -> the family's own cap (R1_CAP 250) per segment (after a full monitored day with
#                                intake-junk = 0 and no gate-refusal spike)
declare -A PER_SEGMENT_FROM=(
  [status-doc-received]=""   # r1: SHARED 100 per tick, paid first (r5 19:06Z); dated only after the first clean monitored tick
)
# bats only: one "family=ISO" entry to test a REACHED per-segment date
PER_SEGMENT_FROM_TEST="$(cfg CVO_PER_SEGMENT_FROM_TEST "")"
[ -z "$PER_SEGMENT_FROM_TEST" ] || PER_SEGMENT_FROM["${PER_SEGMENT_FROM_TEST%%=*}"]="${PER_SEGMENT_FROM_TEST#*=}"
declare -A FIRST_SPENT=()   # this tick's sends per shared-first family (the ledger's count, never a runner's prose)
# A family listed here has ONE budget per tick across all of its segments, for as long as it is listed (FIRST_CAP's
# shape, with the family's own number and no ramp): charged by the ledger's count of each apply's sends (TICK_SPENT),
# in the order credit_families() calls the segments - paid first, free takes what is left.
declare -A SHARED_TICK_CAP=( [uvn-reminder-14]="$R14_CAP" [uvn-new-rows]="$NR_CAP" [proof-refusal]="$PR_CAP" )
declare -A TICK_SPENT=()
# the bats harness only (cfg's seam): every family unsigned at its full cap, so the family tests exercise the applies
UNSIGNED_ALL="$(cfg CVO_UNSIGNED_ALL 0)"
NOW_EPOCH="$(cfg CVO_NOW_EPOCH "$(date -u +%s)")"   # harness-only clock for the date boundaries
# QA #1587: a dated constant counts only once its UTC time has PASSED (equal = passed); a future or unparseable date
# is not yet - the family stays signed-only / at the first cap
reached() { # <YYYY-MM-DDTHH:MMZ | YYYY-MM-DDTHH:MM:SSZ>
  # QA #1648 (the same defect, one file over): this read ONLY the minute form while every other date reader in the repo
  # takes both. A date written with seconds - which is what a copied ledger timestamp looks like - parsed as
  # ValueError, exited 1, and the family sat SILENTLY SIGNED-only with nothing logged: the exact failure the gate's
  # `reached()` was fixed for, and the same rule applies - one reader for every form the writers produce.
  [ -n "$1" ] || return 1
  py - "$1" "$NOW_EPOCH" <<'PY'
import sys
from datetime import datetime, timezone
# QA #1648 finding 3: read_arming() accepts BOTH the minute form and the seconds form, but this parser accepted only the
# minute form - so a row dated "2026-11-03T15:00:30Z" validated, logged as a valid armed policy, and then never applied
# (reached() failed, silently), with no malformed page. One validator and one reader, or the pair lies.
FORMS = ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%MZ")
t = None
for fmt in FORMS:
    try:
        t = datetime.strptime(sys.argv[1], fmt).replace(tzinfo=timezone.utc).timestamp()
        break
    except ValueError:
        continue
if t is None:
    sys.exit(1)
sys.exit(0 if t <= int(sys.argv[2]) else 1)
PY
}
if [ "${1:-}" = "--print-config" ]; then
  for v in CVO_HARNESS HYDRA_ROOT KILL KILL2 LIVE_FLAG PAID_FLAG EXCLUDE STATE PY RUNNER OWING RECEIPTS HEALTH ZERO_READ \
           FRAUD MAIN_ENV LEDGER SCRIPTS_DIR RD_SCAN RD_CAP RD_CHECKS RD_BUDGET POLICY CLAIM_LIST CAP R1_CAP CLAIM_CAP REFUSAL_SPIKE NEED_RUNNER FIRST_CAP R14_CAP R14_ENTRIES NR_CAP NR_ENTRIES PR_RUNNER PR_CAP PR_ENTRIES UNSIGNED_ALL NOW_EPOCH JUDGE DEPLOYED_SHA_FILE CHECK_ENTRIES CHECK_ENTRIES_SEND PAGE_FLOOR TICK_BUDGET_S TICK_HARD_S CLAIM_GROUP_BUDGET_S STARVED_PAGE_AT STARVED_REPAGE_EVERY CHECK_S_PER_USER RESERVE_PAD_S APPLY_S_PER_USER APPLY_USER_WORST_S APPLY_WORKERS TICK_ELAPSED0 FULL_CAP_FROM_TEST PER_SEGMENT_FROM_TEST PAID_FROM_TEST TIMEOUT_BIN \
           CLAIM_PROOF_STATE CLAIM_PROOF_LIMIT_H CLAIM_PROOF_UNREAD_H CLAIM_PROOF_REPEAT_MIN; do
    printf '%s=%s\n' "$v" "${!v}"
  done
  exit 0
fi

STAMP="$(date -u +%Y%m%dT%H%MZ)"
TICK_T0="$(( $(date -u +%s) - TICK_ELAPSED0 ))"
OUT="$OUT_ROOT/$STAMP"
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$OUT/tick.log"; }
killed() { [ -e "$KILL" ] || [ -e "$KILL2" ]; }
# [key=nothing-sent-alert] (firstmate 2026-11-11, Fable ruling (c)): a family that stops with `NOTHING sent` used to leave
# one line in tick.log and nothing else. That is how 2026-11-11 survived a whole day: every tick from 09:2xZ logged
# `reply-due-paid check (rc=1): UVN STATUS (paid): NOTHING sent: the replica facts re-read failed (... timed out after
# 900 seconds); nothing sent.` and no human was ever told. Nothing about a send surface may fail quietly, so a rc=1 that
# names NOTHING sent is escalated here - an ALERT line with the family and the reason, plus a confirmed page. A page that
# could not be delivered is logged as its own ALERT line, so the tick.log record survives a dead Slack.
alert_nothing_sent() { # <tag> <outfile>: 0 and an ALERT when that stage says NOTHING sent
  local why
  why="$(grep -o 'NOTHING sent[^\"]*' "$2" 2>/dev/null | head -1)"
  [ -n "$why" ] || return 1
  log "ALERT: $1 sent NOTHING this tick: $(head -c 300 "$2")"
  page_confirmed "credit-verify-outbound $STAMP: ALERT: $1 sent NOTHING this tick - $why" \
    || log "ALERT (undelivered page, ${PAGE_WHY:-unknown}): $1 sent NOTHING this tick - $why"
  return 0
}
notify() { # <text>: 0 only when the notifier ACCEPTED it (missing notifier / a Slack failure = 1)
  # shellcheck source=/dev/null
  [ -r "$HYDRA_ROOT/scripts/lib/slack-notify.sh" ] && . "$HYDRA_ROOT/scripts/lib/slack-notify.sh" \
    && declare -F slack_notify_critical >/dev/null && slack_notify_critical "credit-verify-outbound: $*" >/dev/null 2>&1
}
page() { # best effort: the kill file is the guarantee, the page is the notice (call sites keep this contract)
  notify "$@" || { log "page not delivered: $*"; return 0; }
}
# [key=reader-alarm-delivered] (QA #1758 Important, second round): `notify` CANNOT report a failed page. Its last
# command is the lib's slack_notify_critical, and slack_notify ends `|| true` - "best effort, never fails the caller" -
# so `if notify ...` is TRUE even when Slack rejected the post or carried no credentials. The reader alarm may only
# start its repeat window on a page that was DELIVERED, so it asks the one function in the lib that returns 0 only on a
# confirmed post (slack_notify_payload_file_status), and treats an older lib without it as NOT delivered: the state line
# and the owed page are then retried next tick instead of being silenced for CLAIM_PROOF_REPEAT_MIN. Fails closed.
page_confirmed() { # <text>: 0 only when Slack CONFIRMED the post; 1 for a refusal, no credentials, or an older lib
  local helper="$HYDRA_ROOT/scripts/lib/slack-notify.sh" payload rc
  [ -r "$helper" ] || { PAGE_WHY="no $helper on this host"; return 1; }
  # shellcheck source=/dev/null
  . "$helper" || { PAGE_WHY="could not source $helper"; return 1; }
  declare -F slack_notify_payload_file_status >/dev/null \
    || { PAGE_WHY="$helper has no slack_notify_payload_file_status (delivery unknown)"; return 1; }
  payload="$(umask 077; mktemp "${TMPDIR:-/tmp}/cvo-page.XXXXXX")" || { PAGE_WHY="no temp file"; return 1; }
  # under the ONE deadline wrapper like every other python subprocess of the tick (b1 560, and the bats structural
  # test enforces it): a hung interpreter here must not hold the tick past TICK_HARD_S
  if ! py -c 'import json,sys; print(json.dumps({"channel": sys.argv[1], "text": sys.argv[2]}))' \
        "${SLACK_CHANNEL:-}" "<@${SLACK_UID_NICK:-}> <@${SLACK_UID_AARON:-}> $*" > "$payload"; then
    rm -f "$payload"; PAGE_WHY="could not build the payload"; return 1
  fi
  slack_notify_payload_file_status "$payload"; rc=$?
  rm -f "$payload"
  [ "$rc" = 0 ] || PAGE_WHY="Slack rejected the post (rc=$rc)"
  return "$rc"
}
# notify_confirmed <text>: 0 only when Slack CONFIRMED the post. `notify` cannot report a failed page (its last
# command is the lib's slack_notify_critical, and slack_notify ends `|| true`), so a caller that DEDUPES on a
# watermark must not use it: a marker written after a silent failure loses that page forever. This asks the lib's
# status-returning variant and treats an older lib without it as NOT delivered (fail closed). notify() itself is
# deliberately unchanged in this PR: making it accurate would also change the zero-read page path, which today
# never takes its "page not delivered -> persist a retry marker" branch - that is a real behaviour change and
# deserves its own PR and review (Fable driver 2026-11-05 15:51Z).
notify_confirmed() { # <text>: 0 only on a confirmed post; 1 for a refusal, no credentials, or an older lib
  local helper="$HYDRA_ROOT/scripts/lib/slack-notify.sh"
  [ -r "$helper" ] || { PAGE_WHY="no $helper on this host"; return 1; }
  # shellcheck source=/dev/null
  . "$helper" || { PAGE_WHY="could not source $helper"; return 1; }
  declare -F slack_notify_critical_status >/dev/null \
    || { PAGE_WHY="$helper has no slack_notify_critical_status (delivery unknown)"; return 1; }
  slack_notify_critical_status "credit-verify-outbound: $*" || { PAGE_WHY="Slack did not confirm the post"; return 1; }
}
elapsed() { echo $(( $(date -u +%s) - TICK_T0 )); }
# QA #1587: every subprocess of a started family runs under the deadline - `bounded` gives it the seconds left before
# TICK_HARD_S (at least 1) and SIGTERMs it there (SIGKILL 30 s later); rc 124/137 = it hit the deadline
bounded_to() { local end="$1"; shift; local left=$(( end - $(elapsed) )); [ "$left" -ge 1 ] || left=1
  "$TIMEOUT_BIN" --kill-after=30 "${left}s" "$@"; }
bounded() { bounded_to "$TICK_HARD_S" "$@"; }
deadline_rc() { [ "$1" = 124 ] || [ "$1" = 137 ]; }
# [key=claims-never-starved] (QA on #1919): a group slice bounds the work IN FLIGHT, not only the next family's start.
# Checked only before family() started, one slow claim check or apply could run to TICK_HARD_S and take the tick from
# the credit families - the same starvation, in the other direction. While a slice is in force (GROUP_END_S set):
#  - a READ-ONLY family step (check, bodies, the shadow judge) runs under the slice's end instead of TICK_HARD_S. It
#    has sent nothing, so stopping it costs only the time already spent; the family waits (not_reached), the tick
#    goes on to the next group. py_ro is for those steps ONLY;
#  - the APPLY is never killed at the slice (a kill mid-apply is a partial send): it is handed the seconds left in
#    the slice as --apply-budget-s, so the send loop starts no user whose worst case would not fit, and the user in
#    flight finishes. Everything after a send (health, zero-read, the fraud re-check) keeps TICK_HARD_S: a read-back
#    is never cut short to save time;
#  - a retry sleep (Trino transient, a held apply lock) must fit the slice as well as the tick budget.
GROUP_END_S=""   # empty = no group slice in force (0 is a real deadline: a slice that starts at second 0)
SLICE_CUT=0      # 1 = the slice ended this family's work before its apply began (family() keeps its not-reached count)
FAMILY_REACHED=0
step_end() { if [ -n "$GROUP_END_S" ] && [ "$GROUP_END_S" -lt "$TICK_HARD_S" ]; then echo "$GROUP_END_S"; else echo "$TICK_HARD_S"; fi; }
slice_spent() { [ -n "$GROUP_END_S" ] && [ "$(elapsed)" -ge "$GROUP_END_S" ]; }
py_ro() { bounded_to "$(step_end)" "$PY" "$@"; }
# Defect A (Fable d2): the runner stops a batch LOUDLY only at unmeasured_users >= max(5, 10% of the batch) and writes
# the reason into the outcome file (`stopped_on_unmeasured`). The tick reads that field - never a string match on the
# summary. [key=family-unmeasured-stop] (firstmate 037, 2026-11-16): that stop ends THAT FAMILY, never the tick. It
# used to end the whole tick ("the gate is slow, every family behind it would stall the same way"), and from 04:00Z
# on 2026-11-16 every tick ended at uvn-status-free's or -paid's bar before proof-need-ask, whose check had not run
# since. A family behind it does not stall blind: it has its OWN bar, so a gate that really is slow stops each later
# family after at most max(5, 10% of its batch) unmeasured users, and TICK_HARD_S still ends the tick. Nothing is
# sent past a bar (it is a read-only check), the family is recorded failed and the tick still exits 1 at the end.
# TICK_ENDS=1 marks the outcomes that DO end the tick for run_group below: the deadline and a failed apply.
TICK_ENDS=0
unmeasured_bar_hit() { # <outcomes json>: 0 iff the runner recorded an UNMEASURED STOP in it
  [ -s "$1" ] || return 1
  py -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("stopped_on_unmeasured") else 1)' "$1" 2>/dev/null
}
unmeasured_summary() { # <outcomes json>: "unmeasured N / bar B" for tick.log (Defect A ruling (3): printed in tick.log too)
  py -c 'import json,sys; d=json.load(open(sys.argv[1])); print("unmeasured %s / bar %s (%s)" % (d.get("unmeasured_users", "?"), d.get("unmeasured_stop_at", "?"), d.get("unmeasured_stop_rule", "")))' "$1" 2>/dev/null || echo "unmeasured ? (outcome file unreadable)"
}
# b1 560: EVERY python subprocess of the tick - builders, filters, cap reads, checks, renders, the judge, the apply and
# the post-send health / ledger / zero-read reads - runs under the one deadline wrapper; no exceptions
py() { bounded "$PY" "$@"; }
# run_transient <tag> <what> <outfile> <cmd...>: run ONE read-only step, retrying a TRANSIENT rc (Trino said "retry in a
# few minutes") TRANSIENT_RETRY_SLEEPS apart, never past the tick budget. Sets RC to the step's own rc. Returns 0 = the
# step ran (RC is its verdict), 2 = DEFERRED (transient after the window: no kill file, no refusal, no cursor move).
RC=0
run_transient() {
  local tag="$1" what="$2" out="$3"; shift 3
  local attempt=0 wait left cost t0
  while :; do
    t0="$(date -u +%s)"
    "$@" > "$out" 2>&1; RC=$?
    cost=$(( $(date -u +%s) - t0 ))
    [ "$RC" = "$TRANSIENT_RC" ] || return 0
    if [ "$attempt" -ge "${#TRANSIENT_RETRY_SLEEPS[@]}" ] || [ "$(elapsed)" -ge "$TICK_BUDGET_S" ] || slice_spent; then
      log "$tag: $what deferred - Trino is transiently unavailable (rc=$RC after $attempt retries); this family and the rest of the tick defer to the next tick (no kill file, no refusal, no cursor move)"
      page "$tag: $what deferred - Trino transiently unavailable; nothing was sent and nothing was refused"
      return 2
    fi
    # QA #1799 r13 (Important): the sleep is clipped to the remaining tick BUDGET, not the hard deadline. A transient
    # arriving just under TICK_BUDGET_S used to sleep past it, and every later family then skipped on its own budget
    # check - recreating exactly the starvation this PR exists to prevent. A retry that does not FIT is not a retry:
    # defer now, so the rest of the tick still has the budget it was promised.
    # QA #1799 r14 (Important): `wait > left` let a retry that only just fits through, and ignored the cost of the
    # retry itself. Sleeping `wait` and then running the step AGAIN lands at elapsed + wait + cost, which is past the
    # budget whenever wait == left, and past it by the step's own duration even when wait < left. Require the WHOLE
    # retry - the sleep plus a repeat of the attempt we just measured - to finish strictly inside the budget.
    left=$(( TICK_BUDGET_S - $(elapsed) ))
    # [key=claims-never-starved]: inside a group slice the retry must fit the slice too
    if [ -n "$GROUP_END_S" ] && [ $(( GROUP_END_S - $(elapsed) )) -lt "$left" ]; then left=$(( GROUP_END_S - $(elapsed) )); fi
    wait="${TRANSIENT_RETRY_SLEEPS[$attempt]}"
    if [ "$left" -le 0 ] || [ "$(( wait + cost ))" -ge "$left" ]; then
      log "$tag: $what deferred - a ${wait}s retry does not fit in the ${left}s left of the ${TICK_BUDGET_S}s budget (the step itself just took ${cost}s, so the retry would finish at or past it); this family and the rest of the tick defer to the next tick (no kill file, no refusal, no cursor move)"
      page "$tag: $what deferred - Trino transiently unavailable and no retry fits the tick budget; nothing was sent and nothing was refused"
      return 2
    fi
    attempt=$(( attempt + 1 ))
    log "$tag: $what Trino transient (rc=$RC); retry $attempt/${#TRANSIENT_RETRY_SLEEPS[@]} in ${wait}s"
    [ "$wait" -ge 1 ] && sleep "$wait"
  done
}
# THE READER ALARM - defined and INVOKED above the kill gate on purpose. A kill file stops the SENDER; a stale reader
# is exactly when the asks already out stop being read, so the one tick that must still page about the reader is the one
# that then exits. Claim-proof-ask may carry a date only because this is live (p1 rule 8); it is read-only, it writes a
# state line every run and pages when its verdict is an alarm, and it never changes this tick's rc or its own state.
claim_proof_check_alarm() {
  local out rc marker last now digest
  out="$(py "$SCRIPTS_DIR/claim-proof-check-watchdog.py" --state-dir "$CLAIM_PROOF_STATE" \
        --ledger "$LEDGER" --limit-h "$CLAIM_PROOF_LIMIT_H" --unread-h "$CLAIM_PROOF_UNREAD_H" 2>&1)"; rc=$?
  # the state line is written EVERY tick, page or not: a tick that cannot say what the reader did is not a healthy tick
  printf '%s rc=%s %s\n' "$(date -u +%FT%TZ)" "$rc" "$(printf '%s' "$out" | tr '\n' ' ')" \
    >> "$STATE/claim-proof-check-alarm.log" 2>/dev/null \
    || log "reader alarm: could not append to $STATE/claim-proof-check-alarm.log: $out"
  if [ "$rc" = 0 ]; then rm -f "$STATE/claim-proof-check.page" 2>/dev/null; return 0; fi
  # the harness never pages: CI has no Slack, and a harness tick's rc and output must stay deterministic. The one
  # exception is a test that has to prove the DELIVERY branch (a refused post must not start the repeat window), which
  # opts in and gets its answer from the fixture lib's slack_notify_payload_file_status.
  [ "${CVO_HARNESS:-0}" = 1 ] && [ "${CVO_ALARM_PAGE_IN_HARNESS:-0}" != 1 ] && return 0
  # repeat-limited, but a CHANGED verdict pages at once: a worsening state must not wait out the window.
  # The digest is the watchdog's own SIGNATURE line - the alarm categories plus the identity of each affected ask -
  # NOT a hash of the text: the text carries elapsed ages and counts, so it changed on every tick of an UNCHANGED
  # outage and made CLAIM_PROOF_REPEAT_MIN dead (QA #1758 Important 1: a persistent reader outage paged every two
  # hours despite a 360m window). An older watchdog with no SIGNATURE line still degrades to the text hash.
  marker="$STATE/claim-proof-check.page"
  digest="$(printf '%s\n' "$out" | sed -n 's/^SIGNATURE //p' | tail -1)"
  [ -n "$digest" ] || digest="$(printf '%s' "$out" | sha256sum | cut -c1-16)"
  last="$(cat "$marker" 2>/dev/null || true)"
  now="$(date -u +%s)"
  if [ "${last%% *}" = "$digest" ] && [ "$(( now - ${last##* } ))" -lt "$(( CLAIM_PROOF_REPEAT_MIN * 60 ))" ] 2>/dev/null; then
    log "reader alarm still open (same verdict paged $(( (now - ${last##* }) / 60 ))m ago, repeat ${CLAIM_PROOF_REPEAT_MIN}m): $out"
    return 0
  fi
  # the repeat window starts ONLY on a confirmed page: a failed page is stated and retried next tick, never swallowed.
  # The verdict is appended to the alarm's own log as well as logged: this runs ABOVE the kill gate and before $OUT
  # exists, so the tick log's tee can be the one thing missing when a page fails.
  if page_confirmed "$out"; then
    printf '%s %s\n' "$digest" "$now" > "$marker" 2>/dev/null || log "reader alarm: paged but could not record it in $marker"
    printf '%s page delivered (digest %s)\n' "$(date -u +%FT%TZ)" "$digest" >> "$STATE/claim-proof-check-alarm.log" 2>/dev/null || true
  else
    local why="${PAGE_WHY:-unknown}"
    log "PAGE NOT DELIVERED (reader alarm): $why; next tick pages it again: $out"
    printf '%s PAGE NOT DELIVERED (reader alarm): %s\n' "$(date -u +%FT%TZ)" "$why" \
      >> "$STATE/claim-proof-check-alarm.log" 2>/dev/null || true
  fi
  return 0
}
claim_proof_check_alarm

killed && { echo "$(date -u +%FT%TZ) credit-verify-outbound: kill file $KILL or $KILL2 present; nothing runs"; exit 0; }
# a tick that could not stop itself never starts: one of the two kill-file locations must be writable
{ { [ -d "$ETC" ] && [ -w "$ETC" ]; } || { [ -d "$STATE" ] && [ -w "$STATE" ]; } \
  || { [ ! -e "$STATE" ] && [ -d "$(dirname "$STATE")" ] && [ -w "$(dirname "$STATE")" ]; }; } \
  || { echo "$(date -u +%FT%TZ) credit-verify-outbound: neither $ETC nor $STATE is writable for a kill file; nothing runs" >&2; exit 2; }
install -d -m 700 "$STATE" "$OUT_ROOT" "$OUT" || exit 2
# [key=tick-deadline-fits-the-send] (2026-11-11): a deadline SHORTER than the send family's own worst case does not
# slow the tick down, it stops it sending - permanently and silently. `family()` refuses to start a family whose worst
# case (2 x walk x CHECK_S_PER_USER + RESERVE_PAD_S) does not fit before TICK_HARD_S, and uvn-status is the family that
# actually sends. On 2026-11-11 00:04Z TICK_BUDGET_S/TICK_HARD_S were cut 6000/6900 -> 1500/1700 on the server to fit a
# 30-minute cron: 1700 < 1900 (the worst case even at a 200-entry page, and 5100 at the sending family's 600-entry
# page), so uvn-status could never start. Every tick from 00:49Z ended "credit families: FAILED at the unmeasured bar, the
# deadline or a failed apply" with the ledger untouched; the last real acknowledgement was 2026-11-10T03:06:37Z.
# The gate itself is right (QA #1587) - a family that cannot finish must not start - so the defect is the NUMBER, and
# the one thing that must never happen is that it is wrong quietly. This is a page, not an exit: the other families
# still have work to do, and a tick that stops here would take them down with it.
# The page here is the SENDING family's (CHECK_ENTRIES_SEND, [key=send-page-per-family]): that is the family this
# guard is about, and its page is the larger of the two, so a deadline that fits it fits every 200-entry family too.
SEND_WALK=$(( CHECK_ENTRIES_SEND > CAP ? CHECK_ENTRIES_SEND : CAP ))
SEND_WORST_S=$(( 2 * SEND_WALK * CHECK_S_PER_USER + RESERVE_PAD_S ))
if [ "$TICK_HARD_S" -lt "$SEND_WORST_S" ]; then
  log "TICK DEADLINE TOO SHORT: TICK_HARD_S=${TICK_HARD_S}s cannot fit the send family's worst case ${SEND_WORST_S}s (2 x ${SEND_WALK} entries x ${CHECK_S_PER_USER}s + ${RESERVE_PAD_S}s pad). family() will refuse to start uvn-status on EVERY tick, so NOTHING will be sent. Raise CVO_TICK_HARD_S to at least ${SEND_WORST_S} (the shipped value is 6900)."
  # page_confirmed, not page: `page` delegates to notify(), whose last command is slack_notify_critical and whose
  # slack_notify ends `|| true`, so it reports success even when Slack rejected the post or carried no credentials.
  # A warning that cannot be delivered is the same silent failure this guard exists to end, so the undelivered case is
  # logged as its own line (QA #1882 Important 2) and the tick still runs - the other families have work to do.
  page_confirmed "credit-verify-outbound $STAMP: TICK DEADLINE TOO SHORT - TICK_HARD_S=${TICK_HARD_S}s < the send family's worst case ${SEND_WORST_S}s, so uvn-status can never start and NOTHING is sent. Raise CVO_TICK_HARD_S to >= ${SEND_WORST_S} (shipped: 6900)." \
    || log "page not delivered: TICK DEADLINE TOO SHORT (${PAGE_WHY:-unknown}); the tick.log line above is the only record of it"
fi
# autokill is defined HERE (before the tick lock) so the pre-lock ledger migration can use it: an
# unreadable/unmigratable ledger is an operational failure that must leave the durable kill file, exactly like the
# cap read that used to be the first thing to notice it.
autokill() { # <why>
  local where="$KILL"
  if ! printf 'auto-kill %s: %s\n' "$STAMP" "$1" > "$KILL" 2>/dev/null; then
    where="$KILL2"
    if ! printf 'auto-kill %s: %s\n' "$STAMP" "$1" > "$KILL2" 2>/dev/null; then
      log "AUTO-KILL: $1 - BOTH kill-file writes FAILED ($KILL, $KILL2); this tick stops here"
      page "AUTO-KILL $STAMP FAILED TO PERSIST: $1. Neither $KILL nor $KILL2 could be written - the next tick will refuse to start only if a location stays unwritable; a human must stop the timer now."
      exit 3
    fi
  fi
  log "AUTO-KILL: $1 (wrote $where)"
  page "AUTO-KILL $STAMP: $1. Nothing more runs until a human reads $OUT and removes $where."
}

# verify-outbound-migration-race-m1 (Fable 2026-11-05 12:2xZ): migrate the ledger ONCE, BEFORE the tick lock, so no
# reader can race a migration a family started mid-tick. At 11:49:02Z the live tick was mid-ALTER while another lane's
# read-only check ran: 89 FAILED "verify ledger needs a migration", rc=1, and the tick stopped with zero sends. The
# migration itself is now atomic (verify_ledger._migrate: one BEGIN IMMEDIATE), and this call makes the schema current
# before any family, check or apply runs. A ledger that cannot be migrated is not a ledger to send against: loud, stop.
py -c 'import sys; sys.path.insert(0, sys.argv[1]); from credit_review import verify_ledger; verify_ledger.connect(sys.argv[2]).close()' \
  "$SCRIPTS_DIR" "$LEDGER" || { autokill "ledger migration failed (the ledger cannot be opened or migrated); tick stops"; exit 1; }
exec 9>>"$STATE/tick.lock"
if ! flock -n 9; then
  # the measured reason (b1 518 / p1 519 (2)): who holds it and for how long. A held flock is a LIVE tick (it dies with its
  # holder), possibly mid-apply - so a tick held past TICK_STALE_S is logged STALE for a human, never killed or taken
  # over. Under the hourly cron a fire meeting a tick that is still inside its deadline is the ordinary case, not STALE.
  read -r hpid hstart < "$STATE/tick.holder" 2>/dev/null || { hpid="?"; hstart=""; }
  age=$(( $(date -u +%s) - ${hstart:-$(date -u +%s)} ))
  if [ "$age" -gt "$TICK_STALE_S" ]; then
    log "STALE: tick pid $hpid has held $STATE/tick.lock for ${age}s (> ${TICK_STALE_S}s, longer than any tick may run); this tick exits, nothing taken over"
  else
    log "another tick holds $STATE/tick.lock (pid $hpid, ${age}s); exit"
  fi
  exit 0
fi
printf '%s %s\n' "$$" "$(date -u +%s)" > "$STATE/tick.holder"
if [ -r "$MAIN_ENV" ]; then set -a; # shellcheck source=/dev/null
  . "$MAIN_ENV"; set +a; fi
LIVE=0; [ -e "$LIVE_FLAG" ] && LIVE=1
PAID_LIVE=0; [ "$LIVE" = 1 ] && [ -e "$PAID_FLAG" ] && PAID_LIVE=1
# QA #1541: no live send without the zero-read reader deployed - the tick runs DRY instead (and says so), never a first
# send that can only auto-kill.
# QA #1648 CRITICAL: this guard is SAFETY, so it is measured from the READER, never from the legacy live flag. Gating it
# on `LIVE=1` meant that under policy arming - where the legacy flag file may not exist at all - an armed row could
# apply with no zero-read reader deployed, i.e. the one send the whole guard exists to prevent.
ZR_MISSING=0
if [ ! -r "$ZERO_READ" ]; then
  LIVE=0; PAID_LIVE=0; ZR_MISSING=1
fi

[ "${ZR_MISSING:-0}" = 1 ] && { log "LIVE REFUSED: the zero-read reader $ZERO_READ is not deployed; this tick runs DRY"; page "live tick refused: $ZERO_READ missing (tick ran dry)"; }

# refusal spike of one apply's outcomes JSON: refused / (sent + refused) > REFUSAL_SPIKE.
# Prints exactly one of: ok | spike | unmeasured <why>.
# "unmeasured" exists because ABSENCE HAS NO RATIO (l1, 2026-11-04 15:05Z, in production): the free family applied,
# sent 39 real emails, then died inside the Intercom note with TimeoutExpired - so credit-review.py returned rc=1 and
# NEVER WROTE the outcomes artefact. The old spike() printed "unreadable", the caller accepted only "ok", and the tick
# killed with the label "refusal spike (> 0.20 of attempts refused)" - a statement about the world, when there was
# nothing to count. The kill was right (39 sends, no artefact = outcome_unknown, fail closed); the LABEL was false, and
# the label is the only part of an incident that a human still reads the next morning. An absent or unparseable
# artefact can yield neither a spike NOR a clean read: it is its own verdict, it stops the family, and it names the
# path it could not read so the next reader does not have to guess which file went missing.
spike() { # <outcomes json> <sent>
  py - "$1" "$2" "$REFUSAL_SPIKE" <<'PY'
import json, sys, os
path = sys.argv[1]
try:
    d = json.load(open(path))
except FileNotFoundError:
    print("unmeasured %s was never written (the apply did not reach its outcome write)" % path); sys.exit(0)
except (OSError, ValueError) as exc:
    print("unmeasured %s is unreadable (%s)" % (path, type(exc).__name__)); sys.exit(0)
o = d.get("outcomes", d) if isinstance(d, dict) else d
if not isinstance(o, list):
    print("unmeasured %s carries no outcomes list (got %s)" % (path, type(o).__name__)); sys.exit(0)
# [key=post-failed-unknown] (Fable driver 2026-11-05 02:2xZ): a row whose result is `post_failed` is an ATTEMPTED send
# whose outcome nobody can prove - the gate printed POST FAILED and left the row CLAIMED (scripts/intercom-verify-
# request.sh exits 5 for exactly this). It is neither a refusal (so it must never be counted into the refusal ratio,
# which would blame the users) nor a delivery. It is outcome-unknown, and unknown KILLS on its own terms, whatever the
# sent/refused ratio says: one note that may or may not have reached a customer is a stop, not a statistic.
post_failed = [x for x in o if str((x or {}).get("result", "")).startswith("post_failed")]
if post_failed:
    users = ", ".join(str((x or {}).get("user", "?")) for x in post_failed[:10])
    print("unmeasured %d post(s) with an UNKNOWN outcome (POST FAILED: attempted, and we cannot prove it was not "
          "delivered; users %s%s)" % (len(post_failed), users, ", ..." if len(post_failed) > 10 else "")); sys.exit(0)
refused = sum(1 for x in o if str(x.get("result", "")).startswith("refused"))
sent = int(sys.argv[2] or 0)
n = sent + refused
print("spike" if n >= 10 and refused / n > float(sys.argv[3]) else "ok")
PY
}

# zero_unmeasured <tag> <lo> <hi> <why> - Fable ruling 2026-11-03 (B): an UNMEASURED must NOT wedge the whole tick.
# It stops THAT batch's segment only: every affected user carries the zero-read verdict on their OWN outcome row in the
# batch's outcomes file (annotated where the row exists, appended where it does not, with the batch ref and the reason -
# so the batch's outcomes balance per user) and #clio_devops is paged the same minute. It stops THIS batch's segment,
# never the family: the next tick measures its own new rows normally (no persistent marker - a single uncorrelated
# notice must not wedge a family forever). The global kill file stays for STOP only: a STOP is an unexplained
# credit-class message and auto-kills the whole run.
zero_unmeasured() { # <tag> <lo> <hi> <why>
  local out
  out="$(py - "$OUT/$1-apply.json" "$LEDGER" "$2" "$3" "$1" "$4" <<'PY'
import json, sqlite3, sys
path, ledger, lo, hi, tag, why = sys.argv[1:7]
try:
    d = json.load(open(path))
except (OSError, ValueError):
    d = {}
rows = d.get("outcomes") if isinstance(d, dict) else None
if not isinstance(rows, list):
    rows = []
try:
    db = sqlite3.connect(f"file:{ledger}?mode=ro", uri=True)
    users = [str(r[0]) for r in db.execute(
        "SELECT DISTINCT account_id FROM verify_messages WHERE id > ? AND id <= ? "
        "AND status IN ('sent','attempted') AND account_id IS NOT NULL", (int(lo), int(hi)))]
    db.close()
except sqlite3.Error as e:
    print("unreadable ledger: %s" % e); sys.exit(3)
by_user = {}
for r in rows:
    if isinstance(r, dict) and r.get("user") is not None:
        by_user.setdefault(str(r["user"]), []).append(r)
annotated = appended = 0
for u in users:
    mine = by_user.get(u)
    if mine:
        for r in mine:                    # the user's own row carries the verdict; never a second row for them
            r["zero_read"] = "unmeasured"; r["zero_read_reason"] = why; r["zero_read_batch"] = tag
            r["zero_read_ledger"] = "%d-%d" % (int(lo) + 1, int(hi))
        annotated += 1
    else:
        rows.append({"user": u, "result": "zero_read_unmeasured", "reason": why, "batch": tag})
        appended += 1
if isinstance(d, dict):
    d["outcomes"] = rows
    d["zero_read"] = {"batch": tag, "ledger": "%d-%d" % (int(lo) + 1, int(hi)), "verdict": "UNMEASURED", "reason": why}
    json.dump(d, open(path, "w"), indent=1, sort_keys=True)
print("zero_read_unmeasured users %d (annotated %d, appended %d)" % (len(users), annotated, appended))
PY
)" || { echo "zero_unmeasured failed"; return 1; }
  echo "$out"
}

# room <campaign> <segment> <cap>: "<n> <daily>" - n = how many this apply may message today (r5 on #1541): min(cap, the
# policy's daily cap for the campaign+segment minus what the RUNNER recorded for that segment today, the SHARED daily
# cap of the campaign's group (credit / claim, m2) minus every message of that group in the ledger today). A pre-check
# only: the credit runner re-reads its segment record under its run lock before every send (--segment-daily-cap; QA
# #1541: atomic with the send, one segment source - the list's paid flag at send time, never the paying export); the
# claim runners keep their own daily maxima. Unreadable record / policy, or no policy row = 0 (fail closed).
room() {
  py - "$LEDGER" "$POLICY" "$1" "$2" "$3" "$SCRIPTS_DIR" <<'PY'
import datetime, json, sqlite3, sys
ledger, policy, campaign, seg, cap, scripts = sys.argv[1:7]
sys.path.insert(0, scripts)
try:
    from credit_review import uvn_status
    pol = json.load(open(policy))
    daily = int(pol["daily_cap"][campaign][seg])
    group = next(g for g, cs in pol["groups"].items() if campaign in cs)
    shared = int(pol["shared_daily_cap"][group])
    day = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    if group == "credit" and campaign not in ("proof-need-ask", "proof-refusal"):
        done = uvn_status.segment_used_today(ledger, campaign, seg, day)
    elif campaign in ("proof-need-ask", "proof-refusal"):
        # need_asks and proof_refusal keep no segment record: the campaign's own ledger rows today (both segments), so
        # a daily_cap row is the campaign's cap for the DAY, never one cap per segment
        done = sqlite3.connect(f"file:{ledger}?mode=ro", uri=True).execute(
            "SELECT count(*) FROM verify_messages WHERE day=? AND campaign=? AND status IN ('sent','attempted')",
            (day, campaign)).fetchone()[0]
    else:  # claim runners keep no segment record: count the campaign's ledger rows for the day (both segments)
        done = 0
    cs = pol["groups"][group]
    db = sqlite3.connect(f"file:{ledger}?mode=ro", uri=True)
    used = db.execute("SELECT count(*) FROM verify_messages WHERE day=? AND status IN ('sent','attempted') AND campaign IN (%s)"
                      % ",".join("?" * len(cs)), (day, *cs)).fetchone()[0]
except Exception as exc:  # noqa: BLE001 - QA #1541: a read problem is an ERROR (stop + page), never "cap reached"
    print("ERR", type(exc).__name__, str(exc)[:160].replace("\n", " ")); sys.exit(0)
print(max(0, min(int(cap), daily - done, shared - int(used))), daily, shared)
PY
}

# fraudhit <lo> <hi>: re-run the fraud lens on every account this apply sent to (ledger rows lo..hi, sent/attempted).
# Prints "ok", "hit <ids>" or "unreadable <why>". A held account that RECEIVED a message is the fraud hit (Fable 10-30).
fraudhit() {
  if [ -n "$FRAUD" ]; then py "$FRAUD" "$LEDGER" "$1" "$2" 2>&1 | tail -1; return 0; fi
  py - "$LEDGER" "$1" "$2" "$SCRIPTS_DIR" <<'PY'
import sqlite3, sys
ledger, lo, hi, scripts = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
sys.path.insert(0, scripts)
try:
    ids = sorted({int(a) for (a,) in sqlite3.connect(f"file:{ledger}?mode=ro", uri=True).execute(
        "SELECT DISTINCT account_id FROM verify_messages WHERE id > ? AND id <= ? AND status IN ('sent','attempted') "
        "AND account_id IS NOT NULL", (lo, hi)) if str(a).strip().isdigit()})
    if not ids:
        print("ok"); sys.exit(0)
    from credit_review import fraud_lens, verify_notify
    held = fraud_lens.split(ids, fraud_lens.default_lens(verify_notify.trino))["held"]
except Exception as exc:  # noqa: BLE001 - an unreadable lens after a send is a stop, never a pass
    print("unreadable", type(exc).__name__, str(exc)[:160]); sys.exit(0)
print("hit " + ",".join(str(h["user_id"]) for h in held) if held else "ok")
PY
}

# sample <tag> <lo> <hi>: the after-the-fact review pointer for flows-verify v1 (2-hourly, 10 sends per family)
sample() {   # returns non-zero when the pointer could not be written (QA #1541: never swallowed)
  printf '{"at":"%s","tick":"%s","family":"%s","ledger_ids":"%s-%s","bodies":"%s"}\n' \
    "$(date -u +%FT%TZ)" "$STAMP" "$1" "$(( $2 + 1 ))" "$3" "$OUT/$1-bodies" >> "$STATE/samples.jsonl" 2>/dev/null
}

maxid() { py -c 'import sqlite3,sys
try:
    print(sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True).execute("SELECT coalesce(max(id),0) FROM verify_messages").fetchone()[0])
except sqlite3.Error:
    print(-1)' "$LEDGER"; }

# family <name> <segment> <list file> <cap> <runner subcommand> <runner args...>:
#   check -> bodies -> (apply -> health -> spike -> fraud hit -> zero-read -> sample pointer)
# judge_shadow <tag>: the batch judge's items file from this family's rendered bodies - {user_id, body_html, facts (the
# renderer's own JSON object), copy_ref} per body - and, when the judge is deployed, its verdict in SHADOW: written and
# logged next to the batch, acting on NOTHING (p1 / r5: live only after the coverage set; the GO-or-no-apply rail is its
# own PR). A missing judge or a failed call is logged, never a stopped tick.
# p1 579 (the 08:00Z artefacts: claim-status free rendered 100 bodies, 13 accepted): the judge contract is
# items == would-send. accept_bodies keeps in <tag>-bodies ONLY the users in the check's ACCEPTED set (the runner's
# report.accepted, written by --outcomes-json); every other rendered body moves to <tag>-bodies-not-accepted. An
# unreadable check file or an accepted user with no rendered body stops the family (the sample IS the would-send set).
accept_bodies() {
  local tag="$1"
  py - "$OUT/$tag-check.json" "$OUT/$tag-bodies" "$OUT/$tag-bodies-not-accepted" <<'PY' >> "$OUT/tick.log" 2>&1
import glob, json, os, sys
chk, d, aside = sys.argv[1:4]
try:
    acc = {str(a.get("user")) for a in json.load(open(chk))["accepted"]}
except (OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
    print(f"accepted set unreadable from {chk}: {type(exc).__name__}"); sys.exit(1)
os.makedirs(aside, mode=0o700, exist_ok=True)
have, moved = set(), 0
for f in sorted(glob.glob(os.path.join(d, "*.txt"))):
    uid = os.path.basename(f)[:-4]
    if uid in acc:
        have.add(uid); continue
    for g in (f, f[:-4] + ".facts.json"):
        if os.path.exists(g):
            os.replace(g, os.path.join(aside, os.path.basename(g)))
    moved += 1
missing = sorted(acc - have)
print(f"bodies == accepted: {len(have)} kept, {moved} rendered but not accepted moved aside, {len(missing)} accepted without a body")
sys.exit(2 if missing else 3 if not acc else 0)      # 3 = the check accepted nobody (QA #1610: no apply)
PY
}

judge_shadow() {
  local tag="$1" items="$OUT/$1-items.jsonl"
  py - "$OUT/$tag-bodies" "$items" "$(cat "$DEPLOYED_SHA_FILE" 2>/dev/null)" <<'PY' >> "$OUT/tick.log" 2>&1 || { log "$tag: judge items not built"; return 0; }
import glob, json, os, sys
d, out, deployed = sys.argv[1:4]
n = 0
with open(out, "w") as fh:
    os.chmod(out, 0o600)
    for f in sorted(glob.glob(os.path.join(d, "*.txt"))):
        txt = open(f).read()
        head, _, rest = txt.partition("\n")
        try:
            body = json.loads(rest).get("body", "")
        except ValueError:
            body = ""
        ff = f[:-4] + ".facts.json"
        facts = json.load(open(ff)) if os.path.exists(ff) else None
        ref = next((w[5:] for w in head.split() if w.startswith("copy=")), "")
        fh.write(json.dumps({"user_id": os.path.basename(f)[:-4], "body_html": body, "facts": facts, "copy_ref": ref,
                             "deployed": deployed or None}) + "\n")
        n += 1
print(f"judge items: {n} bodies -> {out}")
PY
  if [ -r "$JUDGE" ]; then
    # the 10:00Z tick on 231d6c47: the deployed judge wants the batch's --copy-ref (rc=2 without it). One judge call
    # per copy ref in the items (a family renders one copy, but a mixed batch is split, never mislabelled)
    local ref refs
    refs="$(py -c 'import json,sys; print("\n".join(sorted({json.loads(l).get("copy_ref") or "" for l in open(sys.argv[1]) if l.strip()})))' "$items" 2>/dev/null)"
    : > "$OUT/$tag-judge.out"
    while IFS= read -r ref; do
      [ -n "$ref" ] || { log "$tag JUDGE CALL FAILED: an item has no copy_ref; not judged"; page "$tag: shadow judge not run - an item has no copy_ref"; continue; }
      py -c 'import json,sys; [sys.stdout.write(l) for l in open(sys.argv[1]) if l.strip() and json.loads(l).get("copy_ref") == sys.argv[2]]' \
        "$items" "$ref" > "$OUT/$tag-items-$ref.jsonl" 2>/dev/null
      local jrc jend; jend="$(step_end)"
      py_ro "$JUDGE" judge --items "$OUT/$tag-items-$ref.jsonl" --copy-ref "$ref" >> "$OUT/$tag-judge.out" 2>&1; jrc=$?
      # [key=claims-never-starved]: the shadow judge acts on nothing, so a group slice may end it - that is the slice
      # working, not a judge failure, and it is not paged as one (family() then starts no apply)
      if deadline_rc "$jrc" && [ "$jend" -lt "$TICK_HARD_S" ]; then
        log "$tag judge SHADOW copy=$ref stopped at the end of the group slice (acts on nothing)"; continue
      fi
      log "$tag judge SHADOW copy=$ref (rc=$jrc, acts on nothing): $(tail -c 300 "$OUT/$tag-judge.out")"
      # r5 596: a judge call that fails (argv, crash) is LOUD - logged as such and paged - never a silent shadow line;
      # it still acts on nothing (shadow)
      [ "$jrc" = 0 ] || { log "$tag JUDGE CALL FAILED (rc=$jrc) copy=$ref"; page "$tag: shadow judge call failed rc=$jrc (copy=$ref)"; }
    done <<<"$refs"
  else
    log "$tag judge: not deployed ($JUDGE); items written for the shadow read"
  fi
  return 0
}

# QA #1587 / b1 546: ONE cap rule - past the family's dated full-cap line its own cap, before it at most FIRST_CAP
family_cap() { # <family> <its cap>
  if [ "$UNSIGNED_ALL" = 1 ] || reached "${FULL_CAP_FROM[$1]:-}"; then echo "$2"
  elif [ "$2" -gt "$FIRST_CAP" ]; then echo "$FIRST_CAP"; else echo "$2"; fi
}
# Per-family per-tick cap (policy `tick_cap`). Prints the cap this family+segment may use, or "" to mean "no opinion,
# use what you were given". THREE rules, and the order matters:
#   1. no key for this family/segment            -> "" (no opinion; the existing cap stands untouched)
#   2. a readable integer, or a clamps-to list   -> the SMALLEST of the value and the cap handed in. This key can only
#      ever LOWER a cap: a policy value above the family's own cap is inert, so a typo in the policy can slow a family
#      down but can never widen its blast radius.
#   3. an UNREADABLE policy when a tick_cap key was expected -> the FLOOR (1). A cap that grows because a file could not
#      be parsed is the fail-open version of this control; 1 user is ugly and correct, and the log says so.
tick_cap_for() { # <family> <segment> <cap>
  local fam="$1" seg="$2" cap="$3" out
  # QA #1770 (2): the COMPARISON lives in Python, not in `[`. A JSON integer Bash cannot hold (9223372036854775808)
  # passed the type check, failed both Bash comparisons and was emitted AS the cap - a policy edit could RAISE a bound.
  # Python compares at arbitrary precision and prints only: "" (no opinion / inert), an integer in [1, cap), or a word.
  out="$(py - "$POLICY" "$fam" "$seg" "$cap" <<'PYC' 2>&1
import json, sys
path, fam, seg, cap = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
try:
    doc = json.load(open(path))
except Exception as exc:                                   # noqa: BLE001 - the caller decides, this only reports
    print("UNREADABLE %s" % type(exc).__name__); raise SystemExit(0)
if not isinstance(doc, dict) or "tick_cap" not in doc:
    raise SystemExit(0)                                   # rule 1: no key at all -> no opinion
tc = doc["tick_cap"]
if not isinstance(tc, dict):
    print("MALFORMED_TOP"); raise SystemExit(0)           # QA #1770 (1): PRESENT but not an object is not "absent"
if fam not in tc:
    raise SystemExit(0)                                   # rule 1: no opinion for this family
row = tc.get(fam)
if isinstance(row, dict):
    if seg not in row:
        raise SystemExit(0)                               # no opinion for this segment
    val = row[seg]
else:
    val = row                                          # a plain number applies to every segment
if not isinstance(val, int) or isinstance(val, bool) or val < 0:
    print("MALFORMED"); raise SystemExit(0)
if val >= cap:
    raise SystemExit(0)                                   # rule 2: never widen - a value at or above the cap is inert
print(max(val, 1))                                     # 0 is the floor (1): --max-users 0 is not "nobody"
PYC
)"
  # NOTE the `>&2`: log() TEES to stdout as well as $OUT/tick.log, so a diagnostic written from inside a $( ) capture
  # becomes part of the captured VALUE. That is exactly how this control would have failed open - "2026-… tick_cap: …
  # \n1" is not a number, and the arithmetic test that follows it is not a comparison any more. Diagnostics go to
  # stderr (still tee'd into the tick log), and stdout carries the answer alone.
  case "$out" in
    "") return 0 ;;                                       # rule 1
    UNREADABLE*) log "tick_cap: the policy $POLICY could not be read ($out) - holding $fam/$seg at 1 user, not at $cap" >&2
                 echo 1; return 0 ;;
    MALFORMED_TOP) log "tick_cap: the policy's top-level tick_cap is present but not an object - holding $fam/$seg at 1 user (every capped family reads this key)" >&2
                 echo 1; return 0 ;;
    MALFORMED) log "tick_cap: policy tick_cap[$fam][$seg] is not a non-negative integer - holding $fam/$seg at 1 user" >&2
                 echo 1; return 0 ;;
    *[!0-9]*) log "tick_cap: unexpected policy answer '$out' for $fam/$seg - holding it at 1 user" >&2
                 echo 1; return 0 ;;
  esac
  # belt to Python's braces: the answer is 1..9 digits and below the cap, or this function has a bug and holds at 1
  if [ "${#out}" -gt 9 ] || [ "$out" -ge "$cap" ] || [ "$out" -lt 1 ]; then
    log "tick_cap: the policy reader answered '$out' against cap $cap for $fam/$seg, which it must never do - holding it at 1 user" >&2
    echo 1; return 0
  fi
  echo "$out"
}

# r5 19:06Z: is <family> on the SHARED first-batch budget this tick? Listed in PER_SEGMENT_FROM, its per-segment date
# not reached, and not past its full-cap line (a full-cap family is never pulled back to a shared 100)
shared_first() { # <family>
  [ "$UNSIGNED_ALL" = 1 ] && return 1
  [[ -v PER_SEGMENT_FROM[$1] ]] || return 1
  reached "${PER_SEGMENT_FROM[$1]}" && return 1
  reached "${FULL_CAP_FROM[$1]:-}" && return 1
  return 0
}

# QA #1612: the next page's first entry from a run's own page record ({start, end, listed}; end = the first entry that
# run did not get to), wrapping to 0 at the list's end. Non-zero rc = no page record.
page_next() { py -c 'import json,sys; p=json.load(open(sys.argv[1])).get("page") or {}; e,n=int(p["end"]),int(p["listed"]); print(e if e < n else 0)' "$1" 2>/dev/null; }
# QA r5 #1574 finding 1 (round 2): `family` returns 0 for several things that are NOT completion - the tick budget was
# reached, its worst case did not fit, the family is SIGNED-only, the daily cap is spent. Those return 0 because they are
# outcomes, not failures, so a caller cannot tell them from a finished page by the exit code. This marker can: it is
# written ONLY at the points where the family's step for this page is genuinely done (nothing left to do this tick).
completed() { : > "$OUT/$1.done" 2>/dev/null || true; }

advance_cursor() { # <tag> <cursor file> <run's outcomes json> <this tick's start>; the paged families only (a cursor file)
  [ -n "$2" ] || return 0
  local nxt; nxt="$(page_next "$3")" || { log "$1: no page record in $(basename "$3"); the cursor stays at $4"; return 0; }
  printf '%s\n' "$nxt" > "$2.tmp" && mv -f "$2.tmp" "$2"
  log "$1 page: entries from $4 this tick; next tick starts at $nxt"
}

# [key=claims-never-starved]: <tag> <family> <segment> <why>. The one place a family is told to wait for TIME (the tick
# budget, the claim group's slice, a worst case that does not fit). It logs the wait with the running count, and pages
# an ARMED family that has now gone unreached STARVED_PAGE_AT ticks in a row - a family nothing reaches sends nothing,
# and until this existed only somebody reading tick.log could tell. The page marker is written on a CONFIRMED delivery
# only, so an undelivered page is owed again next tick; a family that is reached clears both files.
not_reached() {
  local tag="$1" name="$2" seg="$3" why="$4" f="$STATE/starved-$1" n last
  n="$(cat "$f" 2>/dev/null)"; [[ "$n" =~ ^[0-9]{1,6}$ ]] || n=0
  n=$(( n + 1 ))
  { printf '%s\n' "$n" > "$f.tmp" && mv -f "$f.tmp" "$f"; } 2>/dev/null || true
  log "$tag: $why; this family waits for the next tick (not reached on $n consecutive tick(s))"
  [ "$n" -ge "$STARVED_PAGE_AT" ] || return 0
  [ "$(family_armed "$name" "$seg")" = 1 ] || return 0   # the same key family() arms on
  last="$(cat "$f.paged" 2>/dev/null)"; [[ "$last" =~ ^[0-9]{1,6}$ ]] || last=0
  if [ "$last" -gt 0 ] && [ "$last" -le "$n" ] && [ $(( n - last )) -lt "$STARVED_REPAGE_EVERY" ]; then return 0; fi
  if notify_confirmed "$tag is ARMED but was NOT REACHED on $n consecutive ticks ($why) - it has sent nothing in that time"; then
    { printf '%s\n' "$n" > "$f.paged.tmp" && mv -f "$f.paged.tmp" "$f.paged"; } 2>/dev/null || true
  else
    log "$tag: not-reached page NOT DELIVERED (${PAGE_WHY:-unknown}); owed again next tick"
  fi
}
# <tag> <family> <segment> <where>: the group slice ended this family's work before its apply began. Nothing was sent,
# so it is the same fact as never having been started and is counted (and, for an armed family, paged) the same way.
slice_cut() {
  SLICE_CUT=1
  not_reached "$1" "$2" "$3" "the claim group's own slice (${CLAIM_GROUP_BUDGET_S}s) ended $4"
}
# family <family> <segment> <list> <cap> <subcommand> [runner args]: one family's step for this tick (family_run), and
# the ONE place its not-reached count starts over - only when it was reached AND the slice did not end it before its
# apply. Clearing at the moment a family starts would let one whose check outlasts the slice on every tick send
# nothing for ever and never be counted.
family() {
  local tag="$1-$2" rc
  FAMILY_REACHED=0; SLICE_CUT=0
  family_run "$@"; rc=$?
  if [ "$FAMILY_REACHED" = 1 ] && [ "$SLICE_CUT" = 0 ]; then
    rm -f "$STATE/starved-$tag" "$STATE/starved-$tag.paged" 2>/dev/null || true
  fi
  return "$rc"
}
family_run() {
  local name="$1" seg="$2" list="$3" cap="$4" sub="$5"; shift 5
  local tag="$name-$seg" rc
  killed && { log "$tag: kill file present; stop"; return 1; }
  if [ "$(elapsed)" -ge "$TICK_BUDGET_S" ]; then
    not_reached "$tag" "$name" "$seg" "tick budget ${TICK_BUDGET_S}s reached"; return 0
  fi
  if [ -n "$GROUP_END_S" ] && [ "$(elapsed)" -ge "$GROUP_END_S" ]; then
    not_reached "$tag" "$name" "$seg" "the claim group's own slice (${CLAIM_GROUP_BUDGET_S}s) is used"; return 0
  fi

  [ -s "$list" ] || { log "$tag: empty audience; skipped"; return 0; }
  local excl=(); [ "$sub" = uvn-status ] && excl=("${EXCL_ARGS[@]}")
  # p1 599 / r5 598 (the 10:00Z check walked all 4,172 entries for an hour): the uvn runner's walk is paged by LIST
  # ENTRIES - the check, the bodies and the apply walk the same page (--max-users caps accepts only)
  # QA #1612: the page ROTATES - a per-family cursor in $STATE (the next page's first entry), advanced from the check's
  # own page record right after a clean check, wrapping to 0 at the list's end; so persistent deferrals at the head
  # never starve the rest. The check, bodies and apply of one tick walk the SAME page (the value read here).
  local cur_file="" cur=0 paged=0
  # r5 639 / p1 638: the proof-need-ask family (need_asks) pages the same way (it ran unpaged for 85+ min at 16:20Z)
  { [ "$sub" = uvn-status ] || [ "$sub" = need-send ] || [ "$sub" = refusal-send ]; } && paged=1
  if [ "$paged" = 1 ]; then
    cur_file="$STATE/cursor-$tag"
    cur="$(cat "$cur_file" 2>/dev/null || echo 0)"; [[ "$cur" =~ ^[0-9]{1,9}$ ]] || cur=0
  fi
  # [key=send-page-per-family]: this family's own page - CHECK_ENTRIES_SEND for uvn-status free, CHECK_ENTRIES for
  # every other paged family. Read HERE, before need-send rewrites $sub below.
  local page=0; [ "$paged" = 1 ] && page="$(page_entries "$name" "$seg" "$sub")"
  local pg=(); [ "$paged" = 1 ] && pg=(--max-entries "$page" --start-entry "$cur")
  local runner="$RUNNER"; if [ "$sub" = need-send ]; then runner="$NEED_RUNNER"; sub=send; fi
  if [ "$sub" = refusal-send ]; then runner="$PR_RUNNER"; sub=send; fi
  # [key=scale-now]: the family's unsigned date (unset = SIGNED-only) and its cap before v1's 10-sample line
  local fam="$name"; [ "$name" = r1 ] && fam=status-doc-received
  local unsigned=""
  reached "${UNSIGNED_FROM[$fam]:-}" && unsigned="${UNSIGNED_FROM[$fam]}"
  [ "$UNSIGNED_ALL" = 1 ] && unsigned=harness
  cap="$(family_cap "$fam" "$cap")"
  # per-FAMILY per-tick cap (policy tick_cap, 2026-11-04): a clamp that only ever LOWERS what the lines above allow.
  # Why this exists as its own key: CVO_CAP (an env knob) is ONE value for every family+segment, so using it to slow the
  # free uvn-status batch to 60 would also have slowed r1, claim-status AND c2's approved 70-send claim install. A knob
  # that cannot name one family is not a knob, it is a change to all of them. Absent key = exactly today's behaviour;
  # a value the policy cannot be read for CLAMPS TO THE FLOOR rather than silently widening, because the one thing a
  # cap must never do on a read failure is get bigger.
  local tc; tc="$(tick_cap_for "$fam" "$seg" "$cap")"
  if [ -n "$tc" ] && [ "$tc" != "$cap" ]; then
    log "$tag: per-family tick cap: policy tick_cap[$fam][$seg] holds this segment at $tc (it would otherwise have taken $cap)"
    cap="$tc"
  fi
  if [[ -v SHARED_TICK_CAP[$fam] ]]; then
    local tleft=$(( ${SHARED_TICK_CAP[$fam]} - ${TICK_SPENT[$fam]:-0} ))
    if [ "$tleft" -le 0 ]; then
      log "$tag: the per-tick budget for $fam (${SHARED_TICK_CAP[$fam]}/tick across all segments) was spent by an earlier segment (${TICK_SPENT[$fam]:-0} sent); this segment waits for the next tick"
      return 0
    fi
    if [ "$tleft" -lt "$cap" ]; then
      log "$tag: per-tick budget for $fam: $tleft of ${SHARED_TICK_CAP[$fam]} left this tick (${TICK_SPENT[$fam]:-0} sent by earlier segments); cap $tleft"
      cap="$tleft"
    fi
  fi
  local shared=0
  if shared_first "$fam"; then
    shared=1
    local left=$(( FIRST_CAP - ${FIRST_SPENT[$fam]:-0} ))
    if [ "$left" -le 0 ]; then
      log "$tag: the shared first-batch budget for $fam (${FIRST_CAP}/tick across all segments, r5 19:06Z) was spent by an earlier segment (${FIRST_SPENT[$fam]:-0} sent); this segment waits for the next tick"
      return 0
    fi
    [ "$left" -lt "$cap" ] && cap="$left"
    log "$tag: shared first-batch budget for $fam: $left of ${FIRST_CAP} left this tick (${FIRST_SPENT[$fam]:-0} sent by earlier segments); cap $cap"
  fi
  local walk="$cap"; [ "$paged" = 1 ] && [ "$page" -gt "$cap" ] && walk="$page"
  local worst=$(( 2 * walk * CHECK_S_PER_USER + RESERVE_PAD_S ))
  if [ $(( $(elapsed) + worst )) -gt "$TICK_HARD_S" ]; then
    # [key=tick-budget-page-fit] (2026-11-11): a paged family's worst case is 2 x max(cap, its page) x
    # CHECK_S_PER_USER + RESERVE_PAD_S, so the PAGE SIZE - a throughput knob - decided whether the family ran AT ALL.
    # On node-8 a live CHECK_ENTRIES=600 (one knob for every family then) made that estimate 5,100 s; the tick reaches uvn-status ~4,000 s in (the builders and
    # reply-due run first), so 4,000 + 5,100 > 6,900 and EVERY family was skipped on EVERY tick: the tick never reached
    # a send, and raising the page size made it worse. A page that does not fit is now CUT to what fits instead of the
    # family being dropped - the walk still starts at the same cursor and the cursor still advances from the check's own
    # page record, so a smaller page is a SLOWER page, never a skipped one.
    if [ "$paged" = 1 ]; then
      local fit=$(( (TICK_HARD_S - $(elapsed) - RESERVE_PAD_S) / (2 * CHECK_S_PER_USER) ))
      if [ "$fit" -ge "$PAGE_FLOOR" ] && [ "$fit" -lt "$walk" ]; then
        log "$tag: page cut from $walk to $fit entries (what fits before the ${TICK_HARD_S}s deadline); the family runs"
        walk="$fit"
        pg=(--max-entries "$walk" --start-entry "$cur")
        worst=$(( 2 * walk * CHECK_S_PER_USER + RESERVE_PAD_S ))
      fi
    fi
  fi
  if [ $(( $(elapsed) + worst )) -gt "$TICK_HARD_S" ]; then
    not_reached "$tag" "$name" "$seg" "$(elapsed)s into the tick and its worst case is ${worst}s (cap $cap); it does not fit before the ${TICK_HARD_S}s deadline"
    return 0
  fi
  FAMILY_REACHED=1   # family() clears the not-reached count on the way out, unless the slice ends this run first
  local s_end; s_end="$(step_end)"   # what bounds this family's read-only steps: the slice's end, or TICK_HARD_S
  run_transient "$tag" check "$OUT/$tag-check.out" \
    py_ro "$runner" "$sub" --list "$list" --segment "$seg" "$@" "${excl[@]}" "${pg[@]}" --mode dry-run --max-users "$cap" \
    --check-recipients --outcomes-json "$OUT/$tag-check.json"; rc=$?
  [ "$rc" = 2 ] && return 2
  rc="$RC"
  log "$tag check (rc=$rc): $(head -c 600 "$OUT/$tag-check.out")"
  if deadline_rc "$rc" && [ "$s_end" -lt "$TICK_HARD_S" ]; then
    slice_cut "$tag" "$name" "$seg" "during its check (read-only, stopped; nothing was sent)"; return 0
  fi
  if deadline_rc "$rc"; then log "$tag: check hit the ${TICK_HARD_S}s deadline (read-only, stopped); the tick ends"; TICK_ENDS=1; return 1; fi
  [ -s "$OUT/$tag-check.json" ] && log "$tag check: $(unmeasured_summary "$OUT/$tag-check.json")"
  if unmeasured_bar_hit "$OUT/$tag-check.json"; then
    log "$tag: UNMEASURED STOP - the check crossed the bar ($(unmeasured_summary "$OUT/$tag-check.json")); the gate is slow, not these accounts; nothing sent, THIS FAMILY stops and the families behind it still run, each under its own bar (the tick exits 1 at the end)"
    return 1
  fi
  [ "$rc" = 0 ] || { alert_nothing_sent "$tag" "$OUT/$tag-check.out"; log "$tag: check failed; this family stops"; return 1; }
  # QA #1612 (round 2): the cursor moves only when the family's step for this page is DONE - a dry tick or a check
  # that accepted nobody (to where the CHECK stopped), or a clean apply (to where the APPLY stopped) - and to the
  # first entry that run did not get to (page.end), never past entries a capped run never examined
  if [ "$paged" = 1 ]; then
    page_next "$OUT/$tag-check.json" >/dev/null || { log "$tag: the check recorded no page; tick stops"; return 1; }
  fi
  if [ "$(elapsed)" -ge "$TICK_HARD_S" ]; then log "$tag: ${TICK_HARD_S}s deadline passed after the check; no bodies, no apply this tick"; return 0; fi
  if slice_spent; then slice_cut "$tag" "$name" "$seg" "after its check (no bodies, no apply; nothing was sent)"; return 0; fi
  install -d -m 700 "$OUT/$tag-bodies"
  # r5: the bodies ARE the after-the-fact review sample - no sample, no send (the tick stops). [key=scale-now-openclaw]:
  # the WHOLE batch is rendered (not 5), each body with the renderer's facts beside it - the batch judge's items
  run_transient "$tag" bodies "$OUT/$tag-bodies.out" \
    py_ro "$runner" "$sub" --list "$list" --segment "$seg" "$@" "${excl[@]}" "${pg[@]}" --mode dry-run --max-users "$cap" \
    --preview "$OUT/$tag-bodies" --preview-accepted "$OUT/$tag-check.json"; rc=$?
  [ "$rc" = 2 ] && return 2
  rc="$RC"
  if deadline_rc "$rc" && [ "$s_end" -lt "$TICK_HARD_S" ]; then
    slice_cut "$tag" "$name" "$seg" "while its bodies were rendered (read-only, stopped; nothing was sent)"; return 0
  fi
  if deadline_rc "$rc"; then log "$tag: bodies hit the ${TICK_HARD_S}s deadline (read-only, stopped); no apply, the tick ends"; TICK_ENDS=1; return 1; fi
  [ "$rc" = 0 ] || { alert_nothing_sent "$tag" "$OUT/$tag-bodies.out"; log "$tag: body sample failed; no apply, tick stops: $(head -c 300 "$OUT/$tag-bodies.out")"; return 1; }
  accept_bodies "$tag"; rc=$?
  if deadline_rc "$rc"; then log "$tag: the accepted-bodies step hit the ${TICK_HARD_S}s deadline; no apply, the tick ends"; TICK_ENDS=1; return 1; fi
  # QA #1610: a check that accepted NOBODY is a no-apply family outcome - never an apply over the original list
  if [ "$rc" = 3 ]; then log "$tag: the check accepted nobody; no apply this tick (the family is done)"; completed "$tag"; advance_cursor "$tag" "$cur_file" "$OUT/$tag-check.json" "$cur"; return 0; fi
  [ "$rc" = 0 ] || { log "$tag: the rendered bodies are not the check's accepted set (rc=$rc); no apply, tick stops"; return 1; }
  judge_shadow "$tag"
  # [key=arm-per-family]: armed by THIS family's own policy row (or, before armed_families exists, by the two global
  # files); the check already ran, so a dry family proves its readiness and simply does not apply
  local live; live="$(family_armed "$name" "$seg")"
  # QA #1574 finding 1 (round 2): a dry family still FINISHED this segment's step for the page, so it writes the marker
  # (the reply-due scan cursor keys on it); the SIGNED-only branch below deliberately does not.
  if [ "$live" != 1 ]; then log "$tag: DRY-RUN tick (no send): arming=$ARMING $name=$([ "$live" = 1 ] && echo armed || echo "not armed")"; completed "$tag"; advance_cursor "$tag" "$cur_file" "$OUT/$tag-check.json" "$cur"; return 0; fi
  if [ -z "$unsigned" ]; then
    # 14:3xZ (found on the 14Z tick): this branch used to return WITHOUT advancing, so a signed-only family re-walked
    # the SAME first page on every tick for ever - it never reached entry 201, and it re-paid the page's check work every
    # two hours (cursor-r1-free stayed 0 while every unsigned family moved to 200). "Checked, not applied" is still a
    # page this family is DONE with: advance to where the CHECK stopped, exactly like the DRY branch above.
    # QA #1636 finding 1 (main): the FAMILY cursor advances here - the check is done, so re-walking this family page
    # every tick was the bug. QA #1574 finding 1 round 2 (this branch): the .done marker is NOT written, because that
    # marker means this segment's step for the page is over and it gates the reply-due SCAN cursor; a SIGNED-only
    # segment sent nobody, so treating it as done would skip the page for the next tick (the finding's own words:
    # "a 0 return is not completion"). Two cursors, two meanings - kept apart deliberately.
    log "$tag: SIGNED-only family (no read-back date in UNSIGNED_FROM): checked, not applied"
    advance_cursor "$tag" "$cur_file" "$OUT/$tag-check.json" "$cur"; return 0
  fi
  killed && { log "$tag: kill file present; stop"; return 1; }
  if slice_spent; then slice_cut "$tag" "$name" "$seg" "before its apply (checked, not applied; nothing was sent)"; return 0; fi
  local campaign; campaign="$(printf '%s\n' "$@" | awk 'p{print; exit} $0=="--campaign"{p=1}')"
  [ -n "$campaign" ] || campaign="$sub"   # the claim runners: the subcommand IS the campaign
  [ "$runner" = "$NEED_RUNNER" ] && campaign=proof-need-ask
  [ "$runner" = "$PR_RUNNER" ] && campaign=proof-refusal
  local rm n daily; rm="$(room "$campaign" "$seg" "$cap")"
  if [[ "$rm" == ERR* ]] || ! [[ "$rm" =~ ^[0-9]+\ [0-9]+\ [0-9]+$ ]]; then
    # QA #1541: an unreadable policy / ledger is an operational failure, not an exhausted cap - stop and page
    autokill "$tag: cap source unreadable (${rm:0:200})"; return 1
  fi
  local _shared; read -r n daily _shared <<<"$rm"   # (the shared cap is the runner's own policy read)
  if [ "${n:-0}" -le 0 ]; then log "$tag: daily cap reached for $campaign/$seg; no apply"; return 0; fi
  # [key=apply-pool] (captain 2026-11-11, work order item 1): APPLY_WORKERS note steps run at once, so the users that
  # fit before the deadline is the serial fit x the pool size. The pool is bounded at 6; the runner clamps it.
  # [key=claims-never-starved]: inside a group slice the apply is sized and budgeted to the SLICE's end (a_end); the
  # deadline wrapper around it stays TICK_HARD_S, because an apply is never killed to keep a slice
  local a_end; a_end="$(step_end)"
  if [ "$a_end" -lt "$TICK_HARD_S" ] && [ $(( a_end - $(elapsed) )) -lt "$APPLY_USER_WORST_S" ]; then
    slice_cut "$tag" "$name" "$seg" "with $(( a_end - $(elapsed) )) s left, less than one user's worst case ($APPLY_USER_WORST_S s); no apply this tick"
    return 0
  fi
  local fit=$(( (a_end - $(elapsed)) * APPLY_WORKERS / APPLY_S_PER_USER ))
  if [ "$fit" -le 0 ]; then log "$tag: no time left before the ${TICK_HARD_S}s deadline; no apply this tick"; return 0; fi
  if [ "$n" -gt "$fit" ]; then log "$tag: apply cut from $n to $fit (what fits before the $([ "$a_end" -lt "$TICK_HARD_S" ] && echo "end of the claim group's slice" || echo "${TICK_HARD_S}s deadline"))"; n="$fit"; fi
  local lo; lo="$(maxid)"
  [ "$lo" -ge 0 ] || { autokill "$tag: ledger unreadable before the apply"; return 1; }
  local capargs=(); [ "$sub" = uvn-status ] && capargs=(--segment-daily-cap "$daily")
  # [key=uvn-daily-cap-400] (r5 626): the runner reads the ONE credit daily cap from the policy file itself - the tick
  # passes no cap through the environment (no env-moved gate input)
  # [key=apply-sized-to-list]: the apply sends only this tick's own check's accepted set (--signed-accepted); the
  # tick pages that set by its caps and deadline by design (--page: a subset, never a user outside it)
  # spec-deploy-lock-deferral-m1: a deploy holding the apply lock (rc=3) and a Trino transient (rc=4) are NOT terminal.
  # The precondition for a retry is NOT ATTEMPTED, proved by the LEDGER POSITION (max(id) unchanged) - never by the exit
  # code alone, because the same rc=3 also follows a real partial send. A changed ledger is a partial send and the
  # existing rails below own it. On expiry the family DEFERS: no kill file, no refusal operand, no cursor move.
  # [key=note-step-budget] (Fable 753): the send loop is handed the seconds it may spend and will not START a user whose
  # worst case (one note's whole retry budget, 200 s) would not fit - so it stops ~200 s before the deadline instead of
  # running the family past it. The deadline wrapper stays EXACTLY what it was (QA #1587): an apply that still reaches
  # TICK_HARD_S is a partial send and must fail closed, and a kill there is the one kill that stays real.
  # It is computed ONCE, outside the retry loop: a retry re-enters the same runner, and re-deriving the share from the
  # clock each attempt would hand every attempt a fresh budget (the overrun this key exists to prevent).
  local abudget=$(( a_end - $(elapsed) ))
  [ "$abudget" -ge 0 ] || abudget=0
  # [key=note-step-budget]: not even one user's worst case left -> the send loop would defer every user it was handed and
  # we would have paid for a subprocess to say so. Nothing is owed differently: the tick says it and the next one starts.
  if [ "$abudget" -lt "$APPLY_USER_WORST_S" ]; then
    log "$tag: $abudget s left before the ${TICK_HARD_S}s deadline is less than one user's worst case ($APPLY_USER_WORST_S s); no apply this tick"
    return 0
  fi
  local attempt=0 first_at=0 deferred=0 wait left hi cost t0
  while :; do
    t0="$(date -u +%s)"
    py "$runner" "$sub" --list "$list" --segment "$seg" "$@" "${excl[@]}" "${pg[@]}" --mode apply --max-users "$n" "${capargs[@]}" \
      --apply-budget-s "$abudget" --signed-accepted "$OUT/$tag-check.json" --page \
      --outcomes-json "$OUT/$tag-apply.json" > "$OUT/$tag-apply.out" 2>&1; rc=$?
    cost=$(( $(date -u +%s) - t0 ))
    log "$tag APPLY (rc=$rc): $(head -c 600 "$OUT/$tag-apply.out")"
    case "$rc" in "$APPLY_LOCK_RC"|"$TRANSIENT_RC") ;; *) break ;; esac
    # QA #1799 r11: rc=3 is NOT only a held lock. credit-review.py also exits 3 for a cap-short, a signed-set mismatch
    # and HEAD_REFUSED, and ApplyLockError covers a lock that could not be OPENED. Retrying those mislabelled a HARD
    # REFUSAL as "a deploy holds the apply lock", then let the tick continue into later groups and exit 2 instead of
    # preserving the hard stop. The lock path prints APPLY_LOCK_HELD on stderr; without it, rc=3 is terminal here.
    # rc=4 has exactly one producer (TrinoTransientError) and needs no marker.
    if [ "$rc" = "$APPLY_LOCK_RC" ] && grep -q "$APPLY_LOCK_UNOPENABLE_MARKER" "$OUT/$tag-apply.out" 2>/dev/null; then
      # QA #1799 r12 (carried): ApplyLockError covered BOTH contention and a lock that could not be OPENED, so a
      # permissions or I/O fault was reported as "a deploy holds the lock", retried, deferred, and the tick went on
      # into later groups. An unopenable lock is a hard stop with its own line - never a retry, never a deferral.
      log "$tag: the apply lock could not be OPENED - a permissions or I/O fault, not a deploy; nothing was attempted"
      log "$tag: apply failed rc=$rc; tick stops"
      TICK_ENDS=1; return 1
    fi
    if [ "$rc" = "$APPLY_LOCK_RC" ] && ! grep -q "$APPLY_LOCK_MARKER" "$OUT/$tag-apply.out" 2>/dev/null; then
      # QA #1799 r12 (Critical): the discriminator is the LEDGER, not the return. rc=3 without the marker is NOT only
      # pre-send - credit-review.py returns 3 for a signed-set mismatch and for HEAD_REFUSED AFTER args.fn() has
      # already sent, so an early return here skipped the partial-send detection and every rail below it (health,
      # zero-read, refusal spike, fraud, sample) - the rails that exist to catch an unsafe partial send.
      hi="$(maxid)"
      if [ "$hi" != "$lo" ]; then
        log "$tag: apply rc=3 WITHOUT the held-lock marker AND a CHANGED ledger ($lo -> $hi) - a partial send; the post-send rails own it"
        break
      fi
      # An UNCHANGED ledger proves nothing was attempted, so this is a HARD STOP: no retry, no deferral, no kill file,
      # and no later family group. Returning here (rather than falling through to the health/spike rails) keeps it a
      # clean stop - the rails would read the absent outcomes artefact as UNMEASURED and write a kill file for a run
      # that never attempted a send.
      log "$tag: apply rc=3 WITHOUT the held-lock marker and an UNCHANGED ledger - a hard refusal (cap-short, signed-set mismatch or HEAD_REFUSED), not a deploy lock"
      log "$tag: apply failed rc=$rc; tick stops"
      TICK_ENDS=1; return 1
    fi
    hi="$(maxid)"
    if [ "$hi" != "$lo" ]; then
      log "$tag: apply rc=$rc with a CHANGED ledger ($lo -> $hi) - a partial send is never a clean family; the tick stops"
      break
    fi
    [ "$first_at" = 0 ] && first_at="$(date -u +%s)"
    local held=$(( $(date -u +%s) - first_at ))
    local why="a deploy holds the apply lock"; [ "$rc" = "$TRANSIENT_RC" ] && why="Trino is transiently unavailable"
    if [ "$attempt" -ge "${#APPLY_RETRY_SLEEPS[@]}" ] || [ "$held" -ge "$APPLY_RETRY_CAP_S" ] \
       || [ "$(elapsed)" -ge "$TICK_BUDGET_S" ] || slice_spent; then
      log "$tag: apply deferred - $why for ${held}s (${attempt} retries, ledger unchanged at $lo); this family and the rest of the tick defer to the next tick (no kill file, no refusal, no cursor move)"
      page "$tag: apply deferred after ${held}s - $why; nothing was sent and nothing was refused"
      deferred=1; break
    fi
    # QA #1799 r13 (Important): same clip as run_transient, against the remaining tick BUDGET and the remaining
    # APPLY_RETRY_CAP_S window. A retry that does not fit is not a retry: defer now rather than sleep past the budget
    # and starve every family behind this one.
    left=$(( TICK_BUDGET_S - $(elapsed) ))
    if [ -n "$GROUP_END_S" ] && [ $(( GROUP_END_S - $(elapsed) )) -lt "$left" ]; then left=$(( GROUP_END_S - $(elapsed) )); fi
    local cap_left=$(( APPLY_RETRY_CAP_S - held ))
    [ "$cap_left" -lt "$left" ] && left="$cap_left"
    wait="${APPLY_RETRY_SLEEPS[$attempt]}"
    # QA #1799 r14 (Important): the same whole-retry fit as run_transient - the sleep PLUS a repeat of the attempt we
    # just measured must finish strictly inside the budget and the retry window, or the retry is not a retry.
    if [ "$left" -le 0 ] || [ "$(( wait + cost ))" -ge "$left" ]; then
      log "$tag: apply deferred - a ${wait}s retry does not fit in the ${left}s left of the tick budget/retry window (the attempt itself just took ${cost}s, so the retry would finish at or past it); $why; this family and the rest of the tick defer to the next tick (no kill file, no refusal, no cursor move)"
      page "$tag: apply deferred - $why and no retry fits the tick budget; nothing was sent and nothing was refused"
      deferred=1; break
    fi
    attempt=$(( attempt + 1 ))
    log "$tag: apply lock busy/transient ($why); retry $attempt/${#APPLY_RETRY_SLEEPS[@]} in ${wait}s"
    [ "$wait" -ge 1 ] && sleep "$wait"
  done
  [ "$deferred" = 1 ] && return 2
  # a SEND cut at the deadline: whatever it sent is in the ledger, but the read-back is incomplete - a human looks first
  if deadline_rc "$rc"; then autokill "$tag: the apply hit the ${TICK_HARD_S}s deadline mid-run (ledger $((lo + 1))-…); read back by hand before re-arming"; return 1; fi
  local h hrc; h="$(py "$HEALTH" --since "$RUN_START" --bounce-max-pct 2 --unsub-max-pct 2 --spam-max-pct 2 2>&1 | tail -1)"; hrc=$?
  log "$tag health (rc=$hrc): $h"
  [ "$hrc" = 0 ] || { autokill "$tag health check rc=$hrc: ${h:0:200}"; return 1; }
  # p1 / n1: the durable zero-read over exactly this apply's ledger rows - OK continues; STOP or UNMEASURED (or a missing
  # reader) writes the kill file. Nothing new in the ledger = nothing to read.
  local hi; hi="$(maxid)"
  [ "$hi" -ge 0 ] || { autokill "$tag: ledger unreadable after the apply"; return 1; }   # QA #1541: never a -1 range
  local nsent; nsent="$(py -c 'import sqlite3,sys
print(sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True).execute(
    "SELECT count(*) FROM verify_messages WHERE id > ? AND id <= ? AND status IN (?, ?)",
    (int(sys.argv[2]), int(sys.argv[3]), "sent", "attempted")).fetchone()[0])' \
    "$LEDGER" "$lo" "$hi" 2>/dev/null || echo -1)"
  [ "$nsent" -ge 0 ] || { autokill "$tag: ledger unreadable after the apply"; return 1; }
  # r5 19:06Z: charge the shared first-batch budget with the LEDGER's count (sent + attempted), before any rail below
  # can return - a later segment must see every row this apply wrote, whatever the verdicts on it
  [ "$shared" = 1 ] && FIRST_SPENT[$fam]=$(( ${FIRST_SPENT[$fam]:-0} + nsent ))
  [[ -v SHARED_TICK_CAP[$fam] ]] && TICK_SPENT[$fam]=$(( ${TICK_SPENT[$fam]:-0} + nsent ))
  # QA #1541 (claim runners print 'sent N', credit runners 'N sent'): the spike reads the LEDGER's own count of this
  # apply's sends - never a grep on a runner's prose, which read 0 for claims and wrote the permanent kill file
  # Two different facts, two different sentences. A SPIKE is a measurement of the run and says so with its numbers.
  # An ABSENT/UNREADABLE artefact is the absence of a measurement: it still stops the family (fail closed), but it
  # must never be reported as a spike - "the artefact is missing" and "too many users were refused" send a reader to
  # two completely different investigations, and naming the wrong one is how 2026-11-04's false label happened.
  local sv; sv="$(spike "$OUT/$tag-apply.json" "$nsent")"
  case "$sv" in
    ok) ;;
    spike) autokill "$tag refusal spike: $((nsent)) sent and the run's own outcomes refused more than $(printf '%.0f' "$(awk -v t="$REFUSAL_SPIKE" 'BEGIN{print t*100}')")% of attempts (ledger $((lo + 1))-$hi)"; return 1 ;;
    unmeasured*) autokill "$tag OUTCOMES UNMEASURED after $nsent send(s) (ledger $((lo + 1))-$hi): ${sv#unmeasured }; no ratio can be computed from an artefact that does not exist, so this is not a spike - read the sends back before lifting"; return 1 ;;
    *) autokill "$tag spike() answered '$sv' - an unexpected verdict is not a pass (ledger $((lo + 1))-$hi)"; return 1 ;;
  esac
  if [ "$nsent" -gt 0 ]; then
    local fh; fh="$(fraudhit "$lo" "$hi")"
    log "$tag fraud re-check ledger $((lo + 1))-$hi: ${fh:0:300}"
    [ "$fh" = ok ] || { autokill "$tag FRAUD ${fh:0:200} (ledger $((lo + 1))-$hi)"; return 1; }
    sample "$tag" "$lo" "$hi" || { autokill "$tag: the v1 sample pointer for ledger $((lo + 1))-$hi could not be written to $STATE/samples.jsonl"; return 1; }
    local zr zrc; zr="$(py "$ZERO_READ" --ledger-ids "$((lo + 1))-$hi" 2>&1 | tail -1)"; zrc=$?
    [ -r "$ZERO_READ" ] || zrc=2
    # QA #1545 round 8 (Important): under `set -o pipefail` a READER CRASH exits 1, and 1 means CONFIRMED STOP to the
    # lines below - so a transient Trino/kubectl timeout would write the global kill file as if a credit-class message
    # had been observed. The reader prints exactly one verdict line (OK:/STOP:/UNMEASURED:); anything else is a crash,
    # i.e. a source we could not read, and UNMEASURED is the honest reading of it.
    # qa Critical on #1747 (d2 17:1xZ): zero_read emits a COMBINED verdict `STOP+UNMEASURED:` with exit 1 when a
    # confirmed stop AND an unread source exist in the same batch. This case listed only OK*/STOP*/UNMEASURED*, so the
    # combined word matched NOTHING, fell into the catch-all below, was rewritten to `UNMEASURED: ... no verdict` and
    # forced zrc=2 - which BYPASSED the stop arm entirely, exactly when both a stop and an unread source existed. The
    # lesson is the same one that produced the bug this branch fixes: a status word that means two things, gated by a
    # pattern that can only see one of them. A STOP of ANY form is a STOP, and it WINS over UNMEASURED.
    case "${zr:-}" in
      OK|OK:*|UNMEASURED|UNMEASURED:*) ;;
      STOP|STOP:*|STOP+UNMEASURED|STOP+UNMEASURED:*) zrc=1 ;;   # never let a STOP be re-read as a mere unmeasured
      *) zr="UNMEASURED: the zero-read printed no verdict (a crash is not a STOP): ${zr:0:200}"; zrc=2 ;;
    esac
    log "$tag zero-read ledger $((lo + 1))-$hi (rc=$zrc): ${zr:0:300}"
    if [ "$zrc" = 1 ]; then
      # STOP: an unexplained credit-class message - the auto-kill for the whole run (unchanged).
      # The combined verdict says something extra that the plain STOP does not: the batch had sources NOBODY read, so
      # the stops below do not account for every source. Same kill, honest sentence.
      case "${zr:-}" in
        STOP+UNMEASURED*) autokill "$tag zero-read STOP+UNMEASURED for ledger $((lo + 1))-$hi (a confirmed stop AND sources that were never read - the stops below do NOT account for every source): ${zr:0:240}"; return 1 ;;
        *) autokill "$tag zero-read STOP for ledger $((lo + 1))-$hi: ${zr:0:200}"; return 1 ;;
      esac
    fi
    if [ "$zrc" != 0 ]; then
      # (B) UNMEASURED never wedges the tick: rows so the batch's outcomes balance, a page the same minute, this
      # segment stops here (its remaining users stay owed and unsent), every other family continues on its own read.
      local zu; zu="$(zero_unmeasured "$tag" "$lo" "$hi" "${zr:0:200}" 2>&1 | tail -1)"
      log "$tag zero-read UNMEASURED ledger $((lo + 1))-$hi: $zu; this segment stops here, other families continue"
      case "$zu" in *"zero_read_unmeasured users"*) ;; *) autokill "$tag: the zero_read_unmeasured rows could not be written ($zu) - the batch's outcomes would not balance"; return 1 ;; esac
      # ruling B requires the page the SAME MINUTE. A page that could not be delivered is persisted and RETRIED at the
      # top of the next tick, and THIS tick fails closed for the family - an unattended outage must never be only a log.
      if notify "$tag zero-read UNMEASURED for ledger $((lo + 1))-$hi: ${zr:0:200}. This segment stops after its send; its remaining users stay owed and unsent; every other family continues. Rows: $OUT/$tag-apply.json"; then
        log "$tag: paged #clio_devops"
      else
        printf 'zero-read UNMEASURED (undelivered page) %s ledger %d-%d: %s\n' "$(date -u +%FT%TZ)" "$((lo + 1))" "$hi" "${zr:0:200}" \
          > "$STATE/zero-unmeasured-undelivered-$tag" 2>/dev/null \
          || { autokill "$tag: the zero-read was UNMEASURED, the page FAILED, and no durable retry marker could be written ($STATE)"; return 1; }
        log "$tag zero-read UNMEASURED: the PAGE FAILED; persisted $STATE/zero-unmeasured-undelivered-$tag for the next tick's retry - this tick stops here (fail closed)"
        TICK_ENDS=1; return 1
      fi
      # QA #1545 finding 3: a NONZERO apply is a FAILED apply - rows may already be sent. The UNMEASURED continuation
      # must never turn that into a successful family by skipping the rc guard below.
      if [ "$rc" != 0 ]; then
        log "$tag: apply FAILED (rc=$rc) AND the zero-read was UNMEASURED; the tick stops here (a partial send is never a clean family)"
        TICK_ENDS=1; return 1
      fi
      # QA #1545 round 9 (Important): this continuation returned 0 WITHOUT moving the paged family's cursor, so every
      # later tick re-walked the SAME page - a persistent UNMEASURED (Loki or Trino down for hours) starved every entry
      # behind it while the tick reported clean for the other families. The page's work IS done: the apply ran and its
      # users carry the zero-read verdict on their own rows, so the cursor moves exactly as a clean apply moves it.
      advance_cursor "$tag" "$cur_file" "$OUT/$tag-apply.json" "$cur"
      return 0
    fi
  fi
  [ "$rc" = 0 ] || { alert_nothing_sent "$tag" "$OUT/$tag-apply.out"; log "$tag: apply failed rc=$rc; tick stops"; TICK_ENDS=1; return 1; }
  completed "$tag"
  advance_cursor "$tag" "$cur_file" "$OUT/$tag-apply.json" "$cur"
}

# ---- audiences (deployed builders only) ----------------------------------------------------------------------
# r5 on #1541: the uvn-status family is the UVN class only (owing_proof also lists hold classes - review_hold /
# account_hold - that the uvn-status runner does not cover; they belong to their own campaign's family).
# r5 776 / p1 581: the BUILDER writes the uvn-class list (its own facts header over exactly those users); the tick
# never edits a built list - a list changed after its build is refused by the facts check, by design.
# QA #1857 r1 (Important 1) / r2: a list builder runs under the ONE deadline wrapper, so a builder killed at TICK_HARD_S
# comes back rc 124/137 - the same "nothing behind it would fit" class the tick already ends on at the check, the bodies
# and the accepted-bodies steps. Treating that rc as an ordinary failure (census UNMEASURED at the census, `return 1` on
# a rebuild) made a spent budget look like a read-only read error, and the tick went on into the families PAST the
# deadline with `bounded` clamping every call to 1 s. A non-deadline failure keeps its own behaviour: the census is
# UNMEASURED and the tick continues; a rebuild failure stops that family and the next group still runs.
builder_deadline() { # <rc> <what>: 0 iff rc is the deadline class (logged, TICK_ENDS set); else 1
  deadline_rc "$1" || return 1
  log "$2 hit the ${TICK_HARD_S}s deadline (rc=$1, read-only, stopped); nothing behind it would fit; the tick ends"
  TICK_ENDS=1
}
CENSUS_UNMEASURED=0
census_unmeasured() { # <why>: a census read that failed is UNMEASURED, never a reason to cancel the tick
  CENSUS_UNMEASURED=$((CENSUS_UNMEASURED + 1))
  log "census UNMEASURED ($CENSUS_UNMEASURED): $1; the tick continues into the families (a census read never cancels the run)"
}
# the new-rows list on disk is always the one THIS build wrote: an older file (an earlier build of this tick, or a run in
# the same minute) must never stand in for a build that wrote none - that would read as a measured audience
rm -f "$OUT/owing-new-rows.json"
py "$OWING" --out "$OUT/owing.json" --class-out "uvn=$OUT/owing-uvn.json" --class-out "uvn_reminder_14=$OUT/owing-reminder-14.json" --class-out "uvn_new_rows=$OUT/owing-new-rows.json" > "$OUT/owing.out" 2>&1; rc=$?
if [ "$rc" = 0 ]; then
  [ -s "$OUT/owing-uvn.json" ] || census_unmeasured "owing builder wrote no uvn-class list"
elif builder_deadline "$rc" "owing census builder"; then
  exit 1   # the deadline is the hard stop, at the census as everywhere else: no receipts read, no family starts
else
  census_unmeasured "owing builder failed: $(tail -c 300 "$OUT/owing.out")"
fi
py "$RECEIPTS" --out-dir "$OUT/receipts" > "$OUT/receipts.out" 2>&1; rc=$?
if [ "$rc" != 0 ]; then
  builder_deadline "$rc" "receipts census builder" && exit 1
  census_unmeasured "receipts builder failed: $(tail -c 300 "$OUT/receipts.out")"
fi
log "owing classes: $(tail -1 "$OUT/owing.out" | py -c 'import json,sys; print(json.dumps(json.loads(sys.stdin.read() or "{}").get("classes", {})))' 2>/dev/null) -> uvn-status family gets the uvn class (owing-uvn.json, built by the builder)"
log "audiences: owing $(head -c 300 "$OUT/owing.out"); receipts $(head -c 300 "$OUT/receipts.out")"

# Defect B (Fable d2 owner brief): the owing list was built HERE and consumed by the uvn-status families ~25 min later,
# after the apology and reply-due families; the decider rewrites held rows every 15 min, so owing_proof.verify_facts
# marked every user "owed requests changed since the list was built" and the family sent nothing (02:00Z: 1,391 held,
# 0 on the list). The ruling: rebuild the list, with the SAME builder, immediately before the stage that enforces it.
# The early build above is the tick's audience census and is UNMEASURED, never fatal; each uvn-status family re-runs
# the builder right before its own check, so the facts header the check signs is minutes old, not 25.
rebuild_owing_uvn() { # <for>
  local t0 rc; t0=$(date +%s)
  rm -f "$OUT/owing-new-rows.json"   # as at the census: a file here is the one this build wrote, or there is none
  py "$OWING" --out "$OUT/owing.json" --class-out "uvn=$OUT/owing-uvn.json" --class-out "uvn_reminder_14=$OUT/owing-reminder-14.json" --class-out "uvn_new_rows=$OUT/owing-new-rows.json" > "$OUT/owing.out" 2>&1; rc=$?
  if [ "$rc" != 0 ]; then
    builder_deadline "$rc" "owing builder on the rebuild before $1" && return 1
    log "owing builder failed on the rebuild before $1 (rc=$rc): $(tail -c 300 "$OUT/owing.out")"; return 1
  fi
  [ -s "$OUT/owing-uvn.json" ] || { log "owing builder wrote no uvn-class list on the rebuild before $1; this family stops"; return 1; }
  log "owing list rebuilt immediately before $1 (Defect B: the facts the check enforces are $(( $(date +%s) - t0 ))s old, not the tick's age): $(head -c 200 "$OUT/owing.out")"
}

# [key=arm-per-family] (l1 ruling 2026-11-02, ruling-never-a-bottleneck-1102.md): arming is PER FAMILY, read from the
# policy file's armed_families, so a proven class moves along without arming everything - the defect was that two GLOBAL
# files meant ONE decision for six families, so "move claim-status along" needed every other family armed too, and the
# arming itself became a Muso-side review wait (Aaron's standing rule: waiting is a defect). Three sources, named in the
# log and never inferred:
#   policy    - armed_families is present: a family is armed ONLY by its own row; a family with no row is NOT armed.
#   legacy    - the key is absent: the two global files decide, so writing them still arms everything (the 00Z GO holds).
#   malformed - armed_families (or one of its rows) is malformed: NOTHING is armed (fail closed) and the tick PAGES;
#                it keeps checking, because a config typo must not cost the night's read-only work.
#   unreadable - the policy FILE cannot be read: the tick stops and kills, exactly as an unreadable cap read always has
#                (QA #1541) - a policy we cannot read is an operational failure, not an exhausted cap.
# A dry-run family still CHECKS (that is how it proves readiness); arming gates the APPLY only.
ARMING="legacy"; ARMED_LIST=""
declare -A ARMED_LIVE=() ARMED_PAID=()
read_arming() { # <policy path>: prints "<source>" then "<family> <live> <paid> <unsigned_from|->" lines
  # every python subprocess of the tick runs under the ONE deadline wrapper (b1 560) - no exceptions
  py -I -c 'import json, sys
try:
    doc = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, ValueError):
    print("unreadable"); raise SystemExit(0)
if not isinstance(doc, dict):
    print("unreadable"); raise SystemExit(0)
if "armed_families" not in doc:
    print("legacy"); raise SystemExit(0)
armed = doc["armed_families"]
if not isinstance(armed, dict) or not armed:
    print("malformed"); raise SystemExit(0)
import datetime as _dt
# QA #1648 finding 1: SEMANTIC errors have to reach the malformed path too. A type check is not a value check, and a
# typo that only logs arms nothing while the tick reports a healthy policy - the family then stalls indefinitely with
# no page, which is the opposite of what "malformed pages" promises. Both checks below run BEFORE the source line is
# printed, so a typo arms NOTHING and pages instead of being read as "policy mode, family dry".
# "uvn-status:c2" is a SUB-class of uvn-status, not a family ([key=class-c-is-a-row]): its row arms the /c2 corrected
# ask and nothing else, and the uvn-status row still decides whether the family applies at all
KNOWN = {"r1", "status-doc-received", "uvn-status", "claim-status", "claim-proof-ask", "proof-need-ask", "reply-due",
         "uvn-status:c2", "uvn-reminder-14", "uvn-new-rows", "proof-refusal"}
def _instant(v):
    for fmt in ("%Y-%m-%dT%H:%MZ", "%Y-%m-%dT%H:%M:%SZ"):
        try:
            _dt.datetime.strptime(v, fmt)
            return True
        except ValueError:
            pass
    return False
# QA #1648 finding 2 (the alias collision): two spellings of ONE family both parse, and sorted iteration then decides
# the outcome by STRING ORDER - `r1: {live:false}` plus `status-doc-received: {live:true}` disarms in one line and arms
# in the next, so an operator who disarmed a family can still have it apply. Canonicalise FIRST and refuse the whole
# policy when a family is named twice: a policy we cannot read unambiguously arms NOTHING and pages.
CANON = {"status-doc-received": "r1"}
def _canon(fam):
    return CANON.get(fam, fam)
rows, claim = [], {}
dupes = []
for fam, row in sorted(armed.items()):
    if not isinstance(row, dict) or not isinstance(row.get("live"), bool) or not isinstance(row.get("paid"), bool):
        print("malformed"); raise SystemExit(0)
    if fam not in KNOWN:
        print("malformed"); raise SystemExit(0)        # a misspelled family would arm nothing in silence
    _c = _canon(fam)
    if _c in claim:
        dupes.append("%s and %s both arm the %s family" % (claim[_c], fam, _c))
    else:
        claim[_c] = fam
    uf = row.get("unsigned_from")
    if uf is not None and not isinstance(uf, str):
        print("malformed"); raise SystemExit(0)        # a malformed date is never a quiet SIGNED-only
    if uf is not None and not _instant(uf):
        print("malformed"); raise SystemExit(0)        # "tomorrow" would arm, never apply, and never page
    rows.append("%s %d %d %s" % (fam, 1 if row["live"] else 0, 1 if row["paid"] else 0, uf or "-"))
if dupes:
    print("malformed")
    print("; ".join(dupes))                            # the page names the rows, so the operator knows which pair
    raise SystemExit(0)
print("policy")
for r in rows: print(r)' "$1" 2>/dev/null || echo "unreadable"
}
ARMING_ROWS="$(read_arming "$POLICY")"
ARMING="$(printf '%s\n' "$ARMING_ROWS" | head -1)"
if [ "$ARMING" = "policy" ]; then
  while read -r _fam _live _paid _ufrom; do
    case "$_fam" in ""|policy) continue ;; esac
    # QA #1648 finding 2: the tick names one family differently from its campaign - the r1 receipt IS the
    # status-doc-received campaign. Keyed naively, a row called `status-doc-received` armed nothing (family_armed is
    # asked for `r1`) and a row called `r1` dated nothing (UNSIGNED_FROM is read as `status-doc-received`): a silent
    # miss either way. Both spellings are accepted and mapped to the key EACH reader actually uses.
    _key="$_fam"; _datekey="$_fam"
    case "$_fam" in
      r1|status-doc-received) _key="r1"; _datekey="status-doc-received" ;;
      uvn-status|claim-status|claim-proof-ask|proof-need-ask|reply-due|uvn-status:c2|uvn-reminder-14|uvn-new-rows|proof-refusal) ;;
      *) log "ARMING ROW IGNORED: '$_fam' is not a family this tick runs (r1|status-doc-received, uvn-status, claim-status, claim-proof-ask, proof-need-ask, uvn-reminder-14, uvn-new-rows, proof-refusal); it arms nothing"
         continue ;;   # read_arming() already fails such a row closed; this is the belt to its braces
    esac
    ARMED_LIVE["$_key"]="$_live"; ARMED_PAID["$_key"]="$_paid"
    # [key=dated-windows-are-data]: the family's unsigned date is DATA too, so arming a family is ONE reviewed row and
    # not "a policy flag plus a code date".
    # QA #1648 finding 2 (the default): a row with NO date must CLEAR the code's built-in date, not inherit it. Inheriting
    # meant "live:true and no date" could still apply on a date the operator never saw in the row they reviewed - the
    # opposite of what the row says. This ASSIGNMENT is the point: it is the one place the row overrides the code.
    case "$_ufrom" in
      ""|-) UNSIGNED_FROM["$_datekey"]="" ;;
      *) UNSIGNED_FROM["$_datekey"]="$_ufrom" ;;
    esac
    _dating=""; case "$_ufrom" in ""|-) _dating=" (SIGNED-only: the row sets no unsigned_from)" ;; *) _dating=" from $_ufrom" ;; esac
    ARMED_LIST="${ARMED_LIST:+$ARMED_LIST, }${_key}=$([ "$_live" = 1 ] && echo live || echo dry)/$([ "$_paid" = 1 ] && echo paid || echo dry)$_dating"
  done <<< "$ARMING_ROWS"
  [ -n "$ARMED_LIST" ] || ARMED_LIST="(none)"
fi
# <family> <segment> -> 1 armed (may apply) | 0 not armed (check only). The zero-read guard is safety, not arming: no
# live send anywhere without the reader deployed (QA #1541).
family_armed() {
  local v
  case "$ARMING" in
    policy) v="${ARMED_LIVE[$1]:-0}"; [ "$2" = "paid" ] && v="${ARMED_PAID[$1]:-0}" ;;
    legacy) v="$LIVE"; [ "$2" = "paid" ] && v="$PAID_LIVE" ;;
    malformed|*) v=0 ;;
  esac
  [ "${ZR_MISSING:-0}" = 1 ] && v=0
  printf '%s' "$v"
}
# <segment> -> prints "--no-correction" unless class C is armed for that segment ([key=class-c-is-a-row]). Armed means
# ALL of: the policy is in `policy` mode, the "uvn-status:c2" row says live (and ALSO paid, for the paid segment), and
# the row's own unsigned_from is reached. `live: false` is the one off switch for BOTH segments: unlike family_armed,
# the paid bit never stands in for the live bit here (QA on #1939 - {live:false, paid:true} kept paid class C sending
# after the documented disarm). Legacy and malformed arming, a missing row, a row with no date and a future date
# all print the flag, so the gate defers a corrected ask at the check and at the send alike. It never arms the
# family: uvn-status applies only on its own row, and a dry uvn-status with an armed c2 row is still a dry run.
c2_args() {
  local v=0
  if [ "$ARMING" = "policy" ]; then
    v="${ARMED_LIVE[uvn-status:c2]:-0}"
    if [ "$1" = "paid" ] && [ "${ARMED_PAID[uvn-status:c2]:-0}" != 1 ]; then v=0; fi
  fi
  if [ "$v" = 1 ] && reached "${UNSIGNED_FROM[uvn-status:c2]:-}"; then return 0; fi
  printf '%s\n' "--no-correction"
}
EXCL_ARGS=(); [ -s "$EXCLUDE" ] && EXCL_ARGS=(--exclude-users "$EXCLUDE")
RUN_START="$(date -u +%FT%TZ)"
log "tick start: live=$LIVE paid_live=$PAID_LIVE arming=$ARMING${ARMED_LIST:+ armed: $ARMED_LIST} cap=$CAP out=$OUT deployed=$(cat "$DEPLOYED_SHA_FILE" 2>/dev/null || echo unreadable)"
if [ "$ARMING" = "unreadable" ]; then
  autokill "cap source unreadable ($POLICY): the arming read cannot open it"; exit 1
elif [ "$ARMING" = "malformed" ]; then
  ARMING_WHY="$(printf '%s\n' "$ARMING_ROWS" | tail -n +2 | head -1)"
  log "ARMING MALFORMED: $POLICY armed_families (or a row of it) is malformed${ARMING_WHY:+ - $ARMING_WHY}; NOTHING is armed this tick - every family checks, none applies"
  page "credit-verify-outbound: armed_families malformed in $POLICY${ARMING_WHY:+ ($ARMING_WHY)} - nothing armed (fail closed)"
fi

# ---- the families, in p1's order (paid first; a family whose builder/runner is not deployed is logged) ---------
# uvn-reminder-14 is the reminder family (reminder_family below). The day-7 reminder (hydra PR #1535) never merged:
# the one follow-up of a uvn-status ask is the day-14 one, once per user per ask.
# reply_due (h2 / firstmate 031): the ONE answer to a user who wrote to us, built by the DEPLOYED reply_due_scan.py
# (open threads where the customer replied > 24 h ago and after us; comm_state.reply_due() per thread; one row per user;
# paid first). It runs FIRST so answers go before unsolicited notes. It sends through the uvn-status runner, so it
# charges the SAME uvn-status daily row and the shared credit cap as the uvn-status family (room() counts every
# uvn-status message of the day, whatever list it came from). Not deployed = logged and skipped.
NEED_LIST=""
# Defect B (Fable d2): the need list carries its own facts header too (need_asks.verify_facts), so it is rebuilt
# immediately before need_families enforces it (the same builder, same filter).
build_need_list() { # <when>: 0 = NEED_LIST set; 1 = the builder or the filter failed (logged; TICK_ENDS=1 at the deadline)
  local rc
  py "$NEED_RUNNER" build --out "$OUT/need-asks-all.json" > "$OUT/need-asks.out" 2>&1; rc=$?
  if [ "$rc" != 0 ] && builder_deadline "$rc" "proof-need-ask builder ($1)"; then return 1; fi
  if [ "$rc" = 0 ]; then
    # the exclude file (users another lane messages today) holds them out of the need family too - need_asks has no
    # --exclude-users, so the tick filters its list, as it does the claim list
    py - "$OUT/need-asks-all.json" "$EXCLUDE" "$OUT/need-asks.json" <<'PY' >> "$OUT/tick.log" || { log "need list filter failed ($1)"; return 1; }
import json, os, sys
src, excl, out = sys.argv[1:4]
doc = json.load(open(src))
held = {l.strip() for l in open(excl) if l.strip() and not l.startswith("#")} if os.path.exists(excl) else set()
users = doc.get("users") or []
keep = [u for u in users if str(u.get("user_id")) not in held]
if keep:
    json.dump({**doc, "users": keep}, open(out, "w"))
else:
    open(out, "w").close()                       # an empty audience: the family logs and skips
print(f"need list: {len(users)} users, {len(users) - len(keep)} held out by the exclude file")
PY
    NEED_LIST="$OUT/need-asks.json"
    log "audiences: proof-need-ask ($1) $(head -c 300 "$OUT/need-asks.out")"
    return 0
  fi
  log "proof-need-ask builder failed ($1): rc=$rc $(tail -c 300 "$OUT/need-asks.out")"
  return 1
}
RD_LIST=""
# Persist where the reply-due upstream walk stopped, and the candidates it collected but never finished evaluating.
# Only called when BOTH family segments are done: a page the family did not answer is re-walked, never skipped.
persist_reply_due_upstream() { # <scan-doc> <state-file>
  py - "$1" "$2" <<'PY2' || log "reply-due: the upstream cursor could not be written; the next run restarts its walk"
import json, os, sys
doc = json.load(open(sys.argv[1]))
up = (doc.get("upstream") or {})
keep = {k: v for k, v in up.items() if v}
if keep:
    with open(sys.argv[2] + ".tmp", "w") as fh:
        json.dump(keep, fh)
    os.replace(sys.argv[2] + ".tmp", sys.argv[2])
elif os.path.exists(sys.argv[2]):
    os.unlink(sys.argv[2])
PY2
}

# the cursor's IDENTITY half: the user id the next run resumes after, or a removed file when the page was walked to its
# end (page.end_user null). A missing/unreadable page leaves the existing anchor untouched - the same fail-closed rule as
# the position, so a scan that died cannot silently move the cursor past rows nobody examined.
persist_reply_due_anchor() { # <run's outcomes json> <anchor file>
  local want
  want="$(py -c 'import json,sys
p = (json.load(open(sys.argv[1])).get("page") or {})
v = p.get("end_user")
print("" if v is None else int(v))' "$1" 2>/dev/null)" || { log "reply-due: no page record in $(basename "$1"); the anchor stays at $(cat "$2" 2>/dev/null || echo 0)"; return 0; }
  if [ -n "$want" ]; then
    printf '%s\n' "$want" > "$2.tmp" && mv -f "$2.tmp" "$2"
  elif [ -e "$2" ]; then
    rm -f "$2"
  fi
  log "reply-due anchor: the next tick resumes after user ${want:-<none: the page wrapped>}"
}

if [ -r "$RD_SCAN" ]; then
  RD_CURSOR="$STATE/cursor-reply-due"
  RD_UPSTREAM="$STATE/cursor-reply-due-upstream.json"
  rd_cur="$(cat "$RD_CURSOR" 2>/dev/null || echo 0)"; [[ "$rd_cur" =~ ^[0-9]{1,9}$ ]] || rd_cur=0
  # r5 (1574 finding 3): the audience cursor rotates INSIDE a list preparation has already truncated, so a tick that
  # starves in the first Intercom search pages (or the first historical apology threads) never reaches the tail - ever.
  # The scan reports where its upstream walk stopped and the next tick RESUMES there; a completed walk reports nulls and
  # this file is removed, so the rotation wraps. A runner that predates the flag is not passed it (same rule as the
  # --check-recipients support check): it simply restarts its walk, slower but never wrong.
  rd_ups=(); grep -q -- '--upstream-resume' "$RD_SCAN" 2>/dev/null && rd_ups=(--upstream-resume "$RD_UPSTREAM")
  # QA #1574 (7th round, Important): the cursor is the IDENTITY of the last entry the last run examined, not a position.
  # A position is not a resume point in a list that is REBUILT every run: the rows this tick sends are answered, so they
  # vanish from the next search and every position behind them shifts up - "start at 100" of a 300-row list skipped the
  # next 100 owed replies once the first 100 were gone. `--start-after-user` resumes after that ROW; when it is gone the
  # scan enters the slice at its head (the next owed reply) and counts the reset. A runner that predates the flag still
  # gets --start-entry (same rule as --upstream-resume): slower, never wrong.
  RD_ANCHOR="$STATE/cursor-reply-due-anchor"
  rd_anchor="$(cat "$RD_ANCHOR" 2>/dev/null || true)"; [[ "$rd_anchor" =~ ^[0-9]{1,12}$ ]] || rd_anchor=""
  rd_anc=(); if [ -n "$rd_anchor" ] && grep -q -- '--start-after-user' "$RD_SCAN" 2>/dev/null; then rd_anc=(--start-after-user "$rd_anchor"); fi
  py "$RD_SCAN" --out "$OUT/reply-due.json" --cap "$RD_CAP" --max-checks "$RD_CHECKS" \
    --budget-seconds "$RD_BUDGET" --start-entry "$rd_cur" "${rd_anc[@]}" "${rd_ups[@]}" > "$OUT/reply-due.out" 2>&1 \
    || { log "reply_due builder failed: $(tail -c 300 "$OUT/reply-due.out")"; exit 1; }
  # QA #1574 (round 5, finding 1): the upstream state is NOT written here. The search walk stopping early is only half of
  # "this slice is used" - the rows it collected still have to reach the family, and a deferred family (budget, fit,
  # sign-off, cap) answers nobody. Committing the token at scan time then resumed PAST users the family never reached.
  # It is persisted in credit_families(), on the same completion markers the audience cursor uses.
  rd_ups_ok=0; if [ ${#rd_ups[@]} -gt 0 ]; then rd_ups_ok=1; fi
  # r5 (1574 finding 1): the SCAN is read-only, the PAGE is not. This cursor used to advance the moment the scan
  # returned 0, while `family reply-due …` had not run yet - so a deferred or budget-starved family (the
  # unchecked_budget_starved exit path #1636 added) left every answerable user on the page unsent and the next tick
  # started PAST them: a starved tick then cost the page, not the cycle. It now advances in credit_families, after
  # BOTH segments' step for this page returned 0.
  RD_LIST="$OUT/reply-due.json"
  log "audiences: reply_due $(head -c 300 "$OUT/reply-due.out")"
else
  log "reply_due: no deployed audience builder ($RD_SCAN) on this tree yet (rides its PR); skipped"
fi
# [key=proof-need-ask-family] (b1 / Fable 17:5xZ): the per-need ask (E) - need_asks.py, --check-recipients (#1582);
# SIGNED-only until E's first clean coded batch sets UNSIGNED_FROM[proof-need-ask]. QA #1587: a deployed runner that
# predates #1582 (no --check-recipients) cannot be checked - logged and skipped, never a failed tick.
# Ruling 2 (3 Nov, amended 2026-11-11): free before paid; the paid segment runs when PAID_FROM[proof-need-ask] is unset
# (no barrier, [key=paid-need-ask-no-barrier]) or already reached, and a FUTURE date still holds it. Runs LAST in every
# tick (CTO MUS-27638: one need-ask segment measured ~85 min / ~50 s per recipient on node-8, reviewer 13:41Z, and free is
# checked-only until UNSIGNED_FROM is dated - first would spend the tick on zero sends and starve the paid families)
need_families() {
  if grep -q -- '"--check-recipients"' "$NEED_RUNNER" 2>/dev/null; then
    # Defect B: rebuilt right here, immediately before the stage that enforces its facts header
    build_need_list "rebuild before need families" || return 1
    family proof-need-ask free "$NEED_LIST" "$CAP" need-send || return $?
    # firstmate 2026-11-11 (Aaron: "remove whatever limiters", paid users complaining):
    # an UNSET PAID_FROM meant "never", so the paid proof-need-ask family could never run
    # and paid users were never asked. Unset now means no barrier; a set date still holds
    # the family until that date, so the sequencing lever is preserved.
    if [ -z "${PAID_FROM[proof-need-ask]:-}" ] || reached "${PAID_FROM[proof-need-ask]:-}"; then
      family proof-need-ask paid "$NEED_LIST" "$CAP" need-send || return $?
    else
      log "proof-need-ask paid: held until PAID_FROM[proof-need-ask]=${PAID_FROM[proof-need-ask]} is reached; skipped"
    fi
  else
    log "proof-need-ask: the deployed need_asks.py has no --check-recipients (#1582 not deployed); skipped"
  fi
}
# Fable d2 / firstmate 772 + 774: the wait-apology family. The audience is BUILT here, per segment, by the
# audience builder - which goes INERT (exit 2, names the source, writes no list) unless every exclusion it cannot
# infer loads. An inert build is a segment with no audience, never an unfiltered one.
APOLOGY_BUILDER="$(cfg CVO_APOLOGY_BUILDER "$HYDRA_ROOT/scripts/credit_review/wait_apology_audience.py")"
APOLOGY_PLAN_ROOT="$(cfg CVO_APOLOGY_PLAN_ROOT "/var/lib/hydra/paid-status")"
apology_family() { # <segment>
  local seg="$1" day plan out rc
  day="$(date -u +%F)"
  plan="$APOLOGY_PLAN_ROOT/$day/$seg"
  out="$OUT/wait-apology-$seg.json"
  if [ ! -d "$plan" ]; then
    log "wait-apology $seg: no paid-status run for today at $plan; skipped (never a guessed audience)"
    return 0
  fi
  py "$APOLOGY_BUILDER" --plan-dir "$plan" --segment "$seg" --out "$out" --cap "$R1_CAP" \
    >> "$OUT/wait-apology-$seg.build.log" 2>&1; rc=$?
  if [ "$rc" = 2 ]; then
    log "wait-apology $seg: builder INERT ($(tail -1 "$OUT/wait-apology-$seg.build.log")); no audience this tick"
    page "wait-apology: the audience builder is INERT for $seg - $(tail -1 "$OUT/wait-apology-$seg.build.log")"
    return 0
  fi
  if [ "$rc" != 0 ]; then
    autokill "wait-apology $seg: the audience builder failed (rc=$rc): $(tail -1 "$OUT/wait-apology-$seg.build.log")"
    return 1
  fi
  log "wait-apology $seg: $(tail -1 "$OUT/wait-apology-$seg.build.log")"
  family wait-apology "$seg" "$out" "$R1_CAP" uvn-status --campaign wait-apology || return $?
}

# [key=send-never-starved] (2026-11-11): a family that FAILS must not take the families behind it down with it. The
# group wrapper already learned this ACROSS groups (spec-deploy-lock-deferral-m1: a credit failure never skips the
# claim families), but inside credit_families every call was `|| return $?`, so reply-due failing skipped uvn-status -
# the family that actually sends - for the whole tick. On 2026-11-11 05:39Z exactly that happened: reply-due-paid's
# check timed out after 900 s on a Trino replica read, the group returned 1, and uvn-status never ran. A family that
# cannot run is a reason to run the NEXT one, not to stop. The outcomes that still end the group are the ones that end
# the TICK (TICK_ENDS=1: the deadline, a failed apply) and a kill file - those are not this
# family's problem to swallow. A DEFERRAL (rc 2) is different and still stops the group: the condition that deferred
# it - a deploy lock, a transient Trino read - is still there for the family behind it, so walking past it would only
# buy a second deferral. Only a FAILURE is worth walking past, and it is remembered so the group still reports it.
FAM_RC=0
fam() { # <cmd> <args...>: run one family step, remember a FAILURE, keep going; a DEFERRAL still stops the group
  local rc
  "$@"; rc=$?
  case "$rc" in
    0) return 0 ;;
    # rc 2 is "this family waits" (a deploy lock, a transient Trino read). The condition that deferred it is still
    # there for the family behind it, so the group stops as it always has - only a FAILURE is worth walking past.
    # A failure EARLIER in the group still outranks it: returning 2 here would make run_group report a clean deferral
    # and the tick exit 2, and the failed family would vanish from the tick's outcome (QA #1882).
    2) [ "$FAM_RC" = 1 ] && return 1; FAM_RC=2; return 2 ;;
  esac
  [ "$TICK_ENDS" = 1 ] && return "$rc"
  killed && return "$rc"
  FAM_RC=1
  return 0
}
credit_families() {
  FAM_RC=0
  # d2: PAID first, then free (the ladder's shared first-batch budget is charged in this order).
  fam apology_family paid || return $?
  fam apology_family free || return $?
  if [ -n "$RD_LIST" ]; then
    fam family reply-due paid "$RD_LIST" "$RD_CAP" uvn-status --campaign uvn-status || return $?
    fam family reply-due free "$RD_LIST" "$RD_CAP" uvn-status --campaign uvn-status || return $?
    # r5 (1574 finding 1, round 2): a 0 return is NOT proof of completion - family() also returns 0 when the tick budget
    # is reached, when its worst case does not fit, when it is SIGNED-only or when the daily cap is spent, and in those
    # cases it has processed nobody. So the cursor moves only on the marker the family writes when its step for this
    # page is genuinely done; a deferral leaves the cursor where it was and the next tick re-walks the same page
    # rather than skipping users we never reached.
    if [ -f "$OUT/reply-due-paid.done" ] && [ -f "$OUT/reply-due-free.done" ]; then
      # QA #1574 (round 6, Important): the POSITION and the SEARCH TOKEN are ONE coordinate pair and were being committed
      # independently. `--start-entry` indexes the list the CURRENT token builds, so writing a new token in the same
      # breath moved the search to a different slice while the position still pointed into the old one: the next tick
      # skipped the first N users of the new slice, and skipped NONE of a slice holding fewer than N rows while its
      # cursor still moved past it. The pair now advances together - the token may only move when the page wrapped to 0,
      # i.e. when every row the token collected has been walked. Any other position means "still inside the slice the
      # token on disk builds", so that token is HELD and the next tick rebuilds the same slice and continues there.
      nxt="$(page_next "$OUT/reply-due.json" 2>/dev/null || true)"
      advance_cursor reply-due "$RD_CURSOR" "$OUT/reply-due.json" "$rd_cur"
      # the IDENTITY half of the cursor rides with the position: written from the same page record, at the same points
      # (a page the family did not finish leaves BOTH where they were, so the next tick re-walks what it never reached).
      persist_reply_due_anchor "$OUT/reply-due.json" "$RD_ANCHOR"
      if [ "${rd_ups_ok:-0}" = "1" ]; then
        if [ "$nxt" = "0" ]; then
          persist_reply_due_upstream "$OUT/reply-due.json" "$RD_UPSTREAM"
        else
          log "reply-due: the search token is HELD on this slice - the page stopped at entry ${nxt} (position ${nxt} is inside the slice the token builds, so the next tick rebuilds it and continues from ${nxt}; a token moved past an unwalked slice would skip every row it had collected)"
        fi
      fi
    else
      log "reply-due: the page is NOT done (a segment deferred: budget, fit, sign-off or cap); the cursor stays at $rd_cur"
    fi
  fi
  local c2=() seg
  for seg in paid free; do log "uvn-status-$seg: class C (/c2 corrected asks) $([ -z "$(c2_args "$seg")" ] && echo "ARMED by its row" || echo "signed-only (--no-correction)")"; done
  # a REBUILD that fails still ends the group: the family behind it would read a list the builder did not just write,
  # and messaging from a stale owing list is how a user gets told twice. A family that fails is different - the next
  # family has its own list and its own facts.
  rebuild_owing_uvn "uvn-status paid" || return 1
  mapfile -t c2 < <(c2_args paid)
  fam family uvn-status paid "$OUT/owing-uvn.json" "$CAP" uvn-status --campaign uvn-status "${c2[@]}" || return $?
  fam family r1 paid "$OUT/receipts/receipts-received.json" "$R1_CAP" uvn-status --campaign status-doc-received --wording received || return $?
  # the reminder runs between the paid and the free ask: after every paid family (paid first, as everywhere), and
  # BEFORE the free ask's 600-entry walk, which is the family that uses up the tick. Group rules are everyone's: a
  # failure is remembered and walked past, a deferral or a failed rebuild stops the group.
  # The list is rebuilt right before the family, as for the ask (a stale list is how a user is told twice) - but only
  # when the build minutes ago listed somebody: once the first cohort is through, "nobody is due" is the usual answer
  # and a rebuild for it would be a replica read per tick for nothing.
  if [ "$(reminder_listed)" != 0 ]; then rebuild_owing_uvn "uvn-reminder-14" || return 1; fi
  fam reminder_family paid || return $?
  fam reminder_family free || return $?
  # uvn-new-rows runs here for the reminder's reason: after every paid family and BEFORE the free ask's walk, which
  # uses up the tick. Its list is rebuilt right before it (a stale list is how a user is told twice), and only when
  # the last build listed somebody.
  if [ "$(new_rows_listed)" != 0 ]; then rebuild_owing_uvn "uvn-new-rows" || return 1; fi
  fam new_rows_family paid || return $?
  fam new_rows_family free || return $?
  rebuild_owing_uvn "uvn-status free" || return 1
  mapfile -t c2 < <(c2_args free)
  fam family uvn-status free "$OUT/owing-uvn.json" "$CAP" uvn-status --campaign uvn-status "${c2[@]}" || return $?
  fam family r1 free "$OUT/receipts/receipts-received.json" "$R1_CAP" uvn-status --campaign status-doc-received --wording received || return $?
  return "$FAM_RC"
}
# uvn-reminder-14 (captain 2026-11-13 15:08Z): ONE reminder to a user whose last verification ask is a sent uvn-status
# ask at least 14 days old, who neither replied nor sent a document, and whose asked requests still wait in core. The
# audience is the owing builder's uvn_reminder_14 class (owing_proof.build: the rows the ask named and that are still
# owed, for the users verify_ledger.reminder14_user_done says are due), rebuilt immediately before the family for the
# reason every uvn-status family is (Defect B). It sends through the uvn-status runner under its own campaign, so every
# gate of the ask applies, plus its own: any reply after the ask holds it, and no body goes without a signed approve.
# reminder_listed: how many users the newest owing build listed for the reminder ("unreadable" when it cannot be read,
# which is never 0: the caller then rebuilds and the family reads the list itself).
reminder_listed() {
  [ -s "$OUT/owing-reminder-14.json" ] || { echo 0; return 0; }
  py -c 'import json,sys
try:
    print(len(json.load(open(sys.argv[1])).get("users") or []))
except Exception:
    print("unreadable")' "$OUT/owing-reminder-14.json" 2>/dev/null || echo unreadable
}

reminder_family() { # <segment>
  local seg="$1" list="$OUT/owing-reminder-14.json"
  if [ ! -s "$list" ]; then
    log "uvn-reminder-14 $seg: the owing builder wrote no reminder list; skipped (never a guessed audience)"; return 0
  fi
  # A policy with no row for this campaign means it never applies - and it must mean ONLY that. family() reads a
  # missing row as an unreadable cap source and kills the whole tick, which is right for a family that has always
  # had its row and wrong for the newest one: node-8's policy file is also edited by hand and restored from .bak
  # copies, and a restore to a copy older than this family must stop the reminder, not every verification send.
  # An unreadable policy is not decided here: the family's own cap read fails it closed, as for every family.
  if [ "$(py -c 'import json,sys
try:
    p = json.load(open(sys.argv[1])); c = sys.argv[2]; s = sys.argv[3]
except Exception:
    print("unreadable"); raise SystemExit(0)
row = (p.get("daily_cap") or {}).get(c) if isinstance(p, dict) else None
grp = [g for g, cs in ((p.get("groups") or {}) if isinstance(p, dict) else {}).items() if isinstance(cs, list) and c in cs]
print("row" if isinstance(row, dict) and s in row and grp else "norow")' "$POLICY" uvn-reminder-14 "$seg" 2>/dev/null)" = norow ]; then
    log "uvn-reminder-14 $seg: the policy has no daily_cap row or no group for uvn-reminder-14; skipped (a campaign with no row never applies)"; return 0
  fi
  # nobody due is the usual state once the first cohort is through: say so and start no family (no check, no page of
  # the list, no cursor). An unreadable list is not "nobody": the family reads it and fails closed.
  if [ "$(reminder_listed)" = 0 ]; then
    log "uvn-reminder-14 $seg: nobody is due a reminder (0 listed); skipped"; return 0
  fi
  log "uvn-reminder-14 $seg: audience $(py -c 'import json,sys
u = json.load(open(sys.argv[1])).get("users") or []
c = (json.loads(open(sys.argv[2]).read().strip().splitlines()[-1]).get("counts") or {})
print("%d listed (%d paid, %d free); the ledger left out: %s" % (
    len(u), sum(1 for x in u if x.get("paid")), sum(1 for x in u if not x.get("paid")),
    ", ".join("%s=%s" % (k[len("reminder_skip_"):], v) for k, v in sorted(c.items()) if k.startswith("reminder_skip_")) or "nobody"))' \
    "$list" "$OUT/owing.out" 2>/dev/null || echo "(not readable here; the runner reads the list itself)")"
  family uvn-reminder-14 "$seg" "$list" "$R14_CAP" uvn-status --campaign uvn-reminder-14
}
# uvn-new-rows (ask-never-asked-r1, 2026-11-14): the follow-up ask to a user who already got a SENT uvn-status ask, about
# owed requests that no ask named. The audience is the owing builder's uvn_new_rows class; the ledger's own rule
# (verify_ledger.new_rows_user_done, read by the runner and again by the gate) defers every listed user with no sent ask,
# because the opener "Since we last wrote" would be false for them. It sends through the uvn-status runner under its
# own campaign, so every gate of the ask applies, and no body goes without a signed approve. Always --no-correction:
# the /c2 corrected opener together with this one is not approved copy (the gate refuses it as n1_c2_uncoded).
# new_rows_listed: users on the newest build's list. "missing" and "unreadable" are never 0: a build that was asked for
# the class and wrote no file, or wrote one that is not a JSON object with a "users" LIST, has measured nobody, and
# "nobody is listed" would let the tick stay green with no ask. The builder always writes the list (owing_proof.class_list),
# empty when nobody is in the class, so only [] is 0.
new_rows_listed() {
  [ -s "$OUT/owing-new-rows.json" ] || { echo missing; return 0; }
  py -c 'import json,sys
try:
    d = json.load(open(sys.argv[1]))
    u = d["users"] if isinstance(d, dict) else None
    print(len(u) if isinstance(u, list) else "unreadable")
except Exception:
    print("unreadable")' "$OUT/owing-new-rows.json" 2>/dev/null || echo unreadable
}

new_rows_family() { # <segment>
  local seg="$1" list="$OUT/owing-new-rows.json"
  # As for the reminder: a policy with no row for this campaign means it never applies, and ONLY that. family() would
  # read a missing row as an unreadable cap source and end the whole tick; a policy file restored to a copy older than
  # this family must stop this family, not every verification send.
  if [ "$(py -c 'import json,sys
try:
    p = json.load(open(sys.argv[1])); c = sys.argv[2]; s = sys.argv[3]
except Exception:
    print("unreadable"); raise SystemExit(0)
row = (p.get("daily_cap") or {}).get(c) if isinstance(p, dict) else None
grp = [g for g, cs in ((p.get("groups") or {}) if isinstance(p, dict) else {}).items() if isinstance(cs, list) and c in cs]
print("row" if isinstance(row, dict) and s in row and grp else "norow")' "$POLICY" uvn-new-rows "$seg" 2>/dev/null)" = norow ]; then
    log "uvn-new-rows $seg: the policy has no daily_cap row or no group for uvn-new-rows; skipped (a campaign with no row never applies)"; return 0
  fi
  # Every build of this tick asks for the class, so no file, or a file with no "users" list, is NOT "nobody is listed":
  # the audience was never measured. The family fails (the tick exits 1, the other families still run) instead of
  # skipping green with nobody asked.
  local n; n="$(new_rows_listed)"
  case "$n" in
    0) log "uvn-new-rows $seg: nobody is listed (0 users); skipped"; return 0 ;;
    missing)
      log "uvn-new-rows $seg: UNMEASURED - the owing builder wrote no new-rows list ($list); nobody was asked and that is not '0 listed'. This family fails; the others continue"
      return 1 ;;
    ''|*[!0-9]*)
      log "uvn-new-rows $seg: UNMEASURED - the new-rows list ($list) is not a JSON object with a users list; nobody was asked and that is not '0 listed'. This family fails; the others continue"
      return 1 ;;
  esac
  log "uvn-new-rows $seg: audience $(py -c 'import json,sys
u = json.load(open(sys.argv[1])).get("users") or []
print("%d listed (%d paid, %d free)" % (len(u), sum(1 for x in u if x.get("paid")), sum(1 for x in u if not x.get("paid"))))' \
    "$list" 2>/dev/null || echo "(not readable here; the runner reads the list itself)")"
  family uvn-new-rows "$seg" "$list" "$NR_CAP" uvn-status --campaign uvn-new-rows --no-correction
}
# [key=proof-refusal-family] (captain 2026-11-15): the refusal note. One group of its own, after the credit families and
# before the need ask, so an ask and a refusal for one person are never decided in the same breath: the gate's 7-day
# rule holds whichever comes second, and the builder leaves out every request a proof-need-ask already named.
#   read-back -> build -> paid -> free
# The read-back is the family's entry condition, not a report: it reads EVERY note the campaign has sent (sent =
# claimed, 0 hard bounces, 0 spam complaints) before any list is built. A failed read-back (rc 3) and one that could
# not be made (rc 2) both send nothing; neither is repaired here, and the next tick asks again.
PR_LIST=""
refusal_readback() { # 0 = every note sent so far reads back clean (or none was sent yet); 1 = this tick sends none
  local rc out="$OUT/proof-refusal-readback.json" stamp="$STATE/proof-refusal-readback.paged" what sum
  py "$PR_RUNNER" readback --ledger "$LEDGER" --out "$out" > "$OUT/proof-refusal-readback.out" 2>&1; rc=$?
  if [ "$rc" = 0 ]; then
    log "proof-refusal read-back: ok $(head -c 300 "$OUT/proof-refusal-readback.out")"
    rm -f "$stamp" 2>/dev/null || true
    return 0
  fi
  if [ "$rc" = 3 ]; then what="STOP (sent != claimed, a hard bounce or a spam complaint)"
  else what="UNMEASURED (rc=$rc: the ledger or a contact could not be read)"; fi
  log "proof-refusal read-back: $what; no refusal is sent this tick: $(tail -c 400 "$OUT/proof-refusal-readback.out")"
  # one page per distinct finding: an unchanged stop is quiet, a new one pages at once
  sum="$(cksum < "$OUT/proof-refusal-readback.out" 2>/dev/null | tr -d ' \n')"
  if [ "$(cat "$stamp" 2>/dev/null)" != "$rc:$sum" ]; then
    page "proof-refusal read-back $what; the family sends nothing until it reads back clean. See $OUT/proof-refusal-readback.out"
    { printf '%s\n' "$rc:$sum" > "$stamp.tmp" && mv -f "$stamp.tmp" "$stamp"; } 2>/dev/null || true
  fi
  return 1
}
build_refusal_list() { # <label>
  local rc
  py "$PR_RUNNER" build --ledger "$LEDGER" --out "$OUT/proof-refusal-all.json" > "$OUT/proof-refusal.out" 2>&1; rc=$?
  if [ "$rc" != 0 ] && builder_deadline "$rc" "proof-refusal builder ($1)"; then return 1; fi
  if [ "$rc" != 0 ]; then
    log "proof-refusal builder failed ($1): rc=$rc $(tail -c 300 "$OUT/proof-refusal.out")"
    return 1
  fi
  # the exclude file (users another lane messages today) holds them out of this family too; the runner takes no
  # --exclude-users, so the tick filters its list, as it does the need list
  py - "$OUT/proof-refusal-all.json" "$EXCLUDE" "$OUT/proof-refusal.json" <<'PY' >> "$OUT/tick.log" || { log "proof-refusal list filter failed ($1)"; return 1; }
import json, os, sys
src, excl, out = sys.argv[1:4]
doc = json.load(open(src))
held = {l.strip() for l in open(excl) if l.strip() and not l.startswith("#")} if os.path.exists(excl) else set()
users = doc.get("users") or []
keep = [u for u in users if str(u.get("user_id")) not in held]
if keep:
    json.dump({**doc, "users": keep}, open(out, "w"))
else:
    open(out, "w").close()                       # an empty audience: the family logs and skips
print(f"proof-refusal list: {len(users)} users, {len(users) - len(keep)} held out by the exclude file")
PY
  PR_LIST="$OUT/proof-refusal.json"
  log "audiences: proof-refusal ($1) $(head -c 600 "$OUT/proof-refusal.out")"
  return 0
}
refusal_families() {
  if [ ! -r "$PR_RUNNER" ]; then log "proof-refusal: $PR_RUNNER is not deployed; skipped"; return 0; fi
  # As for the reminder and the new-rows family: a policy with no row for this campaign means it never applies, and
  # ONLY that. family() would read a missing row as an unreadable cap source and end the whole tick.
  if [ "$(py -c 'import json,sys
try:
    p = json.load(open(sys.argv[1])); c = sys.argv[2]
except Exception:
    print("unreadable"); raise SystemExit(0)
row = (p.get("daily_cap") or {}).get(c) if isinstance(p, dict) else None
grp = [g for g, cs in ((p.get("groups") or {}) if isinstance(p, dict) else {}).items() if isinstance(cs, list) and c in cs]
print("row" if isinstance(row, dict) and "paid" in row and "free" in row and grp else "norow")' "$POLICY" proof-refusal 2>/dev/null)" = norow ]; then
    log "proof-refusal: the policy has no daily_cap row or no group for proof-refusal; skipped (a campaign with no row never applies)"; return 0
  fi
  refusal_readback || return 1
  build_refusal_list "rebuild before the refusal family" || return 1
  family proof-refusal paid "$PR_LIST" "$PR_CAP" refusal-send || return $?   # paid first: it takes the shared 100
  family proof-refusal free "$PR_LIST" "$PR_CAP" refusal-send || return $?
}
claim_families() {
  if [ ! -s "$CLAIM_LIST" ]; then log "claim families: no claim list at $CLAIM_LIST (the claim lane drops it); skipped"; return 0; fi
  # QA #1541: the exclude file holds users out of EVERY family - the claim runners take no --exclude-users, so the
  # held claimants are removed from the claim list before any check / preview / apply (unreadable = no claim family)
  local cl="$OUT/claims-filtered.json"
  py - "$CLAIM_LIST" "$EXCLUDE" "$cl" <<'PY' >> "$OUT/tick.log" 2>&1 || { autokill "claim families: the claim list or the exclude file is unreadable"; return 1; }
import json, os, sys
src, excl, out = sys.argv[1:4]
doc = json.load(open(src))
held = set()
if os.path.exists(excl) and os.path.getsize(excl):
    held = {l.strip() for l in open(excl) if l.strip() and not l.startswith("#")}
claims = doc.get("claims") if isinstance(doc, dict) else None
if not isinstance(claims, list):
    sys.exit("claim list has no claims[]")
keep = [c for c in claims if str(c.get("user_id")) not in held]
json.dump({**doc, "claims": keep}, open(out, "w"))
print(f"claim list: {len(claims)} claims, {len(claims) - len(keep)} held out by the exclude file")
PY
  # p1 638 / r5 639 (16Z on 29f: the claim checks ran a list signed on e4f65c4a with 5e733e0f deployed): a claim list
  # whose signed_on is not EXACTLY the deployed head is never checked - the claim lane rebuilds it on the deployed head.
  # Read after the filter (which kills on an unreadable list). Refused LOUD (logged + paged) before any check; the
  # credit families still run. An unreadable deployed sha or a missing signed_on = refused.
  local cl_signed dep_sha
  cl_signed="$(py -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("signed_on") or "" if isinstance(d, dict) else "")' "$cl" 2>/dev/null)" || cl_signed=""
  dep_sha="$(cat "$DEPLOYED_SHA_FILE" 2>/dev/null)" || dep_sha=""
  if ! [[ "$dep_sha" =~ ^[0-9a-f]{40}$ ]] || [ "$cl_signed" != "$dep_sha" ]; then
    log "claim families: list_signed_on_stale - $CLAIM_LIST is signed on ${cl_signed:-(none)}, deployed ${dep_sha:-(unreadable)}; not checked this tick (the claim lane rebuilds it on the deployed head)"
    # Page ONCE per stale pair (signed_on, deployed), not every tick: a list rebuilt 20 minutes later is still
    # announced, but a head that stays stale for three ticks is one page, not three (Fable driver 2026-11-05
    # 14:33Z). The marker is written ONLY on a CONFIRMED delivery: `notify` cannot report a failed page (its last
    # command is the lib's slack_notify_critical, and slack_notify ends `|| true`), so this uses notify_confirmed -
    # slack_notify_critical_status, the one path that returns 0 only on a post Slack confirmed - and an older lib
    # without it is NOT delivered. (page_confirmed is the payload-file variant, used by the reader alarm; the two
    # are legitimately different and both stay.)
    # A failed page is retried next tick rather than silenced; the marker is cleared the moment the list is fresh
    # again, so the next stale event pages again (QA on #1796, Important 1).
    stale_pair="${cl_signed:-(none)} ${dep_sha:-(unreadable)}"
    if [ "$(cat "$STATE/claim-list-stale-paged" 2>/dev/null)" = "$stale_pair" ]; then
      log "claim families: list_signed_on_stale already paged for this pair; not paging again"
    elif notify_confirmed "claim families: list_signed_on_stale (signed on ${cl_signed:0:12}, deployed ${dep_sha:0:12}) - claim list not checked; rebuild it on the deployed head"; then
      printf '%s\n' "$stale_pair" > "$STATE/claim-list-stale-paged" 2>/dev/null || true
    else
      log "claim families: list_signed_on_stale page NOT DELIVERED (${PAGE_WHY:-unknown}); will page again next tick"
    fi
    return 0
  fi
  rm -f "$STATE/claim-list-stale-paged" 2>/dev/null || true
  family claim-proof-ask paid "$cl" "$CLAIM_CAP" claim-proof-ask || return $?
  family claim-status paid "$cl" "$CLAIM_CAP" claim-status || return $?
  family claim-proof-ask free "$cl" "$CLAIM_CAP" claim-proof-ask || return $?
  family claim-status free "$cl" "$CLAIM_CAP" claim-status || return $?
}
# ruling B: an UNMEASURED tick whose page could not be delivered left a durable marker. Retry it at the top of every
# tick; a marker that still cannot be delivered fails this tick closed (the outage is never only a log line).
for m in "$STATE"/zero-unmeasured-undelivered-*; do
  [ -e "$m" ] || continue
  why="$(head -c 400 "$m" 2>/dev/null | tr '\n' ' ')"
  if notify "RETRY (page previously undelivered): $why"; then
    log "retried the undelivered zero-read page from $(basename "$m"); delivered - marker cleared"
    rm -f "$m"
  else
    log "STOP: the undelivered zero-read page in $(basename "$m") still cannot be delivered; this tick fails closed"
    exit 1
  fi
done

# spec-deploy-lock-deferral-m1 addendum 2 (Fable 2026-11-05 14:4xZ): a TRANSIENT family failure (rc=2: deploy lock, Trino transient) stops THAT GROUP and the tick
# CONTINUES to the next one, instead of `exit 1` starving every family behind it. A hard failure (rc=1: kill file,
# partial send, zero-read unmeasured, a real SQL/auth error) still exits 1 immediately. A deferred tick exits 2, so it is
# visible in the exit code and the log without having cost the families behind it.
#
# Fable d2 (2026-11-08, the weekday ordering): a credit-family FAILURE (rc=1) must not skip the claim families, and a
# claim-family failure must not skip the credit families - the families are independent audiences, and `|| exit 1`
# starved everyone behind the first bad check (the 02:30Z tick: uvn-status died, claims and need got nothing). A failed
# GROUP is recorded, the next group still runs, and the tick exits 1 at the end so the failure stays loud. This covers
# the READ-ONLY stages (check, bodies, accepted-bodies, a list rebuild): nothing was sent, so the other audience loses
# nothing by going on. An UNMEASURED STOP is one of these read-only failures since [key=family-unmeasured-stop]: the
# families behind it each have their own bar. The family failures that still end the tick at once (TICK_ENDS=1): the TICK_HARD_S deadline (nothing behind
# it would fit), a FAILED or PARTIAL APPLY (QA #1799 / spec-deploy-lock-deferral-m1: rows may be sent, the post-send
# rails own it and more sends are the wrong direction), and an auto-kill (the kill file means nothing more runs).
# [key=tick-yield] (2026-11-15): what each family's walk bought this tick, read from the check files this tick just
# wrote (credit_review/tick_yield.py; no ledger, replica or Intercom read). A family that is never reached has had a
# page since [key=claims-never-starved]; a family that IS reached, spends the tick on gate calls and sends nobody had
# none - on 2026-11-13 uvn-status walked 3,252 users for 1 send and it took a hand-run census to see that one rule
# answered 62% of the gate calls. It runs on every way the tick ends once the families began. It changes no list, cap
# or gate and can never fail the tick: a reader that is absent or does not answer is logged as not measured. The repeat
# window starts only on a CONFIRMED page (`paged`), so an undelivered page is owed again next tick.
TICK_YIELD="$SCRIPTS_DIR/credit_review/tick_yield.py"
tick_yield() {
  local out line page=""
  [ -r "$TICK_YIELD" ] || { log "tick yield: no reader at $TICK_YIELD on this tree; not measured this tick"; return 0; }
  out="$(py -I "$TICK_YIELD" record --out "$OUT" --state "$STATE/tick-yield.json" 2>&1)" \
    || { log "tick yield UNMEASURED: the reader did not answer ($(printf '%s' "$out" | tail -1 | cut -c1-200)); not measured this tick"; return 0; }
  while IFS= read -r line; do
    case "$line" in
      "PAGE: "*) page="${line#PAGE: }" ;;
      "") ;;
      *) log "$line" ;;
    esac
  done <<< "$out"
  [ -n "$page" ] || return 0
  if notify_confirmed "$page"; then
    py -I "$TICK_YIELD" paged --state "$STATE/tick-yield.json" >/dev/null 2>&1 \
      || log "tick yield: the page was delivered but its repeat window could not be recorded; it repeats next tick"
  else
    log "tick yield: page NOT DELIVERED (${PAGE_WHY:-unknown}); owed again next tick"
  fi
}
FAILED_GROUPS=""
run_group() { # <label> <group fn>: 0 = done, 1 = hard stop (exit 1), 2 = deferred (continue, DEFERRED=1)
  local label="$1" rc; shift
  "$@"; rc=$?
  case "$rc" in
    0) return 0 ;;
    2) DEFERRED=1; log "$label: deferred (transient); continuing to the next family group"; return 0 ;;
  esac
  if [ "$TICK_ENDS" = 1 ]; then log "$label: FAILED at the deadline or a failed apply; the tick ends here"; return 1; fi
  if killed; then log "$label: FAILED and the kill file is present (auto-kill); nothing more runs"; return 1; fi
  FAILED_GROUPS="${FAILED_GROUPS:+$FAILED_GROUPS, }$label"
  log "$label: FAILED (rc=$rc); the next family group still runs (a credit failure never skips the claim families and a claim failure never skips the credit families); the tick exits 1 at the end"
  return 0
}
# [key=claims-never-starved] (2026-11-12, replaces the 10-30 "claims first on Sat/Sun, credit first on weekdays"): the
# claim families run FIRST every day, inside their own slice. On weekdays they ran after the credit families, and on
# 2026-11-12 08:00Z those used the whole tick budget on 18 sends: all four claim segments logged "tick budget 6000s
# reached". A group that is never reached is not low priority, it is unreachable.
log "claim families first (every day), held to their own ${CLAIM_GROUP_BUDGET_S}s slice"
GROUP_END_S=$(( $(elapsed) + CLAIM_GROUP_BUDGET_S ))
run_group "claim families" claim_families || { tick_yield; exit 1; }
GROUP_END_S=""
run_group "credit families" credit_families || { tick_yield; exit 1; }
run_group "refusal family" refusal_families || { tick_yield; exit 1; }
run_group "need families" need_families || { tick_yield; exit 1; }
tick_yield
if [ -n "$FAILED_GROUPS" ]; then
  log "tick done with FAILED group(s): $FAILED_GROUPS (the other groups ran); exit 1"
  exit 1
fi
log "tick done"
if [ "$DEFERRED" = 1 ]; then
  log "tick deferred: a transient condition (deploy lock / Trino) deferred at least one family; nothing was refused and no kill file was written"
  exit 2
fi
exit 0
