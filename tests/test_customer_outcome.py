"""Unit tests for the shared ClickUp customer-outcome contract."""

import pathlib
import sys
import unittest


SCRIPTS = pathlib.Path(__file__).resolve().parent.parent / "scripts"
sys.path.insert(0, str(SCRIPTS))

from lib.customer_outcome import (  # noqa: E402
    customer_complete,
    customer_outcome_of,
    outcome_tag,
    workflow_terminal,
)


def task(status="resolved", status_type="done", *outcomes):
    return {
        "status": {"status": status, "type": status_type},
        "tags": [{"name": outcome_tag(outcome)} for outcome in outcomes],
    }


class TestCustomerOutcome(unittest.TestCase):
    def test_complete_requires_terminal_workflow_and_exactly_one_complete_tag(self):
        self.assertTrue(customer_complete(task("resolved", "done", "complete")))
        self.assertFalse(customer_complete(task("to do", "open", "complete")))
        self.assertFalse(customer_complete(task("resolved", "done")))
        self.assertFalse(customer_complete(task("resolved", "done", "partial")))

    def test_ambiguous_outcomes_fail_closed(self):
        ambiguous = task("resolved", "done", "complete", "partial")
        self.assertIsNone(customer_outcome_of(ambiguous))
        self.assertFalse(customer_complete(ambiguous))

    def test_impossible_never_means_customer_complete(self):
        impossible = task("impossible", "done", "complete")
        self.assertTrue(workflow_terminal(impossible))
        self.assertFalse(customer_complete(impossible))

    def test_unknown_outcome_fails_closed(self):
        unknown = {
            "status": {"status": "resolved", "type": "done"},
            "tags": [{"name": "customer-outcome:maybe"}],
        }
        self.assertIsNone(customer_outcome_of(unknown))
        self.assertFalse(customer_complete(unknown))


if __name__ == "__main__":
    unittest.main()
