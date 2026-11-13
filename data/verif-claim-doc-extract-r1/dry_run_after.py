#!/usr/bin/env python3
"""READ-ONLY dry run of the claim-only floor against the live stores: what the next doc-verify run selects under
the rule on node-8 today (the room the credit filings leave) and under `runner.claim_only_room`.

Both stores are opened `mode=ro`; one replica read for the open-claim accounts; no model call, no step written,
no document fetched. Nothing is read: this is the selection only.

Run on node-8 from /opt/hydra/scripts with the gateway env. Where the deployed runner has no `claim_only_room`
yet, send the function's source ahead of this file, so the rule dry-run is the PR's own code and not a copy:

    (python3 - <<'EOF'
    import ast, pathlib
    src = pathlib.Path("scripts/credit_verify/docverify/runner.py").read_text()
    fn = next(n for n in ast.parse(src).body if getattr(n, "name", "") == "claim_only_room")
    print("NEW_RULE_SRC = " + repr("CLAIM_ONLY_FLOOR = 5\\n" + ast.get_source_segment(src, fn)))
    EOF
    cat data/verif-claim-doc-extract-r1/dry_run_after.py) | ssh node-8 'cd /opt/hydra/scripts && set -a && \
        . /etc/openclaw/main.env; set +a; nice -n 10 python3 -'
"""
import json
import sqlite3
import sys
import time
from types import SimpleNamespace

sys.path.insert(0, "/opt/hydra/scripts")
from claim_verify import decline_rules  # noqa: E402
from credit_verify.proof import stage2  # noqa: E402
from credit_verify.docverify import pace, runner  # noqa: E402
from credit_verify.docverify.blobs import BlobStore  # noqa: E402
from credit_verify.docverify.store import DocVerifyStore  # noqa: E402

MAX_DOCS, WORKERS = 40, 4          # the cron: run --max-docs 40 --workers 4
PAYING = "/var/lib/credit-trust/paying-users.json"

if hasattr(runner, "claim_only_room"):
    room_rule, rule_from = runner.claim_only_room, "deployed runner"
else:
    ns: dict = {}
    exec(globals()["NEW_RULE_SRC"], ns)        # noqa: S102 - the PR's own function, sent ahead of this file
    room_rule, rule_from = ns["claim_only_room"], "PR source sent with this script"


def main() -> int:
    store = DocVerifyStore.read_only()
    proof = sqlite3.connect(f"file:{runner.PROOF_STORE}?mode=ro", uri=True, timeout=60)
    try:
        paying = frozenset(int(u) for u in json.load(open(PAYING))["ids"])
    except (OSError, ValueError, KeyError, TypeError):
        paying = None
    statuses = ",".join(f"'{s}'" for s in decline_rules.OPEN_STATUSES)
    accounts = frozenset(int(r[0]) for r in decline_rules._rows(stage2.trino_query(
        "SELECT DISTINCT cast(userid as varchar) FROM postgresql_core.public.claiming "
        f"WHERE deletedat IS NULL AND userid IS NOT NULL AND status IN ({statuses})")) if r and r[0].isdigit())
    deps = SimpleNamespace(blobs=BlobStore(), claimants=lambda: accounts)
    out: dict = {"at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "version": runner.VERSION,
                 "rule_from": rule_from, "open_claim_accounts": len(accounts), "shards": []}
    per = [MAX_DOCS // WORKERS + (1 if i < MAX_DOCS % WORKERS else 0) for i in range(WORKERS)]
    tot = {"credit_selected": 0, "claim_only_owing_a_read": 0, "claim_only_selected_before": 0,
           "claim_only_selected_after": 0, "claim_only_waiting_after": 0}
    for i, budget in enumerate(per):
        keep = lambda pid, i=i: pace.shard_of(pid, WORKERS) == i  # noqa: E731
        pre = runner._intake_docs(proof, store, deps, budget, keep=keep, paying=paying)     # as run() does, both rules
        owed = runner.claim_only_docs(proof, store, deps, 10 ** 6, keep=keep, paying=paying)
        before = runner.claim_only_docs(proof, store, deps, budget - len(pre), keep=keep, paying=paying)
        after = owed[:room_rule(budget, len(pre))]
        row = {"shard": i, "budget": budget, "credit_selected": len(pre), "claim_only_owing_a_read": len(owed),
               "claim_only_selected_before": len(before), "claim_only_selected_after": len(after),
               "claim_only_waiting_after": len(owed) - len(after),
               "accounts_selected_after": len({d.user_id for d in after})}
        out["shards"].append(row)
        for k in tot:
            tot[k] += row[k]
    out["totals"] = tot
    print(json.dumps(out, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
