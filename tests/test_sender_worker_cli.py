"""CLI tests for scripts/muso-outreach-sender-worker.py --dry-run.

The dry run must make no Gmail / Slack / GHL call and no Sheets write,
and must never print the contact's email.
"""
import importlib.util
import os
from unittest.mock import MagicMock

import pytest

from tests.conftest import make_noco_contact

_PATH = os.path.join(os.path.dirname(__file__), "..", "scripts",
                     "muso-outreach-sender-worker.py")
_LABELS = ("muso-meta/kind-new,muso-meta/nocodb_id-2,muso-meta/row_id-dangjf643,"
           "muso-meta/template-PrivateInvite,muso-meta/sender-a_at_muso.ai")
EMAIL = "secret.person@example.com"


@pytest.fixture
def cli(monkeypatch):
    spec = importlib.util.spec_from_file_location("sender_worker_cli", _PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    adapters = MagicMock()
    adapters.nocodb.get_contact.return_value = make_noco_contact(email=EMAIL)
    monkeypatch.setattr(mod, "RealAdapters", lambda: adapters)
    return mod, adapters


def _assert_no_side_effects(a):
    assert a.gmail.mock_calls == []
    assert a.slack.mock_calls == []
    assert a.ghl.mock_calls == []
    a.sheets.append_logbook_row.assert_not_called()


def test_dry_run_found_exits_0_without_side_effects_or_email(cli, capsys):
    mod, a = cli
    assert mod.main(["--dry-run", "--meta-labels", _LABELS]) == 0
    out = capsys.readouterr().out
    for want in ("nocodb_id=2", "row_id=dangjf643", "opp_id=None",
                 "contact_found=true", "row_id_match=true", "email_present=true"):
        assert want in out
    assert EMAIL not in out
    a.nocodb.get_contact.assert_called_once_with(2)
    _assert_no_side_effects(a)


def test_dry_run_not_found_exits_1(cli, capsys):
    mod, a = cli
    a.nocodb.get_contact.return_value = None
    assert mod.main(["--dry-run", "--meta-labels", _LABELS]) == 1
    assert "contact_found=false" in capsys.readouterr().out
    _assert_no_side_effects(a)


def test_dry_run_row_id_mismatch_exits_1(cli, capsys):
    mod, a = cli
    a.nocodb.get_contact.return_value = make_noco_contact(row_id="other")
    assert mod.main(["--dry-run", "--meta-labels", _LABELS]) == 1
    assert "row_id_match=false" in capsys.readouterr().out


def test_dry_run_followup_prints_prior_from_status_and_logbook(cli, capsys):
    mod, a = cli
    a.nocodb.get_contact.return_value = make_noco_contact(status="Follow Up 2")
    a.sheets.count_prior_followups_by_token.return_value = 1
    labels = _LABELS.replace("kind-new", "kind-followup").replace(
        "template-PrivateInvite", "template-FU-01") + ",muso-meta/opp-abc,muso-meta/thread-t1"
    assert mod.main(["--dry-run", "--meta-labels", labels]) == 0
    assert "prior=2" in capsys.readouterr().out
    _assert_no_side_effects(a)


def test_dry_run_bad_labels_exit_1(cli, capsys):
    mod, a = cli
    assert mod.main(["--dry-run", "--meta-labels", "muso-meta/kind-new"]) == 1
    assert "METADATA_MISSING" in capsys.readouterr().out
    a.nocodb.get_contact.assert_not_called()


def test_dry_run_without_meta_labels_is_usage_error(cli):
    mod, _ = cli
    with pytest.raises(SystemExit) as e:
        mod.main(["--dry-run"])
    assert e.value.code == 2


def test_real_run_still_requires_account_and_target(cli):
    mod, _ = cli
    with pytest.raises(SystemExit):
        mod.main(["--account", "a@muso.ai"])
