# hydra — Claude operating notes

## Verify before agreeing — neither I nor Clio is automatically right

When Nick or Clio (or any other reviewer) tells me something about the code,
treat it as a hypothesis to verify, not a fact to act on. Both can be wrong.

- **Verify with evidence before acting.** Open the file, run the command,
  read the diff. Cite file:line, command output, or git history when stating
  a finding.
- **Push back when I disagree.** If something a reviewer says doesn't match
  what I see in the code, say so plainly with the evidence — don't silently
  capitulate, and don't pretend to agree just to move things along.
- **"Clio said X" is not a justification.** Neither is "Nick said X." The
  code, the tests, the runtime behavior, and the git log are the
  authorities.
- **If I'm uncertain, say so.** Better to flag a maybe-wrong claim than to
  rubber-stamp it and ship a regression.

This applies in both directions: when reviewers flag bugs that aren't real,
and when I believe my own work is correct but a reviewer thinks otherwise.
Disagreement is information; suppress it and we both lose signal.

## Hot-patching skills on node-8

Before editing any file under `/opt/hydra/skills-all/` directly on node-8
(e.g. previewing a fix on the live server before merging the PR), announce
the imminent write so the next deploy doesn't halt at Step 4a:

```bash
sha=$(sha256sum new-content.md | awk '{print $1}')
ANNOUNCE_SHA="$sha" \
  /opt/hydra/scripts/lib/announce-skill-hot-patch.sh nick \
    /opt/hydra/skills-all/<path>
install -m 644 new-content.md /opt/hydra/skills-all/<path>
```

The next deploy's pre-flight drift check accepts the divergence (rsync still
overwrites server bytes with the PR's HEAD bytes — the announce only
suppresses the halt, never the sync). Without an announcement, Step 4a
halts with the existing `DEPLOY BLOCKED — skills-all/ content drift`
runbook (`scripts/sync-from-server.sh skills --apply` → commit → re-deploy
or `HYDRA_FORCE=1` after verification).

Ack window is 1h by default (`HYDRA_HOTPATCH_ACK_WINDOW`); stale
announcements stop shielding after that. See `scripts/lib/announce-skill-hot-patch.sh`
and `scripts/lib/acknowledge-hot-patch-drift.sh`.
