#!/usr/bin/env python3
"""Run `gdpr-pipeline.py hide-batch --open-prs` from THIS tree against a COPY of the register, with the two writes
that leave the box (the hide PRs, the Slack alert) replaced by recorders.

    guard_scratch_run.py <tree root> <scratch copy of erasure.sqlite>

Everything else is the shipped path: the real hide lists, the real open-PR reads, the real identity decision for
rows decided before the proof was recorded, the real claim and catalog reads. It writes only to the scratch copy.
It prints ids, verdicts and reason codes; no name and no address.
"""
import importlib.util
import json
import os
import sys

root, scratch = sys.argv[1], sys.argv[2]
live = "/var/lib/hydra-gdpr/erasure.sqlite"
if os.path.realpath(scratch) == os.path.realpath(live) or not os.path.exists(scratch):
    sys.exit("refusing: pass a scratch COPY of the register")
sys.path.insert(0, os.path.join(root, "scripts"))
spec = importlib.util.spec_from_file_location("cli", os.path.join(root, "scripts", "gdpr-pipeline.py"))
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)
from gdpr_pipeline import hide_batch, hide_guard  # noqa: E402
from gdpr_pipeline.store import Store  # noqa: E402

would_open, posts = [], []


def open_prs(batch, dry_run=True, **_):
    would_open.append([b["id"] for b in batch])
    return {"blocked_items": [], "kept": {}, "superseded": {}, "close_failed": [], "unreadable": {}, "opened": {},
            "hdevops": "", "pdp": ""}


hide_batch.open_prs = open_prs
cli.slack_post = lambda text: posts.append(text) or True
cli.KILL = "/nonexistent/gdpr-pipeline.disabled"
sys.argv = ["gdpr-pipeline.py", "--store", scratch, "hide-batch", "--open-prs", *sys.argv[3:]]
rc = cli.main()
events = Store(scratch).events_of_kind(hide_guard.EVENT)
print("----- scratch run -----")
print(json.dumps({
    "exit": rc,
    "would_prepare": would_open,
    "alerts": posts,
    "guard_rows": [{k: e["detail"].get(k) for k in ("page", "entity", "basis", "outcome", "reason", "proof",
                                                    "requester")} | {"request": e["request_id"]} for e in events],
}, indent=1))
