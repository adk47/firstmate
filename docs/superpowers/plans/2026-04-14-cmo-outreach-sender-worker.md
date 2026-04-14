# CMO Outreach Sender Worker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a deterministic sender worker that validates every outreach email's recipient + reply state before delivery, removing the CMO agent's ability to hallucinate recipients or bypass logging.

**Architecture:** Drafts-as-outbox. The CMO agent still creates Gmail drafts (with metadata encoded in Gmail labels + a JSON HTML comment). A new Python worker (`scripts/muso-outreach-sender-worker.py`) reads approved drafts, runs seven precondition gates (A–G), sends only the valid ones via `gog gmail drafts send`, and atomically appends the logbook row + bumps the GHL opportunity stage. Phase 2 revokes the agent's `drafts send` tool permission so the worker is the only possible send path.

**Tech Stack:** Python 3.11+, `pytest` for tests, `gog` CLI (shelled out) for Gmail/Sheets/Slack operations, systemd cron on the hydra server. No new runtime dependencies beyond the standard library + `pytest`.

---

## File Structure

**New files:**

- `scripts/muso-outreach-sender-worker.py` — CLI entry point for the worker (argparse, orchestration loop).
- `scripts/lib/muso_outreach/__init__.py` — package marker.
- `scripts/lib/muso_outreach/config.py` — constants mirrored from `workspaces/cmo/skills/muso-outreach-engine/references/config.md` (sheet IDs, label names, muso account allow-list, Slack channel IDs).
- `scripts/lib/muso_outreach/types.py` — small dataclasses (`Draft`, `Thread`, `Message`, `ContactRow`, `Metadata`, `GateResult`).
- `scripts/lib/muso_outreach/metadata.py` — parse labels + JSON comment into a `Metadata`, enforce label/JSON reconciliation.
- `scripts/lib/muso_outreach/gates.py` — precondition gates A–G. Pure functions over domain objects.
- `scripts/lib/muso_outreach/gmail_client.py` — thin adapter wrapping `gog gmail` commands (fetch draft, fetch thread, list-drafts-by-label, send draft, apply label).
- `scripts/lib/muso_outreach/sheets_client.py` — thin adapter wrapping `gog sheets` (read contact by row id, append logbook row).
- `scripts/lib/muso_outreach/slack_client.py` — thin adapter wrapping `gog slack` (post block-reason, post batch summary).
- `scripts/lib/muso_outreach/ghl_client.py` — thin adapter calling GHL API to advance opportunity stage.
- `scripts/lib/muso_outreach/worker.py` — per-draft pipeline function (metadata → gates → send → relabel → log → GHL) and batch orchestrator with retry/skip/halt logic.
- `tests/__init__.py`
- `tests/conftest.py` — fixtures that build `Draft`/`Thread`/`Message`/`ContactRow` without hitting gog.
- `tests/test_metadata.py`
- `tests/test_gates.py`
- `tests/test_worker.py`
- `tests/requirements.txt` — just `pytest`.
- `docs/RUNBOOK-outreach-sender-worker.md` — ops runbook for the worker (how to trigger, how to re-run a batch, failure modes).
- `docs/superpowers/plans/2026-04-14-cmo-outreach-sender-worker.md` (this file).

**Modified files:**

- `workspaces/cmo/skills/muso-outreach-writer/SKILL.md` — require emitting label metadata + JSON comment; never emit a bare `drafts send`.
- `workspaces/cmo/skills/muso-outreach-followup/SKILL.md` — same, plus remove Step 6 (Send) and Step 7 (Log) — those now belong to the worker.
- `workspaces/cmo/skills/muso-outreach-sender/SKILL.md` — same, remove Steps 8–11 (Send, Log, GHL Sync, Slack Notification) and replace with "hand off to worker".
- `workspaces/cmo/skills/muso-outreach-engine/references/config.md` — add a new "Outreach Draft Metadata" section documenting the label + JSON convention.
- `scripts/deploy.sh` — add `--exclude='tests/'` to `RSYNC_EXCLUDES` so local pytest scratch doesn't ship to the server.

**Phase 2 and 3 only:**

- `/root/.openclaw-main/openclaw.json` on the server — remove `gog gmail drafts send` and `gog gmail messages send` from CMO's tool allow-list (edited via ops, not checked into the repo — see Task 15).
- `/etc/cron.d/` or root crontab on the server — add Monday worker run (see Task 16).

---

## Phase 1 — Worker MVP

### Task 1: Scaffold tests directory and package skeleton

**Files:**
- Create: `tests/__init__.py`
- Create: `tests/conftest.py`
- Create: `tests/requirements.txt`
- Create: `scripts/lib/__init__.py`
- Create: `scripts/lib/muso_outreach/__init__.py`
- Create: `scripts/lib/muso_outreach/types.py`
- Create: `scripts/lib/muso_outreach/config.py`
- Modify: `scripts/deploy.sh` — add `--exclude='tests/'` to `RSYNC_EXCLUDES`

- [ ] **Step 1: Create empty package markers**

```bash
mkdir -p tests scripts/lib/muso_outreach
touch tests/__init__.py scripts/lib/__init__.py scripts/lib/muso_outreach/__init__.py
```

- [ ] **Step 2: Pin pytest**

Write `tests/requirements.txt`:

```
pytest==8.3.4
```

- [ ] **Step 3: Write domain types**

Write `scripts/lib/muso_outreach/types.py`:

```python
"""Domain dataclasses used by the outreach sender worker.

Adapters (gmail_client, sheets_client) build these from gog CLI output;
gates and worker operate on them. This keeps side effects out of the
logic layer so the gates can be unit-tested without gog installed.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Optional


class Kind(str, Enum):
    FOLLOWUP = "followup"
    NEW = "new"


@dataclass(frozen=True)
class Message:
    message_id: str
    thread_id: str
    from_addr: str
    to_addrs: tuple[str, ...]
    cc_addrs: tuple[str, ...]
    bcc_addrs: tuple[str, ...]
    date_epoch: int  # UTC seconds


@dataclass(frozen=True)
class Thread:
    thread_id: str
    messages: tuple[Message, ...]  # oldest → newest


@dataclass(frozen=True)
class Draft:
    draft_id: str
    account: str  # e.g., "a@muso.ai"
    to_addrs: tuple[str, ...]
    cc_addrs: tuple[str, ...]
    bcc_addrs: tuple[str, ...]
    body_html: str
    labels: tuple[str, ...]
    reply_to_message_id: Optional[str]  # Gmail In-Reply-To header


@dataclass(frozen=True)
class ContactRow:
    row_id: int
    valid_professional_email: str  # may be empty


@dataclass(frozen=True)
class Metadata:
    kind: Kind
    sheet_row_id: int
    opp_id: str
    template: str
    sender: str  # muso.ai account
    original_thread_id: Optional[str]  # followup only
    override_reason: Optional[str] = None
    cc_allowlist: tuple[str, ...] = field(default_factory=tuple)
    bcc_allowlist: tuple[str, ...] = field(default_factory=tuple)


@dataclass(frozen=True)
class GateResult:
    passed: bool
    reason_code: Optional[str] = None  # e.g., "RECIPIENT_MISMATCH"
    reason_human: Optional[str] = None
```

- [ ] **Step 4: Write config constants**

Write `scripts/lib/muso_outreach/config.py`:

```python
"""Constants mirrored from
workspaces/cmo/skills/muso-outreach-engine/references/config.md.

Keep this file in sync with that doc — the pre-commit hook does not
enforce the mirroring; we rely on code review.
"""
from __future__ import annotations

# Google Sheets
CONTACTS_SHEET_ID = "1OWzfmxtgX-xq-aGxgmsjAdzQoyKbb94hnU_j-jm5q6I"
CONTACTS_TAB = "contacts_intelligence"
LOGBOOK_SHEET_ID = "1o1aUpAhQ8tNuZtzWqUm9bOUFvyPaGrCHbImbB4mtmW0"
LOGBOOK_TAB = "muso-b2b-outreach-reports"

# Gmail
OUTREACH_LABEL = "B2B - Ads"
AUTO_FU_APPROVED_LABEL = "B2B - Ads/auto-fu-approved"
OVERRIDE_APPROVED_LABEL = "B2B - Ads/override-approved"
META_LABEL_PREFIX = "muso-meta/"

# Production-safe outreach accounts (only a@muso.ai for now, per
# warming schedule in config.md).
OUTREACH_ALLOWED_SENDERS = frozenset({"a@muso.ai"})
# All muso.ai mailboxes we scan for crosscheck purposes.
MUSO_ACCOUNTS = (
    "a@muso.ai",
    "ak@muso.ai",
    "aaron.k@muso.ai",
    "f@muso.ai",
)

# Slack
SALES_ALERTS_CHANNEL = "C0ARQ021M40"  # #sales-alerts
DEVOPS_CHANNEL = "C0ADV2W76G4"  # #clio_devops

# GHL
GHL_LOCATION_ID = "S5w31kRRgsBjjiVATWlP"
GHL_PIPELINE_ID = "GeSt85TueSvJ0SNFZXfQ"

# Policy
MAX_FOLLOWUPS_PER_CONTACT = 3
CONTACT_REPLY_LOOKBACK_DAYS_NEW = 60
```

- [ ] **Step 5: Add tests exclude to deploy.sh**

Edit `scripts/deploy.sh`. Find the `RSYNC_EXCLUDES=(` array and add `--exclude='tests/'` after the `--exclude='hydra docs/'` line:

```bash
RSYNC_EXCLUDES=(
  # Repo hygiene
  --exclude='.git'
  --exclude='hydra docs/'
  --exclude='tests/'
  --exclude='secrets/'
  ...
```

- [ ] **Step 6: Commit**

```bash
git add -f tests/ scripts/lib/ scripts/deploy.sh
git -c commit.gpgsign=false commit -m "feat(outreach-sender): scaffold tests dir and muso_outreach package"
```

---

### Task 2: Metadata parser — labels are primary, JSON is fallback

**Files:**
- Create: `scripts/lib/muso_outreach/metadata.py`
- Create: `tests/test_metadata.py`

- [ ] **Step 1: Write the failing test**

Write `tests/test_metadata.py`:

```python
"""Tests for metadata.parse_from_draft.

Metadata lives redundantly in Gmail labels (primary) and a JSON HTML
comment in the draft body (fallback). See the design spec §1 for the
reconciliation rules this test suite locks in.
"""
import pytest

from scripts.lib.muso_outreach.metadata import (
    METADATA_LABEL_DISAGREE,
    METADATA_MISSING,
    parse_from_draft,
)
from scripts.lib.muso_outreach.types import Draft, Kind


def _draft(labels=(), body_html="") -> Draft:
    return Draft(
        draft_id="r1",
        account="a@muso.ai",
        to_addrs=("ow@larsenstrings.com",),
        cc_addrs=(),
        bcc_addrs=(),
        body_html=body_html,
        labels=labels,
        reply_to_message_id=None,
    )


def _labels_full(thread_id: str = "1812f") -> tuple[str, ...]:
    return (
        "B2B - Ads",
        "muso-meta/kind-followup",
        "muso-meta/row-1234",
        "muso-meta/opp-abc",
        "muso-meta/template-FU-01",
        "muso-meta/sender-a_at_muso.ai",
        f"muso-meta/thread-{thread_id}",
    )


def _json_comment(overrides: dict | None = None) -> str:
    import json
    payload = {
        "kind": "followup",
        "sheet_row_id": 1234,
        "opp_id": "abc",
        "template": "FU-01",
        "sender": "a@muso.ai",
        "original_thread_id": "1812f",
    }
    if overrides:
        payload.update(overrides)
    return f"<!-- muso-outreach:v1 {json.dumps(payload)} -->"


def test_labels_and_json_agree_uses_labels():
    draft = _draft(labels=_labels_full(), body_html=_json_comment())
    meta, warnings = parse_from_draft(draft)
    assert meta.kind is Kind.FOLLOWUP
    assert meta.sheet_row_id == 1234
    assert meta.opp_id == "abc"
    assert meta.sender == "a@muso.ai"
    assert meta.original_thread_id == "1812f"
    assert warnings == []


def test_labels_present_json_stripped_warns_but_proceeds():
    draft = _draft(labels=_labels_full(), body_html="<p>draft body without comment</p>")
    meta, warnings = parse_from_draft(draft)
    assert meta.sheet_row_id == 1234
    assert warnings and "json metadata missing" in warnings[0].lower()


def test_labels_missing_json_present_raises():
    draft = _draft(labels=("B2B - Ads",), body_html=_json_comment())
    with pytest.raises(ValueError) as exc:
        parse_from_draft(draft)
    assert exc.value.args[0] == METADATA_MISSING


def test_both_missing_raises():
    draft = _draft(labels=("B2B - Ads",), body_html="<p>nothing here</p>")
    with pytest.raises(ValueError) as exc:
        parse_from_draft(draft)
    assert exc.value.args[0] == METADATA_MISSING


def test_labels_and_json_disagree_raises():
    bad_labels = list(_labels_full())
    bad_labels[2] = "muso-meta/row-9999"  # disagrees with JSON sheet_row_id=1234
    draft = _draft(labels=tuple(bad_labels), body_html=_json_comment())
    with pytest.raises(ValueError) as exc:
        parse_from_draft(draft)
    assert exc.value.args[0] == METADATA_LABEL_DISAGREE


def test_new_kind_has_no_thread():
    labels = (
        "B2B - Ads",
        "muso-meta/kind-new",
        "muso-meta/row-55",
        "muso-meta/opp-xyz",
        "muso-meta/template-PrivateInvite",
        "muso-meta/sender-a_at_muso.ai",
    )
    body = _json_comment({"kind": "new", "sheet_row_id": 55, "opp_id": "xyz",
                          "template": "PrivateInvite", "sender": "a@muso.ai",
                          "original_thread_id": None})
    meta, _ = parse_from_draft(_draft(labels=labels, body_html=body))
    assert meta.kind is Kind.NEW
    assert meta.original_thread_id is None
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/nick/.superconductor/worktrees/hydra/sc-trapped-cryostat-2380
python3 -m pytest tests/test_metadata.py -v
```

Expected: `ImportError: No module named 'scripts.lib.muso_outreach.metadata'`

- [ ] **Step 3: Implement metadata parser**

Write `scripts/lib/muso_outreach/metadata.py`:

```python
"""Parse draft metadata from Gmail labels (primary) and JSON HTML
comment (fallback). See design spec §1 for reconciliation rules.
"""
from __future__ import annotations

import json
import re
from typing import Optional

from .config import META_LABEL_PREFIX
from .types import Draft, Kind, Metadata

METADATA_MISSING = "METADATA_MISSING"
METADATA_LABEL_DISAGREE = "METADATA_LABEL_DISAGREE"

_COMMENT_RE = re.compile(r"<!--\s*muso-outreach:v1\s+(\{.*?\})\s*-->", re.DOTALL)
# Label format: "muso-meta/<key>-<value>". Values may contain "-"; key does not.
_LABEL_RE = re.compile(rf"^{re.escape(META_LABEL_PREFIX)}([a-z_]+)-(.+)$")


def _decode_label_email(value: str) -> str:
    """Reverse the '@' → '_at_' replacement used when building labels."""
    return value.replace("_at_", "@")


def _parse_labels(labels: tuple[str, ...]) -> Optional[dict]:
    kv: dict = {}
    for label in labels:
        m = _LABEL_RE.match(label)
        if not m:
            continue
        key, value = m.group(1), m.group(2)
        kv[key] = value
    # "kind" is the sentinel — without it, labels are considered missing.
    if "kind" not in kv:
        return None
    # Normalize
    out = {
        "kind": kv["kind"],
        "sheet_row_id": int(kv["row"]) if "row" in kv else None,
        "opp_id": kv.get("opp"),
        "template": kv.get("template"),
        "sender": _decode_label_email(kv["sender"]) if "sender" in kv else None,
        "original_thread_id": kv.get("thread"),
    }
    return out


def _parse_json_comment(body_html: str) -> Optional[dict]:
    m = _COMMENT_RE.search(body_html or "")
    if not m:
        return None
    try:
        return json.loads(m.group(1))
    except json.JSONDecodeError:
        return None


def _agree(labels: dict, js: dict) -> bool:
    # JSON may include override_reason / cc_allowlist / bcc_allowlist that
    # labels do not carry. Those are compared only if present in both.
    for key in ("kind", "sheet_row_id", "opp_id", "template",
                "sender", "original_thread_id"):
        if labels.get(key) != js.get(key):
            return False
    return True


def _build(labels: dict, js: Optional[dict]) -> Metadata:
    kind = Kind(labels["kind"])
    extras = js or {}
    cc = tuple(extras.get("cc_allowlist") or ())
    bcc = tuple(extras.get("bcc_allowlist") or ())
    return Metadata(
        kind=kind,
        sheet_row_id=labels["sheet_row_id"],
        opp_id=labels["opp_id"],
        template=labels["template"],
        sender=labels["sender"],
        original_thread_id=labels["original_thread_id"] if kind is Kind.FOLLOWUP else None,
        override_reason=extras.get("override_reason"),
        cc_allowlist=cc,
        bcc_allowlist=bcc,
    )


def parse_from_draft(draft: Draft) -> tuple[Metadata, list[str]]:
    """Return (metadata, warnings). Raise ValueError(code) on failure.

    Codes: METADATA_MISSING, METADATA_LABEL_DISAGREE.
    """
    labels = _parse_labels(draft.labels)
    js = _parse_json_comment(draft.body_html)
    warnings: list[str] = []

    if labels is None:
        raise ValueError(METADATA_MISSING)

    if js is not None and not _agree(labels, js):
        raise ValueError(METADATA_LABEL_DISAGREE)

    if js is None:
        warnings.append(
            "JSON metadata missing from draft body (labels present). "
            "This usually means the draft body was edited in Gmail. "
            "Proceeding from labels."
        )

    return _build(labels, js), warnings
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
python3 -m pytest tests/test_metadata.py -v
```

Expected: all 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add -f scripts/lib/muso_outreach/metadata.py tests/test_metadata.py
git -c commit.gpgsign=false commit -m "feat(outreach-sender): metadata parser (labels primary, JSON fallback)"
```

---

### Task 3: Gate A — recipient match (both kinds, incl. inbound-initiated threads)

**Files:**
- Create: `scripts/lib/muso_outreach/gates.py`
- Create: `tests/test_gates.py`
- Create: `tests/conftest.py`

- [ ] **Step 1: Write shared fixtures**

Write `tests/conftest.py`:

```python
"""Shared fixtures for gate tests.

Builds domain objects directly — no gog, no Gmail, no network.
"""
from __future__ import annotations

from scripts.lib.muso_outreach.types import (
    ContactRow, Draft, Kind, Message, Metadata, Thread,
)


def make_draft(
    draft_id: str = "r1",
    account: str = "a@muso.ai",
    to: tuple[str, ...] = ("ow@larsenstrings.com",),
    cc: tuple[str, ...] = (),
    bcc: tuple[str, ...] = (),
    body_html: str = "",
    labels: tuple[str, ...] = (),
    reply_to: str | None = None,
) -> Draft:
    return Draft(draft_id, account, to, cc, bcc, body_html, labels, reply_to)


def make_message(
    message_id: str = "m1",
    thread_id: str = "t1",
    from_addr: str = "a@muso.ai",
    to_addrs: tuple[str, ...] = ("ow@larsenstrings.com",),
    cc_addrs: tuple[str, ...] = (),
    bcc_addrs: tuple[str, ...] = (),
    date_epoch: int = 0,
) -> Message:
    return Message(message_id, thread_id, from_addr, to_addrs,
                   cc_addrs, bcc_addrs, date_epoch)


def make_thread(thread_id: str = "t1", messages: tuple[Message, ...] = ()) -> Thread:
    return Thread(thread_id, messages)


def make_metadata(
    kind: Kind = Kind.FOLLOWUP,
    sheet_row_id: int = 1234,
    opp_id: str = "abc",
    template: str = "FU-01",
    sender: str = "a@muso.ai",
    original_thread_id: str | None = "t1",
    override_reason: str | None = None,
    cc_allowlist: tuple[str, ...] = (),
    bcc_allowlist: tuple[str, ...] = (),
) -> Metadata:
    return Metadata(kind, sheet_row_id, opp_id, template, sender,
                    original_thread_id, override_reason,
                    cc_allowlist, bcc_allowlist)


def make_contact_row(
    row_id: int = 1234,
    email: str = "ow@larsenstrings.com",
) -> ContactRow:
    return ContactRow(row_id, email)
```

- [ ] **Step 2: Write the failing tests for Gate A**

Write `tests/test_gates.py`:

```python
"""Tests for precondition gates A–G. See design spec §3."""
from __future__ import annotations

from scripts.lib.muso_outreach.gates import (
    RECIPIENT_MISMATCH,
    RECIPIENT_SOURCE_MISSING,
    gate_a_recipient_match,
)
from scripts.lib.muso_outreach.types import Kind
from tests.conftest import (
    make_contact_row, make_draft, make_message, make_metadata, make_thread,
)


# -------- Gate A: kind=new --------

def test_gate_a_new_matches_sheet_email_case_insensitive():
    draft = make_draft(to=("OW@LarsenStrings.com",))
    meta = make_metadata(kind=Kind.NEW, original_thread_id=None)
    row = make_contact_row(email="ow@larsenstrings.com")
    result = gate_a_recipient_match(draft, meta, thread=None, contact_row=row)
    assert result.passed, result.reason_human


def test_gate_a_new_hallucinated_domain_blocks():
    draft = make_draft(to=("ow@lfrequencies.com",))
    meta = make_metadata(kind=Kind.NEW, original_thread_id=None)
    row = make_contact_row(email="ow@larsenstrings.com")
    result = gate_a_recipient_match(draft, meta, thread=None, contact_row=row)
    assert not result.passed
    assert result.reason_code == RECIPIENT_MISMATCH
    # The human-readable reason must contain both addresses so Fede sees
    # the hallucination at a glance in #sales-alerts.
    assert "ow@lfrequencies.com" in result.reason_human
    assert "ow@larsenstrings.com" in result.reason_human


def test_gate_a_new_sheet_email_blank_blocks():
    draft = make_draft(to=("ow@larsenstrings.com",))
    meta = make_metadata(kind=Kind.NEW, original_thread_id=None)
    row = make_contact_row(email="")
    result = gate_a_recipient_match(draft, meta, thread=None, contact_row=row)
    assert not result.passed
    assert result.reason_code == RECIPIENT_SOURCE_MISSING


# -------- Gate A: kind=followup --------

def test_gate_a_followup_matches_first_outgoing_muso_message():
    thread = make_thread(messages=(
        make_message(message_id="m1", from_addr="a@muso.ai",
                     to_addrs=("ow@larsenstrings.com",), date_epoch=100),
        make_message(message_id="m2", from_addr="ow@larsenstrings.com",
                     to_addrs=("a@muso.ai",), date_epoch=200),
    ))
    draft = make_draft(to=("ow@larsenstrings.com",))
    meta = make_metadata(kind=Kind.FOLLOWUP, original_thread_id="t1")
    result = gate_a_recipient_match(draft, meta, thread=thread, contact_row=None)
    assert result.passed


def test_gate_a_followup_inbound_initiated_thread_uses_second_message():
    """Thread started by the contact; our reply is the second message.
    Gate A must compare the draft against the To: of our reply, not
    the original inbound message's To: (which would be @muso.ai)."""
    thread = make_thread(messages=(
        make_message(message_id="m1", from_addr="ole@larsenstrings.com",
                     to_addrs=("a@muso.ai",), date_epoch=100),
        make_message(message_id="m2", from_addr="a@muso.ai",
                     to_addrs=("ole@larsenstrings.com",), date_epoch=200),
    ))
    draft = make_draft(to=("ole@larsenstrings.com",))
    meta = make_metadata(kind=Kind.FOLLOWUP, original_thread_id="t1")
    result = gate_a_recipient_match(draft, meta, thread=thread, contact_row=None)
    assert result.passed


def test_gate_a_followup_hallucinated_domain_blocks():
    thread = make_thread(messages=(
        make_message(from_addr="a@muso.ai",
                     to_addrs=("ow@larsenstrings.com",), date_epoch=100),
    ))
    draft = make_draft(to=("ow@lfrequencies.com",))
    meta = make_metadata(kind=Kind.FOLLOWUP, original_thread_id="t1")
    result = gate_a_recipient_match(draft, meta, thread=thread, contact_row=None)
    assert not result.passed
    assert result.reason_code == RECIPIENT_MISMATCH


def test_gate_a_followup_no_outgoing_muso_message_blocks():
    thread = make_thread(messages=(
        make_message(from_addr="ole@larsenstrings.com",
                     to_addrs=("a@muso.ai",), date_epoch=100),
    ))
    draft = make_draft(to=("ole@larsenstrings.com",))
    meta = make_metadata(kind=Kind.FOLLOWUP, original_thread_id="t1")
    result = gate_a_recipient_match(draft, meta, thread=thread, contact_row=None)
    assert not result.passed
    assert result.reason_code == RECIPIENT_SOURCE_MISSING


def test_gate_a_override_reason_bypasses_mismatch():
    """Only gate A can be overridden. With override_reason set, a
    mismatched recipient is allowed through (send → worker logs override)."""
    thread = make_thread(messages=(
        make_message(from_addr="a@muso.ai",
                     to_addrs=("ow@larsenstrings.com",), date_epoch=100),
    ))
    draft = make_draft(to=("o.wichmann@larsenstrings.com",))
    meta = make_metadata(kind=Kind.FOLLOWUP, original_thread_id="t1",
                         override_reason="Contact asked us to CC their assistant")
    result = gate_a_recipient_match(draft, meta, thread=thread, contact_row=None)
    assert result.passed
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
python3 -m pytest tests/test_gates.py -v
```

Expected: `ImportError` for `gates`.

- [ ] **Step 4: Implement Gate A**

Write `scripts/lib/muso_outreach/gates.py`:

```python
"""Precondition gates A–G. Each is a pure function that returns a
GateResult. No I/O here — adapters fetch the data and pass it in.
"""
from __future__ import annotations

from typing import Optional

from .types import ContactRow, Draft, GateResult, Kind, Metadata, Thread

RECIPIENT_MISMATCH = "RECIPIENT_MISMATCH"
RECIPIENT_SOURCE_MISSING = "RECIPIENT_SOURCE_MISSING"


def _norm(addr: str) -> str:
    return addr.strip().lower()


def _first_outgoing_muso(thread: Thread, muso_domain: str = "@muso.ai") -> Optional[object]:
    for msg in thread.messages:
        if _norm(msg.from_addr).endswith(muso_domain):
            return msg
    return None


def gate_a_recipient_match(
    draft: Draft,
    meta: Metadata,
    thread: Optional[Thread],
    contact_row: Optional[ContactRow],
) -> GateResult:
    # Override escape hatch (design §5).
    if meta.override_reason:
        return GateResult(passed=True)

    if len(draft.to_addrs) != 1:
        return GateResult(
            passed=False,
            reason_code=RECIPIENT_MISMATCH,
            reason_human=(
                f"Draft must have exactly one To: recipient; got "
                f"{len(draft.to_addrs)}: {draft.to_addrs}"
            ),
        )

    draft_to = _norm(draft.to_addrs[0])

    if meta.kind is Kind.NEW:
        if contact_row is None or not contact_row.valid_professional_email:
            return GateResult(
                passed=False,
                reason_code=RECIPIENT_SOURCE_MISSING,
                reason_human=(
                    f"Sheet row {meta.sheet_row_id} has no valid_professional_email. "
                    "Update the sheet or drop this draft."
                ),
            )
        expected = _norm(contact_row.valid_professional_email)
        if draft_to != expected:
            return GateResult(
                passed=False,
                reason_code=RECIPIENT_MISMATCH,
                reason_human=(
                    f"Draft To: {draft.to_addrs[0]} does not match sheet "
                    f"{contact_row.valid_professional_email}. Likely hallucination."
                ),
            )
        return GateResult(passed=True)

    # kind == FOLLOWUP
    if thread is None or not thread.messages:
        return GateResult(
            passed=False,
            reason_code=RECIPIENT_SOURCE_MISSING,
            reason_human=(
                f"No thread {meta.original_thread_id} or thread is empty."
            ),
        )
    first_out = _first_outgoing_muso(thread)
    if first_out is None:
        return GateResult(
            passed=False,
            reason_code=RECIPIENT_SOURCE_MISSING,
            reason_human=(
                f"Thread {meta.original_thread_id} has no outgoing @muso.ai "
                f"message — cannot determine original recipient."
            ),
        )
    if len(first_out.to_addrs) != 1:
        return GateResult(
            passed=False,
            reason_code=RECIPIENT_SOURCE_MISSING,
            reason_human=(
                f"First outgoing message in {meta.original_thread_id} has "
                f"{len(first_out.to_addrs)} recipients; follow-up requires exactly 1."
            ),
        )
    expected = _norm(first_out.to_addrs[0])
    if draft_to != expected:
        return GateResult(
            passed=False,
            reason_code=RECIPIENT_MISMATCH,
            reason_human=(
                f"Draft To: {draft.to_addrs[0]} does not match original thread "
                f"recipient {first_out.to_addrs[0]}. Likely hallucination."
            ),
        )
    return GateResult(passed=True)
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
python3 -m pytest tests/test_gates.py -v
```

Expected: 8 tests pass.

- [ ] **Step 6: Commit**

```bash
git add -f scripts/lib/muso_outreach/gates.py tests/test_gates.py tests/conftest.py
git -c commit.gpgsign=false commit -m "feat(outreach-sender): gate A (recipient match) with inbound-thread handling"
```

---

### Task 4: Gate B — no contact reply

**Files:**
- Modify: `scripts/lib/muso_outreach/gates.py`
- Modify: `tests/test_gates.py`

- [ ] **Step 1: Add failing tests for Gate B**

Append to `tests/test_gates.py`:

```python
from scripts.lib.muso_outreach.gates import (
    CONTACT_REPLIED, gate_b_no_contact_reply,
)


def test_gate_b_followup_no_inbound_reply_passes():
    thread = make_thread(messages=(
        make_message(from_addr="a@muso.ai",
                     to_addrs=("ow@larsenstrings.com",), date_epoch=100),
    ))
    meta = make_metadata(kind=Kind.FOLLOWUP, original_thread_id="t1")
    result = gate_b_no_contact_reply(meta, thread=thread, inbound_messages=())
    assert result.passed


def test_gate_b_followup_contact_replied_blocks():
    thread = make_thread(messages=(
        make_message(from_addr="a@muso.ai",
                     to_addrs=("ow@larsenstrings.com",), date_epoch=100),
        make_message(from_addr="ow@larsenstrings.com",
                     to_addrs=("a@muso.ai",), date_epoch=200),
    ))
    meta = make_metadata(kind=Kind.FOLLOWUP, original_thread_id="t1")
    result = gate_b_no_contact_reply(meta, thread=thread, inbound_messages=())
    assert not result.passed
    assert result.reason_code == CONTACT_REPLIED


def test_gate_b_new_no_inbound_from_contact_passes():
    meta = make_metadata(kind=Kind.NEW, original_thread_id=None)
    result = gate_b_no_contact_reply(meta, thread=None, inbound_messages=())
    assert result.passed


def test_gate_b_new_contact_already_emailed_blocks():
    # For kind=new, the adapter fetches any recent messages from the
    # target contact across all muso accounts and passes them in.
    meta = make_metadata(kind=Kind.NEW, original_thread_id=None)
    prior = (make_message(from_addr="prospect@acme.com",
                          to_addrs=("a@muso.ai",), date_epoch=100),)
    result = gate_b_no_contact_reply(meta, thread=None, inbound_messages=prior)
    assert not result.passed
    assert result.reason_code == CONTACT_REPLIED
```

- [ ] **Step 2: Run tests — expect ImportError**

```bash
python3 -m pytest tests/test_gates.py -v
```

- [ ] **Step 3: Implement Gate B**

Append to `scripts/lib/muso_outreach/gates.py`:

```python
CONTACT_REPLIED = "CONTACT_REPLIED"


def _is_muso(addr: str, muso_domain: str = "@muso.ai") -> bool:
    return _norm(addr).endswith(muso_domain)


def gate_b_no_contact_reply(
    meta: Metadata,
    thread: Optional[Thread],
    inbound_messages: tuple,  # for kind=new: prior messages from target contact
) -> GateResult:
    if meta.kind is Kind.FOLLOWUP:
        if thread is None:
            return GateResult(passed=True)
        for msg in thread.messages:
            if not _is_muso(msg.from_addr):
                return GateResult(
                    passed=False,
                    reason_code=CONTACT_REPLIED,
                    reason_human=(
                        f"Contact replied in thread {meta.original_thread_id} "
                        f"at epoch {msg.date_epoch}. Move GHL to Replied manually."
                    ),
                )
        return GateResult(passed=True)

    # kind=new
    for msg in inbound_messages:
        if not _is_muso(msg.from_addr):
            return GateResult(
                passed=False,
                reason_code=CONTACT_REPLIED,
                reason_human=(
                    f"Prior inbound message from target "
                    f"{msg.from_addr} at epoch {msg.date_epoch} — do not cold-email again."
                ),
            )
    return GateResult(passed=True)
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
python3 -m pytest tests/test_gates.py -v
```

Expected: 12 tests pass total.

- [ ] **Step 5: Commit**

```bash
git add -f scripts/lib/muso_outreach/gates.py tests/test_gates.py
git -c commit.gpgsign=false commit -m "feat(outreach-sender): gate B (no contact reply)"
```

---

### Task 5: Gate C — no human-teammate reply on the thread (Phase 1, not deferred)

**Files:**
- Modify: `scripts/lib/muso_outreach/gates.py`
- Modify: `tests/test_gates.py`

- [ ] **Step 1: Add failing tests for Gate C**

Append to `tests/test_gates.py`:

```python
from scripts.lib.muso_outreach.gates import (
    HUMAN_TEAMMATE_REPLIED, gate_c_no_human_reply,
)


def test_gate_c_only_bot_sender_in_thread_passes():
    thread = make_thread(messages=(
        make_message(from_addr="a@muso.ai", date_epoch=100),
        make_message(from_addr="ow@larsenstrings.com",
                     to_addrs=("a@muso.ai",), date_epoch=200),
        make_message(from_addr="a@muso.ai", date_epoch=300),
    ))
    meta = make_metadata(kind=Kind.FOLLOWUP, sender="a@muso.ai")
    # Gate C looks at muso.ai messages AFTER the last bot-sender message.
    # Here the last bot-sender msg is at 300 and nothing follows.
    result = gate_c_no_human_reply(meta, thread=thread, bot_senders=("a@muso.ai",))
    assert result.passed


def test_gate_c_human_teammate_replied_blocks():
    """Aaron (a human on the team) replied from aaron.k@muso.ai after
    the bot's last send. Bot must stand down."""
    thread = make_thread(messages=(
        make_message(from_addr="a@muso.ai", date_epoch=100),  # bot
        make_message(from_addr="aaron.k@muso.ai", date_epoch=200),  # human
    ))
    meta = make_metadata(kind=Kind.FOLLOWUP, sender="a@muso.ai")
    result = gate_c_no_human_reply(meta, thread=thread, bot_senders=("a@muso.ai",))
    assert not result.passed
    assert result.reason_code == HUMAN_TEAMMATE_REPLIED
    assert "aaron.k@muso.ai" in result.reason_human


def test_gate_c_bot_resend_not_flagged_as_human():
    """Multiple bot messages in sequence do not trigger the gate."""
    thread = make_thread(messages=(
        make_message(from_addr="a@muso.ai", date_epoch=100),
        make_message(from_addr="a@muso.ai", date_epoch=200),
    ))
    meta = make_metadata(kind=Kind.FOLLOWUP, sender="a@muso.ai")
    result = gate_c_no_human_reply(meta, thread=thread, bot_senders=("a@muso.ai",))
    assert result.passed


def test_gate_c_new_kind_skipped():
    meta = make_metadata(kind=Kind.NEW, original_thread_id=None)
    result = gate_c_no_human_reply(meta, thread=None, bot_senders=("a@muso.ai",))
    assert result.passed
```

- [ ] **Step 2: Run tests — expect ImportError**

```bash
python3 -m pytest tests/test_gates.py -v
```

- [ ] **Step 3: Implement Gate C**

Append to `scripts/lib/muso_outreach/gates.py`:

```python
HUMAN_TEAMMATE_REPLIED = "HUMAN_TEAMMATE_REPLIED"


def gate_c_no_human_reply(
    meta: Metadata,
    thread: Optional[Thread],
    bot_senders: tuple[str, ...],
) -> GateResult:
    """Block if any muso.ai address that is NOT the bot sender has a
    message in the thread after the bot's last send. Only applies to
    followups."""
    if meta.kind is Kind.NEW or thread is None:
        return GateResult(passed=True)

    bot_set = {_norm(s) for s in bot_senders}
    last_bot_epoch = -1
    for msg in thread.messages:
        if _norm(msg.from_addr) in bot_set:
            last_bot_epoch = max(last_bot_epoch, msg.date_epoch)

    if last_bot_epoch < 0:
        # No bot messages yet — nothing to follow up on. Gate C abstains.
        return GateResult(passed=True)

    for msg in thread.messages:
        if msg.date_epoch <= last_bot_epoch:
            continue
        if _is_muso(msg.from_addr) and _norm(msg.from_addr) not in bot_set:
            return GateResult(
                passed=False,
                reason_code=HUMAN_TEAMMATE_REPLIED,
                reason_human=(
                    f"Human teammate {msg.from_addr} replied in thread "
                    f"{meta.original_thread_id} after the bot's last send. "
                    "Bot stands down."
                ),
            )
    return GateResult(passed=True)
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
python3 -m pytest tests/test_gates.py -v
```

Expected: 16 tests pass.

- [ ] **Step 5: Commit**

```bash
git add -f scripts/lib/muso_outreach/gates.py tests/test_gates.py
git -c commit.gpgsign=false commit -m "feat(outreach-sender): gate C (bot stands down on human teammate reply)"
```

---

### Task 6: Gates D, E, F, G — weekend, followup cap, sender domain, CC/BCC

**Files:**
- Modify: `scripts/lib/muso_outreach/gates.py`
- Modify: `tests/test_gates.py`

- [ ] **Step 1: Add failing tests for D, E, F, G**

Append to `tests/test_gates.py`:

```python
from scripts.lib.muso_outreach.gates import (
    FOLLOWUP_CAP_REACHED,
    SENDER_NOT_ALLOWED,
    UNEXPECTED_CC_BCC,
    WEEKEND_BLOCKED,
    gate_d_not_weekend,
    gate_e_followup_cap,
    gate_f_sender_allowed,
    gate_g_cc_bcc_match_allowlist,
)


# Gate D
def test_gate_d_monday_passes():
    # 2026-04-13 is a Monday (UTC).
    assert gate_d_not_weekend(epoch=1776096000).passed


def test_gate_d_saturday_blocks():
    # 2026-04-11 is a Saturday (UTC).
    r = gate_d_not_weekend(epoch=1775923200)
    assert not r.passed
    assert r.reason_code == WEEKEND_BLOCKED


def test_gate_d_sunday_blocks():
    # 2026-04-12 is a Sunday (UTC).
    r = gate_d_not_weekend(epoch=1776009600)
    assert not r.passed
    assert r.reason_code == WEEKEND_BLOCKED


# Gate E
def test_gate_e_under_cap_passes():
    assert gate_e_followup_cap(prior_followup_count=2).passed


def test_gate_e_at_cap_blocks():
    r = gate_e_followup_cap(prior_followup_count=3)
    assert not r.passed
    assert r.reason_code == FOLLOWUP_CAP_REACHED


# Gate F
def test_gate_f_allowed_sender_passes():
    draft = make_draft(account="a@muso.ai")
    meta = make_metadata(sender="a@muso.ai")
    assert gate_f_sender_allowed(draft, meta,
                                 allow_list=frozenset({"a@muso.ai"})).passed


def test_gate_f_draft_from_non_allowed_account_blocks():
    draft = make_draft(account="random@elsewhere.com")
    meta = make_metadata(sender="a@muso.ai")
    r = gate_f_sender_allowed(draft, meta,
                              allow_list=frozenset({"a@muso.ai"}))
    assert not r.passed
    assert r.reason_code == SENDER_NOT_ALLOWED


def test_gate_f_draft_account_mismatches_metadata_sender_blocks():
    """The draft's actual sending account must agree with what the
    agent declared in metadata."""
    draft = make_draft(account="ak@muso.ai")
    meta = make_metadata(sender="a@muso.ai")
    r = gate_f_sender_allowed(draft, meta,
                              allow_list=frozenset({"a@muso.ai", "ak@muso.ai"}))
    assert not r.passed
    assert r.reason_code == SENDER_NOT_ALLOWED


# Gate G
def test_gate_g_no_cc_bcc_passes():
    draft = make_draft(cc=(), bcc=())
    meta = make_metadata(cc_allowlist=(), bcc_allowlist=())
    assert gate_g_cc_bcc_match_allowlist(draft, meta).passed


def test_gate_g_unexpected_cc_blocks():
    draft = make_draft(cc=("assistant@larsenstrings.com",))
    meta = make_metadata(cc_allowlist=())
    r = gate_g_cc_bcc_match_allowlist(draft, meta)
    assert not r.passed
    assert r.reason_code == UNEXPECTED_CC_BCC


def test_gate_g_explicit_cc_allowlist_passes():
    draft = make_draft(cc=("assistant@larsenstrings.com",))
    meta = make_metadata(cc_allowlist=("assistant@larsenstrings.com",))
    assert gate_g_cc_bcc_match_allowlist(draft, meta).passed


def test_gate_g_unexpected_bcc_blocks():
    draft = make_draft(bcc=("sneak@example.com",))
    meta = make_metadata()
    r = gate_g_cc_bcc_match_allowlist(draft, meta)
    assert not r.passed
    assert r.reason_code == UNEXPECTED_CC_BCC
```

- [ ] **Step 2: Run tests — expect ImportError**

```bash
python3 -m pytest tests/test_gates.py -v
```

- [ ] **Step 3: Implement Gates D, E, F, G**

Append to `scripts/lib/muso_outreach/gates.py`:

```python
from datetime import datetime, timezone

WEEKEND_BLOCKED = "WEEKEND_BLOCKED"
FOLLOWUP_CAP_REACHED = "FOLLOWUP_CAP_REACHED"
SENDER_NOT_ALLOWED = "SENDER_NOT_ALLOWED"
UNEXPECTED_CC_BCC = "UNEXPECTED_CC_BCC"


def gate_d_not_weekend(epoch: int) -> GateResult:
    """Saturday=5, Sunday=6 in Python's weekday()."""
    dow = datetime.fromtimestamp(epoch, tz=timezone.utc).weekday()
    if dow >= 5:
        return GateResult(
            passed=False,
            reason_code=WEEKEND_BLOCKED,
            reason_human="Weekend send blocked per outreach policy. Push to Monday.",
        )
    return GateResult(passed=True)


def gate_e_followup_cap(prior_followup_count: int,
                        cap: int = 3) -> GateResult:
    if prior_followup_count >= cap:
        return GateResult(
            passed=False,
            reason_code=FOLLOWUP_CAP_REACHED,
            reason_human=(
                f"Already sent {prior_followup_count} follow-ups; cap is {cap}."
            ),
        )
    return GateResult(passed=True)


def gate_f_sender_allowed(
    draft: Draft,
    meta: Metadata,
    allow_list: frozenset[str],
) -> GateResult:
    draft_account = _norm(draft.account)
    meta_sender = _norm(meta.sender)
    allowed = {_norm(a) for a in allow_list}
    if draft_account not in allowed:
        return GateResult(
            passed=False,
            reason_code=SENDER_NOT_ALLOWED,
            reason_human=(
                f"Draft account {draft.account} is not in the outreach "
                f"sender allow-list {sorted(allow_list)}."
            ),
        )
    if draft_account != meta_sender:
        return GateResult(
            passed=False,
            reason_code=SENDER_NOT_ALLOWED,
            reason_human=(
                f"Draft account {draft.account} disagrees with metadata "
                f"sender {meta.sender}. Precision mismatch."
            ),
        )
    return GateResult(passed=True)


def gate_g_cc_bcc_match_allowlist(
    draft: Draft,
    meta: Metadata,
) -> GateResult:
    cc_allow = {_norm(a) for a in meta.cc_allowlist}
    bcc_allow = {_norm(a) for a in meta.bcc_allowlist}
    extra_cc = [a for a in draft.cc_addrs if _norm(a) not in cc_allow]
    extra_bcc = [a for a in draft.bcc_addrs if _norm(a) not in bcc_allow]
    if extra_cc or extra_bcc:
        return GateResult(
            passed=False,
            reason_code=UNEXPECTED_CC_BCC,
            reason_human=(
                f"Unexpected CC: {extra_cc} / BCC: {extra_bcc}. "
                "Refusing to send."
            ),
        )
    return GateResult(passed=True)
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
python3 -m pytest tests/test_gates.py -v
```

Expected: 29 tests pass (4 D + 2 E + 3 F + 4 G + 16 prior).

- [ ] **Step 5: Commit**

```bash
git add -f scripts/lib/muso_outreach/gates.py tests/test_gates.py
git -c commit.gpgsign=false commit -m "feat(outreach-sender): gates D E F G (weekend, cap, sender, CC/BCC)"
```

---

### Task 7: Gmail / Sheets / Slack / GHL adapters (thin shell-out wrappers)

**Files:**
- Create: `scripts/lib/muso_outreach/gmail_client.py`
- Create: `scripts/lib/muso_outreach/sheets_client.py`
- Create: `scripts/lib/muso_outreach/slack_client.py`
- Create: `scripts/lib/muso_outreach/ghl_client.py`

Adapters only. Each function is a thin wrapper around a `gog` CLI call or HTTP request, returning the domain object. No logic. These are not unit-tested in this plan (they're tested via the end-to-end smoke test in Task 16). The worker tests in Task 8 mock them.

- [ ] **Step 1: Implement `gmail_client.py`**

```python
"""Gog-CLI adapter for Gmail operations. Each function returns a
domain object (or raises on CLI failure) with no side effects other
than the underlying gog call.
"""
from __future__ import annotations

import json
import subprocess
from typing import Optional

from .types import Draft, Message, Thread


def _run_gog(*args: str) -> str:
    """Run a gog command and return stdout. Raise CalledProcessError on
    non-zero exit."""
    res = subprocess.run(
        ("gog", *args),
        check=True,
        capture_output=True,
        text=True,
        timeout=30,
    )
    return res.stdout


def _parse_message(js: dict) -> Message:
    return Message(
        message_id=js["id"],
        thread_id=js["threadId"],
        from_addr=js["from"],
        to_addrs=tuple(js.get("to") or ()),
        cc_addrs=tuple(js.get("cc") or ()),
        bcc_addrs=tuple(js.get("bcc") or ()),
        date_epoch=int(js["internalDate"]) // 1000,
    )


def fetch_draft(draft_id: str, account: str) -> Draft:
    out = _run_gog("gmail", "drafts", "get", draft_id, "--account", account, "--json")
    js = json.loads(out)
    return Draft(
        draft_id=js["id"],
        account=account,
        to_addrs=tuple(js.get("to") or ()),
        cc_addrs=tuple(js.get("cc") or ()),
        bcc_addrs=tuple(js.get("bcc") or ()),
        body_html=js.get("bodyHtml", ""),
        labels=tuple(js.get("labels") or ()),
        reply_to_message_id=js.get("inReplyTo"),
    )


def fetch_thread(thread_id: str, account: str) -> Thread:
    out = _run_gog("gmail", "threads", "get", thread_id,
                   "--account", account, "--json")
    js = json.loads(out)
    msgs = tuple(_parse_message(m) for m in js.get("messages", []))
    return Thread(thread_id=thread_id, messages=msgs)


def list_drafts_with_label(label: str, account: str) -> list[str]:
    out = _run_gog("gmail", "drafts", "list",
                   "--label", label, "--account", account, "--json")
    js = json.loads(out)
    return [d["id"] for d in js.get("drafts", [])]


def send_draft(draft_id: str, account: str) -> str:
    """Returns the message_id of the sent message."""
    out = _run_gog("gmail", "drafts", "send", draft_id,
                   "--account", account, "--json")
    js = json.loads(out)
    return js["id"]


def apply_label(message_id: str, label: str, account: str) -> None:
    _run_gog("gmail", "messages", "modify", message_id,
            "--add", label, "--account", account)


def search_inbound_from(email: str, days: int, accounts: tuple[str, ...]) -> tuple[Message, ...]:
    """Search all muso accounts for messages FROM `email` in the last N days.
    Returns Messages across all accounts (de-duped by message_id)."""
    seen: dict[str, Message] = {}
    for acct in accounts:
        query = f"from:{email} newer_than:{days}d"
        out = _run_gog("gmail", "messages", "search", query,
                       "--account", acct, "--json")
        js = json.loads(out)
        for m in js.get("messages", []):
            msg = _parse_message(m)
            seen[msg.message_id] = msg
    return tuple(seen.values())
```

- [ ] **Step 2: Implement `sheets_client.py`**

```python
"""Gog-CLI adapter for Google Sheets."""
from __future__ import annotations

import json
import subprocess
from typing import Optional

from .config import CONTACTS_SHEET_ID, CONTACTS_TAB, LOGBOOK_SHEET_ID, LOGBOOK_TAB
from .types import ContactRow


def _run_gog(*args: str) -> str:
    res = subprocess.run(
        ("gog", *args),
        check=True,
        capture_output=True,
        text=True,
        timeout=30,
    )
    return res.stdout


def get_contact_by_row_id(row_id: int, account: str = "a@muso.ai") -> Optional[ContactRow]:
    """Read one row from contacts_intelligence by its Row ID column."""
    out = _run_gog("sheets", "get", CONTACTS_SHEET_ID,
                   "--range", f"{CONTACTS_TAB}!A:Z",
                   "--account", account, "--json")
    js = json.loads(out)
    header = js.get("values", [[]])[0]
    try:
        idx_row = header.index("Row ID")
        idx_email = header.index("Valid Professional Email")
    except ValueError:
        return None
    for row in js.get("values", [])[1:]:
        if len(row) <= max(idx_row, idx_email):
            continue
        if str(row[idx_row]).strip() != str(row_id):
            continue
        return ContactRow(row_id=row_id,
                          valid_professional_email=(row[idx_email] or "").strip())
    return None


def count_prior_followups(sheet_row_id: int, account: str = "a@muso.ai") -> int:
    """Scan the logbook for Action='Follow-Up Sent' rows with this
    sheet_row_id embedded in the notes or contact column."""
    out = _run_gog("sheets", "get", LOGBOOK_SHEET_ID,
                   "--range", f"{LOGBOOK_TAB}!A:Z",
                   "--account", account, "--json")
    js = json.loads(out)
    rows = js.get("values", [])
    if not rows:
        return 0
    header = rows[0]
    try:
        idx_action = header.index("Action")
        idx_notes = header.index("Hook / Notes")
    except ValueError:
        return 0
    needle = f"row:{sheet_row_id}"
    count = 0
    for row in rows[1:]:
        if len(row) <= max(idx_action, idx_notes):
            continue
        if row[idx_action].strip() == "Follow-Up Sent" and needle in (row[idx_notes] or ""):
            count += 1
    return count


def append_logbook_row(values: list, account: str = "a@muso.ai") -> None:
    payload = json.dumps([values])
    _run_gog("sheets", "append", LOGBOOK_SHEET_ID,
             "--range", LOGBOOK_TAB,
             "--values", payload,
             "--account", account)
```

- [ ] **Step 3: Implement `slack_client.py`**

```python
"""Gog-CLI adapter for Slack."""
from __future__ import annotations

import subprocess

from .config import DEVOPS_CHANNEL, SALES_ALERTS_CHANNEL


def _run_gog(*args: str) -> None:
    subprocess.run(("gog", *args), check=True, capture_output=True,
                   text=True, timeout=15)


def post_sales_alert(text: str) -> None:
    _run_gog("slack", "chat", "postMessage",
             "--channel", SALES_ALERTS_CHANNEL,
             "--text", text)


def post_devops_alert(text: str) -> None:
    _run_gog("slack", "chat", "postMessage",
             "--channel", DEVOPS_CHANNEL,
             "--text", text)
```

- [ ] **Step 4: Implement `ghl_client.py`**

```python
"""Minimal GHL adapter — only the one operation the worker needs:
advance an opportunity stage."""
from __future__ import annotations

import json
import os
import urllib.error
import urllib.request

from .config import GHL_LOCATION_ID


def advance_opportunity_stage(opp_id: str, stage_id: str) -> None:
    api_key = os.environ.get("GHL_API_KEY")
    if not api_key:
        raise RuntimeError("GHL_API_KEY is not set in the environment")
    body = json.dumps({"pipelineStageId": stage_id,
                       "locationId": GHL_LOCATION_ID}).encode()
    req = urllib.request.Request(
        f"https://services.leadconnectorhq.com/opportunities/{opp_id}",
        data=body, method="PUT",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Version": "2021-07-28",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        if resp.status >= 300:
            raise RuntimeError(f"GHL PUT opp {opp_id} → {resp.status}")
```

- [ ] **Step 5: Commit**

```bash
git add -f scripts/lib/muso_outreach/gmail_client.py \
            scripts/lib/muso_outreach/sheets_client.py \
            scripts/lib/muso_outreach/slack_client.py \
            scripts/lib/muso_outreach/ghl_client.py
git -c commit.gpgsign=false commit -m "feat(outreach-sender): gog-CLI adapters for gmail/sheets/slack/ghl"
```

---

### Task 8: Per-draft pipeline — metadata → gates → send → relabel → log → GHL

**Files:**
- Create: `scripts/lib/muso_outreach/worker.py`
- Create: `tests/test_worker.py`

- [ ] **Step 1: Write the failing tests**

Write `tests/test_worker.py`:

```python
"""Tests for the per-draft pipeline in worker.process_draft.

We mock all adapter functions so no network call happens. The pipeline
must:
  - Parse metadata
  - Run all gates A–G
  - On any gate failure, NOT send, and return a Block result
  - On all gates pass, send → apply label → append logbook row → advance GHL
  - Treat logbook failure after successful send as red-alert (warn devops)
  - Treat GHL failure after successful send+log as warn (sales-alerts)
"""
from __future__ import annotations

from dataclasses import replace
from unittest.mock import MagicMock

import pytest

from scripts.lib.muso_outreach import worker
from scripts.lib.muso_outreach.types import Kind
from tests.conftest import make_contact_row, make_draft, make_message, make_metadata, make_thread


class Adapters:
    """Dependency bag so tests can inject mocks."""
    def __init__(self):
        self.gmail = MagicMock()
        self.sheets = MagicMock()
        self.slack = MagicMock()
        self.ghl = MagicMock()


def _labels_for(meta):
    kind_label = f"muso-meta/kind-{meta.kind.value}"
    sender_label = f"muso-meta/sender-{meta.sender.replace('@', '_at_')}"
    labels = [
        "B2B - Ads", kind_label,
        f"muso-meta/row-{meta.sheet_row_id}",
        f"muso-meta/opp-{meta.opp_id}",
        f"muso-meta/template-{meta.template}",
        sender_label,
    ]
    if meta.kind is Kind.FOLLOWUP:
        labels.append(f"muso-meta/thread-{meta.original_thread_id}")
    return tuple(labels)


def _happy_followup(adapters):
    meta = make_metadata(kind=Kind.FOLLOWUP, original_thread_id="t1")
    draft = make_draft(
        labels=_labels_for(meta),
        body_html='<!-- muso-outreach:v1 '
                  '{"kind":"followup","sheet_row_id":1234,"opp_id":"abc",'
                  '"template":"FU-01","sender":"a@muso.ai",'
                  '"original_thread_id":"t1"} -->',
    )
    thread = make_thread(messages=(
        make_message(from_addr="a@muso.ai",
                     to_addrs=("ow@larsenstrings.com",), date_epoch=100),
    ))
    adapters.gmail.fetch_draft.return_value = draft
    adapters.gmail.fetch_thread.return_value = thread
    adapters.gmail.send_draft.return_value = "sent-msg-id"
    adapters.sheets.count_prior_followups.return_value = 0
    return draft, meta


def test_happy_path_sends_relabels_logs_ghl(monkeypatch):
    a = Adapters()
    draft, meta = _happy_followup(a)
    monkeypatch.setattr(worker, "NOW_EPOCH",
                        lambda: 1776096000)  # Monday
    result = worker.process_draft(draft_id="r1", account="a@muso.ai",
                                  adapters=a)
    assert result.sent
    a.gmail.send_draft.assert_called_once_with("r1", "a@muso.ai")
    a.gmail.apply_label.assert_called_once_with(
        "sent-msg-id", "B2B - Ads", "a@muso.ai")
    a.sheets.append_logbook_row.assert_called_once()
    a.ghl.advance_opportunity_stage.assert_called_once()


def test_hallucinated_recipient_is_blocked_not_sent(monkeypatch):
    a = Adapters()
    draft, meta = _happy_followup(a)
    # Break the draft: wrong To:
    a.gmail.fetch_draft.return_value = replace(
        draft, to_addrs=("ow@lfrequencies.com",))
    monkeypatch.setattr(worker, "NOW_EPOCH", lambda: 1776096000)
    result = worker.process_draft(draft_id="r1", account="a@muso.ai",
                                  adapters=a)
    assert not result.sent
    assert result.reason_code == "RECIPIENT_MISMATCH"
    a.gmail.send_draft.assert_not_called()
    a.sheets.append_logbook_row.assert_not_called()
    # Block must be reported.
    a.slack.post_sales_alert.assert_called_once()


def test_logbook_failure_after_send_raises_devops_red_alert(monkeypatch):
    a = Adapters()
    _happy_followup(a)
    a.sheets.append_logbook_row.side_effect = RuntimeError("Sheets down")
    monkeypatch.setattr(worker, "NOW_EPOCH", lambda: 1776096000)
    result = worker.process_draft(draft_id="r1", account="a@muso.ai",
                                  adapters=a)
    # Send happened but log didn't.
    assert result.sent
    assert result.reason_code == "LOGBOOK_APPEND_FAILED"
    a.slack.post_devops_alert.assert_called_once()


def test_ghl_failure_after_send_logs_warning_not_red_alert(monkeypatch):
    a = Adapters()
    _happy_followup(a)
    a.ghl.advance_opportunity_stage.side_effect = RuntimeError("GHL 500")
    monkeypatch.setattr(worker, "NOW_EPOCH", lambda: 1776096000)
    result = worker.process_draft(draft_id="r1", account="a@muso.ai",
                                  adapters=a)
    assert result.sent
    # Logbook is OK, just GHL is flaky — not a red alert.
    assert result.reason_code == "GHL_SYNC_FAILED"
    a.slack.post_devops_alert.assert_not_called()
    a.slack.post_sales_alert.assert_called_once()
```

- [ ] **Step 2: Run tests — expect ImportError**

```bash
python3 -m pytest tests/test_worker.py -v
```

- [ ] **Step 3: Implement the pipeline**

Write `scripts/lib/muso_outreach/worker.py`:

```python
"""Per-draft pipeline and batch orchestrator for the outreach sender.

Imports of adapter modules are deferred/injected so tests can pass a
mock `Adapters` bag without the gog CLI being installed.
"""
from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Optional, Protocol

from . import gates
from .config import (
    AUTO_FU_APPROVED_LABEL,
    MAX_FOLLOWUPS_PER_CONTACT,
    MUSO_ACCOUNTS,
    OUTREACH_ALLOWED_SENDERS,
    OUTREACH_LABEL,
)
from .metadata import parse_from_draft
from .types import Kind, Metadata


# Overridable for tests.
def NOW_EPOCH() -> int:
    return int(time.time())


@dataclass(frozen=True)
class ProcessResult:
    draft_id: str
    sent: bool
    reason_code: Optional[str]
    reason_human: Optional[str]
    sent_message_id: Optional[str] = None


class Adapters(Protocol):
    gmail: object
    sheets: object
    slack: object
    ghl: object


def _fetch_contact_row(meta: Metadata, adapters) -> Optional[object]:
    if meta.kind is not Kind.NEW:
        return None
    return adapters.sheets.get_contact_by_row_id(meta.sheet_row_id)


def _fetch_thread(meta: Metadata, adapters) -> Optional[object]:
    if meta.kind is not Kind.FOLLOWUP or not meta.original_thread_id:
        return None
    return adapters.gmail.fetch_thread(meta.original_thread_id, meta.sender)


def _fetch_inbound(meta: Metadata, draft, adapters) -> tuple:
    if meta.kind is not Kind.NEW or not draft.to_addrs:
        return ()
    return adapters.gmail.search_inbound_from(
        draft.to_addrs[0],
        days=60,
        accounts=MUSO_ACCOUNTS,
    )


def _run_all_gates(draft, meta, thread, contact_row, adapters) -> gates.GateResult:
    # Order: A, B, C, D, E, F, G. First failure wins.
    a = gates.gate_a_recipient_match(draft, meta, thread, contact_row)
    if not a.passed:
        return a
    b = gates.gate_b_no_contact_reply(
        meta, thread,
        inbound_messages=_fetch_inbound(meta, draft, adapters),
    )
    if not b.passed:
        return b
    c = gates.gate_c_no_human_reply(meta, thread,
                                    bot_senders=tuple(OUTREACH_ALLOWED_SENDERS))
    if not c.passed:
        return c
    d = gates.gate_d_not_weekend(NOW_EPOCH())
    if not d.passed:
        return d
    prior = 0
    if meta.kind is Kind.FOLLOWUP:
        prior = adapters.sheets.count_prior_followups(meta.sheet_row_id)
    e = gates.gate_e_followup_cap(prior, cap=MAX_FOLLOWUPS_PER_CONTACT)
    if not e.passed:
        return e
    f = gates.gate_f_sender_allowed(draft, meta,
                                    allow_list=OUTREACH_ALLOWED_SENDERS)
    if not f.passed:
        return f
    return gates.gate_g_cc_bcc_match_allowlist(draft, meta)


def _build_logbook_row(draft, meta, sent_message_id: str) -> list:
    from datetime import datetime, timezone
    date_str = datetime.now(tz=timezone.utc).strftime("%Y-%m-%d")
    domain = (draft.to_addrs[0].split("@")[-1] if draft.to_addrs else "")
    action = "Follow-Up Sent" if meta.kind is Kind.FOLLOWUP else "Sent"
    notes = f"row:{meta.sheet_row_id} template:{meta.template}"
    if meta.override_reason:
        notes += f" override:{meta.override_reason[:120]}"
    return [
        "",  # # column (sheet autoincrements)
        date_str,
        meta.sender,
        domain,
        "",  # contact name — not available here, filled by the agent's drafting step on sheet update
        "",  # company — same
        "",  # title — same
        draft.to_addrs[0] if draft.to_addrs else "",
        action,
        "Sent",
        "",  # subject — optional
        meta.template,
        notes,
    ]


def process_draft(draft_id: str, account: str, adapters) -> ProcessResult:
    """Run the full per-draft pipeline. Returns a ProcessResult.

    If any gate blocks, post a #sales-alerts line and return sent=False.
    If send succeeds but logbook append fails, post a DEVOPS red-alert.
    If send+log succeed but GHL fails, post a sales-alerts warning.
    """
    draft = adapters.gmail.fetch_draft(draft_id, account)

    try:
        meta, warnings = parse_from_draft(draft)
    except ValueError as e:
        reason = (
            "Metadata labels missing. This usually means the draft was "
            "created outside the agent workflow or the body was edited "
            "in Gmail. Re-create the draft from the agent."
            if e.args[0] == "METADATA_MISSING"
            else "Metadata label/body mismatch — refusing to send. Re-create the draft."
        )
        adapters.slack.post_sales_alert(
            f":no_entry: Draft `{draft_id}` blocked: {reason}"
        )
        return ProcessResult(draft_id, False, e.args[0], reason)

    for w in warnings:
        adapters.slack.post_sales_alert(
            f":warning: Draft `{draft_id}`: {w}"
        )

    thread = _fetch_thread(meta, adapters)
    contact_row = _fetch_contact_row(meta, adapters)

    gate_result = _run_all_gates(draft, meta, thread, contact_row, adapters)
    if not gate_result.passed:
        adapters.slack.post_sales_alert(
            f":no_entry: Draft `{draft_id}` ({meta.kind.value}) blocked: "
            f"{gate_result.reason_code} — {gate_result.reason_human}"
        )
        return ProcessResult(draft_id, False,
                             gate_result.reason_code,
                             gate_result.reason_human)

    # Send.
    sent_id = adapters.gmail.send_draft(draft_id, account)
    adapters.gmail.apply_label(sent_id, OUTREACH_LABEL, account)

    # Logbook append — critical. Failure here is a red alert.
    try:
        adapters.sheets.append_logbook_row(_build_logbook_row(draft, meta, sent_id))
    except Exception as e:  # noqa: BLE001
        adapters.slack.post_devops_alert(
            f":rotating_light: RED ALERT: draft `{draft_id}` sent "
            f"(message `{sent_id}`) but logbook append failed: {e!r}. "
            "Manual reconciliation required."
        )
        return ProcessResult(draft_id, True, "LOGBOOK_APPEND_FAILED",
                             f"Logbook failed: {e!r}", sent_id)

    # GHL sync — best effort. Do not retry (risks double-moving the opp).
    try:
        adapters.ghl.advance_opportunity_stage(meta.opp_id, stage_id="")
    except Exception as e:  # noqa: BLE001
        adapters.slack.post_sales_alert(
            f":warning: Draft `{draft_id}` sent, logged, but GHL sync failed "
            f"for opp `{meta.opp_id}`: {e!r}. Advance manually."
        )
        return ProcessResult(draft_id, True, "GHL_SYNC_FAILED",
                             f"GHL failed: {e!r}", sent_id)

    return ProcessResult(draft_id, True, None, None, sent_id)
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
python3 -m pytest tests/test_worker.py -v
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add -f scripts/lib/muso_outreach/worker.py tests/test_worker.py
git -c commit.gpgsign=false commit -m "feat(outreach-sender): per-draft pipeline with error triage"
```

---

### Task 9: Batch orchestrator + retry/skip/halt semantics

**Files:**
- Modify: `scripts/lib/muso_outreach/worker.py`
- Modify: `tests/test_worker.py`

- [ ] **Step 1: Add failing tests for batch behavior**

Append to `tests/test_worker.py`:

```python
def test_batch_reports_summary(monkeypatch):
    """Batch of 3: one passes, one blocks, one send-fails once then succeeds."""
    a = Adapters()
    monkeypatch.setattr(worker, "NOW_EPOCH", lambda: 1776096000)
    # Draft IDs in order
    drafts = ["r1", "r2", "r3"]
    # Build happy responses for r1 and r3, blocker for r2 (bad To:)
    def fake_fetch(draft_id, account):
        base, meta = _happy_followup(a)
        if draft_id == "r2":
            return replace(base, draft_id="r2", to_addrs=("ow@wrong.com",))
        return replace(base, draft_id=draft_id)
    a.gmail.fetch_draft.side_effect = fake_fetch
    a.gmail.fetch_thread.return_value = make_thread(messages=(
        make_message(from_addr="a@muso.ai",
                     to_addrs=("ow@larsenstrings.com",), date_epoch=100),
    ))
    a.sheets.count_prior_followups.return_value = 0

    # send_draft: r1 ok, r3 ok, r2 never called
    a.gmail.send_draft.side_effect = ["m1", "m3"]

    report = worker.process_batch(drafts, account="a@muso.ai", adapters=a)
    assert report.sent_count == 2
    assert report.blocked_count == 1
    assert report.batch_halted is False
    a.slack.post_sales_alert.assert_any_call(
        ":white_check_mark: Batch done — sent: 2, blocked: 1, halted: no"
    )


def test_batch_halts_after_two_consecutive_send_failures(monkeypatch):
    """If two drafts in a row both fail retry, halt the batch."""
    a = Adapters()
    monkeypatch.setattr(worker, "NOW_EPOCH", lambda: 1776096000)
    drafts = ["r1", "r2", "r3"]
    def fake_fetch(draft_id, account):
        base, _ = _happy_followup(a)
        return replace(base, draft_id=draft_id)
    a.gmail.fetch_draft.side_effect = fake_fetch
    a.gmail.fetch_thread.return_value = make_thread(messages=(
        make_message(from_addr="a@muso.ai",
                     to_addrs=("ow@larsenstrings.com",), date_epoch=100),
    ))
    a.sheets.count_prior_followups.return_value = 0

    # Every send_draft call fails (twice per draft; after 2 consecutive
    # failing drafts the worker halts, so only r1 and r2 are attempted).
    a.gmail.send_draft.side_effect = RuntimeError("Gmail 503")

    report = worker.process_batch(drafts, account="a@muso.ai", adapters=a)
    assert report.batch_halted is True
    assert report.sent_count == 0
    # r3 never attempted.
    fetched = {call.args[0] for call in a.gmail.fetch_draft.call_args_list}
    assert "r3" not in fetched
```

- [ ] **Step 2: Run tests — expect AttributeError for `process_batch`**

- [ ] **Step 3: Implement batch orchestrator**

Append to `scripts/lib/muso_outreach/worker.py`:

```python
import time as _time

SEND_RETRY_BACKOFF_SEC = 5


@dataclass(frozen=True)
class BatchReport:
    sent_count: int
    blocked_count: int
    send_failed_count: int
    batch_halted: bool


def _process_one_with_retry(draft_id: str, account: str, adapters) -> tuple[ProcessResult, bool]:
    """Return (result, send_failed_after_retry)."""
    try:
        return process_draft(draft_id, account, adapters), False
    except Exception:
        # Single retry for transient send-side failures only.
        _time.sleep(SEND_RETRY_BACKOFF_SEC)
        try:
            return process_draft(draft_id, account, adapters), False
        except Exception as e:  # noqa: BLE001
            return (
                ProcessResult(
                    draft_id=draft_id, sent=False,
                    reason_code="SEND_FAILED_RETRIED",
                    reason_human=f"Both attempts raised: {e!r}",
                ),
                True,
            )


def process_batch(draft_ids: list[str], account: str, adapters) -> BatchReport:
    sent = 0
    blocked = 0
    send_failed = 0
    halted = False
    consecutive_send_failures = 0

    for draft_id in draft_ids:
        result, failed_to_send = _process_one_with_retry(draft_id, account, adapters)
        if failed_to_send:
            send_failed += 1
            consecutive_send_failures += 1
            adapters.slack.post_sales_alert(
                f":warning: Draft `{draft_id}` send failed after retry — skipping."
            )
            if consecutive_send_failures >= 2:
                halted = True
                adapters.slack.post_devops_alert(
                    f":rotating_light: Batch halted — 2 consecutive send failures. "
                    "Gmail likely in outage state."
                )
                break
            continue
        consecutive_send_failures = 0
        if result.sent:
            sent += 1
        else:
            blocked += 1

    adapters.slack.post_sales_alert(
        f":white_check_mark: Batch done — sent: {sent}, blocked: {blocked}, "
        f"halted: {'yes' if halted else 'no'}"
    )
    return BatchReport(sent_count=sent, blocked_count=blocked,
                       send_failed_count=send_failed, batch_halted=halted)
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
python3 -m pytest tests/test_worker.py -v
```

Expected: 6 tests pass in `test_worker.py`.

- [ ] **Step 5: Commit**

```bash
git add -f scripts/lib/muso_outreach/worker.py tests/test_worker.py
git -c commit.gpgsign=false commit -m "feat(outreach-sender): batch orchestrator with retry/skip/halt"
```

---

### Task 10: CLI entry point

**Files:**
- Create: `scripts/muso-outreach-sender-worker.py`

- [ ] **Step 1: Write the CLI script**

Write `scripts/muso-outreach-sender-worker.py`:

```python
#!/usr/bin/env python3
"""Outreach Sender Worker — the ONLY code path that sends B2B outreach email.

Usage:
  muso-outreach-sender-worker.py --label "B2B - Ads/auto-fu-approved" \\
                                  --account a@muso.ai

  muso-outreach-sender-worker.py --draft-id r1234 --account a@muso.ai

The worker reads drafts, validates recipient against original thread
(for follow-ups) or against the contacts sheet (for new outreach),
verifies no contact/human-teammate reply has landed, then sends and
logs atomically. See docs/RUNBOOK-outreach-sender-worker.md.
"""
from __future__ import annotations

import argparse
import sys

# Make the lib importable whether we're run from /opt/hydra/scripts/
# or the repo root.
import os
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from lib.muso_outreach import gmail_client, sheets_client, slack_client, ghl_client
from lib.muso_outreach.config import AUTO_FU_APPROVED_LABEL
from lib.muso_outreach.worker import process_batch, process_draft


class RealAdapters:
    gmail = gmail_client
    sheets = sheets_client
    slack = slack_client
    ghl = ghl_client


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--account", required=True,
                   help="Sending Gmail account, e.g. a@muso.ai")
    group = p.add_mutually_exclusive_group(required=True)
    group.add_argument("--draft-id",
                       help="Process exactly one draft by ID")
    group.add_argument("--label",
                       help="Process every draft with this label")
    args = p.parse_args(argv)

    a = RealAdapters()
    if args.draft_id:
        result = process_draft(args.draft_id, args.account, a)
        print(result)
        return 0 if result.sent or result.reason_code else 1

    draft_ids = gmail_client.list_drafts_with_label(args.label, args.account)
    if not draft_ids:
        slack_client.post_sales_alert(
            f":information_source: No drafts under label `{args.label}`."
        )
        return 0
    report = process_batch(draft_ids, args.account, a)
    print(report)
    return 0 if not report.batch_halted else 2


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x scripts/muso-outreach-sender-worker.py
```

- [ ] **Step 3: Syntax-check it**

```bash
python3 -m py_compile scripts/muso-outreach-sender-worker.py
```

Expected: no output, exit 0.

- [ ] **Step 4: Commit**

```bash
git add -f scripts/muso-outreach-sender-worker.py
git -c commit.gpgsign=false commit -m "feat(outreach-sender): CLI entry point"
```

---

### Task 11: Update CMO skill prose — writer, followup, sender, shared config

**Files:**
- Modify: `workspaces/cmo/skills/muso-outreach-engine/references/config.md` — add metadata section
- Modify: `workspaces/cmo/skills/muso-outreach-writer/SKILL.md` — require metadata emission
- Modify: `workspaces/cmo/skills/muso-outreach-followup/SKILL.md` — drop Steps 6–7
- Modify: `workspaces/cmo/skills/muso-outreach-sender/SKILL.md` — drop Steps 8–11

- [ ] **Step 1: Add metadata section to shared config**

Open `workspaces/cmo/skills/muso-outreach-engine/references/config.md`. Find the `## Gmail` section (around line with "Muso Email Accounts"). At the end of the Gmail section, append:

```markdown

### Outreach Draft Metadata (REQUIRED on every outreach draft)

Every draft created by CMO for outreach MUST carry both (1) a set of
`muso-meta/*` Gmail labels and (2) a JSON HTML comment at the bottom
of the body. Drafts lacking the labels are **refused** by the sender
worker (see `scripts/muso-outreach-sender-worker.py`).

**Labels (primary):**
- `muso-meta/kind-followup` or `muso-meta/kind-new`
- `muso-meta/row-<sheet_row_id>`
- `muso-meta/opp-<ghl_opp_id>`
- `muso-meta/template-<template_key>`
- `muso-meta/sender-<a_at_muso.ai>` (replace `@` with `_at_`)
- `muso-meta/thread-<thread_id>` (follow-ups only)

**JSON comment (fallback):**
```html
<!-- muso-outreach:v1 {"kind":"followup","sheet_row_id":1234,"opp_id":"abc","template":"FU-01","sender":"a@muso.ai","original_thread_id":"1812f..."} -->
```

The worker prefers labels (they survive body edits). If the two
disagree, the worker blocks the draft with code `METADATA_LABEL_DISAGREE`.
```

- [ ] **Step 2: Update muso-outreach-writer SKILL.md**

Open `workspaces/cmo/skills/muso-outreach-writer/SKILL.md`. Find the part that describes the returned payload (around the mention of `subject`, `body_html`, `template_id`). Add a mandatory step so every returned body includes the JSON comment and the caller applies the labels. Replace any existing draft-create example with this one:

```markdown
### Draft Creation

After generating the HTML body, ALWAYS append this HTML comment at the
very bottom of `body_html` (between the sign-off and the closing
`</body>`):

```html
<!-- muso-outreach:v1 {"kind":"new","sheet_row_id":<N>,"opp_id":"<X>","template":"<T>","sender":"a@muso.ai","original_thread_id":null} -->
```

When creating the Gmail draft via `gog gmail drafts create`, ALWAYS
also apply the full set of `muso-meta/*` labels described in
`../muso-outreach-engine/references/config.md` → "Outreach Draft Metadata".

Omitting either the comment or the labels will cause the sender worker
to block the draft at send time.
```

- [ ] **Step 3: Strip send steps from muso-outreach-followup SKILL.md**

Open `workspaces/cmo/skills/muso-outreach-followup/SKILL.md`. Delete the content between and including `### Step 6: Send` and `### Step 7: Log + GHL Sync` (inclusive of both headers and all lines until the next `##` or `###`). Replace with:

```markdown
### Step 6: Hand off to Sender Worker

Do NOT call `gog gmail drafts send`. Sending is the worker's job.

When the batch is approved (Fede reacts ✅ on the Slack approval post),
the sender worker runs, reads every draft under label
`B2B - Ads/auto-fu-approved`, applies the precondition gate, and sends
only the valid drafts. The worker owns Gmail send + logbook append +
GHL stage advance as one atomic step.

If a draft is blocked, the worker posts the reason to `#sales-alerts`.
Fix the draft (re-create from this skill if the data changed) and
re-approve. Do NOT attempt to bypass the gate by calling `drafts send`
directly — the gateway allow-list denies it.

See `docs/RUNBOOK-outreach-sender-worker.md` for failure-mode details.
```

- [ ] **Step 4: Strip send steps from muso-outreach-sender SKILL.md**

Open `workspaces/cmo/skills/muso-outreach-sender/SKILL.md`. Delete the content starting at `### Step 8: Send` up to (but not including) the `## Constraints` heading. Replace with:

```markdown
### Step 8: Hand off to Sender Worker

Do NOT call `gog gmail drafts send`. Sending is the worker's job.

Once Fede / Aaron approves the batch, the sender worker (running via
Slack event handler) reads every draft under label `B2B - Ads` with
`muso-meta/kind-new` applied, runs the precondition gate, and sends
only the valid drafts. The worker owns Gmail send + logbook append +
GHL `Emailed` stage set + Slack notification as one atomic step.

Blocked drafts appear in `#sales-alerts` with a machine-readable
reason code. Fix and re-approve; do NOT bypass.

See `docs/RUNBOOK-outreach-sender-worker.md` for ops details.
```

- [ ] **Step 5: Commit**

```bash
git add -f workspaces/cmo/skills/muso-outreach-engine/references/config.md \
            workspaces/cmo/skills/muso-outreach-writer/SKILL.md \
            workspaces/cmo/skills/muso-outreach-followup/SKILL.md \
            workspaces/cmo/skills/muso-outreach-sender/SKILL.md
git -c commit.gpgsign=false commit -m "docs(outreach): move send responsibility from agent skills to worker"
```

---

### Task 12: Operator runbook

**Files:**
- Create: `docs/RUNBOOK-outreach-sender-worker.md`

- [ ] **Step 1: Write the runbook**

Write `docs/RUNBOOK-outreach-sender-worker.md`:

```markdown
# Runbook: Outreach Sender Worker

**Script:** `/opt/hydra/scripts/muso-outreach-sender-worker.py`
**Source of truth:** `docs/superpowers/specs/2026-04-14-cmo-outreach-sender-worker-design.md`
**On call:** Nick / Aaron

## What it does

Reads outreach drafts from Gmail, validates recipient + reply state,
sends only the valid ones, and appends a logbook row atomically.
CMO agent creates drafts; this worker sends them.

## Triggers

- **Approval batch:** Slack reaction ✅ on the CMO's approval post in
  `#sales-alerts` → Slack event handler invokes the worker with the
  label for that batch.
- **Monday cron:** `0 9 * * 1` UTC — processes drafts under
  `B2B - Ads/auto-fu-approved`.
- **Manual:** SSH to node-8 and run:
  ```bash
  /opt/hydra/scripts/muso-outreach-sender-worker.py \\
    --label "B2B - Ads/auto-fu-approved" --account a@muso.ai
  ```

## Reading the output

After every run the worker posts a batch summary to `#sales-alerts`:

> ✅ Batch done — sent: 12, blocked: 3, halted: no

For each blocked draft, a separate `#sales-alerts` message names the
draft ID and reason code.

## Block reason codes

| Code | What happened | Fix |
|------|---------------|-----|
| `METADATA_MISSING` | Labels not set; draft was edited in Gmail or created outside the agent | Delete the draft and re-create from the agent |
| `METADATA_LABEL_DISAGREE` | Labels and JSON comment say different things | Re-create from the agent |
| `RECIPIENT_MISMATCH` | Draft `To:` differs from original thread / sheet value | Agent hallucinated; re-create |
| `RECIPIENT_SOURCE_MISSING` | Sheet email blank, or thread has no outgoing muso message | Fix the sheet row, or check the thread |
| `CONTACT_REPLIED` | The contact has already replied | Move GHL opp to Replied manually |
| `HUMAN_TEAMMATE_REPLIED` | Someone on the team replied on the thread after the bot | Bot stands down; if you still want to nudge, do it manually |
| `WEEKEND_BLOCKED` | Saturday or Sunday UTC | Re-trigger on Monday |
| `FOLLOWUP_CAP_REACHED` | Already sent 3 follow-ups to this contact | Move GHL opp to Closed Lost or No Reply |
| `SENDER_NOT_ALLOWED` | Draft is from an account outside the allow-list | Check the account; update config if warming is complete |
| `UNEXPECTED_CC_BCC` | Draft has CC/BCC not in metadata's allowlist | Remove the CC/BCC, or add to metadata and re-approve |
| `LOGBOOK_APPEND_FAILED` | Email sent but Sheets append raised | **Red alert** — manual reconciliation required |
| `GHL_SYNC_FAILED` | Email sent + logged, GHL API failed | Advance the opp manually |
| `SEND_FAILED_RETRIED` | `gog gmail drafts send` failed twice on this draft | Single flake; ignore unless two in a row (then batch halts) |

## Red-alert response (LOGBOOK_APPEND_FAILED)

The email was delivered but we have no record. To reconcile:

1. Find the message in Gmail via the `draft_id` or `sent-msg-id` in the alert.
2. Append the missing logbook row manually, using the format from
   `workspaces/cmo/.../config.md` → "Outreach Log Sheet".
3. Advance the GHL opp manually if needed.
4. File an issue on the Sheets API reliability if this happens twice.

## Halted batch (2 consecutive send failures)

Gmail is likely in an outage. Check
<https://www.google.com/appsstatus/dashboard/> and retry the batch
after the incident clears:

```bash
/opt/hydra/scripts/muso-outreach-sender-worker.py --label ... --account a@muso.ai
```

The worker is idempotent per-draft; already-sent drafts are skipped.

## Override an A-check block

Only Gate A (recipient match) is overridable. For every other block
code, the worker's decision is final.

1. Edit the draft in Gmail: fix `To:` manually.
2. Apply label `B2B - Ads/override-approved`.
3. In the hidden JSON comment, add `"override_reason": "<text>"`.
4. Re-approve in Slack (react ✅).

The worker will log `override:<reason>` in the notes column.
```

- [ ] **Step 2: Commit**

```bash
git add docs/RUNBOOK-outreach-sender-worker.md
git -c commit.gpgsign=false commit -m "docs: runbook for outreach sender worker"
```

---

### Task 13: Run the full test suite + syntax check

**Files:** none (verification only)

- [ ] **Step 1: Run full test suite**

```bash
python3 -m pytest tests/ -v
```

Expected: all tests pass. Total count from tasks 2–9: 6 (metadata) + 29 (gates) + 6 (worker) = 41.

- [ ] **Step 2: Compile-check all new Python**

```bash
python3 -m py_compile scripts/muso-outreach-sender-worker.py
python3 -c "
import sys; sys.path.insert(0, 'scripts')
from lib.muso_outreach import (
    config, types, metadata, gates,
    gmail_client, sheets_client, slack_client, ghl_client, worker,
)
print('all modules import cleanly')
"
```

Expected: `all modules import cleanly`.

- [ ] **Step 3: Shellcheck deploy.sh**

```bash
shellcheck scripts/deploy.sh
```

Expected: no new warnings from our edit.

- [ ] **Step 4: No commit needed** (verification only).

---

## Phase 2 — Revoke send capability from the agent

### Task 14: Gateway allow-list change

**Files:**
- Modify: `/root/.openclaw-main/openclaw.json` on the server (NOT in repo)
- Create: `scripts/apply-cmo-send-denylist.sh` (in repo, for ops repeatability)

> **⚠️ Phase 2 must only ship after Phase 1 has been verified live for at least one full follow-up batch.** Removing send permission before the worker is reliable means zero outreach ships.

- [ ] **Step 1: Write the deny-list application script**

Write `scripts/apply-cmo-send-denylist.sh`:

```bash
#!/bin/bash
# Remove gog gmail send capabilities from the CMO agent's tool
# allow-list, so the outreach sender worker is the only path that
# can send. Idempotent: safe to re-run.
#
# Usage: ssh root@node-8 'bash -s' < apply-cmo-send-denylist.sh

set -euo pipefail

CONFIG=/root/.openclaw-main/openclaw.json
BACKUP="/root/openclaw.json.bak.$(date -u +%Y%m%dT%H%M%SZ)"

cp "$CONFIG" "$BACKUP"
echo "Backup: $BACKUP"

python3 - <<'PY'
import json
path = "/root/.openclaw-main/openclaw.json"
with open(path) as f:
    c = json.load(f)

# Find the CMO agent config.
cmo = next(a for a in c["agents"]["list"] if a.get("id") == "cmo")

deny = cmo.setdefault("toolDenyList", [])
for pattern in (
    "bash:gog gmail drafts send",
    "bash:gog gmail messages send",
    "bash:source ~/.zshrc && gog gmail drafts send",
    "bash:source ~/.zshrc && gog gmail messages send",
):
    if pattern not in deny:
        deny.append(pattern)

with open(path, "w") as f:
    json.dump(c, f, indent=2)
    f.write("\n")
print("CMO toolDenyList:", deny)
PY

systemctl restart openclaw-gateway-main
echo "openclaw-gateway-main restarted."
```

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/apply-cmo-send-denylist.sh
```

- [ ] **Step 3: Shellcheck**

```bash
shellcheck scripts/apply-cmo-send-denylist.sh
```

Expected: no warnings.

- [ ] **Step 4: Commit**

```bash
git add scripts/apply-cmo-send-denylist.sh
git -c commit.gpgsign=false commit -m "feat(ops): script to revoke CMO's gmail drafts send permission"
```

- [ ] **Step 5: Phase 2 application (manual, post-Phase-1-verification)**

After Phase 1 has shipped and the worker has processed at least one
live batch without red alerts:

```bash
ssh root@node-8 'bash -s' < scripts/apply-cmo-send-denylist.sh
```

Verify the CMO agent cannot send by asking it to draft + send a test
email — the send step must be denied at the gateway. Document the
verification in `#clio_devops`.

---

## Phase 3 — Monday cron

### Task 15: Monday follow-up cron

**Files:**
- Modify: `scripts/deploy.sh` (or server crontab directly — pick one path)
- Create: `scripts/cron-muso-outreach-monday.sh` (wrapper with logging)

- [ ] **Step 1: Write cron wrapper**

Write `scripts/cron-muso-outreach-monday.sh`:

```bash
#!/bin/bash
# Runs once per week via root crontab: 0 9 * * 1
# Processes drafts labeled B2B-Ads/auto-fu-approved and sends via the
# outreach sender worker. Idempotent per draft.
set -euo pipefail

LOGPREFIX="[muso-outreach-monday $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
echo "$LOGPREFIX start"

/opt/hydra/scripts/muso-outreach-sender-worker.py \
  --label "B2B - Ads/auto-fu-approved" \
  --account "a@muso.ai" \
  2>&1 | sed "s/^/$LOGPREFIX /"

echo "$LOGPREFIX done"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/cron-muso-outreach-monday.sh
```

- [ ] **Step 3: Shellcheck**

```bash
shellcheck scripts/cron-muso-outreach-monday.sh
```

Expected: no warnings.

- [ ] **Step 4: Commit**

```bash
git add scripts/cron-muso-outreach-monday.sh
git -c commit.gpgsign=false commit -m "feat(cron): Monday outreach follow-up trigger"
```

- [ ] **Step 5: Install on server (manual, post-Phase-2)**

```bash
ssh root@node-8 'crontab -l; echo "0 9 * * 1 /opt/hydra/scripts/cron-muso-outreach-monday.sh >> /var/log/muso-outreach-monday.log 2>&1" | crontab -'
```

Verify:

```bash
ssh root@node-8 'crontab -l | grep muso-outreach'
```

---

### Task 16: End-to-end smoke test on staging Gmail account

**Files:** none (verification)

- [ ] **Step 1: Create a staging draft manually**

SSH to node-8. Using a non-production Gmail account (e.g., a newly
created `staging@muso.ai` or any account with Gmail API creds), create
a draft with all the required metadata:

- Label: `muso-meta/kind-new`, `muso-meta/row-999999`, `muso-meta/opp-TEST`,
  `muso-meta/template-SmokeTest`, `muso-meta/sender-staging_at_muso.ai`.
- Body: includes the JSON comment with matching values.
- `To:` deliberately wrong (doesn't match sheet row 999999).

- [ ] **Step 2: Run the worker against this single draft**

```bash
/opt/hydra/scripts/muso-outreach-sender-worker.py \
  --draft-id <draft_id> --account staging@muso.ai
```

Expected: worker blocks the draft with `RECIPIENT_MISMATCH`, posts to
`#sales-alerts`, does NOT call `drafts send`.

- [ ] **Step 3: Fix the draft's `To:` and re-run**

Edit the draft's `To:` to match `contacts_intelligence[row_id=999999].valid_professional_email`
(you may need to add a test row to the sheet). Re-run the worker.

Expected: worker sends, posts success to `#sales-alerts`, appends a
logbook row.

- [ ] **Step 4: Document the smoke test result**

Post the outcome in `#clio_devops` linking to the `#sales-alerts`
posts. If any gate misbehaved, file an issue referencing this plan
and the specific test case; do NOT enable Phase 2 until resolved.

---

## Self-review

**Spec coverage (§ of spec → task):**

- § Goals → Phase 1 tasks (2–12), Phase 2 (14), Phase 3 (15).
- § Non-Goals → no tasks (intentionally excluded).
- § Architecture (drafts-as-outbox) → Task 10 (CLI), Task 14 (revoke agent send).
- § Components → §1 metadata: Task 2, 11. §2 worker: Task 8, 9, 10. §3 gates: Tasks 3–6. §4 tool restrictions: Task 14. §5 override: Task 3 (overridable gate A), Task 12 (runbook section).
- § Data flow → Task 10 + 11 + 12.
- § Error handling → Task 8 (per-draft triage), Task 9 (batch halt semantics), Task 12 (runbook).
- § Testing → Tasks 2–9 TDD, Task 13 full-suite check, Task 16 E2E smoke.
- § Rollout Phase 1 → Tasks 1–13. Phase 2 → Task 14. Phase 3 → Task 15, 16.
- § Observability → Tasks 8 + 9 post to Slack; Task 12 runbook; (log-file path `/var/log/muso-outreach-sender-worker.log` is implicit via cron wrapper in Task 15).

**Placeholder scan:** none found. Every step has actual code or an exact command with expected output.

**Type consistency:** `Draft`, `Thread`, `Message`, `ContactRow`, `Metadata`, `GateResult` defined in Task 1 and used consistently through Tasks 2–9. Reason codes (`RECIPIENT_MISMATCH`, `CONTACT_REPLIED`, etc.) defined in the gate that uses them and referenced by name in the runbook (Task 12). Adapter method names (`fetch_draft`, `fetch_thread`, `send_draft`, `apply_label`, `search_inbound_from`, `list_drafts_with_label`, `get_contact_by_row_id`, `count_prior_followups`, `append_logbook_row`, `post_sales_alert`, `post_devops_alert`, `advance_opportunity_stage`) are consistent between the adapter implementations (Task 7) and the worker (Tasks 8–9) and the mocked tests.
