#!/usr/bin/env python3
"""Which user_verification_needed requests does a document on file cover? Read-only, run OFF node-8.

Runs the decider's own code (`decide.proof_on_file`, `with_intake`, `ProofOnFile.covers`,
`replica_uvn_rows`' parser) over three files copied from node-8: the replica answer to
`decide.UVN_REPLICA_SQL`, the proof-on-file export, and the proof_intake candidate lists. Writes
`<request id>,<user id>` per covered request, for the indexed ledger probe in ledger_probe.sql.

usage: covered_uvn.py UVN.csv PROOF-ON-FILE.json INTAKE.txt OUT.csv
"""
import json
import sqlite3
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "scripts"))
from credit_review import decide  # noqa: E402
from credit_review.evidence import parse_ts  # noqa: E402

uvn_csv, pof, intake, out = sys.argv[1:5]
rows = decide.replica_uvn_rows(run=lambda *a, **k: SimpleNamespace(returncode=0, stdout=Path(uvn_csv).read_text(), stderr=""))
at = parse_ts(json.loads(Path(pof).read_text())["generated_at"])
proof, why = decide.proof_on_file(Path(pof), now=at)
if proof is None:
    sys.exit(f"proof status unknown: {why}")
with tempfile.TemporaryDirectory() as tmp:
    store = str(Path(tmp) / "proof.sqlite")
    db = sqlite3.connect(store)
    db.execute("CREATE TABLE proof_intake (subject TEXT, candidate_request_ids_json TEXT)")
    db.executemany("INSERT INTO proof_intake VALUES ('credit', ?)",
                   [(ln,) for ln in Path(intake).read_text().splitlines() if ln.strip()])
    db.commit()
    db.close()
    proof = decide.with_intake(proof, store)
assert proof.scoped, "proof_intake was not read"
covered = []
for req in rows:
    d = decide.request_decision(req)
    if d.user_id is not None and proof.covers(d):
        covered.append((d.request_id.lower(), d.user_id))
Path(out).write_text("".join(f"{r},{u}\n" for r, u in covered))
print(json.dumps({"uvn_requests_read": len(rows), "uvn_users_read": len({r["userId"] for r in rows}),
                  "covered_requests": len(covered), "covered_users": len({u for _, u in covered})}))
