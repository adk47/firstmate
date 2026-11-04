# The exact command to refresh cs-gmail by hand (until the 429 clears)

Posted 2026-10-31 06:3xZ for Fable's 09:30Z decision. Requirements met: it runs under **#1558's shared lock**,
it is **paced** (one scan, the script's own 1200 s budget and honoured Retry-After), it **never fakes
freshness** (a failed or quota-blocked scan leaves the stamp alone), and it restores the kill file so the
hourly crons stay quiet.

```bash
# 1. write it locally - the trap is the point: a dropped session must not leave the switches off
cat > /tmp/manual-proof-refresh.sh <<'SH'
set -u
restore() { touch /etc/hydra/cs-proof-feed.disabled /etc/hydra/gmail-readers.disabled; }
trap restore EXIT HUP INT TERM      # restored even if this session dies between rm and touch
ls -l /etc/hydra/gmail-readers.disabled /etc/hydra/cs-proof-feed.disabled 2>&1   # what is being turned off
rm -f /etc/hydra/cs-proof-feed.disabled /etc/hydra/gmail-readers.disabled
/opt/hydra/scripts/cs-proof-feed.sh >> /var/log/cs-proof-manual-refresh.log 2>&1
tail -6 /var/log/cs-proof-manual-refresh.log
python3 -c 'import json; d=json.load(open("/var/lib/credit-trust/inputs/cs-proofs.json")); print([(x["name"], x["generated_at"], x["stale"]) for x in d["sources"] if x["name"] in ("cs-gmail", "cs-intercom")])'
SH

# 2. run it on node-8 (node-1 is only the jump host)
scp /tmp/manual-proof-refresh.sh root@135.148.169.37:/tmp/ && \
  ssh root@135.148.169.37 'scp /tmp/manual-proof-refresh.sh root@10.0.0.8:/tmp/ && ssh root@10.0.0.8 "bash /tmp/manual-proof-refresh.sh"'
```

There are **two** kill files, and the scan honours both: `/etc/hydra/cs-proof-feed.disabled` stops the feed
script, and `/etc/hydra/gmail-readers.disabled` (hydra #1569) makes `gmail_scan.sh` exit 4 before its first gog
call — a manual refresh with only the first one removed exits 4 and refreshes nothing. The command above prints
both before touching them, clears both, and restores both.

What it guarantees:

- **the lock** — do NOT wrap this in `flock /run/hydra/gmail-support.lock`: `gmail_scan.sh` takes that lock
  itself, and flock is per open file description, so an outer flock makes the scan wait on its own caller for
  the whole 600 s and then exit 4 (r5 caught exactly this). The wrapper above stops the timers first (the kill
  file is already in place) and lets the script take its own lock;
- **paced** — `gmail_scan.sh` honours Google's `Retry-after` (+5 s, capped), carries a 1200 s total budget, and
  exits 4 (`QUOTA SATURATED`) instead of dying inside `gmail_proof.py`'s 1500 s kill;
- **honest** — on a 429 the scan writes no page and no `DONE`, so the `cs-gmail` stamp does not move and the part
  stays stale. Nothing in this path can turn a failed read into a fresh-looking part;
- **quiet** — the kill file is restored afterwards, so the hourly `:21` feed keeps exiting until #1558 deploys.

Before running it, do **not** probe the mailbox by hand: a bare `gog gmail messages search` is a second
support@ consumer with no lock and no backoff, and "just checking" is how this outage was extended (QA on #1558).

The state that decides whether to run is already on disk:

```bash
ssh root@135.148.169.37 'ssh root@10.0.0.8 "cat /var/lib/hydra/gmail-support/backoff.json 2>/dev/null; echo; \
  ls -l /etc/hydra/gmail-readers.disabled /etc/hydra/cs-proof-feed.disabled 2>&1"'
```

- `{"until": "<a time in the future>"}` → the window is open against us; wait for it, do not spend a request.
- no file, or `until` in the past → run the script above; **it** takes the shared lock and publishes a fresh
  window if Google refuses, which is the only way this state gets written.

