#!/usr/bin/env python3
"""Render outreach plans and validate the private idempotency ledger."""

import argparse
import fcntl
import hashlib
import json
import os
import re
import stat
import sys
import tempfile
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

APPLIED_SKILL_DIR = Path("/opt/hydra/workspaces/operations/skills/muso-profile-claim-evidence-outreach")
LEDGER_RELATIVE_PATH = Path("state/outreach-ledger.jsonl")
LOCK_RELATIVE_PATH = Path("state/outreach.lock")
RUNS_RELATIVE_PATH = Path("state/runs")
PROFILE_URL_RE = re.compile(r"https://credits\.muso\.ai/profile/[^\s/?#]+")

ALLOWED_ROUTES = {"support_email", "intercom_existing"}
ALLOWED_EVIDENCE = {
    "official_links": "Official artist or company links that connect you to this profile",
    "distributor_label": "Distributor or label documentation showing your connection",
    "publisher_pro": "Publisher or PRO documentation showing your connection",
    "alias_linkage": "Evidence linking your professional alias to your legal or established identity",
    "representative_authorization": "Authorization showing you may act for the artist or company",
    "organization_authority": "Proof of your role and authority within the organization",
}
CORRELATION = (
    "run_id", "communication_id", "attempt_number", "audit_id",
    "recipient_id", "claim_ids", "route", "content_hash",
)
UTC_RE = re.compile(r"Z$")
ALLOWED_SKIPPED_REASONS = frozenset({
    "no_longer_pending",
    "contested_cross_team",
    "organization_duplicate",
    "special_resolution",
    "mapping_unresolved",
    "prior_verified_delivery",
    "stale_revalidation",
    "other_ineligible",
})


class ValidationError(Exception):
    pass


def fail(message):
    raise ValidationError(message)


def load_json(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"malformed manifest: {exc}")
    if not isinstance(value, dict):
        fail("malformed manifest: root must be an object")
    return value


def parse_utc(value, field):
    if not isinstance(value, str) or not UTC_RE.search(value):
        fail(f"{field} must be an ISO-8601 UTC timestamp ending in Z")
    try:
        return datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError:
        fail(f"{field} is not a valid timestamp")


def require_mode(path, expected, kind):
    path = Path(path)
    try:
        metadata = os.lstat(path)
    except OSError as exc:
        fail(f"cannot inspect {path}: {exc}")
    if stat.S_ISLNK(metadata.st_mode):
        fail(f"{path} must not be a symlink")
    if kind == "directory":
        if not stat.S_ISDIR(metadata.st_mode):
            fail(f"{path} must be a directory")
    elif not stat.S_ISREG(metadata.st_mode):
        fail(f"{path} must be a regular file")
    mode = stat.S_IMODE(metadata.st_mode)
    if mode != expected:
        fail(f"{path} permissions must be {expected:04o}, found {mode:04o}")
    return path


def ensure_private_directory(path):
    path = Path(path)
    if os.path.lexists(path):
        return require_mode(path, 0o700, "directory")
    try:
        os.mkdir(path, 0o700)
        os.chmod(path, 0o700)
    except OSError as exc:
        fail(f"cannot create private directory {path}: {exc}")
    return require_mode(path, 0o700, "directory")


def resolve_exact_state_path(value, relative, label):
    supplied = Path(value)
    if supplied != relative:
        fail(f"{label} path must be exactly {relative.as_posix()}")
    return APPLIED_SKILL_DIR / relative


def ensure_state_directory():
    return ensure_private_directory(APPLIED_SKILL_DIR / "state")


def ensure_ledger(value):
    ensure_state_directory()
    path = resolve_exact_state_path(value, LEDGER_RELATIVE_PATH, "ledger")
    if not os.path.lexists(path):
        try:
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
            if hasattr(os, "O_NOFOLLOW"):
                flags |= os.O_NOFOLLOW
            fd = os.open(path, flags, 0o600)
            os.fchmod(fd, 0o600)
            os.close(fd)
        except OSError as exc:
            fail(f"cannot create ledger: {exc}")
    return require_mode(path, 0o600, "file")


def ensure_lock_file():
    ensure_state_directory()
    path = APPLIED_SKILL_DIR / LOCK_RELATIVE_PATH
    created_fd = None
    if not os.path.lexists(path):
        try:
            flags = os.O_RDWR | os.O_CREAT | os.O_EXCL
            if hasattr(os, "O_NOFOLLOW"):
                flags |= os.O_NOFOLLOW
            created_fd = os.open(path, flags, 0o600)
            os.fchmod(created_fd, 0o600)
        except FileExistsError:
            created_fd = None
        except OSError as exc:
            fail(f"cannot create outreach lock: {exc}")
    if created_fd is not None:
        return created_fd
    require_mode(path, 0o600, "file")
    try:
        flags = os.O_RDWR
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        fd = os.open(path, flags)
    except OSError as exc:
        fail(f"cannot open outreach lock: {exc}")
    try:
        descriptor_metadata = os.fstat(fd)
        path_metadata = os.lstat(path)
        if stat.S_ISLNK(path_metadata.st_mode):
            fail(f"{path} must not be a symlink")
        if not stat.S_ISREG(descriptor_metadata.st_mode):
            fail(f"{path} must be a regular file")
        if (descriptor_metadata.st_dev, descriptor_metadata.st_ino) != (
            path_metadata.st_dev, path_metadata.st_ino
        ):
            fail(f"{path} changed while opening")
        mode = stat.S_IMODE(descriptor_metadata.st_mode)
        if mode != 0o600:
            fail(f"{path} permissions must be 0600, found {mode:04o}")
        return fd
    except Exception:
        os.close(fd)
        raise


@contextmanager
def state_lock():
    fd = ensure_lock_file()
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def validate_run_id(run_id):
    if not isinstance(run_id, str) or not re.fullmatch(r"[A-Za-z0-9._-]+", run_id):
        fail("run_id must be a non-empty safe path segment")
    if run_id in {".", ".."}:
        fail("run_id must be a non-empty safe path segment")
    return run_id


def prepare_plan_path(run_id, supplied_output=None):
    run_id = validate_run_id(run_id)
    expected_relative = RUNS_RELATIVE_PATH / run_id / "plan.json"
    if supplied_output is not None and Path(supplied_output) != expected_relative:
        fail(f"plan path must be exactly {expected_relative.as_posix()}")
    state_dir = ensure_state_directory()
    runs_dir = ensure_private_directory(state_dir / "runs")
    run_dir = ensure_private_directory(runs_dir / run_id)
    path = run_dir / "plan.json"
    if os.path.lexists(path):
        require_mode(path, 0o600, "file")
    return path


def atomic_write_plan(path, encoded):
    path = Path(path)
    require_mode(path.parent, 0o700, "directory")
    encoded_bytes = encoded.encode("utf-8")
    if os.path.lexists(path):
        require_mode(path, 0o600, "file")
        try:
            existing_bytes = path.read_bytes()
        except OSError as exc:
            fail(f"cannot read existing immutable plan: {exc}")
        if existing_bytes != encoded_bytes:
            fail("existing run plan is immutable and differs from regenerated plan")
        return
    fd = None
    temporary = None
    try:
        fd, temporary = tempfile.mkstemp(prefix=".plan.", suffix=".tmp", dir=path.parent)
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as handle:
            fd = None
            handle.write(encoded_bytes)
            handle.flush()
            os.fsync(handle.fileno())
        require_mode(temporary, 0o600, "file")
        if os.path.lexists(path):
            require_mode(path, 0o600, "file")
            try:
                existing_bytes = path.read_bytes()
            except OSError as exc:
                fail(f"cannot read existing immutable plan: {exc}")
            if existing_bytes != encoded_bytes:
                fail("existing run plan is immutable and differs from regenerated plan")
            os.unlink(temporary)
            temporary = None
            return
        os.replace(temporary, path)
        temporary = None
        require_mode(path, 0o600, "file")
        directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except OSError as exc:
        fail(f"cannot atomically write plan: {exc}")
    finally:
        if fd is not None:
            os.close(fd)
        if temporary is not None:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass


def load_ledger(path):
    path = ensure_ledger(path)
    rows = []
    with path.open("r", encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError as exc:
                fail(f"malformed ledger line {number}: {exc}")
            if not isinstance(row, dict):
                fail(f"malformed ledger line {number}: expected object")
            rows.append(row)
    validate_ledger(rows, require_complete_run=None)
    return rows


def same_correlation(left, right):
    return all(left.get(key) == right.get(key) for key in CORRELATION)


def validate_common(row, index):
    required = {
        "schema_version", "event", "run_id", "communication_id", "attempt_number",
        "audit_id", "timestamp", "recipient_id", "claim_ids", "route", "content_hash",
    }
    missing = sorted(required - set(row))
    if missing:
        fail(f"ledger row {index} missing: {', '.join(missing)}")
    if row["schema_version"] != 1:
        fail(f"ledger row {index} has unsupported schema_version")
    parse_utc(row["timestamp"], f"ledger row {index} timestamp")
    if not all(isinstance(row[key], str) and row[key] for key in
               ("run_id", "communication_id", "audit_id", "recipient_id", "content_hash")):
        fail(f"ledger row {index} has invalid identifiers")
    if not re.fullmatch(r"[0-9a-f]{64}", row["communication_id"]):
        fail(f"ledger row {index} has invalid communication_id")
    if isinstance(row["attempt_number"], bool) or not isinstance(
        row["attempt_number"], int
    ) or row["attempt_number"] < 1:
        fail(f"ledger row {index} has invalid attempt_number")
    expected_audit_id = deterministic_attempt_audit_id(
        row["communication_id"], row["attempt_number"]
    )
    if row["audit_id"] != expected_audit_id:
        fail(f"ledger row {index} has invalid attempt audit_id")
    if row["route"] not in ALLOWED_ROUTES:
        fail(f"ledger row {index} has invalid route")
    claims = row["claim_ids"]
    if not isinstance(claims, list) or not claims or claims != sorted(set(claims)):
        fail(f"ledger row {index} claim_ids must be non-empty, sorted, and unique")
    if not all(isinstance(item, str) and item for item in claims):
        fail(f"ledger row {index} contains invalid claim id")
    if not re.fullmatch(r"[0-9a-f]{64}", row["content_hash"]):
        fail(f"ledger row {index} has invalid content_hash")


# ONE address contract, stated once: REJECT ANYTHING SMTP WILL REJECT.
#
# The provider is the real arbiter. Every shape it bounces that we let through
# reaches pre_send, and the claim then sits behind an active attempt until
# reconciliation. So the rules below are the union of what SMTP constrains, each
# with its source, rather than a check per defect as one is reported:
#
#   canonical form  no surrounding whitespace (ours: the value is copied
#                   verbatim into the content-hashed plan)
#   addr-spec       exactly one @, non-empty local and domain  RFC 5322 s3.4.1
#   local part      dot-atom: atoms joined by single dots, no
#                   leading/trailing/doubled dot                RFC 5322 s3.2.3
#   local length    <= 64 octets                             RFC 5321 s4.5.3.1.1
#   domain labels   LDH, 1-63 octets, no leading/trailing
#                   hyphen                                      RFC 1035 s2.3.1
#   domain length   <= 255 octets, subsumed by the total     RFC 5321 s4.5.3.1.2
#   TLD             present, alphabetic, >= 2 characters        (deliverability)
#   total mailbox   <= 254 octets                            RFC 5321 s4.5.3.1.3
#   ASCII           no control characters, no non-ASCII octets  RFC 5321 s2.3.1
#
# Deliberately narrower than RFC 5322 permits: no quoted strings, comments, or
# address literals. Those are legal to parse and useless to send to.
_ATOM = r"[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+"
_LABEL = r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
# Applied with fullmatch(), which anchors on its own - no \A/\Z needed.
EMAIL_RE = re.compile(
    _ATOM + r"(?:\." + _ATOM + r")*"
    r"@" + _LABEL + r"(?:\." + _LABEL + r")*"
    r"\.[A-Za-z]{2,}"
)
# Intercom conversation ids: same contract as the address - reject anything the
# provider will reject. A URL-safe token, because the id is used to address a
# conversation: this refuses embedded whitespace, newlines, control characters
# and path/query punctuation, which strip() could never see. Deliberately NOT
# narrowed to digits: every id observed in production here is numeric, but that
# is an observation rather than a documented guarantee, and wrongly rejecting a
# real conversation is the more expensive mistake.
CONVERSATION_ID_RE = re.compile(r"[A-Za-z0-9_-]{1,64}")

MAX_EMAIL_LOCAL = 64
MAX_EMAIL_TOTAL = 254
# RFC 5321's 255-octet domain limit needs no check of its own: the 254-octet
# mailbox limit above already caps the domain below it, so the branch could
# never fire.


def is_actionable_email(value):
    """True only for an address SMTP would accept. See the contract above.

    Surrounding whitespace, control characters and non-ASCII octets are all
    rejected by EMAIL_RE itself, which is anchored and whose character classes
    are ASCII-only, so they get no separate branch here: a guard no test can
    falsify is dead weight that reads as protection. The lengths DO need their
    own checks - the grammar constrains shape, not size - and the total is not
    implied by the parts, since a 64-octet local part and a 255-octet domain
    both satisfy their own limits and together far exceed the 254-octet
    mailbox limit. Characters equal octets for anything the grammar accepts.
    """
    if not isinstance(value, str) or not value:
        return False
    if len(value) > MAX_EMAIL_TOTAL:
        return False
    local, sep, _domain = value.partition("@")
    if not sep or len(local) > MAX_EMAIL_LOCAL:
        return False
    return EMAIL_RE.fullmatch(value) is not None


def register_provider_id(provider_owners, row, audit_id):
    provider_id = row.get("provider_id")
    if provider_id is None:
        return
    if not isinstance(provider_id, str) or not provider_id:
        fail(f"invalid provider_id: {audit_id}")
    namespace = (row["route"], provider_id)
    owner = provider_owners.get(namespace)
    if owner is not None and owner != audit_id:
        fail(f"duplicate provider_id within route: {provider_id}")
    provider_owners[namespace] = audit_id


def classify_attempt(pre_send, result, verification, reconciliation_rows, pre_send_index):
    latest_reconciliation = reconciliation_rows[-1] if reconciliation_rows else None
    incomplete = result is None or verification is None
    reconciled_result = latest_reconciliation.get("result") if latest_reconciliation else None
    # Terminal, not latest-wins. An authoritative delivered signal ANYWHERE in
    # this attempt's history means the customer received it, so a later
    # contradictory reconciliation must not make the attempt retryable and let
    # us contact them a second time. Round 4 applied this to the verification;
    # reading only the LATEST reconciliation left the same hole one layer down.
    delivered = (
        verification is not None
        and verification.get("verified_status") == "delivered"
    ) or any(
        isinstance(row, dict) and row.get("result") == "delivered"
        for row in reconciliation_rows
    )
    # A delivered attempt is never retryable, even if a later reconciliation
    # contradicts it. status_value below already resolves the contradiction in
    # favour of delivered; the flags have to agree, because cmd_reserve reads
    # `retryable` BEFORE `delivered` and would otherwise reserve an
    # already-delivered claim and contact the customer a second time.
    retryable = reconciled_result == "not_delivered" and not delivered
    has_unknown = (
        result is not None
        and result.get("outcome") == "unknown"
    ) or (
        verification is not None
        and verification.get("verified_status") == "unknown"
    )
    unresolved = incomplete or reconciled_result == "unknown" or (
        has_unknown and reconciled_result not in {"delivered", "not_delivered"}
    )
    if delivered:
        status_value = "delivered"
    elif retryable:
        status_value = "retryable"
    elif incomplete:
        status_value = "incomplete"
    elif unresolved:
        status_value = "unresolved"
    else:
        status_value = "active"
    return {
        "pre_send": pre_send,
        "provider_result": result,
        "verification": verification,
        "reconciliations": reconciliation_rows,
        "latest_reconciliation": latest_reconciliation,
        "pre_send_index": pre_send_index,
        "incomplete": incomplete,
        "delivered": delivered,
        "retryable": retryable,
        "unresolved": unresolved,
        "active": not delivered and not retryable,
        "status": status_value,
    }


def validate_ledger(rows, require_complete_run=None):
    presends = {}
    pre_send_order = []
    results = {}
    verifications = {}
    provider_owners = {}
    effective_provider_ids = {}
    reconciliations = []
    reconciliations_by_audit = {}
    communication_owners = {}

    for index, row in enumerate(rows, 1):
        validate_common(row, index)
        event = row["event"]
        key = row["audit_id"]
        communication_id = row["communication_id"]
        if event == "pre_send":
            if key in presends:
                fail(f"duplicate pre_send audit_id: {key}")
            communication_owner = (
                row["run_id"], row["recipient_id"], row["claim_ids"],
                row["route"], row["content_hash"],
            )
            prior_owner = communication_owners.get(communication_id)
            if prior_owner is not None and prior_owner != communication_owner:
                fail(f"communication_id correlation mismatch: {communication_id}")
            communication_owners[communication_id] = communication_owner
            presends[key] = row
            pre_send_order.append(key)
            reconciliations_by_audit[key] = []
        elif event == "provider_result":
            if key not in presends or not same_correlation(presends[key], row):
                fail(f"mismatched provider result: {key}")
            if key in results:
                fail(f"duplicate provider result: {key}")
            if row.get("outcome") not in {"accepted", "failed", "unknown"}:
                fail(f"invalid provider outcome: {key}")
            provider_id = row.get("provider_id")
            if row["outcome"] == "accepted" and not provider_id:
                fail(f"accepted provider result missing provider_id: {key}")
            register_provider_id(provider_owners, row, key)
            effective_provider_ids[key] = provider_id
            results[key] = row
        elif event == "verification":
            if key not in results or not same_correlation(presends[key], row):
                fail(f"mismatched verification: {key}")
            if key in verifications:
                fail(f"duplicate verification: {key}")
            status_value = row.get("verified_status")
            if status_value not in {"delivered", "not_delivered", "unknown"}:
                fail(f"invalid verification status: {key}")
            if row.get("provider_id") != effective_provider_ids.get(key):
                fail(f"verification provider mismatch: {key}")
            if status_value == "delivered" and not row.get("provider_id"):
                fail(f"delivered verification missing provider_id: {key}")
            register_provider_id(provider_owners, row, key)
            verifications[key] = row
        elif event == "reconciliation":
            if key not in results or key not in verifications or not same_correlation(presends[key], row):
                fail(f"mismatched reconciliation: {key}")
            if row.get("history_source") not in {"intercom", "gmail"}:
                fail(f"invalid reconciliation source: {key}")
            if row.get("result") not in {"delivered", "not_delivered", "unknown"}:
                fail(f"invalid reconciliation result: {key}")
            provider_id = row.get("provider_id")
            known_provider_id = effective_provider_ids.get(key)
            if provider_id is not None:
                if not isinstance(provider_id, str) or not provider_id:
                    fail(f"invalid provider_id: {key}")
                if known_provider_id is not None and provider_id != known_provider_id:
                    fail(f"reconciliation provider mismatch: {key}")
                effective_provider_ids[key] = provider_id
                register_provider_id(provider_owners, row, key)
            if row["result"] == "delivered" and not effective_provider_ids.get(key):
                fail(f"delivered reconciliation missing provider_id: {key}")
            reconciliations.append(row)
            reconciliations_by_audit[key].append(row)
        else:
            fail(f"unknown ledger event on row {index}: {event}")

    attempts = {}
    latest_attempt_by_claim = {}
    for pre_send_index, audit_id in enumerate(pre_send_order):
        attempt = classify_attempt(
            presends[audit_id],
            results.get(audit_id),
            verifications.get(audit_id),
            reconciliations_by_audit.get(audit_id, []),
            pre_send_index,
        )
        attempt["effective_provider_id"] = effective_provider_ids.get(audit_id)
        attempts[audit_id] = attempt
        for claim_id in presends[audit_id]["claim_ids"]:
            latest_attempt_by_claim[claim_id] = attempt

    if require_complete_run:
        for audit_id in pre_send_order:
            attempt = attempts[audit_id]
            if attempt["pre_send"]["run_id"] != require_complete_run:
                continue
            if attempt["incomplete"]:
                fail(f"incomplete audit sequence: {audit_id}")
            if attempt["unresolved"]:
                fail(f"unresolved audit sequence: {audit_id}")

    return {
        "presends": presends,
        "pre_send_order": pre_send_order,
        "results": results,
        "verifications": verifications,
        "reconciliations": reconciliations,
        "reconciliations_by_audit": reconciliations_by_audit,
        "attempts": attempts,
        "latest_attempt_by_claim": latest_attempt_by_claim,
    }

def validate_url(value):
    if not isinstance(value, str) or not value:
        fail("missing profile URL")
    if PROFILE_URL_RE.fullmatch(value) is None:
        fail(f"invalid canonical Muso profile URL: {value}")


def validate_skipped_counts(value):
    if not isinstance(value, dict):
        fail("skipped_counts must be an object")
    normalized = {}
    for reason in sorted(value):
        count = value[reason]
        if not isinstance(reason, str) or reason not in ALLOWED_SKIPPED_REASONS:
            fail("skipped_counts contains an unsupported reason key")
        if isinstance(count, bool) or not isinstance(count, int) or count < 0:
            fail(f"skipped_counts.{reason} must be a nonnegative integer")
        normalized[reason] = count
    return normalized


def validate_manifest(manifest, rows, now, max_age):
    required = {
        "schema_version", "run_id", "captured_at", "revalidated_at",
        "skipped_counts", "recipients",
    }
    missing = sorted(required - set(manifest))
    if missing:
        fail(f"malformed manifest missing: {', '.join(missing)}")
    if manifest["schema_version"] != 1:
        fail("unsupported manifest schema_version")
    validate_run_id(manifest["run_id"])
    validate_skipped_counts(manifest["skipped_counts"])
    parse_utc(manifest["captured_at"], "captured_at")
    revalidated = parse_utc(manifest["revalidated_at"], "revalidated_at")
    age = (now - revalidated).total_seconds()
    if age < -5 or age > max_age:
        fail(f"live revalidation is stale or future-dated: age={age:.0f}s")
    recipients = manifest["recipients"]
    if not isinstance(recipients, list):
        fail("recipients must be an array")

    ledger_state = validate_ledger(rows, require_complete_run=None)
    seen_recipients = set()
    seen_claims = {}

    for recipient in recipients:
        if not isinstance(recipient, dict):
            fail("recipient entry must be an object")
        rid = recipient.get("recipient_id")
        canonical_text(rid, "recipient_id")
        if rid in seen_recipients:
            fail(f"duplicate recipient: {rid}")
        seen_recipients.add(rid)
        canonical_text(recipient.get("recipient_name"), "recipient_name", required=False)
        if recipient.get("mapping_verified") is not True:
            fail(f"recipient-to-claim mapping is not verified: {rid}")
        route = recipient.get("route")
        if route not in ALLOWED_ROUTES:
            fail(f"invalid route for recipient: {rid}")
        # One rule for every surface. The manifest, the plan builder and the
        # plan loader all call validate_route_destination, so a destination
        # accepted in one place cannot be refused in another - the drift that
        # let padded values through on one route after the other was fixed.
        if route == "intercom_existing":
            if recipient.get("relevant_conversation_verified") is not True:
                fail(f"Intercom conversation relevance is not verified: {rid}")
            validate_route_destination(
                recipient, route, f"Intercom conversation relevance is not verified: {rid}"
            )
        else:
            validate_route_destination(
                recipient, route, f"support email route is malformed: {rid}"
            )
        claims = recipient.get("claims")
        if not isinstance(claims, list) or not claims:
            fail(f"recipient has no claims: {rid}")
        for claim in claims:
            if not isinstance(claim, dict):
                fail(f"claim entry is malformed for recipient: {rid}")
            cid = claim.get("claim_id")
            canonical_text(cid, "claim_id")
            if cid in seen_claims:
                other = seen_claims[cid]
                if other != rid:
                    fail(f"claim-to-recipient ambiguity: {cid}")
                fail(f"duplicate claim id: {cid}")
            seen_claims[cid] = rid
            if claim.get("status") != "pending":
                fail(f"claim is not pending: {cid}")
            for field in (
                "profile_id", "snapshot_profile_id", "live_profile_id",
                "snapshot_team_id", "live_team_id",
            ):
                canonical_text(claim.get(field), f"{field} for {cid}")
            if claim["snapshot_profile_id"] != claim["live_profile_id"] or (
                claim["profile_id"] != claim["live_profile_id"]
            ):
                fail(f"profile mismatch: {cid}")
            if claim["snapshot_team_id"] != claim["live_team_id"]:
                fail(f"team mismatch: {cid}")
            canonical_text(claim.get("profile_name"), f"profile_name for {cid}")
            validate_url(claim.get("profile_url"))
            claim_time = parse_utc(claim.get("revalidated_at"), f"claim {cid} revalidated_at")
            claim["_revalidated_dt"] = claim_time
            claim_age = (now - claim_time).total_seconds()
            if claim_age < -5 or claim_age > max_age:
                fail(f"claim revalidation is stale or future-dated: {cid}")
            if "excluded_case_flags" not in claim or not isinstance(
                claim["excluded_case_flags"], list
            ):
                fail(f"excluded_case_flags must be a present list: {cid}")
            if claim["excluded_case_flags"]:
                fail(f"excluded-case flag present: {cid}")
            latest_attempt = ledger_state["latest_attempt_by_claim"].get(cid)
            if claim.get("prior_verified_delivery") is not False or (
                latest_attempt is not None and latest_attempt["delivered"]
            ):
                fail(f"prior verified delivery exists: {cid}")
            if latest_attempt is not None and not latest_attempt["retryable"]:
                fail(f"latest outreach attempt is active or unresolved: {cid}")
            kinds = claim.get("evidence_kinds")
            if not isinstance(kinds, list) or not kinds or len(kinds) != len(set(kinds)):
                fail(f"evidence_kinds must be non-empty and unique: {cid}")
            unknown = sorted(set(kinds) - set(ALLOWED_EVIDENCE))
            if unknown:
                fail(f"unsupported evidence kind for {cid}: {', '.join(unknown)}")
    return recipients


def render_recipient(recipient, template):
    blocks = []
    for claim in sorted(recipient["claims"], key=lambda item: item["claim_id"]):
        evidence = "\n".join(
            f"- {ALLOWED_EVIDENCE[kind]}" for kind in sorted(claim["evidence_kinds"])
        )
        blocks.append(
            f"Claim {claim['claim_id']} - {claim['profile_name']}\n"
            f"{claim['profile_url']}\n"
            f"{evidence}"
        )
    count = len(recipient["claims"])
    message = template.format(
        recipient_name=recipient.get("recipient_name") or "there",
        claim_plural="s" if count != 1 else "",
        claim_object="these claims" if count != 1 else "this claim",
        claim_blocks="\n\n".join(blocks),
        pending_sentence=(
            "These claims will stay pending while we review your evidence."
            if count != 1 else
            "This claim will stay pending while we review your evidence."
        ),
    )
    return message.strip() + "\n"


def communication_subject(claim_count):
    return (
        "Evidence needed for your Muso profile claims"
        if claim_count != 1 else
        "Evidence needed for your Muso profile claim"
    )


def oldest_revalidated_at(manifest, recipients):
    """The earliest revalidation instant anywhere in this plan, as a Z string."""
    oldest = parse_utc(manifest["revalidated_at"], "revalidated_at")
    for recipient in recipients:
        for claim in recipient["claims"]:
            claim_time = claim.get("_revalidated_dt")
            if claim_time is not None and claim_time < oldest:
                oldest = claim_time
    return oldest.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def canonical_text(value, label, required=True):
    """A user-supplied string in CANONICAL form: present, non-empty, unpadded.

    Every field this guards is copied verbatim into the immutable plan, the
    deterministic communication identity, or the customer-facing message.
    Surrounding whitespace is invisible in almost every rendering, survives all
    three, and is otherwise only discovered at provider time - after pre_send
    is committed and the claim is stranded behind an active attempt. Reject it
    where it enters, once, for every field, rather than per reported instance.
    """
    if value is None and not required:
        return None
    if not isinstance(value, str) or not value or value != value.strip():
        fail(f"{label} must be a non-empty string without surrounding whitespace")
    return value


def route_destination(source, route):
    """The address this route actually sends to, or None when absent."""
    field = "intercom_conversation_id" if route == "intercom_existing" else "recipient_email"
    return source.get(field)


def validate_route_destination(source, route, label):
    """The same destination rules the manifest enforces, applied to a plan.

    The plan is what the sending workflow reads, so a destination that only the
    manifest checked can be reintroduced by editing the plan.
    """
    destination = route_destination(source, route)
    if route == "intercom_existing":
        # Same padding rule the email path uses: " 12345 " is copied verbatim
        # into the immutable plan and the provider can only reject it once
        # pre_send is committed.
        if not isinstance(destination, str) or CONVERSATION_ID_RE.fullmatch(destination) is None:
            fail(f"{label} has a malformed destination")
        if source.get("recipient_email"):
            fail(f"{label} has a malformed destination")
    else:
        if not isinstance(destination, str) or not is_actionable_email(destination):
            fail(f"{label} has a malformed destination")
        if source.get("intercom_conversation_id"):
            fail(f"{label} has a malformed destination")

    return destination


def deterministic_communication_id(run_id, recipient_id, claim_ids, route, content_hash, destination):
    # The destination is part of the identity. content_hash covers only the
    # subject and body, so without this an edited plan could point a
    # byte-identical message at a different address and every integrity value
    # would still agree, disclosing one customer's claims to another.
    fields = {
        "claim_ids": claim_ids,
        "content_hash": content_hash,
        "destination": destination,
        "recipient_id": recipient_id,
        "route": route,
        "run_id": run_id,
    }
    canonical = json.dumps(fields, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return hashlib.sha256(canonical.encode("ascii")).hexdigest()


def deterministic_attempt_audit_id(communication_id, attempt_number):
    fields = {
        "attempt_number": attempt_number,
        "communication_id": communication_id,
    }
    canonical = json.dumps(fields, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return hashlib.sha256(canonical.encode("ascii")).hexdigest()


def cmd_plan(args):
    manifest = load_json(args.manifest)
    validate_run_id(manifest.get("run_id"))
    with state_lock():
        rows = load_ledger(args.ledger)
        plan_path = prepare_plan_path(manifest["run_id"], args.output)
        manifest_rows = rows
        if os.path.lexists(plan_path):
            manifest_rows = [
                row for row in rows
                if row.get("run_id") != manifest["run_id"]
            ]
        now = parse_utc(args.now, "now") if args.now else datetime.now(timezone.utc)
        recipients = validate_manifest(
            manifest, manifest_rows, now, args.max_revalidation_age_seconds
        )
        try:
            template = Path(args.template).read_text(encoding="utf-8")
        except OSError as exc:
            fail(f"cannot read template: {exc}")
        required_tokens = {
            "{recipient_name}", "{claim_plural}", "{claim_object}",
            "{claim_blocks}", "{pending_sentence}",
        }
        if not required_tokens.issubset(set(re.findall(r"\{[^}]+\}", template))):
            fail("message template is malformed")
        output = {
            "schema_version": 1,
            "run_id": manifest["run_id"],
            # Carried so reserve can re-apply the same freshness window this
            # command already enforced on the manifest. Without it, reserve
            # could act on a plan whose live revalidation had since expired.
            "revalidated_at": manifest["revalidated_at"],
            # The FLOOR of freshness for this plan: the oldest of the root
            # revalidation and every claim's own. Planning validates each claim
            # separately, so the root alone understates real staleness - a
            # claim already 299s old at planning is 499s old 200s later, while
            # the root still reads 200s.
            "oldest_revalidated_at": oldest_revalidated_at(manifest, recipients),
            # The window this plan was VALIDATED with. Persisted so reserve
            # enforces the planner's limit rather than whatever it is handed:
            # a freshness gate a caller can widen is not a gate.
            "max_revalidation_age_seconds": args.max_revalidation_age_seconds,
            "skipped_counts": validate_skipped_counts(manifest["skipped_counts"]),
            "communications": [],
        }
        for recipient in recipients:
            message = render_recipient(recipient, template)
            claim_ids = sorted(claim["claim_id"] for claim in recipient["claims"])
            subject = communication_subject(len(claim_ids))
            content_hash = hashlib.sha256(
                (subject + "\n" + message).encode("utf-8")
            ).hexdigest()
            communication_id = deterministic_communication_id(
                manifest["run_id"],
                recipient["recipient_id"],
                claim_ids,
                recipient["route"],
                content_hash,
                validate_route_destination(
                    recipient, recipient["route"], f"recipient {recipient['recipient_id']}"
                ),
            )
            output["communications"].append({
                "communication_id": communication_id,
                "subject": subject,
                "recipient_id": recipient["recipient_id"],
                "route": recipient["route"],
                "intercom_conversation_id": recipient.get("intercom_conversation_id"),
                "recipient_email": recipient.get("recipient_email"),
                "claim_ids": claim_ids,
                "content_hash": content_hash,
                "message": message,
            })
        output["communications"].sort(key=lambda item: item["recipient_id"])
        encoded = json.dumps(output, indent=2, sort_keys=True) + "\n"
        atomic_write_plan(plan_path, encoded)
    sys.stdout.write(json.dumps({"communications_planned": len(output["communications"])},
                                sort_keys=True) + "\n")


def append_ledger_row(path, row):
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n")
        handle.flush()
        os.fsync(handle.fileno())


def load_private_plan(value):
    supplied = Path(value)
    parts = supplied.parts
    if (
        len(parts) != 4
        or parts[0] != "state"
        or parts[1] != "runs"
        or parts[3] != "plan.json"
    ):
        fail("plan path must be exactly state/runs/<run_id>/plan.json")
    run_id = validate_run_id(parts[2])
    expected = RUNS_RELATIVE_PATH / run_id / "plan.json"
    if supplied != expected:
        fail(f"plan path must be exactly {expected.as_posix()}")
    state_dir = require_mode(APPLIED_SKILL_DIR / "state", 0o700, "directory")
    runs_dir = require_mode(state_dir / "runs", 0o700, "directory")
    run_dir = require_mode(runs_dir / run_id, 0o700, "directory")
    path = require_mode(run_dir / "plan.json", 0o600, "file")
    try:
        plan = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"malformed private plan: {exc}")
    if not isinstance(plan, dict) or plan.get("schema_version") != 1:
        fail("malformed private plan")
    if plan.get("run_id") != run_id:
        fail("private plan run_id does not match its path")
    parse_utc(plan.get("revalidated_at"), "private plan revalidated_at")
    parse_utc(plan.get("oldest_revalidated_at"), "private plan oldest_revalidated_at")
    planned_age = plan.get("max_revalidation_age_seconds")
    if not isinstance(planned_age, int) or isinstance(planned_age, bool) or planned_age <= 0:
        fail("private plan max_revalidation_age_seconds must be a positive integer")
    plan["skipped_counts"] = validate_skipped_counts(plan.get("skipped_counts"))
    communications = plan.get("communications")
    if not isinstance(communications, list):
        fail("private plan communications must be an array")
    seen_recipients = set()
    seen_communications = set()
    for communication in communications:
        if not isinstance(communication, dict):
            fail("malformed planned communication")
        recipient_id = communication.get("recipient_id")
        communication_id = communication.get("communication_id")
        claim_ids = communication.get("claim_ids")
        route = communication.get("route")
        subject = communication.get("subject")
        message = communication.get("message")
        canonical_text(recipient_id, "planned recipient_id")
        if recipient_id in seen_recipients:
            fail(f"duplicate planned recipient: {recipient_id}")
        seen_recipients.add(recipient_id)
        if (
            not isinstance(communication_id, str)
            or communication_id in seen_communications
        ):
            fail("invalid or duplicate planned communication_id")
        seen_communications.add(communication_id)
        if not isinstance(claim_ids, list) or not claim_ids:
            fail(f"invalid planned claim_ids: {recipient_id}")
        for item in claim_ids:
            canonical_text(item, f"planned claim_id for {recipient_id}")
        if claim_ids != sorted(set(claim_ids)):
            fail(f"invalid planned claim_ids: {recipient_id}")
        if route not in ALLOWED_ROUTES:
            fail(f"invalid planned route: {recipient_id}")
        if subject != communication_subject(len(claim_ids)):
            fail(f"invalid planned subject: {recipient_id}")
        if not isinstance(message, str) or not message:
            fail(f"invalid planned message: {recipient_id}")
        content_hash = hashlib.sha256(
            (subject + "\n" + message).encode("utf-8")
        ).hexdigest()
        if communication.get("content_hash") != content_hash:
            fail(f"planned content hash mismatch: {recipient_id}")
        expected_communication = deterministic_communication_id(
            run_id, recipient_id, claim_ids, route, content_hash,
            validate_route_destination(
                communication, route, f"planned communication {recipient_id}"
            ),
        )
        if communication_id != expected_communication:
            fail(f"planned communication_id mismatch: {recipient_id}")
    return plan


def cmd_reserve(args):
    with state_lock():
        plan = load_private_plan(args.plan)
        # Re-apply the freshness window cmd_plan enforced on the manifest. A
        # plan is a snapshot of live eligibility, so reserving from a stale one
        # can contact a customer whose claim was resolved or reassigned in the
        # meantime. Same knob and same default as the plan gate: this command
        # inherits that policy rather than inventing a second one.
        now = parse_utc(args.now, "now") if args.now else datetime.now(timezone.utc)
        # Measure from the FLOOR, not the root: planning validated each claim
        # separately, so the oldest of them is the real age of this plan's data.
        revalidated = min(
            parse_utc(plan["revalidated_at"], "private plan revalidated_at"),
            parse_utc(plan["oldest_revalidated_at"], "private plan oldest_revalidated_at"),
        )
        # The plan's own limit is the ceiling. A reserve-time value may only
        # NARROW it, never widen it, or passing a large number would disable
        # the check entirely.
        max_age = min(plan["max_revalidation_age_seconds"], args.max_revalidation_age_seconds)
        age = (now - revalidated).total_seconds()
        if age < -5 or age > max_age:
            fail(f"private plan live revalidation is stale or future-dated: age={age:.0f}s")
        if not plan["communications"]:
            fail("cannot reserve from a no-op plan")
        matches = [
            communication
            for communication in plan["communications"]
            if communication["recipient_id"] == args.recipient_id
        ]
        if len(matches) != 1:
            fail("recipient must match exactly one planned communication")
        communication = matches[0]
        path = ensure_ledger(args.ledger)
        rows = load_ledger(args.ledger)
        ledger_state = validate_ledger(rows, require_complete_run=None)
        for claim_id in communication["claim_ids"]:
            latest = ledger_state["latest_attempt_by_claim"].get(claim_id)
            if latest is None or latest["retryable"]:
                continue
            if latest["delivered"]:
                fail(f"claim already delivered: {claim_id}")
            fail(f"claim already has an active attempt: {claim_id}")
        prior_attempt_numbers = [
            attempt["pre_send"]["attempt_number"]
            for attempt in ledger_state["attempts"].values()
            if attempt["pre_send"]["communication_id"] == communication["communication_id"]
        ]
        attempt_number = max(prior_attempt_numbers, default=0) + 1
        audit_id = deterministic_attempt_audit_id(
            communication["communication_id"], attempt_number
        )
        timestamp = args.now or datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        parse_utc(timestamp, "reservation timestamp")
        row = {
            "schema_version": 1,
            "event": "pre_send",
            "run_id": plan["run_id"],
            "communication_id": communication["communication_id"],
            "attempt_number": attempt_number,
            "audit_id": audit_id,
            "timestamp": timestamp,
            "recipient_id": communication["recipient_id"],
            "claim_ids": communication["claim_ids"],
            "route": communication["route"],
            "content_hash": communication["content_hash"],
        }
        validate_ledger(rows + [row], require_complete_run=None)
        append_ledger_row(path, row)
    sys.stdout.write(json.dumps({
        "attempt_number": row["attempt_number"],
        "audit_id": row["audit_id"],
        "claims_reserved": len(row["claim_ids"]),
        "communication_id": row["communication_id"],
        "reservations": 1,
    }, sort_keys=True) + "\n")


def cmd_append(args):
    with state_lock():
        path = ensure_ledger(args.ledger)
        rows = load_ledger(args.ledger)
        try:
            row = json.loads(args.row_json)
        except json.JSONDecodeError as exc:
            fail(f"malformed row JSON: {exc}")
        if isinstance(row, dict) and row.get("event") == "pre_send":
            fail("pre_send must be created with reserve")
        validate_ledger(rows + [row], require_complete_run=None)
        append_ledger_row(path, row)


def cmd_validate(args):
    with state_lock():
        rows = load_ledger(args.ledger)
        validate_ledger(rows, require_complete_run=args.require_complete_run)
    sys.stdout.write(json.dumps({"ok": True, "rows": len(rows)}) + "\n")


def summary_attempt_status(attempt):
    if attempt["incomplete"]:
        return "incomplete"
    if attempt["delivered"]:
        return "delivered"
    latest = attempt["latest_reconciliation"]
    if (
        latest is not None and latest.get("result") == "not_delivered"
    ) or attempt["verification"].get("verified_status") == "not_delivered":
        return "not_delivered"
    return "unknown"


def summary_counts(rows, plan, run_id):
    validate_run_id(run_id)
    if plan.get("run_id") != run_id:
        fail("summary run_id does not match private plan")
    state = validate_ledger(rows, require_complete_run=None)
    run_attempts = [
        attempt for attempt in state["attempts"].values()
        if attempt["pre_send"]["run_id"] == run_id
    ]
    status_counts = {
        "delivered": 0,
        "not_delivered": 0,
        "unknown": 0,
        "incomplete": 0,
    }
    route_counts = {route: 0 for route in sorted(ALLOWED_ROUTES)}
    delivered_recipients = set()
    delivered_claims = set()
    for attempt in run_attempts:
        status_value = summary_attempt_status(attempt)
        status_counts[status_value] += 1
        route_counts[attempt["pre_send"]["route"]] += 1
        if status_value == "delivered":
            delivered_recipients.add(attempt["pre_send"]["recipient_id"])
            delivered_claims.update(attempt["pre_send"]["claim_ids"])
    return {
        "delivered_customers": len(delivered_recipients),
        "delivered_claims": len(delivered_claims),
        "per_route_attempts": route_counts,
        "delivered_attempts": status_counts["delivered"],
        "not_delivered_attempts": status_counts["not_delivered"],
        "unknown_attempts": status_counts["unknown"],
        "incomplete_attempts": status_counts["incomplete"],
        "skipped_counts": validate_skipped_counts(plan["skipped_counts"]),
    }


def cmd_summary(args):
    with state_lock():
        plan = load_private_plan(args.plan)
        if plan["run_id"] != args.run_id:
            fail("summary run_id does not match private plan")
        rows = load_ledger(args.ledger)
        summary = summary_counts(rows, plan, args.run_id)
    sys.stdout.write(json.dumps(summary, sort_keys=True, separators=(",", ":")) + "\n")


def positive_int(value):
    """An argparse type for any parameter that BOUNDS a guard.

    Zero or negative never tightens such a bound, it disables the guard or
    strands the run: `--max-revalidation-age-seconds 0` builds a plan that
    load_private_plan then rejects, and the run id cannot be reused because the
    plan bytes differ. Rejecting at PARSE time means nothing is written first.
    Same defect class as UVN_REVERSAL_WINDOW_DAYS on hydra #917.
    """
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        raise argparse.ArgumentTypeError(f"must be an integer, got {value!r}")
    if parsed <= 0:
        raise argparse.ArgumentTypeError(f"must be a positive integer, got {parsed}")
    return parsed


def build_parser():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    plan = sub.add_parser("plan")
    plan.add_argument("--manifest", required=True)
    plan.add_argument("--ledger", default=LEDGER_RELATIVE_PATH.as_posix())
    plan.add_argument("--template", required=True)
    plan.add_argument("--output", help="must equal state/runs/<run_id>/plan.json")
    plan.add_argument("--now", help="fixed UTC time for hermetic testing")
    plan.add_argument("--max-revalidation-age-seconds", type=positive_int, default=300)
    plan.set_defaults(func=cmd_plan)
    reserve = sub.add_parser("reserve")
    reserve.add_argument("--plan", required=True)
    reserve.add_argument("--recipient-id", required=True)
    reserve.add_argument("--ledger", default=LEDGER_RELATIVE_PATH.as_posix())
    reserve.add_argument("--max-revalidation-age-seconds", type=positive_int, default=300)
    reserve.add_argument("--now", help="fixed UTC time for hermetic testing")
    reserve.set_defaults(func=cmd_reserve)
    append = sub.add_parser("append-row")
    append.add_argument("--ledger", default=LEDGER_RELATIVE_PATH.as_posix())
    append.add_argument("--row-json", required=True)
    append.set_defaults(func=cmd_append)
    validate = sub.add_parser("validate-ledger")
    validate.add_argument("--ledger", default=LEDGER_RELATIVE_PATH.as_posix())
    validate.add_argument("--require-complete-run")
    validate.set_defaults(func=cmd_validate)
    summary = sub.add_parser("summary")
    summary.add_argument("--plan", required=True)
    summary.add_argument("--run-id", required=True)
    summary.add_argument("--ledger", default=LEDGER_RELATIVE_PATH.as_posix())
    summary.set_defaults(func=cmd_summary)
    return parser


def main():
    try:
        args = build_parser().parse_args()
        args.func(args)
    except ValidationError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
