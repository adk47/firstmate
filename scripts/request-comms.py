#!/usr/bin/env python3
"""CLI for the request status feed: `tick`, `report`, `check`, `stop`.

The implementation lives in scripts/request_comms/ (this file is only the entry point so the
timer, a human and the tests all run the same code).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from request_comms.driver import main  # noqa: E402

if __name__ == "__main__":
    raise SystemExit(main())
