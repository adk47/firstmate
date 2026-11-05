# SA-02 Router — end-to-end evidence

Intent: a `sa-cli` with exactly five verbs (ticket, assign, reply, rule, escalate)
and no bash/exec/read/write verb, plus a Pi extension registering exactly five
tools (`sa_ticket`, `sa_assign`, `sa_reply`, `sa_rule`, `sa_escalate`). A Router
Pi session launched with `--no-builtin-tools --no-mcp --tools <the five>` has
exactly those five tools and cannot reach a shell, a file read, or an edit.

## Artifacts

| file | what it shows |
| --- | --- |
| `cli-surface.txt` | `sa-cli --help` lists exactly the five verbs; `bash sh exec read cat edit write` each exit 2 with `unknown command: <verb>` and write no event log |
| `live-router-tool-list.txt` | a real `pi` session launched with the intent's exact flags reports exactly the five `sa_*` tools |
| `live-router-negative.txt` | the same session cannot read `AGENTS.md` and cannot run `echo SHELL_REACHED`; it says so explicitly |
| `live-router-five-verbs.txt` | the same session drives all five tools through the extension and returns ticket `T-0001` |
| `live-router-store-state.txt` | the persisted store projections after that session: ticket row, assignment, thread message, ruling, and the queryable `ticket.escalated` event |

## Commands

```
bash tests/sa-router.test.sh
SA_LIVE_PI=1 bash tests/sa-router.test.sh
bin/fm-test-run.sh --check-coverage
```

The live probe is development-only evaluation (it needs a model provider); the
deterministic CI proof is `tests/sa-router.test.sh` sections 1-8, which build a
stub Pi SDK + stub typebox fixture and assert the extension's registered tool
list, absence of commands/hooks, and the exact `python3 <sa-cli> ticket ...`
argv with no shell.
