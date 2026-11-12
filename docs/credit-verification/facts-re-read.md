# The facts re-read: scoped, age-stamped, and never silent

Every send family re-reads the replica immediately before it sends, so no ask goes
out on a list whose owed set has changed since it was built
(`owing_proof.verify_facts`, `need_asks.verify_facts`; the uvn-status family enforces
it at `uvn_status._enforce_facts`; `claim_proof_ask` does not call it). Three rules keep that re-read
from becoming the outage it caused on 2026-11-11.

## 1. It asks about THIS page's users, never the whole table

`[key=facts-scope]`. The re-read used to re-run the builder's whole-table query
(`REPLICA_SQL` / `FACTS_SQL`: every open `credit_requests` row). On 2026-11-11 that
query stopped finishing — `verify_notify.trino()` runs the wrapper under
`timeout=900` — and every family behind it answered `NOTHING sent` for a day.

The re-read is now the SAME query with `AND cr.userid IN (...)` for the users on
this page (`owing_proof.replica_sql` / `need_asks.facts_sql`, chunked at
`FACTS_SCOPE_CHUNK`). The builder still reads the whole table — that is how the
tick learns who owes — only the re-read is scoped. The list's `replica_facts`
header keeps pinning the base query and its sha256, so a list built by an older
tree still verifies.

**Do not raise the timeout instead.** A longer timeout moves the hang further
inside the budget; it does not make the read finish.

## 2. A timeout falls back to the list's own facts, with their age

`[key=facts-stale-fallback]`. A replica that does not answer is not evidence the
facts changed. When the re-read raises `subprocess.TimeoutExpired` and the list's
own `generated_at` is inside `uvn_status.FACTS_STALE_MAX_MIN` (90 min), the family
sends on the list's facts and says so: `facts stale Nm` in the run's summary line.
`Nm` is disclosed whenever the fallback fired, `facts stale 0m` included — the
signal is "a fallback happened" (`facts_stale_min is None` = not measured), never
the age's truthiness, so a same-minute send still says it did not re-read.

Only the replica-DEPENDENT comparison falls back. Every check
`owing_proof.verify_facts` makes before it touches the replica still runs on the
timeout path, via `owing_proof.local_diffs`: the header digest
(`replica_facts.sha256` vs the listed facts — a list edited after its build
still halts), the account holds (`held_accounts`: a hold released since the build
refuses that user), and the sent asks (`asked_rows`: an ask sent since the build
refuses that user). A duplicate ask to a held or already-asked user is worse than
a slow send. If those local checks cannot run either, nothing is sent.

Past the bar the claim the re-read exists to make — "the owed set has not changed
since the list was built" — is gone, so the family halts exactly as before
(`NOTHING sent: the replica facts re-read timed out and the list's own facts are
Nm old (bar 90m)`).

Anything that is not a timeout (a SQL error, a bad row shape, a
`TrinoTransientError`) stays terminal: that is the replica telling us something we
must not paper over. A transient error is the tick's deferral rail's business
(`run_transient` retries, then defers), not a licence to send unconfirmed.

## 3. `NOTHING sent` is an ALERT, never one quiet log line

`[key=nothing-sent-alert]`. A family step that returns rc=1 and says `NOTHING sent`
now logs `ALERT: <family> sent NOTHING this tick: <reason>` and pages through
`page_confirmed`. If Slack does not confirm the post, the tick.log keeps a second
line saying the page was undelivered — a warning nobody receives is the same
silent failure. That is how 2026-11-11 survived a whole day: every tick logged the
timeout and told nobody.

## Tests

- `scripts/tests/test_owing_proof.py` — the re-read asks only about the page's
  users, and an empty page asks the replica nothing.
- `scripts/tests/test_need_asks.py` — the same for the `need_asks` twin: a
  populated page issues only user-scoped SQL, chunked at `FACTS_SCOPE_CHUNK`,
  never the whole-table `FACTS_SQL`; an empty page issues no query at all.
- `scripts/tests/test_uvn_status.py` — a timeout inside the bar sends and reports
  `facts stale Nm` (including the `0m` case); a list whose digest no longer
  matches, a held user and an already-asked user are still refused on the timeout
  path; past the bar the family halts.
- `scripts/tests/credit-verify-outbound.bats` — `STUB_NOTHING_SENT` drives the
  ALERT + confirmed page, and a rejected page still leaves the ALERT in tick.log.
