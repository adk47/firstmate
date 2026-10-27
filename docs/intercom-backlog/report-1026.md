# Intercom customer-last backlog: census, triage and copy for Fable (2026-10-26)

Lane: intercom-backlog-i1 (taken over from cs-systemic-c2). Everything below was measured
read-only from node-8 at 21:14Z: Intercom search, the core replica through Trino, and the verify
ledger. **No customer message has been sent and no conversation has been closed by this lane.**

Tools (this PR, `scripts/intercom-backlog/`, all read-only):
- `census.py`: lists every OPEN conversation where the customer spoke last. It writes
  `/var/lib/intercom-backlog-i1/census-<UTC>.jsonl` (0600) on node-8 and prints counts only.
- `triage.py`: joins each row to the user's live core state (pending credit rows, UVN rows, proof
  responses, claims, paid flag) and to the verify ledger, then assigns ONE rule-based action.
- `lists.py`: renders the triage as tables. No names, no emails.

## 1. Census

5,260 open conversations, 1,938 of them customer-last (the steward reads 1,939).

| band | customer-last |
|---|---|
| < 1 day | 27 |
| 1-30 days | 170 |
| > 30 days | 1,741 |

The steward counts 111 in the 1-30 day band. This census counts 170 because it also counts an
inbound first message that nobody ever answered. The steward counts only `last_contact_reply_at`.

## 2. Triage (live state, first matching rule wins)

| action | < 1 d | 1-30 d | > 30 d | total | what happens |
|---|---|---|---|---|---|
| captain-legal | 2 | 1 | 1 | 4 | captain's list (section 3) |
| captain-billing | 1 | 11 | 122 | 134 | captain's list (section 3) |
| gate-uvn-status | 11 | 25 | 125 | 161 | `intercom-verify-request.sh --campaign uvn-status` (approved ask copy, ledgered) |
| gate-team-review | 1 | 10 | 16 | 27 | `status-team-review` (approved Copy B0 / count note) |
| ledger-today | 0 | 5 | 85 | 90 | already had a ledger note today: tomorrow (one message per user per day) |
| claim-pending | 1 | 6 | 3 | 10 | `claim-status` copy, which is SEND-LOCKED (`CLAIM_STATUS_COPY_APPROVED=0`) |
| no-identity | 1 | 52 | 594 | 647 | Intercom `external_id` matches no account (stale UUIDs): no status can be stated |
| draft-credit | 0 | 15 | 112 | 127 | nothing pending: needs category copy (section 4) |
| draft-claim | 5 | 4 | 19 | 28 | section 4 |
| draft-merge | 0 | 5 | 7 | 12 | section 4 |
| draft-removal | 1 | 8 | 3 | 12 | section 4 |
| draft-account | 0 | 5 | 9 | 14 | section 4 |
| draft-stats | 0 | 2 | 24 | 26 | section 4 |
| draft-other | 4 | 21 | 621 | 646 | section 4 |

The topic is a keyword rule over subject + first message, so it is noisy. The recent band (< 30 d) was
read by hand. Fixes to the captain list from that reading are in section 3. The > 30 d tail is not
read one by one; it gets the per-category apology after Fable's GO.

### Why the gate rows are not being sent tonight
- The deployed driver hard-codes its day caps: `uvn_status.DAILY_MAX = 400` for asks and
  `STATUS_DAILY_MAX = 1000` for status notes. Today the ledger shows uvn-status 400 sent and
  status-team-review 1,004 sent, so both caps are spent.
- The captain's 20:35Z "in-app status/asks uncapped tonight" is not in the deployed code: node-8
  is DEPLOY BLOCKED at 14d55b2d.
- `gate-doc-received` came out 0 because core's `proofRequest.responseAt` is not where the
  "proof on file" lives. The gate's own Intercom check still skips a user who attached documents,
  so the uvn-status rows are safe as they are.

## 3. Captain's list (money and legal: no reply from this lane)

Recent band, read by hand (paid = active or trialing workspace subscription):

| conversation | what it is | paid |
|---|---|---|
| 215476566208497 | **formal trademark cease-and-desist** (registration number cited), addressed to Jan. Under the 10-23 11:59Z rule an aggressive legal threat means: hide the disputed item now and route the reply via counsel (legal@) | - |
| 215476542559417 | "I would like to speak to Aaron Kaufman about a lawsuit" | - |
| 215476359577538 | signed up monthly at GBP 9.84, charged GBP 84.66 | paid |
| 215476141235223 | tried to cancel, got switched to annual and charged USD 108, wants a refund (the same pattern as the 10-12 "refund annual, back to monthly" order) | - |
| 215476250947389 | "still haven't received my payment back", account still Pro | - |
| 215476481682087 | wants the subscription cancelled for them | paid |
| 215476356274043 | "I need to cancel my account" | - |
| 215471306255424 | subscription thread (support@ email) | - |
| 215476346408173 | plaque order: asks whether the number can be rounded to 1,000 (German) | - |

Moved OFF the captain list after reading (keyword misfires): 215475055007096 (credit proof
reply), 215476530302829 (SoundExchange auto-reply: close, reason auto-responder),
215476520259268 (sign-in email change on a Pro account), 215476495717959 (profile rename),
215476297067085 (dashboard vs export numbers), 215476540440008 (manager's merge request).

Tail: 122 billing and 1 legal conversations over 30 days old. The full list is
`docs/intercom-backlog/captain-list-1026.md` (ids, band, age, paid flag; no PII).

## 4. Copy for Fable's GO (needs-decision)

Every message renders from FIXED text. The only fill-ins are server facts (first name and up to 3
titles from the replica, the profile name from core). No model writes any part of a message. The
copy contains no sanitizer words and no em dash. It is sent through `intercom-ops-write.sh reply
--customer-facing --approved-by U7RP6HKUZ` (the captain's id, as the fleet already does under his
standing orders) and recorded as one ledger row per user (see decision D3).

**Opener, recent band (1-30 d):** "Hi {first name|there}, thanks for your patience with this."
**Opener, tail (> 30 d):** "Hi {first name|there}, I'm sorry we didn't get back to you sooner."
**Closer, both bands:** "If you still need help with this, just reply here and it will come
straight back to our team."

The status line between them is chosen by the rule, from live state at send time:

| category | status line |
|---|---|
| credit, nothing pending | "Every credit request on your account has now been reviewed, and you can see each credit's status on your profile." |
| credit, rows pending (tail only; recent goes through the gate) | "Your credit request(s) for {titles} are with our team for review. Nothing else is needed from you right now." (approved Copy B0, unchanged) |
| claim, claim pending | "Your claim on {profile_name} is with our team for review, and we will message you here as soon as it has been checked." (Fable's claim-status sentence, verbatim) |
| claim, none pending | "There is no profile claim waiting on your account right now. If you still want to claim a profile, open it on muso.ai and start a claim from there." |
| merge | "We can merge profiles once every profile involved is claimed, verified and in your workspace. If that is already the case, reply here with the profile links and we will take it from there." (the 10-23 15:46Z rule) |
| removal | "We remove a credit once Spotify and Tidal no longer list you on that track. If a credit on your profile still looks wrong, reply here with the track and we will check it again." (the 10-23 rule) |
| account / stats / other / no-identity | "We are going through older messages one by one so that nobody is left without an answer." (no status claim: the system has not measured one for these) |

**Close rule (tail only):** send, then close in the same run. A customer reply reopens the
conversation, which is the recovery path the stale closer already relies on. The recent band is
answered and left OPEN.

## 5. Decisions asked (posted to firstmate as needs-decision)

- **D1 copy:** GO on the openers, closer and status lines in section 4, as written or edited.
- **D2 gate caps tonight:** let the 47 recent gate rows (36 uvn-status, 11 team-review) go
  in-thread tonight, past the spent day caps (the captain's 20:35Z "in-app uncapped"), or
  wait for tomorrow's cap. Either the cap-lift lands in a deploy (node-8 is blocked), or this
  lane runs the driver with a one-off list of these users once the lane that owns the lift
  confirms it.
- **D3 ledger:** this lane's replies are written to the shared verify ledger
  (`verify_messages`, campaign `backlog-reply`, `message_type` comment), so every other lane's
  one-message-per-user-per-day check sees them. The alternative is a separate ledger that the
  other lanes do not read.
- **D4 close:** `intercom-ops-write.sh` cannot close and `close-stale-conversations.py` closes
  only we-spoke-last threads. Closing the tail after the apology needs a small closer: one
  shadow-logged `close` part per conversation, gated on our reply part having landed in the
  same run. Build it in this PR?
- **D5 claim-status lock:** flip `CLAIM_STATUS_COPY_APPROVED` for the 10 claim-pending rows, or
  send them the claim sentence from section 4 through this lane.
- **D6 no-identity (647):** send the generic line with no status, or run
  `credit-review.py intercom-reconcile` first (audited, revertible) so these get a real status.

## 6. Update 23:50Z: 4h sentinel (inbox 004) and the sender dry run

A fast census (`census.py --since-hours 30`) found 30 conversations under 24 h old where the
customer spoke last, 25 of them past 4 h. I read each one:

| route | conversations |
|---|---|
| p2's approved uvn-status / B0 (single sender: prioritise in-thread) | 215476552205621, 215476473466746, 215476347501620, 215476530361345 (paid), 215476471183648, 215475995330292, 215476459854106, 215476479847680, 215476449610220 (paid), 215476519350882 (paid), 215476433322735, 215476460756711 (paid, B0) |
| merge line (plan `plans/recent-lt1d-2350Z.json`), waits on D1 | 215476525469637, 215476519342709, 215476518054751 |
| claim dispute: two-claimant / same-name / ownership error. Goes to Fable (no rule answers it) | 215476452955137, 215476358271992, 215476452718609, 215476471489361 (claim under a new email) |
| captain's list | 215476566208497 (trademark C&D), 215476540440008 (attorney-in-fact asks for profile access + merge), 215476553442968 (formal privacy request to remove profile + credits), 215476336419274 (paid: plaque shipment returned by DHL at customs), 215472661480176 (plaque address), 215475055007096 (credit proof reply: belongs to the stage-2 proof path, not billing) |
| no approved line: Fable | 215476559782020 (paid: how to present TikTok creation data to labels), 215475769201909 (credits by album link, no account match) |
| close with reason, waits on D4 | 215476565158904 ("claude.ai?", not a request), 215476559752621 (reply to our welcome email) |
| pending claim (claim-status lock, D5) | 215476564520153 |

**What the dry run taught (fixes already in `send.py`):**
- The "no claim waiting, start a claim" line is harmful: in the recent band every no-pending-claim
  claim message was a dispute. It is withdrawn; the tail maps those rows to the generic line.
- Keyword topics cannot pick a reply. The recent band is now answered ONLY from a per-conversation
  plan written by reading each thread (`--plan`, enforced); the tail uses the category mapping.
- `users.firstname` often holds the full name, so the greeting uses its first word.
- Copy edit for Fable: the merge line asks for profile links even when the user already sent them,
  and repeats "reply here" with the closer.

## Outside the rules (log)

None yet. No send and no close has been made.
