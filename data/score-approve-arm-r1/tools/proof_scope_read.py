#!/usr/bin/env python3
"""READ-ONLY, runs on node-8: WHY each engaged request reads "proof on file", from the deployed readers.

score-approve keeps a row on the proof path when its ACCOUNT has any proof entry (`uid in proof.user_ids`),
which is wider than the decider's own per-request rule (`ProofOnFile.covers`). This says, per request,
which of the two it is. stdin literal REQUESTS_JSON: {request id: [user id, createdAt]}. stdout: one JSON
object of ids, classes, entry sources and kinds only (no name, no email, no document text or ref).

It calls decide.proof_on_file() (reads the hourly export) and decide.with_intake() (opens the proof store
`mode=ro`), with the run log silenced so that nothing on the host is written. No API call.

    { printf 'REQUESTS_JSON = %s\n' "$(python3 measure_held.py OUT_JSONL --scope-ids)"; cat proof_scope_read.py; } \
      | ssh root@<node-8> 'cd /opt/hydra && PYTHONDONTWRITEBYTECODE=1 python3 -B -'
"""
import collections
import json
import sys

sys.path.insert(0, "/opt/hydra/scripts")
from credit_review import decide  # noqa: E402

decide.log = lambda msg: False          # with_intake() logs a failed read to run.log: this tool writes nothing

REQUESTS = json.loads(REQUESTS_JSON)  # noqa: F821 - prepended by the caller
proof, why = decide.proof_on_file()
if proof is None:
    print(json.dumps({"error": f"proof on file unknown: {why}"}))
    sys.exit(2)
proof = decide.with_intake(proof)
export = json.loads(decide.PROOF_ON_FILE.read_text(encoding="utf-8"))
by_user = collections.defaultdict(list)
for e in export["entries"]:
    uid = decide.muso_user_id(e["user_id"])
    by_user[uid].append((str(e.get("source") or ""), str(e.get("kind") or ""), e.get("request_id") is None))

out = {}
for rid, (uid, created) in REQUESTS.items():
    uid, rid_l = int(uid), rid.lower()
    if rid_l in proof.request_ids:
        cls = "this_request_named_by_an_entry"
    elif rid_l in proof.intake_requests:
        cls = "this_request_a_filed_documents_candidate"
    elif uid not in proof.user_ids:
        cls = "account_not_on_file_now"
    elif not proof.scoped:
        cls = "scope_unread"                       # proof_intake unreadable: whole-user cover, as the decider
    elif uid not in proof.user_level:
        cls = "account_entries_name_other_requests_only"
    else:
        newest = proof.user_level[uid]
        made = decide.parse_ts(created)
        cls = ("whole_account_entry_covers" if newest is None or made is None or made <= newest
               else "whole_account_entry_older_than_the_request")
    out[rid] = {"class": cls,
                "sources": sorted({s for s, _, _ in by_user.get(uid, [])}),
                "kinds": sorted({k for _, k, _ in by_user.get(uid, [])}),
                "whole_account_sources": sorted({s for s, _, whole in by_user.get(uid, []) if whole}),
                "support_contact": uid in proof.support_contacts}
print(json.dumps({"export_generated_at": export.get("generated_at"), "scoped": bool(proof.scoped),
                  "export_users": len(proof.user_ids), "export_requests": len(proof.request_ids),
                  "intake_requests": len(proof.intake_requests), "requests": out}))
