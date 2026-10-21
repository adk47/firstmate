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
assert not os.path.realpath(LOG_PATH).startswith(PROD_PREFIX), LOG_PATH
