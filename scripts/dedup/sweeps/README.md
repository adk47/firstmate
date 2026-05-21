# dedup sweeps

Periodic, read-only-by-default cleanup scripts that operate on the
profile-merge action-request backlog using the dedup detector + side data.

## close-merged-tickets.sh

Find ClickUp `profile-merge` tickets whose merge already executed
(per `postgresql_core.public.action_log`) and close them.

### Usage

    # Dry-run (default): list what would be closed, no side effects.
    bash scripts/dedup/sweeps/close-merged-tickets.sh

    # Apply: post comment + set status="resolved" on each match.
    bash scripts/dedup/sweeps/close-merged-tickets.sh --apply

    # Tune look-back window (default 90 days).
    bash scripts/dedup/sweeps/close-merged-tickets.sh --days 30

    # Skip the customer-reply audit (closes every stale ticket even if the
    # customer was never told post-merge — use only when you've handled
    # customer communication out-of-band):
    bash scripts/dedup/sweeps/close-merged-tickets.sh --apply --skip-customer-reply-check

### Env

| Var | Default | Purpose |
|---|---|---|
| `CLICKUP_API_KEY` | (required) | ClickUp personal token |
| `CLICKUP_LIST_ID` | `901000600160` | hydra-action-request list |
| `CLICKUP_API`     | `https://api.clickup.com/api/v2` | API base |
| `TRINO_QUERY`     | `/opt/hydra/scripts/trino-query.sh` | Trino wrapper |
| `DAYS`            | `90` | action_log look-back |
| `MUSOAI_INTERCOM_TOKEN` | (required unless `--skip-customer-reply-check`) | Intercom Bearer for the customer-reply audit |
| `PAGINATION_CAP`  | `20` | max ClickUp pages walked (~100 tasks/page) |
| `CLOSE_ADD_ASSIGNEES` | `99656609` (Nick) | comma-separated ClickUp user IDs added as assignees on each closed ticket. Empty string disables. |

On hydra the gateway service env carries `CLICKUP_API_KEY`; for ad-hoc runs:

    pid=$(systemctl show openclaw-gateway-main.service -p MainPID --value)
    eval $(cat /proc/$pid/environ | tr '\0' '\n' | grep '^CLICKUP_API_KEY=' | sed 's/^/export /')

### What it does

1. Trino: pull every executed merge in the look-back window from
   `action_log` where `route='/api/v3/admin/profiles/merge'`. Each row is
   `{mergeInto, profilesIds[], at}`.
2. ClickUp: page through `list/$CLICKUP_LIST_ID/task?include_closed=false`,
   filter to tasks whose description has `action_type: "profile-merge"`,
   parse `customer_profile_id` out of the action-request JSON block.
3. Pure match (see `match-stale-tickets.sh`): a ticket is "stale" if its
   `customer_profile_id` equals either the `mergeInto` (survivor side) or
   appears in `profilesIds[]` (loser side) of any merge in the window.
4. Apply: POST a comment ("Automated closure ... merge executed at <ts>")
   then PUT status="resolved" on each stale task.

### Why it exists

The 2026-05-19 dry-run found **15/27 open profile-merge tickets had
already been merged** by Jan/Yann (via `muso-ops-profiles` skill +
`/admin/profiles/merge`) but the ClickUp ticket was never closed —
the muso-ops-profiles workflow doesn't auto-close. This sweep is the
backstop until that's fixed at the source.

## notify-merged-customers.py

Posts a templated "merge complete" reply in Intercom to customers whose
profile-merge was executed but who haven't been told yet. Read-only by
default; `--apply` is the explicit trigger to actually send.

### Usage

    # Dry-run: print proposed messages as JSONL on stdout.
    printf "869dadcrq\n869daak39\n" | python3 scripts/dedup/sweeps/notify-merged-customers.py

    # Apply: post to Intercom, comment + close the ClickUp ticket.
    printf "869dadcrq\n" | python3 scripts/dedup/sweeps/notify-merged-customers.py --apply

Ticket IDs are read from stdin, one per line — typically piped from the
`needs_human_reply` rows emitted by `close-merged-tickets.sh`'s
customer-reply audit.

### Env

| Var | Default | Purpose |
|---|---|---|
| `CLICKUP_API_KEY` | (required) | ClickUp personal token |
| `MUSOAI_INTERCOM_TOKEN` | (required) | Intercom Bearer |
| `INTERCOM_ADMIN_ID` | `5763097` (Caroline) | Admin user the reply is posted AS — defaults to Caroline so the merge confirmation matches the rest of the Intercom thread; override only when you intentionally want a different teammate's avatar on the reply |

### Safety contract

- `--apply` is the only way to write; no flag = dry-run.
- Per-conv dedup: if two tickets resolve to the same Intercom conv (e.g.
  same customer filed two tickets), only the first triggers a reply. The
  second still closes its ClickUp ticket with a "customer already told
  via earlier ticket" comment.
- Runs an inline single-conv admin-reply audit (analogous to
  `check-customer-replied.py`'s multi-conv audit used by
  `close-merged-tickets.sh` — same intent, scoped to the picked conv).
  A manual Jan/Yann reply that landed since the sweep was last run is
  honored (no double-message).
- Message: `hi! just confirming your profile merge request is done. the
  credits we found are now consolidated under your main profile. let me
  know if anything's off.` — Caroline tone (lowercase, no em-dash, no
  corporate filler), same conventions as the founder-voice rules in
  memory:feedback_founder_voice_rules.

### Validation log

**2026-05-19** dry-run against the 4 needs_human_reply tickets:
- `869dadcrq` matthewmarchesi6@gmail.com → conv 215474314332122, would send
- `869daak39` emil7@live.com.mx → skip (no Intercom conv for that email)
- `869d9uby4` larsbd@gmail.com → conv 215474292180251, would send
- `869d9ubq7` larsbd@gmail.com → skip (same conv as 869d9uby4, dedup'd)

So 2 of 4 are actionable via this script; the emil7 ticket needs manual
ops because the customer's Intercom registration email doesn't match.

### Validation log (sweep)

**2026-05-19** (dry-run, last 90 days, customer-reply audit ENABLED):
- 291 merges in `action_log`
- 27 open profile-merge tickets in ClickUp (status != closed)
- **15 matches** — all `customer_profile_id` was the `mergeInto` survivor,
  except `869d9uby4` which matched as a loser (someone filed a ticket
  using the to-be-merged-away profile id; merge happened from another
  ticket).
- Customer-reply audit (Intercom): **11 safe to close** (admin replied
  to customer after merge), **4 need human reply first**:
  - `869dadcrq` matthewmarchesi6@gmail.com
  - `869daak39` emil7@live.com.mx
  - `869d9uby4` and `869d9ubq7` larsbd@gmail.com (same customer, two tickets)
- The 4 untold customers were merged 2026-05-15 but never told. The
  sweep leaves their ClickUp tickets open under `needs_human_reply` so
  Jan/Yann (or a future Caroline-side reply path) can confirm with the
  customer before closure.
- Apply pending Nick's review.
