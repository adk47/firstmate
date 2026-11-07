#!/usr/bin/env python3
"""The copy: ONE fixed line per (request type, state), and the rules that keep it honest.

Source of truth: `policies/request-status-lines.json`. Every line is a single sentence or two
that says WHERE THE REQUEST IS and nothing else. That is a hard rule, not a style note, because
these lines go to people who already suspect us:

  * **never a reason, score, band, flag or rule name** — the reviewer's reasoning and the fraud
    lens's view never leave the store (captain 10-29: keep the score, never disclose it);
  * **never a date promise** ("by Friday", "within 7 days") — the only clock an approved line may
    name is one a process actually enforces, and none does yet;
  * **never a promise about the outcome** ("you will be credited", "your page is deleted") —
    the decline line says a request is closed when the information was not enough, and the
    erasure ack says what happens next, not what will be deleted;
  * **band-invariant**: the same state produces the same bytes for every user, so no line can
    vary with a score. There are no per-user variables at all (see VARIABLES).

Lines that are already approved verbatim elsewhere are CARRIED, not retyped: they name their
source and must match it byte for byte (`scripts/check-request-status-lines.py` in PR
Validation compares both sides):

  * the decline line -> `plugins/intercom/src/answer-bank.ts#declined`
  * the erasure ack -> `workspaces/support/reference/gdpr-erasure-requests.md`
    (`<!-- approved: gdpr-ack-v2-1101 -->`, ruled 2026-11-01)

Every other line ships `"enabled": false` with `"review": "pending-fable-r5"`. A line is sent
only when `enabled` is true AND it carries a non-empty `approval_ref`; the CI guard refuses a
file where those two disagree, so "flip the copy on" is always a reviewable one-line change.
"""
from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

POLICY_PATH = "/opt/hydra/policies/request-status-lines.json"
REPO_POLICY = str(Path(__file__).resolve().parents[2] / "policies" / "request-status-lines.json")


def default_policy_path() -> str:
    """The deployed copy on node-8; the repo copy on a workstation or inside CI."""
    return POLICY_PATH if os.path.exists(POLICY_PATH) else REPO_POLICY
STATES = ("received", "verifying", "need_you", "decided", "waiting")
TYPES = ("credit", "claim", "merge", "erasure", "refund")
CHANNELS = ("bell", "intercom", "email")

# No per-user substitution: a line that names a fact we did not measure would be a claim, and
# nothing customer- or agent-authored may ever reach a status line. `{date}` is the ONE variable,
# and it is only ever the request's own arrival date (measured, never a promise).
VARIABLES: tuple[str, ...] = ("date",)

# Words a status line may never contain (band-invariance + "never a reason / score / promise").
#
# The deadline patterns are deliberately WIDE. A date promise is the one thing the policy forbids
# outright (no process enforces it), so the gate must not be evadable by writing the number out:
# `within 2 days` was banned while `within two days` and `by next Friday` validated clean, which
# let an editor enable a non-verbatim line with an approval ref and ship a promise the policy
# forbids. Verbatim approved blocks are exempt from this gate (they are pinned to their source),
# which is why the erasure ack's own "within one month of today" still validates.
# A count is ANY short run of words before a time unit, not a list of the numbers we thought of.
# Enumerating them (one..twelve) left `within thirteen days` and `in twenty days` validating clean,
# which is the same evasion one number further out. The run is bounded so the pattern cannot walk
# across a sentence, and the unit word is what makes it a deadline rather than ordinary prose.
_COUNT = r"(?:[a-z][a-z'-]*\s+){0,4}"
_UNIT = r"(?:business |working |calendar )?(?:day|hour|week|month|year)s?"
_NUM = r"(?:\d+|a|an|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)"
BANNED = (
    r"\b(reason|because|due to|score|risk|band|flag|flagged|watchlist|fraud|hold|held|"
    r"suspicious|manual review|rule|threshold|priority|guarantee\w*|promise\w*|"
    rf"within {_COUNT}{_UNIT}|"
    rf"in {_COUNT}{_UNIT}|"
    rf"{_NUM} {_UNIT}" + r"s?\b|"
    r"by (next |this |the end of )?(mon|tues|wednes|thurs|fri|satur|sun)day|"
    r"by (next|this|the end of) (week|month|year)|"
    r"next (week|month|year)|tomorrow|end of (the )?(day|week|month))\b",
)
BANNED_RE = re.compile("|".join(BANNED), re.I)
# Anything that would leak an internal surface or a marketing channel into a status line.
INTERNAL_RE = re.compile(r"(slack|clickup|notion|intercom\.io|klaviyo|jira|zendesk|/[a-z0-9_-]+\.(sh|py)\b)", re.I)
PLACEHOLDER_RE = re.compile(r"\{[^}]*\}")


class PolicyError(RuntimeError):
    pass


@dataclass(frozen=True)
class Line:
    key: str                # "<type>/<state>"
    text: str
    enabled: bool
    review: str = ""
    approval_ref: str = ""
    source: str = ""
    verbatim: bool = False
    slot_required: bool = False
    slots: dict[str, str] = None            # type: ignore[assignment]
    gap_fill: bool = False                   # may fill a gap another sender owns (off unless reviewed)

    def __post_init__(self) -> None:
        if self.slots is None:
            object.__setattr__(self, "slots", {})


def load(path: str = "") -> dict[str, Any]:
    path = path or default_policy_path()
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError) as exc:
        raise PolicyError(f"copy policy unreadable: {exc}") from exc
    if not isinstance(doc, dict) or not isinstance(doc.get("lines"), dict):
        raise PolicyError("copy policy has no `lines` block")
    return doc


def _mk(key: str, got: dict[str, Any]) -> Line:
    return Line(key=key, text=str(got["text"]), enabled=bool(got.get("enabled")),
                review=str(got.get("review") or ""), approval_ref=str(got.get("approval_ref") or ""),
                source=str(got.get("source") or ""), verbatim=bool(got.get("verbatim")),
                slot_required=bool(got.get("slot_required")), gap_fill=bool(got.get("gap_fill")),
                slots={str(k): str(v) for k, v in (got.get("slots") or {}).items()})


def line(policy: dict[str, Any], typ: str, state: str) -> Line | None:
    got = ((policy.get("lines") or {}).get(typ) or {}).get(state)
    if not isinstance(got, dict) or not str(got.get("text") or "").strip():
        return None
    return _mk(f"{typ}/{state}", got)


def digest_line(policy: dict[str, Any]) -> Line | None:
    got = (policy.get("lines") or {}).get("digest")
    if not isinstance(got, dict) or not str(got.get("text") or "").strip():
        return None
    return _mk("digest", got)


def render(l: Line, facts: dict[str, Any]) -> tuple[str, str]:
    """(the exact bytes to send, '' ) or ('', why nothing may be sent).

    A line with fixed slots is sent whole or not at all: an approved block with the wrong slot
    (or no slot) is a DIFFERENT letter, so an unknown slot is a hold, never a guess.
    """
    text = l.text
    if l.slot_required:
        slot = str(facts.get("slot") or "")
        extra = l.slots.get(slot, "") if slot else ""
        if not extra:
            return "", f"slot_unknown:{slot or 'none'}"
        text = f"{text}\n\n{extra}"
    if "{date}" in text:
        when = str(facts.get("date") or "").strip()
        if not when:
            return "", "date_unknown"
        text = text.replace("{date}", when)
    return text, ""


def channel_conf(policy: dict[str, Any], channel: str) -> dict[str, Any]:
    return dict(((policy.get("channels") or {}).get(channel) or {}))


def driver_enabled(policy: dict[str, Any]) -> bool:
    return bool(policy.get("enabled"))


def sendable(l: Line | None) -> bool:
    """A line may be sent only when it is enabled AND carries the approval it claims.

    A non-empty `approval_ref` is not the same as an approved one: the policy's own placeholders
    (`unapproved`, `pending`, `tbd`, ...) are non-empty, so an enabled line still carrying one is
    an unapproved line and must never go out.
    """
    if not (l and l.enabled):
        return False
    return l.approval_ref.strip().lower() not in APPROVAL_SENTINELS


# Every approved block this repo carries is bound to the ONE line it was approved FOR: the ref, the
# line key, the pinned-source name and the file the bytes come from. Matching "any pinned text" let
# a swap (the credit decline under the erasure ack's ref and vice versa) validate clean, and a
# data-erasure requester would receive the credit-decline letter the moment the lane went bright.
PINNED_BINDINGS: dict[str, tuple[str, str, str, str]] = {
    "answer-bank:declined": ("credit", "decided", "decline", "plugins/intercom/src/answer-bank.ts"),
    "gdpr-ack-v2-1101": ("erasure", "received", "erasure_ack",
                         "workspaces/support/reference/gdpr-erasure-requests.md"),
}

APPROVAL_SENTINELS = {"", "unapproved", "pending", "tbd", "todo", "none", "placeholder", "n/a"}


def validate(policy: dict[str, Any]) -> list[str]:
    """Every structural problem in one pass (CI guard + `request-comms check`)."""
    problems: list[str] = []
    lines = policy.get("lines") or {}
    pinned: dict[str, str] | None = None

    def pinned_texts() -> dict[str, str]:
        """The already-approved blocks, read once. Unreadable sources mean NOTHING is pinned, so
        every verbatim line fails below — the safe direction, and it says why."""
        nonlocal pinned
        if pinned is None:
            try:
                pinned = pinned_verbatim_texts()
            except Exception as exc:  # noqa: BLE001 — a missing source file is not an exemption
                problems.append(f"cannot read the pinned verbatim sources: {type(exc).__name__}: {exc}")
                pinned = {}
        return pinned
    if not isinstance(policy.get("enabled"), bool):
        problems.append("top-level `enabled` must be a boolean (the driver's own switch)")
    for typ in TYPES:
        block = lines.get(typ)
        if not isinstance(block, dict):
            problems.append(f"missing lines.{typ}")
            continue
        for state in STATES:
            got = block.get(state)
            if not isinstance(got, dict):
                problems.append(f"missing lines.{typ}.{state}")
                continue
            text = str(got.get("text") or "").strip()
            if not text:
                problems.append(f"lines.{typ}.{state}.text is empty")
                continue
            if not isinstance(got.get("enabled"), bool):
                problems.append(f"lines.{typ}.{state}.enabled must be a boolean")
            if got.get("enabled"):
                # `approval_ref: "pending"` is non-empty and not an approval: `sendable()` holds the
                # line, so a live tick left it unsent while the copy gate reported green. The two
                # judgements are now the same one.
                if str(got.get("approval_ref") or "").strip().lower() in APPROVAL_SENTINELS:
                    problems.append(f"lines.{typ}.{state} is enabled with no approval_ref "
                                    f"({got.get('approval_ref')!r} is a placeholder, not an approval)")
                if str(got.get("review") or "").startswith("pending"):
                    problems.append(f"lines.{typ}.{state} is enabled while its review is pending")
            if got.get("verbatim") and not str(got.get("source") or "").strip():
                problems.append(f"lines.{typ}.{state} is verbatim with no source")
            if got.get("verbatim") and str(got.get("source") or "").strip():
                # `verbatim: true` is a claim that this text IS an already-approved block, and it
                # is what waives the banned-wording check below (a made-up source carrying "Your
                # fraud score is 99." passed every gate before the pin). Now the pin is also
                # BOUND: this line must be the line that ref was approved for, and the bytes must
                # be that source's, so the decline and the erasure ack cannot be swapped.
                ref = str(got.get("approval_ref") or "").strip()
                binding = PINNED_BINDINGS.get(ref)
                if not binding:
                    problems.append(f"lines.{typ}.{state} is verbatim under {ref!r}, which is not a "
                                    f"pinned approved block (add it to lines.PINNED_BINDINGS)")
                else:
                    btyp, bstate, bname, bpath = binding
                    if (btyp, bstate) != (typ, state):
                        problems.append(f"lines.{typ}.{state} carries {ref}, which was approved for "
                                        f"{btyp}/{bstate}: approved copy is bound to its own line")
                    want = str(pinned_texts().get(bname, "")).strip()
                    if not want:
                        problems.append(f"cannot read the approved source for {ref} ({bname})")
                    elif text != want:
                        problems.append(f"lines.{typ}.{state} drifted from its approved source "
                                        f"({ref}): copy the sentence, never retype it")
                    src = str(got.get("source") or "")
                    if not src.startswith(bpath):
                        problems.append(f"lines.{typ}.{state} cites {src!r} but {ref} lives in {bpath}")
            slots = got.get("slots")
            pinned_slots = pinned_slot_texts()
            if got.get("slot_required"):
                if not isinstance(slots, dict) or not slots:
                    problems.append(f"lines.{typ}.{state} requires a slot but declares none")
                elif not all(str(v or "").strip() for v in slots.values()):
                    problems.append(f"lines.{typ}.{state} has an empty slot text")
                else:
                    for slot, val in slots.items():
                        slid = str(val or "").strip()
                        if not any(slid == p for p in pinned_slots):
                            problems.append(f"lines.{typ}.{state}.slots.{slot} matches no approved slot "
                                            f"text in the GDPR source (a slot is approved copy too)")
                        hit = BANNED_RE.search(slid) or INTERNAL_RE.search(slid)
                        if hit:
                            problems.append(f"lines.{typ}.{state}.slots.{slot} carries banned wording "
                                            f"{hit.group(0)!r}")
                        for var in PLACEHOLDER_RE.findall(slid):
                            if var.strip("{}") not in VARIABLES:
                                problems.append(f"lines.{typ}.{state}.slots.{slot} has an unapproved "
                                                f"placeholder {var}")
                if not got.get("verbatim"):
                    problems.append(f"lines.{typ}.{state} requires a slot but is not a verbatim approved block")
            elif slots:
                problems.append(f"lines.{typ}.{state} declares slots but not slot_required")
            if not got.get("verbatim"):
                hit = BANNED_RE.search(text)
                if hit:
                    problems.append(f"lines.{typ}.{state} carries banned wording {hit.group(0)!r}")
                hit = INTERNAL_RE.search(text)
                if hit:
                    problems.append(f"lines.{typ}.{state} names an internal surface {hit.group(0)!r}")
            for var in PLACEHOLDER_RE.findall(text):
                if var.strip("{}") not in VARIABLES:
                    problems.append(f"lines.{typ}.{state} has an unapproved placeholder {var}")
    dig = lines.get("digest")
    if not isinstance(dig, dict) or not str(dig.get("text") or "").strip():
        problems.append("missing lines.digest (the one-message-per-user-per-day digest line)")
    elif dig.get("verbatim"):
        # The digest is a roll-up we compose (count, titles), never a carried block from another
        # source, so `verbatim` here could only ever be a way to skip the wording gate. Without
        # this branch, `verbatim: true` + "Your fraud score is 99." validated clean.
        problems.append("lines.digest cannot be verbatim: it is composed here, not carried from an "
                        "approved source (drop the flag, or make the text a pinned block)")
    elif BANNED_RE.search(str(dig.get("text"))):
        problems.append("lines.digest carries banned wording")
    if isinstance(dig, dict) and str(dig.get("text") or "").strip():
        # The digest is a customer letter like any other, so it passes the same gate: an enabled
        # digest with no real approval (or a still-pending review) may not be sent, and its
        # placeholders are held to the same list. Without this, `enabled: true` + `approval_ref:
        # "unapproved"` passed validation and `sendable()` waved it through.
        if not isinstance(dig.get("enabled"), bool):
            problems.append("lines.digest.enabled must be a boolean")
        if dig.get("enabled"):
            if str(dig.get("approval_ref") or "").strip().lower() in APPROVAL_SENTINELS:
                problems.append("lines.digest is enabled with no real approval_ref")
            if str(dig.get("review") or "").startswith("pending"):
                problems.append("lines.digest is enabled while its review is pending")
        if not dig.get("verbatim"):
            hit = INTERNAL_RE.search(str(dig.get("text")))
            if hit:
                problems.append(f"lines.digest names an internal surface {hit.group(0)!r}")
        for var in PLACEHOLDER_RE.findall(str(dig.get("text") or "")):
            if var.strip("{}") not in VARIABLES:
                problems.append(f"lines.digest has an unapproved placeholder {var}")
    for ch in CHANNELS:
        conf = (policy.get("channels") or {}).get(ch)
        if not isinstance(conf, dict):
            problems.append(f"missing channels.{ch}")
            continue
        if not isinstance(conf.get("enabled"), bool):
            problems.append(f"channels.{ch}.enabled must be a boolean")
    keys = channel_conf(policy, "bell").get("workflow_keys") or {}
    if not isinstance(keys, dict):
        problems.append("channels.bell.workflow_keys must be an object (or absent)")
    else:
        from .routing import BELL_KEYS, bell_allowed_keys, bell_override_allowed  # noqa: PLC0415
        for k, v in keys.items():
            key = str(v or "").strip()
            if key not in BELL_KEYS:
                problems.append(f"channels.bell.workflow_keys.{k} is not one of the ten status bells: {v!r}")
                continue
            typ, _, state = str(k).partition("/")
            if not bell_override_allowed(typ, key, state):
                # Two ways to be wrong: a kind from another type (`credit/received ->
                # claim_approved` tells a credit requester their claim was approved), and a kind
                # of this type that this state cannot have (`credit/received ->
                # credit_status_approved` announces an approval the row does not contain).
                problems.append(f"channels.bell.workflow_keys.{k} names {key!r}, which {typ}/{state} "
                                f"cannot ring (allowed: {sorted(bell_allowed_keys(typ, state)) or 'none'})")
    if channel_conf(policy, "email").get("enabled"):
        keys = channel_conf(policy, "email").get("template_keys") or {}
        for typ in TYPES:
            if not str(keys.get(typ) or "").strip():
                problems.append(f"channels.email is enabled but has no template key for {typ}")
        # The gateway renders the template, so the only way the user reads the sentence we
        # approved is a template that renders `{{event.status_line}}`. Enabling the rung without
        # that promise is how a send-gateway template quietly substitutes other copy.
        if channel_conf(policy, "email").get("template_uses_line_text") is not True:
            problems.append("channels.email is enabled but its templates are not declared to render "
                            "the approved line (set template_uses_line_text: true)")
    return problems


def pinned_slot_texts(root: Path | None = None) -> set[str]:
    """The slot sentences approved in the GDPR source ("Fixed slots (pick, never edit)").

    A slot is appended to an enabled, approved block, so it is the same letter: an unpinned slot is
    copy nobody approved, and validating only "non-empty" let `Your fraud score is 99.` ride along
    with the approved ack.
    """
    root = root or Path(__file__).resolve().parents[2]
    text = (root / "workspaces/support/reference/gdpr-erasure-requests.md").read_text(encoding="utf-8")
    start = text.find("Fixed slots")
    if start < 0:
        return set()
    out: set[str] = set()
    block: list[str] = []
    for raw in text[start:].splitlines():
        s = raw.strip()
        if s.startswith(">"):
            block.append(s[1:].strip())
            continue
        if block:
            joined = " ".join(p for p in block if p)
            if joined:
                out.add(joined)
            block = []
        if s.startswith("**A claim is NOT required"):
            break
    if block:
        joined = " ".join(p for p in block if p)
        if joined:
            out.add(joined)
    return out


def pinned_verbatim_texts(repo_root: Path | None = None) -> dict[str, str]:
    """The already-approved texts this policy carries, read from their own source file.

    `decline` -> answer-bank.ts `id: "declined"`; `erasure_ack` -> the pinned v2 block. The CI
    guard compares both against the policy so the two can never drift. Wrapped source lines are
    joined with single spaces (the reference wraps for readability; the copy is the paragraph).
    """
    root = repo_root or Path(__file__).resolve().parents[2]
    out: dict[str, str] = {}
    bank = (root / "plugins/intercom/src/answer-bank.ts").read_text(encoding="utf-8")
    m = re.search(r'id:\s*"declined",(?:.|\n)*?text:\s*((?:\s*"[^"]*"\s*\+?)+)', bank)
    if m:
        out["decline"] = "".join(re.findall(r'"([^"]*)"', m.group(1)))
    ref = root / "workspaces/support/reference/gdpr-erasure-requests.md"
    text = ref.read_text(encoding="utf-8")
    marker = "<!-- approved: gdpr-ack-v2-1101 -->"
    start = text.find(marker)
    if start >= 0:
        # The block runs from the marker to the "Fixed slots" heading; each paragraph is one
        # (possibly wrapped) `>` quote and blank quoted lines separate paragraphs.
        body = text[start + len(marker):]
        paras: list[list[str]] = [[]]
        for raw in body.splitlines():
            s = raw.strip()
            if s.startswith("Fixed slots"):
                break
            if not s.startswith(">"):
                continue
            content = s[1:].strip()
            if content:
                paras[-1].append(content)
            elif paras[-1]:
                paras.append([])
        out["erasure_ack"] = "\n\n".join(" ".join(p) for p in paras if p)
    return out
