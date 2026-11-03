"""nocodb_client.get_contact via a stub nocodb-api.sh (MUSO_NOCODB_API_SH).

The stub records its argv so the tests also pin that exactly one read
verb (`records.get`) is issued against the Contacts Intelligence table.
"""
import json
import stat

import pytest

from scripts.lib.muso_outreach import nocodb_client


def _stub(tmp_path, monkeypatch, body, rc=0, stderr=""):
    argv_log = tmp_path / "argv"
    script = tmp_path / "nocodb-api.sh"
    script.write_text(
        '#!/usr/bin/env bash\n'
        f'echo "$@" >> {argv_log}\n'
        f"cat <<'EOF'\n{body}\nEOF\n"
        f"echo {stderr!r} >&2\nexit {rc}\n")
    script.chmod(script.stat().st_mode | stat.S_IXUSR)
    monkeypatch.setenv("MUSO_NOCODB_API_SH", str(script))
    return argv_log


def test_found_maps_fields_and_issues_one_read(tmp_path, monkeypatch):
    log = _stub(tmp_path, monkeypatch, json.dumps({
        "Id": 2, "Row ID": "dangjf643", "Status": "Follow Up 2",
        "Valid Professional Email": " ow@larsenstrings.com "}))
    c = nocodb_client.get_contact(2)
    assert (c.nocodb_id, c.row_id, c.status) == (2, "dangjf643", "Follow Up 2")
    assert c.valid_professional_email == "ow@larsenstrings.com"
    assert log.read_text().splitlines() == ["--raw records.get m9vsbijhrr9ddeu 2"]


def test_not_found_returns_none(tmp_path, monkeypatch):
    _stub(tmp_path, monkeypatch, '{"error":"ERR_RECORD_NOT_FOUND","message":"x"}',
          rc=3, stderr="ERROR: HTTP 404")
    assert nocodb_client.get_contact(999) is None


@pytest.mark.parametrize("body,rc", [
    ('{"error":"ERR_FORBIDDEN"}', 3),      # other HTTP error
    ("", 2),                               # token missing
    ("not json", 0),                       # bad JSON
    ('{"no_id": 1}', 0),                   # not a record
])
def test_every_other_failure_raises(tmp_path, monkeypatch, body, rc):
    _stub(tmp_path, monkeypatch, body, rc=rc)
    with pytest.raises(RuntimeError):
        nocodb_client.get_contact(2)


def test_default_script_path_is_repo_relative(monkeypatch):
    monkeypatch.delenv("MUSO_NOCODB_API_SH", raising=False)
    p = nocodb_client._script_path()
    assert p.endswith("skills-all/muso-nocodb/scripts/nocodb-api.sh")
    import os
    assert os.path.isfile(p)


def test_module_issues_no_write_verb():
    src = open(nocodb_client.__file__).read()
    assert "records.create" not in src and "records.update" not in src
    assert "records.delete" not in src
