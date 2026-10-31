#!/usr/bin/env python3
"""paid-wave-runner-p2: READ-ONLY. For each population user held on the support@ 90-day rule, did a HUMAN
answer them from support@muso.ai in the last 7 days? (Gmail read-only via gog, as cs-systemic's scan.)
human reply = a message in support@'s Sent mail, to the account email, newer than 7 days, that is not one of
legal-intake.py's templated acks (cs-systemic scripts/cs-systemic/legal-intake.py:50-51).
Output: <PWR_DIR>/support7d.json  [{user_id, human_7d, auto_7d, last_human}]  (ids + dates only)."""
import csv, io, json, subprocess, sys, time

D = __import__("os").environ["PWR_DIR"]  # the run dir (daily.sh sets it)
ENV = "set -a; . /etc/openclaw/main.env; set +a; "
AUTO = ("We have recorded it and are reviewing it under our copyright process",
        "We have passed it to our credits team, who will review it and reply on this thread")


class Unreadable(Exception):
    """gog did not give a verified answer (nonzero exit, unparseable, or not the expected shape)."""


def sh(cmd, *, run=None, sleep=None, tries=4):
    """A gog JSON answer, only from a SUCCESSFUL exit (QA on #1384: a nonzero exit printing a JSON error must
    never read as an answer). Retried; still unreadable -> Unreadable (fail closed: the caller holds the user)."""
    run, sleep = run or subprocess.run, sleep or time.sleep
    why = ""
    for t in range(tries):
        try:
            p = run(["bash", "-c", ENV + cmd], capture_output=True, text=True, timeout=120)
        except subprocess.SubprocessError as exc:
            why = type(exc).__name__
        else:
            if p.returncode == 0:
                try:
                    ans = json.loads(p.stdout)
                    if isinstance(ans, dict):
                        return ans
                    why = "not a JSON object"
                except ValueError:
                    why = "unparseable output"
            else:
                why = f"gog rc={p.returncode}: {p.stderr.strip()[-120:]}"
        if t + 1 < tries:
            sleep(30 * (t + 1))
    raise Unreadable(why)


def search(email_, **kw):
    """support@'s Sent messages to this address in the last 7 days. gog answers {"messages": [...]} even when
    there are none (checked on node-8 2026-10-27), so a missing or non-list `messages` is unreadable, never an
    empty inbox."""
    ans = sh(f"gog gmail messages search --account support@muso.ai 'in:sent to:{email_} newer_than:7d' --max 20 --json", **kw)
    msgs = ans.get("messages")
    if not isinstance(msgs, list) or not all(isinstance(m, dict) and m.get("id") for m in msgs):
        raise Unreadable("search answer has no messages[] of {id}")
    return msgs


def judge(email_, **kw):
    """{human_7d, auto_7d, last_human} for one address; Unreadable propagates."""
    human, auto, last = 0, 0, ""
    for m in search(email_, **kw):
        g = sh(f"gog gmail get {m['id']} --account support@muso.ai --json", **kw)
        blob = json.dumps(g)
        if any(a in blob for a in AUTO):
            auto += 1
        else:
            human += 1
            last = max(last, str(m.get("date", "")))
        (kw.get("sleep") or time.sleep)(1)
    return {"human_7d": human, "auto_7d": auto, "last_human": last}


# The ONE support@ Gmail readers kill file (#1569; a constant, never an env var - r5 [key=unattended]).
GMAIL_READERS_KILL = "/etc/hydra/gmail-readers.disabled"


def main():
    import os
    if os.path.exists(GMAIL_READERS_KILL):
        # before the first gog call; fail closed like an unreadable mailbox (never 'no human reply')
        sys.exit(f"support@ Gmail readers disabled ({GMAIL_READERS_KILL}): support@ check skipped (fail closed)")


    segs = json.load(open(f"{D}/segments.json"))
    ids = [r["user_id"] for r in segs if r["support90"]]
    email = {}
    if ids:
        p = subprocess.run(["/opt/hydra/scripts/trino-query.sh"], capture_output=True, text=True, timeout=600,
                           input=f"select cast(id as varchar), lower(trim(email)) from postgresql_core.public.users where id in ({','.join(map(str, ids))})")
        if p.returncode != 0:
            sys.exit(f"trino failed (rc={p.returncode}): support@ check unreadable, segment skipped (fail closed)")
        email = {int(a): b for a, b in csv.reader(io.StringIO("\n".join(l for l in p.stdout.splitlines() if l.startswith('"'))))}
    out = []
    for u in ids:
        e = email.get(u, "")
        if not e or '"' in e or "'" in e or " " in e:
            out.append({"user_id": u, "error": "no usable email"}); continue
        try:
            out.append({"user_id": u, **judge(e)})
        except Unreadable as exc:
            # never "no human reply": the error row holds the user (daily.sh), and the run is failed below
            out.append({"user_id": u, "error": f"support@ mailbox unreadable: {exc}"[:200]})
        time.sleep(3)
    json.dump(out, open(f"{D}/support7d.json", "w"), indent=1)
    unread = sum(1 for r in out if str(r.get("error", "")).startswith("support@ mailbox unreadable"))
    print(json.dumps({"support90_users": len(ids), "human_answered_7d": sum(1 for r in out if r.get("human_7d")),
                      "auto_ack_only_7d": sum(1 for r in out if r.get("auto_7d") and not r.get("human_7d")),
                      "errors": sum(1 for r in out if r.get("error")), "mailbox_unreadable": unread}))
    # An unreadable mailbox fails the segment (daily.sh: FAILED, no sends for it): nobody is sent a status note
    # on the strength of a check that did not run.
    return 3 if unread else 0


if __name__ == "__main__":
    sys.exit(main())
