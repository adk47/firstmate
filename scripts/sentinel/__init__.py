"""SENTINEL (hydra half).

`policies/sentinel-capabilities.json` is the ONE registry: every automation that can
act is a row there, and a row's `rollout.state` (shadow -> canary -> live) is what
lets it act at all. This package holds the parts that must be **code, never an AI and
never a queue** (request-sentinel-fable-s1 §2.7):

  registry.py  repo truth + the HOST runtime state file, and the one invariant that
               makes a kill durable: the runtime state can only DEMOTE, never promote.
  outcomes.py  the 7-day outcome join: ACTION-AUDIT reverts + manipulated verdicts,
               contradicted (contra_appr) decider rows, Intercom complaints, spot-audit
               fails, and `waiting_on=us` rows past `due_at`. Every source reports
               ok / unknown separately, because "we could not measure it" is not
               "healthy" (AGENTS.md, codex-quota doctrine, same shape).
  demote.py    the tick: trip -> flip runtime state, drop the kill file, page
               #clio_devops, mirror the demotion into the repo via a PR.
  report.py    rendering only (digest, demotion page, mirror-PR body, parity report).

Legacy module names are singular on purpose: `scripts/sentinel/demote.py` is the
`ExecStart` of the timers, so it must stay runnable as a plain file path.
"""
