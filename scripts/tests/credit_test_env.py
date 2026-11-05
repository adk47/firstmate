"""Isolate the credit test suites from production logs (firstmate 056).

PR Validation runs on node-8, so a test that reaches credit_review.runner.log (directly, or
through a credit-review.py / credit-retro.py subprocess) appended its halt and refusal lines to
the PRODUCTION /var/lib/hydra/credit-review/run.log. Import this module first in every credit
test file: it points CREDIT_REVIEW_LOG at a per-process temp file (inherited by every
subprocess), and refuses to let a test run with the log under /var/lib.
"""

from __future__ import annotations

import atexit
import os
import shutil
import tempfile

PROD_PREFIX = "/var/lib/"

_dir = tempfile.mkdtemp(prefix="credit-test-logs-")
atexit.register(shutil.rmtree, _dir, True)
os.environ["CREDIT_REVIEW_LOG"] = os.path.join(_dir, "run.log")
LOG_PATH = os.environ["CREDIT_REVIEW_LOG"]
# r5 556 (signed-head rail): PR Validation runs on node-8, where /opt/hydra/.deployed-sha and the production apply lock
# exist. The suites' apply-mode runs use a harness-only stand-in (verify_notify reads it only when this marker exists in
# a directory under the system temp dir): no deployed head, a temp apply lock - never the production lock.
os.environ["CREDIT_TEST_ENV_DIR"] = _dir
# The model chain's spend cap fails CLOSED when its ledger cannot be read (2026-11-03):
# correct in production, but on a non-root test host /var/lib/hydra is unreadable, so a
# test would refuse the metered tier and assert the wrong failure. Point the ledger at
# the per-process temp dir too.
os.environ["MODEL_CHAIN_LEDGER_PATH"] = os.path.join(_dir, "model-chain-calls.jsonl")
open(os.path.join(_dir, ".credit-test-env"), "w").close()
assert not os.path.realpath(LOG_PATH).startswith(PROD_PREFIX), LOG_PATH
