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
#     -> <https://app.intercom.com/a/inboxes/all/conversations/215474457437629|215474457437629>
# The URL pattern mirrors check-escalated.sh -- the canonical in-skill Intercom conv URL.
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

perl -pe 's{(?<![0-9/|])([0-9]{15,16})(?![0-9])}{<https://app.intercom.com/a/inboxes/all/conversations/$1|$1>}g'
