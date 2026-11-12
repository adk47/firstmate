#!/usr/bin/env python3
"""Caroline monitor and fix loop. The code is the package next door (scripts/caroline_monitor/);
this file is only the entry point systemd and people call.

    caroline-monitor.py tick          read Intercom, measure, page on a regression
    caroline-monitor.py report        the current reading
    caroline-monitor.py shapes        the fix loop, one row per shape
    caroline-monitor.py remeasure     did a shipped fix move its own number
    caroline-monitor.py drill         send one labelled test page

Runbook: docs/support/caroline-monitor.md
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from caroline_monitor.cli import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main())
