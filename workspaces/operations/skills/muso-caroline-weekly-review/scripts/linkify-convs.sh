#!/usr/bin/env bash
# Turn every Intercom conversation id in the assembled digest into a clickable Slack
# link. Reads stdin, writes stdout. Runs in the Phase-3 pipeline AFTER redact-output.sh
# (so it only ever sees already-PII-scrubbed text) and BEFORE assert-digest-contract.sh.
#
# WHY a script, not the LLM: same rule as scan-voice.sh / redact-output.sh -- the grader
# must not be trusted to emit fiddly Slack <url|label> syntax for every conversation id
# (the digest delivers as Slack mrkdwn via the cron's announce mode, so <url|label>
# renders). The grader writes BARE 15-16 digit ids; this turns each into:
#   215474457437629
#     -> <https://app.intercom.com/a/inbox/dwjzhcge/inbox/conversation/215474457437629|215474457437629>
# The URL pattern mirrors check-escalated.sh + render-digest.py -- the canonical
# in-skill Intercom conv URL. The legacy inboxes/all/conversations/<id> form 404s.
# Workspace id comes from INTERCOM_WORKSPACE_ID (default dwjzhcge), exactly like
# render-digest.py's CONV_URL; the two MUST agree (same text pipeline).
#
# WHY perl: the match needs non-consuming lookarounds so two adjacent ids both wrap and
# the pass is idempotent; BSD/GNU sed has no lookbehind. perl ships on node-8 (a git
# dependency) and on the mac (where the bats suite runs).
#
# The lookbehind excludes:
#   0-9  -- don't wrap the leading 15-16 of a longer digit run;
#   /    -- don't re-wrap an id already inside a conversations/<id> URL (also guards a
#           hand-written URL the grader was told not to emit);
#   |    -- don't re-wrap the label id of a link this script just produced.
# Combined with the lookahead (?![0-9]), running twice == running once. The only 15-16
# digit tokens in the digest are conversation ids (counts/scores/dates are short;
# email/phone/stripe are already redacted upstream), so wrapping every match is safe.
set -euo pipefail

# LC_ALL=C: the regex is pure ASCII/digits, so byte semantics are exactly
# right — and it stops perl spraying "Setting locale failed" warnings on
# stderr when the caller's LANG names a locale the host never generated
# (the node-8 actions-runner .env declares en_US.UTF-8, which isn't
# locale-gen'd there; bats merges that stderr into $output and the CI
# first-line assertions broke on it — PR #496).
# Interpolate the workspace id via perl's %ENV (not the shell) so the URL never
# has to be shell-quoted into the perl program; default it inline. The lookbehind
# already excludes `/`, so an id already inside .../conversation/<id> is not
# re-wrapped (idempotent).
LC_ALL=C INTERCOM_WORKSPACE_ID="${INTERCOM_WORKSPACE_ID:-dwjzhcge}" perl -pe 's{(?<![0-9/|])([0-9]{15,16})(?![0-9])}{<https://app.intercom.com/a/inbox/$ENV{INTERCOM_WORKSPACE_ID}/inbox/conversation/$1|$1>}g'
