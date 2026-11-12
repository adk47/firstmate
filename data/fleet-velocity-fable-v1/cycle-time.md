Evidence recorded at 2026-11-12T01:51:32Z for Muso-AI/hydra. Hours. `>=N open` = still running at that time.

| PR | state | brief -> worker start | start -> first commit | first commit -> PR open | PR open -> first QA verdict | first verdict -> GO on shipped head | GO -> merge | merge -> deployed | deployed -> first effect | CI runs (h) | max CI queue | NO-GO | heads reviewed | local gates |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| #1882 | merged | unmeasured | unmeasured | 0.0 | 0.8 | 8.1 | 5.4 | >=7.0 open | unmeasured | 5 (3.6) | 10s | 3 | 5 | unmeasured |
| #1883 | merged | unmeasured | unmeasured | 2.7 | 3.1 | 9.5 | 0.8 | >=7.4 open | unmeasured | 8 (5.8) | 15s | 14 | 10 | unmeasured |
| #1884 | merged | unmeasured | unmeasured | 4.8 | 0.8 | 3.4 | 0.3 | >=11.3 open | unmeasured | 3 (2.4) | 13s | 2 | 3 | unmeasured |
| #1885 | open | unmeasured | unmeasured | 0.0 | 0.2 | 0.0 | >=15.4 open | unmeasured | unmeasured | 1 (0.8) | 10s | 0 | 1 | unmeasured |
| #1886 | open | unmeasured | unmeasured | 0.0 | 0.1 | 1.3 | >=12.8 open | unmeasured | unmeasured | 2 (1.5) | 7s | 3 | 2 | unmeasured |
| **all** | | **0.0** | **0.0** | **7.6** | **5.1** | **22.3** | **34.6** (2 open) | **25.7** (3 open) | **0.0** | 19 (14.0) | | 22 | | |

Top costs (hours across these PRs, open stages still counting):
1. GO -> merge: 34.6 h, 2 still open
2. merge -> deployed: 25.7 h, 3 still open
3. first verdict -> GO on shipped head: 22.3 h

Unmeasured, and so in no total: brief -> worker start (5 of 5); start -> first commit (5 of 5); merge -> deployed (2 of 5); deployed -> first effect (5 of 5).
